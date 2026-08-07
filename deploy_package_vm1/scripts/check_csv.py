import pandas as pd

def main():
    clean_csv_path = '/run/media/root/D/data/T_CUST/T_CUST_CLEANED/T_CUST_202608_CLEAN.csv'
    header_csv_path = '/run/media/root/D/data/fromFPP/T_CUST/T_CUST_202608_ENCRYPTED.csv'

    print("讀取欄位結構中...")
    try:
        header_df = pd.read_csv(header_csv_path, nrows=0)
        cols = list(header_df.columns)
        cols.extend(['TABLE_DATE', 'BATCH_ID'])
    except Exception as e:
        print(f"無法讀取 Header，將使用數字索引。錯誤: {e}")
        cols = None

    print(f"開始掃描清洗後的資料: {clean_csv_path}")
    print("💡 依照要求，本次只抽取前 10,000 筆資料進行快速診斷...\n")
    
    # 直接使用 nrows=10000，1萬筆資料極小，絕對不會 OOM，瞬間就能跑完
    df = pd.read_csv(
        clean_csv_path, 
        sep='|', 
        names=cols, 
        header=None, 
        dtype=str, 
        encoding='utf-16-le',
        nrows=10000
    )

    print("="*50)
    print(" 🚨 1. [長度異常檢查] 字串最長的 Top 20 欄位 (可能是 Truncation 兇手)")
    print("="*50)
    # 計算每個欄位的最大字元長度
    lengths = df.apply(lambda x: x.fillna('').astype(str).str.len().max())
    print(lengths.sort_values(ascending=False).head(20))

    print("\n" + "="*50)
    print(" 🚨 2. [假日期檢查] 找尋沒被轉換成功的 8 碼髒日期")
    print("="*50)
    found_bad_date = False
    for col in df.columns:
        if isinstance(col, str) and 'DATE' in col.upper():
            bad_dates = df[df[col].fillna('').astype(str).str.len() == 8][col].unique()
            if len(bad_dates) > 0:
                found_bad_date = True
                print(f"❌ 欄位 [{col}] 發現未成功轉換的假日期！範例: {bad_dates[:5]}")
    
    if not found_bad_date:
        print("✅ 前 10000 筆中，沒有發現殘留的 8 碼髒日期。")

    print("\n" + "="*50)
    print(" 🚨 3. [數值溢位檢查] 找出長度異常的數字/金額欄位")
    print("="*50)
    for col in df.columns:
        if isinstance(col, str) and ('AMT' in col.upper() or 'BAL' in col.upper()):
            max_len = df[col].fillna('').astype(str).str.len().max()
            print(f"欄位 [{col}] 的最大字串長度為: {max_len}")

if __name__ == "__main__":
    main()
