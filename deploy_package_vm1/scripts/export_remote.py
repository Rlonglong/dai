import argparse
import csv
import io
import os
import ssl
import sys
import ftplib

import pymssql
from dagster_pipes import open_dagster_pipes
from dotenv import load_dotenv

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from encryption import decrypt_value

env_path = '/home/bcp_runner/.env'
load_dotenv(dotenv_path=env_path)

DB_SERVER = os.getenv("DB_SERVER")
DB_NAME   = os.getenv("DB_NAME")
DB_USER   = os.getenv("DB_USER")
DB_PASS   = os.getenv("DB_PASS")

FTP_HOST  = os.getenv("FTP_HOST")
FTP_USER  = os.getenv("FTP_USER")
FTP_PASS  = os.getenv("FTP_PASS")


def build_query(args) -> str:
    if args.sql:
        return args.sql.format(start_date=args.start_date, end_date=args.end_date)
    return f"""
        SELECT * FROM dbo.{args.table}
        WHERE {args.date_column} >= '{args.start_date}'
          AND {args.date_column} < '{args.end_date}'
    """


class _IterToFileobj:
    """把 generator 包成 file-like object 給 ftplib.storbinary 用"""
    def __init__(self, gen):
        self._gen = gen
        self._buf = b""

    def read(self, size=8192):
        while len(self._buf) < size:
            try:
                self._buf += next(self._gen)
            except StopIteration:
                break
        data, self._buf = self._buf[:size], self._buf[size:]
        return data


def _csv_row_generator(cursor, columns, decrypt_indices, args, row_count_ref):
    """從 cursor 逐批產生 CSV bytes，不落地"""
    output = io.StringIO()
    writer = csv.writer(output, delimiter=args.delimiter)
    writer.writerow(columns)
    yield output.getvalue().encode(args.encoding)

    while True:
        rows = cursor.fetchmany(50000)
        if not rows:
            break
        output = io.StringIO()
        writer = csv.writer(output, delimiter=args.delimiter)
        if decrypt_indices:
            processed = []
            for row in rows:
                row = list(row)
                for idx in decrypt_indices:
                    v = row[idx]
                    if v and str(v).strip():
                        row[idx] = decrypt_value(str(v))
                processed.append(row)
            writer.writerows(processed)
        else:
            writer.writerows(rows)
        row_count_ref[0] += len(rows)
        yield output.getvalue().encode(args.encoding)


def _write_to_local(cursor, columns, decrypt_indices, args, row_count_ref):
    """寫到本地檔案"""
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", newline="", encoding=args.encoding) as f:
        writer = csv.writer(f, delimiter=args.delimiter)
        writer.writerow(columns)
        while True:
            rows = cursor.fetchmany(50000)
            if not rows:
                break
            if decrypt_indices:
                processed = []
                for row in rows:
                    row = list(row)
                    for idx in decrypt_indices:
                        v = row[idx]
                        if v and str(v).strip():
                            row[idx] = decrypt_value(str(v))
                    processed.append(row)
                writer.writerows(processed)
            else:
                writer.writerows(rows)
            row_count_ref[0] += len(rows)

class ImplicitFTP_TLS(ftplib.FTP_TLS):
    """
    修正兩個 Python ftplib 在 FTPS 資料連線上的已知問題：
    1. 資料連線沒有重用(reuse)控制連線的 TLS session -> 部分 server 拒絕連線
    2. storbinary 傳完資料後會呼叫 conn.unwrap() 做 TLS 層的 graceful shutdown，
       這一來一回的額外交握，在 IIS FTP Server 上容易被判定為資料連線「速率過低」，
       進而以 425 Data channel timed out ... 中斷連線（小檔案特別容易觸發，
       因為 unwrap 交握時間佔整體傳輸時間比例過高，拉低平均 bytes/sec）。
    解法：資料連線重用 TLS session，且傳輸完成後直接關閉底層 socket，不做 unwrap()。
    """
    def ntransfercmd(self, cmd, rest=None):
        conn, size = ftplib.FTP.ntransfercmd(self, cmd, rest)
        if self._prot_p:
            conn = self.context.wrap_socket(
                conn,
                server_hostname=self.host,
                session=self.sock.session,  # 重用控制連線的 TLS session
            )
        return conn, size

    def storbinary(self, cmd, fp, blocksize=8192, callback=None, rest=None):
        """複寫自 CPython ftplib.storbinary，拿掉結尾的 conn.unwrap()，
        避免額外 TLS shutdown 交握觸發 IIS 的 425 bandwidth timeout"""
        self.voidcmd('TYPE I')
        with self.transfercmd(cmd, rest) as conn:
            while True:
                buf = fp.read(blocksize)
                if not buf:
                    break
                conn.sendall(buf)
                if callback:
                    callback(buf)
            # 刻意不呼叫 conn.unwrap()
        return self.voidresp()


