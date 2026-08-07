import argparse
import gzip
import os
import shutil
import subprocess
import sys
 
from dotenv import load_dotenv

env_path = '/home/bcp_runner/.env'
load_dotenv(dotenv_path=env_path)
 
 
def _safe_resolve_plaintext_path(raw_path: str) -> str:
    """展開 ~ 並確認結果路徑落在使用者家目錄底下，避免誤刪家目錄以外的檔案"""
    expanded = os.path.abspath(os.path.expanduser(raw_path))
    home = os.path.abspath(os.path.expanduser("~"))
    if os.path.commonpath([expanded, home]) != home:
        raise ValueError(f"❌ 明碼路徑必須位於使用者家目錄底下: {raw_path} -> {expanded}")
    return expanded
 
 
def _archive_with_zip_password(encrypted_path: str, archive_dir: str, password_env_key: str) -> str:
    """用系統 zip -P 把 encrypted_path 壓成密碼保護的 .zip，回傳封存後的完整路徑"""
    password = os.environ.get(password_env_key)
    if not password:
        raise RuntimeError(f"❌ 找不到環境變數 {password_env_key}，無法壓縮 {encrypted_path}")
 
    archive_filename = os.path.basename(encrypted_path) + ".zip"
    archive_path = os.path.join(archive_dir, archive_filename)
 
    result = subprocess.run(
        ["zip", "-j", "-P", password, archive_path, encrypted_path],
        capture_output=True,
        timeout=3600,
    )
    if result.returncode != 0:
        raise RuntimeError(f"❌ 壓縮失敗: {result.stderr.decode('utf-8', errors='ignore')}")
 
    return archive_path
 
 
def _archive_with_gzip(encrypted_path: str, archive_dir: str) -> str:
    """原本的封存方式：無密碼 gzip，維持不變"""
    archive_filename = os.path.basename(encrypted_path) + ".gz"
    archive_path = os.path.join(archive_dir, archive_filename)
    with open(encrypted_path, "rb") as f_in, gzip.open(archive_path, "wb") as f_out:
        shutil.copyfileobj(f_in, f_out)
    return archive_path
 
 
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plaintext-path", default=None)
    parser.add_argument("--encrypted-path", required=True)
    parser.add_argument("--archive-dir", required=True)
    parser.add_argument("--zip-password-env-key", default=None)
    args = parser.parse_args()
 
    # 1. 刪除明碼暫存檔（存在才刪，不存在不視為錯誤，避免重跑時卡住）
    if args.plaintext_path:
        plaintext_path = _safe_resolve_plaintext_path(args.plaintext_path)
        if os.path.exists(plaintext_path):
            os.remove(plaintext_path)
            print(f"刪除明碼暫存檔: {plaintext_path}")
        else:
            print(f"明碼暫存檔不存在，略過刪除: {plaintext_path}")
 
    # 2. 壓縮來源檔案（加密後的檔案，或沒有加密欄位時的原始檔）
    encrypted_path = args.encrypted_path
    if not os.path.exists(encrypted_path):
        print(f"❌ 找不到來源檔案: {encrypted_path}", file=sys.stderr)
        sys.exit(1)
 
    archive_dir = args.archive_dir
    os.makedirs(archive_dir, exist_ok=True)
 
    if args.zip_password_env_key:
        archive_path = _archive_with_zip_password(encrypted_path, archive_dir, args.zip_password_env_key)
        print(f"已封存至（加密 zip）: {archive_path}")
    else:
        archive_path = _archive_with_gzip(encrypted_path, archive_dir)
        print(f"已封存至: {archive_path}")
 
    # 3. 封存完成後移除未壓縮的原檔，避免同一份資料留兩份
    os.remove(encrypted_path)
    print(f"清除未壓縮的來源檔: {encrypted_path}")
 
 
if __name__ == "__main__":
    main()
