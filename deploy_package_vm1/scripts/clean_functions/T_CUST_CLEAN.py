import pandas as pd
from datetime import datetime

def clean_t_cust(input_file: str, output_file: str, partition_date: str):
    """
    專門負責 T_CUST 的資料清洗邏輯
    """
    TRUE_VALUES = ['Y', '1', 'y', 'TRUE']

    # 根據 partition_date (例如 "2026-02-01") 產生 BATCH_ID
    batch_date_str = partition_date.replace("-", "")
    batch_id = f"T_CUST_{batch_date_str}{datetime.now().strftime('%H%M')}"

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

    def fix_cobol_amount(val):
        s = clean_str(val)
        if s == '' or s.lower() == 'nan' or s.lower() == 'none': return ''
        
        # COBOL Overpunch 字典
        neg_overpunch = {'}': '0', 'J': '1', 'K': '2', 'L': '3', 'M': '4', 'N': '5', 'O': '6', 'P': '7', 'Q': '8', 'R': '9'}
        pos_overpunch = {'{': '0', 'A': '1', 'B': '2', 'C': '3', 'D': '4', 'E': '5', 'F': '6', 'G': '7', 'H': '8', 'I': '9'}
        
        last_char = s[-1].upper()
        is_negative = False
        
        if last_char in neg_overpunch:
            s = s[:-1] + neg_overpunch[last_char]
            is_negative = True
        elif last_char in pos_overpunch:
            s = s[:-1] + pos_overpunch[last_char]
            
        try:
            num = float(s)
            if is_negative:
                num = -num
            # 強制輸出為 SQL DECIMAL(18,4) 的格式
            return f"{num:.4f}"
        except:
            return s

    # ==========================================
    # 欄位型別設定
    # ==========================================
    bit_columns = [
        'CGT_FLG', 'PSW_FLG_VC', 'LIVE183_FLG', 'CUI_FLG', 'SEX_CODE',
        'EMAIL_FLG', 'DATA_SELL_FLG', 'STOP_USE_FLG', 'HIGH_RISK_FLG',
        'MOJ_LAUN_FLG', 'SPC_CNTL_FLG',
        'POLITICIAN_TYPE_BIT_1', 'POLITICIAN_TYPE_BIT_2', 'POLITICIAN_TYPE_BIT_3', 'POLITICIAN_TYPE_BIT_4',
        'POLITICIAN_TYPE_BIT_5', 'POLITICIAN_TYPE_BIT_6', 'POLITICIAN_TYPE_BIT_7', 'POLITICIAN_TYPE_BIT_8',
        'POLITICIAN_TYPE_BIT_9', 'POLITICIAN_TYPE_BIT_10', 'POLITICIAN_TYPE_BIT_11', 'POLITICIAN_TYPE_BIT_12',
        'POLITICIAN_TYPE_BIT_13', 'POLITICIAN_TYPE_BIT_14', 'POLITICIAN_TYPE_BIT_15', 'POLITICIAN_TYPE_BIT_16',
        'REL_1_1GUAR_MINOR', 'REL_1_2GUAR', 'REL_1_3OWNER', 'REL_1_4BENEFI_OWNER', 'REL_1_5_SUPERVISOR',
        'REL_2_1GUAR_MINOR', 'REL_2_2GUAR', 'REL_2_3OWNER', 'REL_2_4BENEFI_OWNER', 'REL_2_5_SUPERVISOR',
        'REL_3_1GUAR_MINOR', 'REL_3_2GUAR', 'REL_3_3OWNER', 'REL_3_4BENEFI_OWNER', 'REL_3_5_SUPERVISOR'
    ]
    date_columns = ['BIRTH_DATE', 'RESIDENT_EXP_DATE', 'LAST_LAUN_DATE']
    cobol_amt_columns = ['AUM_AMT']

    # ==========================================
    # 進行清洗並逐 chunk 輸出
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
            elif col in cobol_amt_columns:
                clean_df[col] = chunk[col].apply(fix_cobol_amount)
            else:
                clean_df[col] = chunk[col]

        # 3. 長度裁切 (避免 BCP 因字串過長報錯 Right Truncation)
        if 'RESIDENT_CITY_DIST' in clean_df.columns: clean_df['RESIDENT_CITY_DIST'] = clean_df['RESIDENT_CITY_DIST'].str.slice(0, 7)

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
