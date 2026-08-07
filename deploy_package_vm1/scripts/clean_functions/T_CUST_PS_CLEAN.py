import pandas as pd
from datetime import datetime

def clean_t_cust_ps(input_file: str, output_file: str, partition_date: str):
    """
    專門負責 T_CUST_PS 的資料清洗邏輯
    """
    TRUE_VALUES = ['Y', '1', 'y', 'TRUE']

    # 根據 partition_date (例如 "2026-03-01") 產生 BATCH_ID
    batch_date_str = partition_date.replace("-", "")
    batch_id = f"T_CUST_PS_{batch_date_str}{datetime.now().strftime('%H%M')}"

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
                # 嚴格校驗：測試是否為合法日期 (擋下無效日期)
                datetime.strptime(s, '%Y%m%d')
                return f"{s[:4]}-{s[4:6]}-{s[6:]}"
            except ValueError:
                # 遇到無效日期，直接洗成空字串 (SQL 的 NULL)
                return ''

        return s

    def convert_decimal(val):
        s = clean_str(val)
        if s == '' or s.lower() == 'nan' or s.lower() == 'none': return ''
        
        try:
            # 強制輸出為 SQL DECIMAL(18,2) 的格式，同時避免科學記號
            return f"{float(s):.2f}"
        except:
            return ''

    # ==========================================
    # 欄位型別設定 (已與 T_CUST_PS SQL Schema 100% 對齊)
    # ==========================================
    bit_columns = [
        'CARD_APLY_FLG', 'BRH_INTEGRATE_FLG', 'DUP_ACT_FLG', 'PSW_FLG_VC',
        'STOP_TRF_FLG', 'GRA_CHK_FLG', 'AUTO_MTG_FLG', 'CD_FREE_TRF_FLG',
        'EBANK_FLG', 'STATUS_ECTRL_FLG', 'PURCHASE_FLG', 'VISA_ABROAD_TXN_FLG',
        'VISA_BILL_FLG', 'VISA_TXN_HALT_FLG', 'INFORM_NEWS_FLG', 'INFORM_INT_OVER_FLG',
        'EBILL_FLG_VC', 'EMAIL_VISA_FLG', 'ACT_RESCUE_FLG', 'ACT_VETERAN_FLG',
        'CNP_TXN_FLG', 'ACT_SETTLED_FLG', 'EMAIL_BILL_FLG', 'UPAY_ABROAD_TXN_FLG',
        'UPAY_TXN_HALT_FLG', 'ACT_ANNUITY_FLG', 'ACT_FARMER_FLG', 'ACT_INSURE_FLG',
        'CD_010_FLG', 'CD_020_FLG', 'CD_021_FLG', 'ID_DUP_FLG',
        'ACT_M_RETIRE_FLG', 'ACT_L_RETIRE_FLG', 'WEB_CLS_FLG', 'INFORM_ACT_FLG',
        'ACT_POLITICS_FLG', 'ONLINE_SET_TRF_FLG', 'CANCEL_PRT_FLG', 'SALARY_TRF_FLG',
        'EBANK_VC_CHK_LIST_FLG', 'NCW_FLG', 'SALARY_TYPE_FLG', 'WEB_NOT_TRF_FLG',
        'DIGITAL_ACT_FLG', 'TPS_FLG', 'PBA_CNTR_RECONF_FLG', 'PBA_DG_PARENT_FLG1',
        'PBA_DG_PARENT_FLG2', 'RM_FLG'
    ]
    
    date_columns = [
        'LAST_TX_DATE', 'OPEN_DATE', 'LAST_PRT_DATE', 'DISAB_EXP_DATE'
    ]
    
    decimal_columns = [
        'PB_BAL', 'CUT_BAL', 'AVL_BAL', 'FD_AMT', 'FD_LOAN_AMT', 'LAST_CUT_BAL'
    ]

    # ==========================================
    # 進行清洗並逐 chunk 輸出
    # ==========================================
    first_chunk = True
    reader = pd.read_csv(input_file, dtype=str, chunksize=100000, encoding='utf-8')

    for chunk in reader:
        # 1. 清除換行與特殊空白
        chunk = chunk.apply(lambda x: x.map(clean_str) if x.dtype == "object" else x)

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

        # 3. 補上環境與批次欄位
        clean_df['TABLE_DATE'] = partition_date
        clean_df['BATCH_ID'] = batch_id
        # 註：舊版腳本的 CUST_UNIQ_ID 已移除，以精準對齊 v_BCP_T_CUST_PS 結構

        # 4. fillna (將 NaN 轉為空字串，以利 BCP 轉 NULL)
        clean_df.fillna('', inplace=True)

        # 5. 輸出檔案 (UTF-16-LE 配合 BCP，避免亂碼與截斷)
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
