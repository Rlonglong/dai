import argparse
import ftplib
import json
import os
import ssl
import sys
from datetime import datetime, timezone
 
from dotenv import load_dotenv
 
env_path = '/home/bcp_runner/.env'
load_dotenv(dotenv_path=env_path)
 
FTP_HOST = os.getenv("FTP_HOST")
FTP_USER = os.getenv("FTP_USER")
FTP_PASS = os.getenv("FTP_PASS")
 
 
class ImplicitFTP_TLS(ftplib.FTP_TLS):
    """資料連線重用 TLS session，避免部分 FTPS server 拒絕連線"""
    def ntransfercmd(self, cmd, rest=None):
        conn, size = ftplib.FTP.ntransfercmd(self, cmd, rest)
        if self._prot_p:
            conn = self.context.wrap_socket(
                conn, server_hostname=self.host, session=self.sock.session,
            )
        return conn, size
 
 
def _parse_mlsd_time(modify_str: str) -> float:
    dt = datetime.strptime(modify_str[:14], "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)
    return dt.timestamp()
 
 
def list_dir(remote_dir: str):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
 
    entries = []
    with ImplicitFTP_TLS(context=ctx) as ftp:
        ftp.connect(FTP_HOST)
        ftp.auth()
        ftp.prot_p()
        ftp.login(FTP_USER, FTP_PASS)
        ftp.set_pasv(True)
 
        try:
            # 優先用 MLSD：一次拿到檔名 + mtime + size，來回次數最少
            for name, facts in ftp.mlsd(remote_dir):
                if facts.get("type") != "file":
                    continue
                modify_str = facts.get("modify")
                mtime = _parse_mlsd_time(modify_str) if modify_str else None
                size = int(facts["size"]) if facts.get("size") else None
                entries.append({"name": name, "mtime": mtime, "size": size})
        except ftplib.error_perm:
            # server 不支援 MLSD，退回 NLST + 逐檔 MDTM/SIZE
            names = ftp.nlst(remote_dir)
            for full in names:
                name = os.path.basename(full)
                remote_path = f"{remote_dir}/{name}"
                mtime = None
                size = None
                try:
                    resp = ftp.sendcmd(f"MDTM {remote_path}")
                    mtime = _parse_mlsd_time(resp.split()[-1])
                except Exception:
                    pass
                try:
                    size = ftp.size(remote_path)
                except Exception:
                    pass
                entries.append({"name": name, "mtime": mtime, "size": size})
 
        try:
            ftp.quit()
        except Exception:
            pass
 
    return entries
 
 
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--remote-dir", required=True)
    args = parser.parse_args()
 
    if not all([FTP_HOST, FTP_USER, FTP_PASS]):
        print(json.dumps({"error": "FTP 連線資訊不完整"}), file=sys.stderr)
        sys.exit(1)
 
    try:
        entries = list_dir(args.remote_dir)
        print(json.dumps(entries))
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)
 
 
if __name__ == "__main__":
    main()
