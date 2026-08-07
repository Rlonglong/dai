import pandas as pd
from datetime import datetime


def clean_t_txn_ps(input_file: str, output_file: str, partition_date: str):
    """
    專門負責 T_TXN_PS 的資料清洗邏輯
    """
    TRUE_VALUES = ['Y', '1', 'y', 'TRUE']

    # 根據 partition_date (例如 "2026-06-12") 產生 BATCH_ID
    batch_date_str = partition_date.replace("-", "")
    batch_id = f"T_TXN_PS_{batch_date_str}{datetime.now().strftime('%H%M')}"

    # ==========================================
    # 共用清洗函式
    # ==========================================
    def clean_str(val):
        if pd.isna(val): return ''
        return str(val).replace('\n', '').replace('\r', '').strip(' \t\u3000')

    def yn_to_bit(val):
        return '1' if clean_str(val).upper() in TRUE_VALUES else '0'

    def convert_to_sql_date(date_str):
        s = clean_str(date_str)
        if s == '' or s == '00000000': return ''
        
        if len(s) == 8 and s.isdigit():
            # 處理部分系統常見的極大防呆值
            if s == '99991231': return '9999-12-31'
            
            try:
                # 嚴格校驗：測試是否為合法日期 (擋下 21932032 這種髒資料)
                datetime.strptime(s, '%Y%m%d')
                return f"{s[:4]}-{s[4:6]}-{s[6:]}"
            except ValueError:
                # 遇到無效日期，直接洗成空字串 (SQL 的 NULL)
                return ''
                
        return s

    def convert_decimal(val):
        s = clean_str(val)
        if s == '': return ''
        try: return f"{float(s):.2f}"
        except: return ''

    # ==========================================
    # 欄位型別設定
    # ==========================================
    bit_columns = ['DR_FLG', 'WITH_BOOK_FLG', 'IS_102_ACT', 'IS_GIRO_ACT_FLG']
    date_columns = ['CPU_DATE']
    decimal_columns = ['TXN_AMT', 'PS_BAL']

    # ==========================================
    # 第一階段：掃一遍統計每個 CPU_DATE 的筆數（用於序號 offset）
    # ==========================================
    date_current_seq = {}
    reader = pd.read_csv(input_file, dtype=str, chunksize=100000, encoding='utf-8', usecols=['CPU_DATE', 'TXN_TIME'])
    for chunk in reader:
        chunk['CPU_DATE'] = chunk['CPU_DATE'].apply(convert_to_sql_date)
        for date in chunk['CPU_DATE'].unique():
            if date not in date_current_seq:
                date_current_seq[date] = 1

    # ==========================================
    # 第二階段：正式清洗並逐 chunk 輸出
    # ==========================================
    first_chunk = True
    reader = pd.read_csv(input_file, dtype=str, chunksize=100000, encoding='utf-8')

    for chunk in reader:
        # 1. 清除換行與特殊空白
        chunk = chunk.apply(lambda x: x.map(clean_str) if x.dtype == "object" else x)

        # 如果過濾後這個 chunk 沒資料了，就跳過不寫入
        if chunk.empty:
            continue

        clean_df = pd.DataFrame()

        # 2. 欄位型別轉換
        for col in chunk.columns:
            if col in bit_columns:
                clean_df[col] = chunk[col].apply(yn_to_bit)
            elif col in date_columns:
                clean_df[col] = chunk[col].apply(convert_to_sql_date)
            elif col in decimal_columns:
                clean_df[col] = chunk[col].apply(convert_decimal)
            else:
                clean_df[col] = chunk[col]

        # 3. 長度裁切 (避免 BCP 因字串過長報錯 Right Truncation)
        if 'FUNC_CODE'       in clean_df.columns: clean_df['FUNC_CODE']        = clean_df['FUNC_CODE'].str.slice(0, 4)
        if 'STATUS_CODE_PBA' in clean_df.columns: clean_df['STATUS_CODE_PBA']  = clean_df['STATUS_CODE_PBA'].str.slice(0, 1)
        if 'TXN_TYPE'        in clean_df.columns: clean_df['TXN_TYPE']         = clean_df['TXN_TYPE'].str.slice(0, 2)
        if 'CD_FLG'          in clean_df.columns: clean_df['CD_FLG']           = clean_df['CD_FLG'].str.slice(0, 1)
        if 'CHANNEL_FLG'     in clean_df.columns: clean_df['CHANNEL_FLG']      = clean_df['CHANNEL_FLG'].str.slice(0, 2)
        if 'TXN_TIME'        in clean_df.columns: clean_df['TXN_TIME']         = clean_df['TXN_TIME'].str.slice(0, 6)
        if 'TXN_BRH'         in clean_df.columns: clean_df['TXN_BRH']          = clean_df['TXN_BRH'].str.slice(0, 6)
        if 'EMP_NO'          in clean_df.columns: clean_df['EMP_NO']           = clean_df['EMP_NO'].str.slice(0, 6)
        if 'JRNL_NO'         in clean_df.columns: clean_df['JRNL_NO']          = clean_df['JRNL_NO'].str.slice(0, 9)
        if 'TXN_NAME'        in clean_df.columns: clean_df['TXN_NAME']         = clean_df['TXN_NAME'].str.slice(0, 4)
        if 'TXN_MEMO'        in clean_df.columns: clean_df['TXN_MEMO']         = clean_df['TXN_MEMO'].str.slice(0, 15)
        if 'DRCR'            in clean_df.columns: clean_df['DRCR']             = clean_df['DRCR'].str.slice(0, 1)
        if 'CUR'             in clean_df.columns: clean_df['CUR']              = clean_df['CUR'].str.slice(0, 3)
        if 'BNK_ID'          in clean_df.columns: clean_df['BNK_ID']           = clean_df['BNK_ID'].str.slice(0, 3)
        if 'TXN_MEMO_C'      in clean_df.columns: clean_df['TXN_MEMO_C']       = clean_df['TXN_MEMO_C'].str.slice(0, 9)
        if 'TXN_ENAME'       in clean_df.columns: clean_df['TXN_ENAME']        = clean_df['TXN_ENAME'].str.slice(0, 3)

        # 4. 補上環境與批次欄位
        clean_df['TABLE_DATE'] = partition_date
        clean_df['BATCH_ID'] = batch_id

        # 5. fillna
        clean_df.fillna('', inplace=True)

        # 6. 輸出檔案
        clean_df.to_csv(
            output_file,
            mode='w' if first_chunk else 'a',
            sep='|',
            index=False,
            header=False,
            encoding='utf-16-le',
            lineterminator='\n'
        )
        first_chunk = False
