import argparse
import json
import os
import re
import sys

import pymssql
from dotenv import load_dotenv

env_path = '/home/bcp_runner/.env'
load_dotenv(dotenv_path=env_path)

_SQL_IDENTIFIER_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$')


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
        login_timeout=15,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-db", required=True)
    parser.add_argument("--source-table", required=True)
    parser.add_argument("--notify-date-col", default="NOTIFY_DATE")
    parser.add_argument("--after-date", default="0")   # yyyymmdd / yyyymm / "0"
    parser.add_argument("--group-len", type=int, choices=[6, 8], default=8)
    args = parser.parse_args()

    try:
        validate_identifier(args.source_db, "source_db")
        table = validate_table(args.source_table)
        col = validate_identifier(args.notify_date_col, "notify_date_col")
        if args.after_date != "0" and not re.match(r'^\d{6}$|^\d{8}$', args.after_date):
            raise ValueError(f"after_date 格式錯誤: {args.after_date!r}")

        # 識別字已白名單驗證;group_len 受 choices=[6,8] 限制;
        # after_date 是唯一的外部資料值,用 %s bind parameter 帶入
        sql = (
            f"SELECT"
            f"    LEFT([{col}], {args.group_len}) AS notify_date"
            f"    , COUNT(*)                      AS cnt"
            f" FROM {table} WITH (NOLOCK)"
            f" WHERE LEFT([{col}], {args.group_len}) > %s"
            f" GROUP BY LEFT([{col}], {args.group_len})"
            f" ORDER BY notify_date"
        )

        with get_connection(args.source_db) as conn:
            cursor = conn.cursor()
            cursor.execute(sql, (args.after_date,))
            rows = cursor.fetchall()

        result = [{"notify_date": r[0], "count": int(r[1])} for r in rows]
        print(json.dumps(result))
        return 0
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
