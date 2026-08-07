import argparse
import ftplib
import os
import ssl
import subprocess
import sys
import zipfile

from dotenv import load_dotenv

env_path = '/home/bcp_runner/.env'
load_dotenv(dotenv_path=env_path)

FTP_HOST = os.getenv("FTP_HOST")
FTP_USER = os.getenv("FTP_USER")
FTP_PASS = os.getenv("FTP_PASS")


class ImplicitFTP_TLS(ftplib.FTP_TLS):
    def ntransfercmd(self, cmd, rest=None):
        conn, size = ftplib.FTP.ntransfercmd(self, cmd, rest)
        if self._prot_p:
            conn = self.context.wrap_socket(
                conn,
                server_hostname=self.host,
                session=self.sock.session,
            )
        return conn, size

    def retrbinary(self, cmd, callback, blocksize=8192, rest=None):
        self.voidcmd('TYPE I')
        with self.transfercmd(cmd, rest) as conn:
            while True:
                data = conn.recv(blocksize)
                if not data:
                    break
                callback(data)
        return self.voidresp()


def _safe_resolve_local_path(raw_path: str) -> str:
    expanded = os.path.abspath(os.path.expanduser(raw_path))
    home = os.path.abspath(os.path.expanduser("~"))
    if os.path.commonpath([expanded, home]) != home:
        raise ValueError(f"❌ 本地路徑必須位於使用者家目錄底下: {raw_path} -> {expanded}")
    return expanded