def _stream_to_ftp(cursor, columns, decrypt_indices, args, row_count_ref, pipes):
    """先把資料寫進記憶體，再一次性上傳到 FTP"""
    if not all([FTP_HOST, FTP_USER, FTP_PASS]):
        raise RuntimeError("FTP 連線資訊不完整")

    buffer = io.BytesIO()
    wrapper = io.TextIOWrapper(buffer, encoding=args.encoding, newline="")
    writer = csv.writer(wrapper, delimiter=args.delimiter)
    writer.writerow(columns)
    while True:
        rows = cursor.fetchmany(50000)
        if not rows:
            break
        if decrypt_indices:
            processed = []
            for row in rows:
                row = list(row)
                for idx in decrypt_indices:
                    v = row[idx]
                    if v and str(v).strip():
                        row[idx] = decrypt_value(str(v))
                processed.append(row)
            writer.writerows(processed)
        else:
            writer.writerows(rows)
        row_count_ref[0] += len(rows)
    wrapper.flush()
    buffer.seek(0)
    pipes.log.info(f"資料已載入記憶體，共 {row_count_ref[0]} 筆，開始上傳 FTP...")

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    remote_dir  = os.path.dirname(args.ftp_remote_path)
    remote_file = os.path.basename(args.ftp_remote_path)

    with ImplicitFTP_TLS(context=ctx) as ftp:
        ftp.connect(FTP_HOST)
        ftp.auth()
        ftp.prot_p()
        ftp.login(FTP_USER, FTP_PASS)
        ftp.set_pasv(True)
        if remote_dir:
            ftp.cwd(remote_dir)
        ftp.storbinary(f"STOR {remote_file}", buffer)
        try:
            ftp.quit()
        except Exception:
            pass

    pipes.log.info(f"✅ FTP 上傳完成: {FTP_HOST}{args.ftp_remote_path}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output",          default=None)   # 沒填就不落地
    parser.add_argument("--delimiter",       default=",")
    parser.add_argument("--encoding",        default="utf-8-sig")
    parser.add_argument("--start-date",      required=True)
    parser.add_argument("--end-date",        required=True)
    parser.add_argument("--sql",             default=None)
    parser.add_argument("--table",           default=None)
    parser.add_argument("--date-column",     default=None)
    parser.add_argument("--decrypt-fields",  default="")
    parser.add_argument("--ftp-remote-path", default=None)
    args = parser.parse_args()

    decrypt_fields = [f.strip() for f in args.decrypt_fields.split(",") if f.strip()]

    if not args.output and not args.ftp_remote_path:
        raise ValueError("--output 跟 --ftp-remote-path 至少要填一個")

    with open_dagster_pipes() as pipes:
        if not all([DB_SERVER, DB_NAME, DB_USER, DB_PASS]):
            pipes.log.error("❌ 環境變數有缺，連線資訊不完整")
            raise RuntimeError("DB 連線資訊不完整")

        query = build_query(args)
        row_count_ref = [0]

        try:
            with pymssql.connect(
                server=DB_SERVER,
                user=DB_USER,
                password=DB_PASS,
                database=DB_NAME,
                tds_version="7.4",
                as_dict=False,
            ) as conn:
                with conn.cursor() as cursor:
                    cursor.execute(query)
                    columns = [desc[0] for desc in cursor.description]

                    if decrypt_fields:
                        missing = [f for f in decrypt_fields if f not in columns]
                        if missing:
                            raise ValueError(
                                f"指定的解密欄位 {missing} 在查詢結果裡找不到，"
                                f"實際欄位: {columns}"
                            )

                    decrypt_indices = [
                        i for i, col in enumerate(columns) if col in decrypt_fields
                    ]

                    if args.ftp_remote_path:
                        # 直接串流到 FTP，不落地
                        _stream_to_ftp(cursor, columns, decrypt_indices, args, row_count_ref, pipes)
                    else:
                        # 寫到本地檔案
                        _write_to_local(cursor, columns, decrypt_indices, args, row_count_ref)
                        pipes.log.info(f"✅ 匯出完成，共 {row_count_ref[0]} 筆 -> {args.output}")

            pipes.report_asset_materialization(
                metadata={
                    "output_file": os.path.basename(args.ftp_remote_path or args.output or ""),
                    "row_count": row_count_ref[0],
                    "delimiter": args.delimiter,
                    "ftp_uploaded": bool(args.ftp_remote_path),
                    "destination": args.ftp_remote_path or args.output or "",
                }
            )

        except Exception as e:
            pipes.log.error(f"❌ 失敗: {str(e)}")
            raise


if __name__ == "__main__":
    main()
