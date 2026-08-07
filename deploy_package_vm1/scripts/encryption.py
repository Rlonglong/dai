import os
import csv
import base64
import hashlib
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend
from dotenv import load_dotenv

env_path = '/home/bcp_runner/.env'
load_dotenv(dotenv_path=env_path)

ENCRYPTION_KEY = os.getenv("CSV_ENCRYPTION_KEY")
if not ENCRYPTION_KEY:
    raise ValueError("環境變數 CSV_ENCRYPTION_KEY 未設定，請先產生金鑰並寫入 .env")

_aes_key = hashlib.sha256(ENCRYPTION_KEY.encode()).digest()


def encrypt_value(value: str) -> str:
    """確定性加密：同一個明文每次結果都一樣，可解回來。"""
    if value is None or value == "":
        return value
    value_bytes = value.encode("utf-8")
    pad_len = 16 - (len(value_bytes) % 16)
    padded = value_bytes + bytes([pad_len] * pad_len)
    cipher = Cipher(algorithms.AES(_aes_key), modes.ECB(), backend=default_backend())
    encrypted = cipher.encryptor().update(padded)
    return base64.urlsafe_b64encode(encrypted).decode()


def decrypt_value(value: str) -> str:
    """解密。"""
    if value is None or value == "":
        return value
    encrypted = base64.urlsafe_b64decode(value.encode())
    cipher = Cipher(algorithms.AES(_aes_key), modes.ECB(), backend=default_backend())
    padded = cipher.decryptor().update(encrypted)
    pad_len = padded[-1]
    return padded[:-pad_len].decode("utf-8")


def encrypt_csv(
    input_path: str,
    output_path: str,
    encrypt_fields: list[str],
    delimiter: str = ","
):
    """
    讀取 CSV，將指定欄位加密，輸出新 CSV。
    任何環節失敗（欄位找不到、檔案壞掉、加密失敗、列數不符等）一律 raise，
    確保含個資的明文資料絕不會悄悄流向下游。
    """
    if not os.path.exists(input_path):
        raise FileNotFoundError(f"加密來源檔案不存在: {input_path}")

    if not encrypt_fields:
        raise ValueError("encrypt_fields 為空，這個函式不該在沒有指定加密欄位時被呼叫")

    with open(input_path, 'r', encoding='utf-8', newline='') as infile, \
         open(output_path, 'w', encoding='utf-8', newline='') as outfile:

        reader = csv.reader(infile, delimiter=delimiter)
        writer = csv.writer(outfile, delimiter=delimiter)

        try:
            header = next(reader)
        except StopIteration:
            raise ValueError(f"CSV 檔案是空的，連 header 都沒有: {input_path}")

        writer.writerow(header)

        missing_fields = [f for f in encrypt_fields if f not in header]
        if missing_fields:
            raise ValueError(
                f"指定的加密欄位 {missing_fields} 在 CSV header 裡找不到，"
                f"實際 header: {header}，來源檔案: {input_path}"
            )

        encrypt_indices = [
            i for i, col_name in enumerate(header) if col_name in encrypt_fields
        ]

        row_count = 0
        for row_idx, row in enumerate(reader, start=2):
            if len(row) != len(header):
                raise ValueError(
                    f"第 {row_idx} 列欄位數量 ({len(row)}) 跟 header 數量 ({len(header)}) 不符，"
                    f"資料可能有換行符號污染或格式錯誤，來源檔案: {input_path}"
                )

            for idx in encrypt_indices:
                original_value = row[idx]
                try:
                    row[idx] = encrypt_value(original_value)
                except Exception as e:
                    raise RuntimeError(
                        f"第 {row_idx} 列第 {idx} 欄加密失敗，"
                        f"欄位名: {header[idx]}，原始值長度: {len(original_value)}，"
                        f"錯誤: {e}"
                    ) from e

            writer.writerow(row)
            row_count += 1

        if row_count == 0:
            raise ValueError(f"CSV 檔案沒有任何資料列（只有 header）: {input_path}")

        return row_count
