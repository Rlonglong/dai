import argparse
import os
import sys

import pandas as pd
import re
from datetime import datetime
from dagster_pipes import open_dagster_pipes

from clean_functions import *

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--partition-date", required=True)
    parser.add_argument("--table", required=True)
    args = parser.parse_args()

    CLEAN_FUNC_MAP = {
        "T_TXN_PS": clean_t_txn_ps,
	"T_TXN_PS_FIRST": clean_t_txn_ps,
	"T_CUST": clean_t_cust,
        "T_CUST_PS": clean_t_cust_ps,
        # 之後有其他表的清洗邏輯就加在這裡
    }

    clean_func = CLEAN_FUNC_MAP.get(args.table)
    if not clean_func:
        raise ValueError(f"找不到 {args.table} 的清洗邏輯")

    with open_dagster_pipes() as pipes:
        if not os.path.exists(args.input):
            pipes.log.error(f"[VM1] <error> 檔案未抵達: {args.input}")
            raise FileNotFoundError(f"檔案未抵達: {args.input}")

        os.makedirs(os.path.dirname(args.output), exist_ok=True)

        pipes.log.info(f"[VM1] <info> 開始清洗: {args.input}")
        clean_func(args.input, args.output, args.partition_date)
        pipes.log.info(f"[VM1] <info> 清洗完成: {args.output}")

        pipes.report_asset_materialization(
            metadata={
                "clean_file_path": args.output,
                "partition_date": args.partition_date,
            }
        )


if __name__ == "__main__":
    main()
