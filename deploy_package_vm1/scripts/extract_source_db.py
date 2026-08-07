import argparse
import csv
import os
import re
import sys

import pymssql
from dotenv import load_dotenv
from dagster_pipes import open_dagster_pipes

env_path = '/home/bcp_runner/.env'
load_dotenv(dotenv_path=env_path)

_SQL_IDENTIFIER_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$')
BATCH_SIZE = 50000


def validate_identifier(value: str, name: str) -> str:
    if not value or not _SQL_IDENTIFIER_RE.match(value):
        raise ValueError(f"{name} 不是合法 SQL 識別字: {value!r}")
    return value


def validate_table(value: str) -> str:
    for part in value.split("."):
        validate_identifier(part, "source_table")
    return value


def get_connection(source_db: str):
    return pymssql.connect(
        server=os.getenv("SOURCE_DB_SERVER"),
        user=os.getenv("SOURCE_DB_USER"),
        password=os.getenv("SOURCE_DB_PASS"),
        database=source_db,
        login_timeout=30,
    )


def get_all_columns(cursor, table: str) -> list[str]:
    """從 INFORMATION_SCHEMA 取得表的全部欄位,依原始順序。等效 SELECT *。"""
    if "." in table:
        schema, tbl = table.split(".", 1)
    else:
        schema, tbl = "dbo", table
    cursor.execute(
        "SELECT COLUMN_NAME"
        " FROM INFORMATION_SCHEMA.COLUMNS"
        " WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s"
        " ORDER BY ORDINAL_POSITION",
        (schema, tbl),
    )
    cols = [r[0] for r in cursor.fetchall()]
    if not cols:
        raise RuntimeError(f"找不到表 {table} 的欄位(表不存在或無權限)")
    return cols


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-db", required=True)
    parser.add_argument("--source-table", required=True)
    parser.add_argument("--notify-date-col", default="NOTIFY_DATE")
    parser.add_argument("--notify-date", required=True)   # yyyymmdd 或 yyyymm
    parser.add_argument("--decrypt-fields", default="")   # 逗號分隔,可為空
    parser.add_argument("--decrypt-key-env", default="SOURCE_DECRYPT_KEY")
    parser.add_argument("--output", required=True)
    parser.add_argument("--delimiter", default="|")
    args = parser.parse_args()

    with open_dagster_pipes() as pipes:
        validate_identifier(args.source_db, "source_db")
        table = validate_table(args.source_table)
        date_col = validate_identifier(args.notify_date_col, "notify_date_col")
        if not re.match(r'^\d{6}$|^\d{8}$', args.notify_date):
            raise ValueError(f"notify_date 必須是 yyyymmdd 或 yyyymm: {args.notify_date!r}")
        prefix_len = len(args.notify_date)

        decrypt_fields = [f for f in args.decrypt_fields.split(",") if f]
        for f in decrypt_fields:
            validate_identifier(f, f"decrypt_field({f})")

        decrypt_key = os.environ.get(args.decrypt_key_env)
        if decrypt_fields and not decrypt_key:
            raise RuntimeError(f"環境變數 {args.decrypt_key_env} 未設定,無法解密")

        output_path = os.path.expanduser(args.output)
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        tmp_path = output_path + ".tmp"

        with get_connection(args.source_db) as conn:
            cursor = conn.cursor()
            all_columns = get_all_columns(cursor, table)

            missing = set(decrypt_fields) - set(all_columns)
            if missing:
                raise RuntimeError(f"decrypt_fields 中的欄位不存在於 {table}: {sorted(missing)}")

            # 解密欄位包 F_DecryptData,key 用 %s bind parameter
            select_parts = []
            params = []
            for col in all_columns:
                if col in decrypt_fields:
                    select_parts.append(f"dbo.F_DecryptData(%s, [{col}]) AS [{col}]")
                    params.append(decrypt_key)
                else:
                    select_parts.append(f"[{col}]")

            sql = (
                f"SELECT {', '.join(select_parts)}"
                f" FROM {table} WITH (NOLOCK)"
                f" WHERE LEFT([{date_col}], {prefix_len}) = %s"
            )
            params.append(args.notify_date)

            pipes.log.info(
                f"[VM1] <info> 開始撈取 {table} ({date_col} 前綴={args.notify_date}),"
                f"欄位 {len(all_columns)} 個,解密欄位 {decrypt_fields}"
            )

            cursor.execute(sql, tuple(params))

            def _sanitize(v, delimiter: str) -> str:
                if v is None:
                    return ""
                s = str(v)
                return s.replace(delimiter, " ").replace("\r", " ").replace("\n", " ")
            row_count = 0
            with open(tmp_path, "w", newline="", encoding="utf-8") as fh:
                writer = csv.writer(fh, delimiter=args.delimiter)
                writer.writerow(all_columns)
                while True:
                    rows = cursor.fetchmany(BATCH_SIZE)
                    if not rows:
                        break
                    for row in rows:
                        writer.writerow([_sanitize(v, args.delimiter) for v in row])
                    row_count += len(rows)
                    pipes.log.info(f"[VM1] <info> 已寫出 {row_count} 列...")

        if row_count == 0:
            os.remove(tmp_path)
            raise RuntimeError(
                f"{table} 在 {date_col} 前綴={args.notify_date} 撈不到任何資料,"
                f"視為異常直接失敗(sensor 判定到齊才會觸發,不應為空)"
            )

        os.replace(tmp_path, output_path)
        pipes.log.info(f"[VM1] <info> 撈取完成,共 {row_count} 列 -> {output_path}")

        pipes.report_asset_materialization(
            metadata={
                "extracted_file_path": output_path,
                "source_table": table,
                "notify_date": args.notify_date,
                "decrypt_fields": str(decrypt_fields),
                "row_count": row_count,
            }
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
