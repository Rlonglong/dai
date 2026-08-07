import argparse
import os
import sys

import pandas as pd

from data_rule import data_rule


def _safe_resolve_path(raw_path: str) -> str:
    """展開 ~ 並確認結果路徑落在使用者家目錄底下，跟其他腳本的防禦性檢查一致"""
    expanded = os.path.abspath(os.path.expanduser(raw_path))
    home = os.path.abspath(os.path.expanduser("~"))
    if os.path.commonpath([expanded, home]) != home:
        raise ValueError(f"❌ 路徑必須位於使用者家目錄底下: {raw_path} -> {expanded}")
    return expanded


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--table", required=True)
    parser.add_argument("--encoding", default="utf-8")
    # 新增 chunksize 參數，預設 10 萬筆處理一次，防止 OOM 記憶體爆炸
    parser.add_argument("--chunksize", type=int, default=100000)
    args = parser.parse_args()

    input_path = _safe_resolve_path(args.input)
    output_path = _safe_resolve_path(args.output)

    if not os.path.exists(input_path):
        raise FileNotFoundError(f"檔案未抵達: {input_path}")

    widths, offsets, names = data_rule(args.table)
    colspecs = list(zip(offsets[:-1], offsets[1:]))

    if len(colspecs) != len(names):
        raise RuntimeError(
            f"❌ 檔規解析出來的欄位數對不上: colspecs={len(colspecs)} 個, names={len(names)} 個"
        )

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    # 如果輸出檔案已經存在（例如重跑），先刪除避免 append 髒資料
    if os.path.exists(output_path):
        os.remove(output_path)

    print(f"🔄 開始分批轉換欄位命名: {input_path} -> {output_path}")

    first_chunk = True
    total_rows = 0

    # 使用 chunksize 分批讀取
    reader = pd.read_fwf(
        input_path, 
        colspecs=colspecs, 
        names=names, 
        dtype=str, 
        encoding=args.encoding,
        chunksize=args.chunksize
    )

    for chunk in reader:
        # =================================================================
        # 針對 T_TXN_PS 的特定業務清洗邏輯 (排除特例、新增特徵欄位)
        # =================================================================
        if "T_TXN_PS" in args.table.upper():
            # 1. 排除 TXN_NAME == "行政院發"
            if "TXN_NAME" in chunk.columns:
                chunk = chunk[chunk["TXN_NAME"].fillna("").astype(str).str.strip() != "行政院發"]

            # 2. 新增 IS_102_ACT (OWN_TRANS_ACCT 前三碼是否為 '102')
            if "OWN_TRANS_ACCT" in chunk.columns:
                chunk["IS_102_ACT"] = chunk["OWN_TRANS_ACCT"].fillna("").astype(str).str.strip().apply(
                    lambda x: '1' if x[:3] == '102' else '0'
                )
            else:
                chunk["IS_102_ACT"] = '0'

            # 3. 新增 IS_GIRO_ACT_FLG (ACT_NO_IN 去除空白後長度是否不等於 8)
            if "ACT_NO_IN" in chunk.columns:
                chunk["IS_GIRO_ACT_FLG"] = chunk["ACT_NO_IN"].fillna("").astype(str).str.strip().apply(
                    lambda x: '1' if len(x) != 8 else '0'
                )
            else:
                chunk["IS_GIRO_ACT_FLG"] = '0'
        # =================================================================

        if chunk.empty:
            continue

        total_rows += len(chunk)

        # 逐批寫入 CSV
        chunk.to_csv(
            output_path, 
            mode='w' if first_chunk else 'a', 
            index=False, 
            sep=",", 
            header=first_chunk
        )
        first_chunk = False

    os.chmod(output_path, 0o600)

    # 原始固定寬度明碼檔套完名字就沒用了，立刻刪掉
    os.remove(input_path)

    try:
        print(f"✅ 欄位命名完成: {input_path} -> {output_path}（共處理 {total_rows} 筆）")
    except BrokenPipeError:
        # 如果 SSH 連線已斷開，直接忽略並正常退出
        pass


if __name__ == "__main__":
    main()
