import argparse
import os
import subprocess

from dotenv import load_dotenv
from dagster_pipes import open_dagster_pipes
import dotenv

env_path = '/home/bcp_runner/.env'
load_dotenv(dotenv_path=env_path)

DB_SERVER = os.getenv("DB_SERVER")
DB_NAME   = os.getenv("DB_NAME")
DB_USER   = os.getenv("DB_USER")
DB_PASS   = os.getenv("DB_PASS")

missing = [k for k, v in {
    "DB_SERVER": DB_SERVER,
    "DB_NAME": DB_NAME,
    "DB_USER": DB_USER,
    "DB_PASS": DB_PASS,
}.items() if not v]

if missing:
    raise EnvironmentError(f"缺少必要的環境變數: {', '.join(missing)}，請確認 .env 檔案是否正確設定")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input",      required=True)   # 要匯入的 CSV 路徑
    parser.add_argument("--target",     required=True)   # BCP 目標（view 或 table）
    parser.add_argument("--delimiter",  default="|")
    parser.add_argument("--error-log",  required=True)
    parser.add_argument("--encoding",   default=None)    # 新增 encoding 參數，預設不強制指定
    args = parser.parse_args()

    # 1. 組合基礎指令
    bcp_command = [
        "/opt/mssql-tools18/bin/bcp",
        f"{DB_NAME}.dbo.{args.target}", "in", args.input,
        "-S", DB_SERVER,
        "-U", DB_USER,
        "-P", DB_PASS,
    ]

    # 2. 判斷編碼：如果有明確指定 utf-8 就用 utf-8，否則一律照原本使用 -w
    if args.encoding and args.encoding.lower() == "utf-8":
        bcp_command.extend(["-c", "-C", "65001"])
    else:
        bcp_command.append("-w")

    # 3. 組合剩餘參數
    bcp_command.extend([
        "-t", args.delimiter,
        "-b", "50000",
        "-a", "16384",
        "-h", "TABLOCK",
        "-m", "100",
        "-u",
        "-e", args.error_log,
    ])

    with open_dagster_pipes() as pipes:
        if not os.path.exists(args.input):
            pipes.log.error(f"[VM1] <error> 匯入檔案不存在: {args.input}")
            raise FileNotFoundError(f"匯入檔案不存在: {args.input}")

        pipes.log.info(f"[VM1] <info> 開始 BCP 匯入: {args.input} → dbo.{args.target}")

        result = subprocess.run(
            bcp_command,
            capture_output=True,
            text=True,
        )

        if result.stdout:
            pipes.log.info(f"[BCP stdout]\n{result.stdout}")

        if result.returncode != 0:
            error_details = result.stderr
            error_log_file = args.error_log
            error_dir = os.path.dirname(error_log_file)

            if error_dir:
                os.makedirs(error_dir, exist_ok=True)

            if os.path.exists(error_log_file):
                os.remove(error_log_file)

            if os.path.exists(args.error_log):
                try:
                    with open(args.error_log, 'r', encoding='utf-16') as f:
                        error_details += f"\n{f.read()}"
                except UnicodeError:
                    with open(args.error_log, 'r', encoding='utf-8', errors='replace') as f:
                        error_details += f"\n{f.read()}"
            else:
                error_details += f"\n[注意] BCP 失敗，但並未產生 Error Log 檔案 ({args.error_log})。這通常是連線、權限或指令錯誤。"
            pipes.log.error(f"[VM1] <error> BCP 失敗:\n{error_details}")
            raise Exception(f"BCP 匯入失敗: {error_details}")

        pipes.log.info("[VM1] <info> BCP 匯入完成")
        pipes.report_asset_materialization(
            metadata={
                "source_file": os.path.basename(args.input),
                "target_table": f"dbo.{args.target}",
                "encoding_used": args.encoding if args.encoding else "utf-16 (default -w)",
            }
        )


if __name__ == "__main__":
    main()
