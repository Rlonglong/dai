import argparse
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from encryption import encrypt_csv
from dagster_pipes import open_dagster_pipes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--fields", required=True)
    parser.add_argument("--delimiter", default=",")
    args = parser.parse_args()
    args.input = os.path.expanduser(args.input)
    os.makedirs(os.path.dirname(args.output), exist_ok=True)

    encrypt_fields = args.fields.split(",")

    with open_dagster_pipes() as pipes:
        if not os.path.exists(args.input):
            pipes.log.error(f"[VM1] <error> 檔案未抵達: {args.input}")
            raise FileNotFoundError(f"檔案未抵達: {args.input}")

        pipes.log.info(f"[VM1] <info> 開始加密欄位 {encrypt_fields}: {args.input}")

        row_count = encrypt_csv(
            input_path=args.input,
            output_path=args.output,
            encrypt_fields=encrypt_fields,
            delimiter=args.delimiter,
        )

        pipes.log.info(f"[VM1] <info> 加密完成，共處理 {row_count} 列")
        pipes.report_asset_materialization(
            metadata={
                "encrypted_file_path": args.output,
                "encrypt_fields": str(encrypt_fields),
                "row_count": row_count,
            }
        )


if __name__ == "__main__":
    main()