def _extract_zip_with_password(
    zip_path: str,
    inner_filename: str,
    password_env_key: str,
    output_path: str,
):
    password = os.environ.get(password_env_key)
    if not password:
        raise RuntimeError(
            f"❌ 找不到環境變數 {password_env_key}，請確認 .env 裡有設這張表的 zip 密碼"
        )
    with open(output_path, "wb") as out_f:
        result = subprocess.run(
            ["unzip", "-P", password, "-p", zip_path, inner_filename],
            stdout=out_f,
            stderr=subprocess.PIPE,
            timeout=120,
        )
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="ignore")
        if "incorrect password" in stderr.lower() or "wrong password" in stderr.lower():
            raise RuntimeError(
                f"❌ zip 密碼錯誤（環境變數 {password_env_key}）: {os.path.basename(zip_path)}"
            )
        raise RuntimeError(f"❌ 解壓縮失敗: {stderr}")
    if os.path.getsize(output_path) == 0:
        raise RuntimeError(
            f"❌ 解壓縮結果是空的，請確認 zip 裡是否真的有 {inner_filename}: {os.path.basename(zip_path)}"
        )
    os.chmod(output_path, 0o600)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--remote-path",          default=None)
    parser.add_argument("--ftp-remote-dir",       default=None)
    parser.add_argument("--ftp-filename-prefix",  default=None)
    parser.add_argument("--local-path",           required=True)
    parser.add_argument("--zip-password-env-key", default=None)
    parser.add_argument("--zip-inner-filename",   default=None)
    parser.add_argument("--expected-part-count",  type=int, default=1)
    
    # 改為 Prefix + Ext 支援時間戳
    parser.add_argument("--multi-part-prefix",    default=None)
    parser.add_argument("--multi-part-ext",       default=None)
    
    parser.add_argument("--part-start",           default="1")
    parser.add_argument("--part-list",            default=None) 
    args = parser.parse_args()

    if not all([FTP_HOST, FTP_USER, FTP_PASS]):
        print("❌ FTP 連線資訊不完整", file=sys.stderr)
        sys.exit(1)

    # =========================================================
    # 解析多檔名清單 (parts_to_fetch)
    # =========================================================
    parts_to_fetch = []
    
    if args.part_list:
        parts_to_fetch = [p.strip() for p in args.part_list.split(",")]
        
        if args.expected_part_count > 1 and len(parts_to_fetch) != args.expected_part_count:
            print(f"❌ --part-list 數量 ({len(parts_to_fetch)}) 與 --expected-part-count ({args.expected_part_count}) 不符！", file=sys.stderr)
            sys.exit(1)
            
        args.expected_part_count = len(parts_to_fetch)
        
    elif args.expected_part_count > 1:
        start_val = str(args.part_start)
        if start_val.isdigit():
            start_num = int(start_val)
            parts_to_fetch = [str(start_num + i) for i in range(args.expected_part_count)]
        elif len(start_val) == 1 and start_val.isalpha():
            start_char = ord(start_val)
            parts_to_fetch = [chr(start_char + i) for i in range(args.expected_part_count)]
        else:
            print(f"❌ 不支援的 --part-start 格式: {start_val} (必須是數字或單一英文字母)", file=sys.stderr)
            sys.exit(1)

    is_multi_part = (args.expected_part_count > 1 and args.multi_part_prefix)

    if not is_multi_part:
        if not args.remote_path and not (args.ftp_remote_dir and args.ftp_filename_prefix):
            print("❌ 單檔模式必須提供 --remote-path，或同時提供 --ftp-remote-dir 與 --ftp-filename-prefix", file=sys.stderr)
            sys.exit(1)

    local_path = _safe_resolve_local_path(args.local_path)
    local_dir = os.path.dirname(local_path)
    os.makedirs(local_dir, mode=0o700, exist_ok=True)
    os.chmod(local_dir, 0o700)

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    remote_dir = None
    remote_file = None
    download_target_path = None
    tmp_path = None

    try:
        with ImplicitFTP_TLS(context=ctx) as ftp:
            ftp.connect(FTP_HOST)
            ftp.auth()
            ftp.prot_p()
            ftp.login(FTP_USER, FTP_PASS)
            ftp.set_pasv(True)

            if is_multi_part:
                remote_dir = args.ftp_remote_dir if args.ftp_remote_dir else "."
                if remote_dir != ".":
                    ftp.cwd(remote_dir)

                files_in_dir = set(os.path.basename(n) for n in ftp.nlst())
                missing = []
                part_files_mapping = {}

                # 檢查 parts_to_fetch 模糊比對
                for part in parts_to_fetch:
                    prefix = args.multi_part_prefix.format(part=part)
                    ext = args.multi_part_ext
                    
                    matches = [f for f in files_in_dir if f.startswith(prefix) and f.endswith(ext)]
                    if not matches:
                        missing.append(f"{prefix}*{ext}")
                    else:
                        # 找到多個相同 part，取名稱排序最後的一個 (通常是時間戳最新)
                        matched_file = sorted(matches)[-1]
                        part_files_mapping[part] = matched_file

                if missing:
                    print(f"⚠️ [暫停執行] 檔案尚未到齊！預期 {args.expected_part_count} 檔，缺少 {len(missing)} 檔。")
                    print(f"缺少的檔案包含: {missing[:3]}...")
                    print("✅ 乾淨退出，等待下一批次重試。")
                    sys.exit(99) 

                print(f"✅ 確認 {args.expected_part_count} 個切檔皆已抵達，準備下載與合併...")

                with open(local_path, "wb") as out_f:
                    for part in parts_to_fetch:
                        actual_remote_file = part_files_mapping[part]
                        tmp_part = local_path + f".part{part}"

                        with open(tmp_part, "wb") as tmp_f:
                            ftp.retrbinary(f"RETR {actual_remote_file}", tmp_f.write)

                        if args.zip_password_env_key:
                            target_inner = args.zip_inner_filename
                            if not target_inner:
                                with zipfile.ZipFile(tmp_part) as z:
                                    target_inner = z.namelist()[0]

                            ext_tmp = tmp_part + ".ext"
                            _extract_zip_with_password(tmp_part, target_inner, args.zip_password_env_key, ext_tmp)

                            with open(ext_tmp, "rb") as ef:
                                while True:
                                    chunk = ef.read(1024 * 1024 * 10)
                                    if not chunk: break
                                    out_f.write(chunk)
                            os.remove(ext_tmp)
                        else:
                            with open(tmp_part, "rb") as tf:
                                while True:
                                    chunk = tf.read(1024 * 1024 * 10)
                                    if not chunk: break
                                    out_f.write(chunk)

                        os.remove(tmp_part)
                        print(f"✅ 合併完成: {actual_remote_file}")

                print(f"全部合併完成: {local_path}")
                
            elif args.expected_part_count == 1 and args.ftp_remote_dir:
                ftp.cwd(args.ftp_remote_dir)
                names = [os.path.basename(n) for n in ftp.nlst()]
                matches = [n for n in names if n.startswith(args.ftp_filename_prefix)]
                if not matches:
                    raise RuntimeError(
                        f"❌ 在 {args.ftp_remote_dir} 找不到符合前綴 {args.ftp_filename_prefix} 的檔案"
                    )
                if len(matches) > 1:
                    print(f"⚠️ 找到 {len(matches)} 個符合的檔案，取檔名排序最後（最新）的一個: {matches}")
                remote_dir = args.ftp_remote_dir
                remote_file = sorted(matches)[-1]
            else:
                remote_dir = os.path.dirname(args.remote_path)
                remote_file = os.path.basename(args.remote_path)
                if remote_dir:
                    ftp.cwd(remote_dir)

            # 單檔模式下載邏輯
            if not is_multi_part:
                download_target_path = (
                    os.path.join(local_dir, remote_file)
                    if args.zip_password_env_key
                    else local_path
                )
                tmp_path = download_target_path + ".part"

                with open(tmp_path, "wb") as f:
                    ftp.retrbinary(f"RETR {remote_file}", f.write)

                os.chmod(tmp_path, 0o600)
                os.replace(tmp_path, download_target_path)
                print(f"✅ FTP 下載完成: {FTP_HOST}{remote_dir}/{remote_file} -> {download_target_path}")

                if args.zip_password_env_key:
                    try:
                        if args.zip_inner_filename:
                            target = args.zip_inner_filename
                        else:
                            with zipfile.ZipFile(download_target_path) as z:
                                names = z.namelist()
                            if len(names) != 1:
                                raise ValueError(
                                    f"zip 裡有多個檔案，請指定 zip_inner_filename: {names}"
                                )
                            target = names[0]

                        _extract_zip_with_password(
                            zip_path=download_target_path,
                            inner_filename=target,
                            password_env_key=args.zip_password_env_key,
                            output_path=local_path,
                        )
                        print(f"解壓縮完成: {local_path}")
                    finally:
                        if os.path.exists(download_target_path):
                            os.remove(download_target_path)
                            print(f"已刪除暫存 zip: {download_target_path}")

            try:
                ftp.quit()
            except Exception:
                pass

    except SystemExit:
        raise
    except Exception:
        if tmp_path and os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise

if __name__ == "__main__":
    main()
