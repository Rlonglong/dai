#!/usr/bin/env bash
# =============================================================================
# 每日 log 雜湊存證（VM4）
# 部署路徑：/opt/dai/scripts/log_hash.sh   （0755，root 執行）
# =============================================================================
# 做什麼：
#   1. 對前一天所有已落地的 log 檔算 sha256
#   2. 寫成一份 manifest 存在 /var/log/dai-integrity/
#   3. 用 logger 送進 rsyslog（tag dai/log-integrity），
#      由 25-dai-integrity-fwd.conf 轉一份到 VM1（存兩台才擋得住單台竄改）
#
# cron（Phase 6-3）：
#   55 23 * * * root /opt/dai/scripts/log_hash.sh >> /var/log/dai-integrity/hash_cron.log 2>&1
#
# 為什麼算「前一天」而不是「今天」：23:55 執行時今天的檔案還在寫，
# 算出來的雜湊隔天就對不上。真正封存的是已經不會再變動的那一天。
# =============================================================================
set -euo pipefail

LOG_ROOT="${DAI_LOG_ROOT:-/data/log/dai}"
OUT_DIR="${DAI_INTEGRITY_DIR:-/var/log/dai-integrity}"
TARGET_DATE="${1:-$(date -d 'yesterday' +%Y-%m-%d)}"

MANIFEST="${OUT_DIR}/manifest-${TARGET_DATE}.sha256"

mkdir -p "$OUT_DIR"

if [[ ! -d "$LOG_ROOT" ]]; then
    echo "[FAIL] log 目錄不存在：${LOG_ROOT}" >&2
    exit 1
fi

# 只收該日期的 log 檔（檔名就是 YYYY-MM-DD.log，見 vm4-server.conf 的 DynaFile）
mapfile -t FILES < <(find "$LOG_ROOT" -type f -name "${TARGET_DATE}.log" | sort)

if (( ${#FILES[@]} == 0 )); then
    echo "[WARN] ${TARGET_DATE} 沒有任何 log 檔，不產生 manifest"
    logger -t 'dai/log-integrity' \
        "MANIFEST date=${TARGET_DATE} files=0 note=no-log-files"
    exit 0
fi

sha256sum "${FILES[@]}" > "$MANIFEST"
chmod 640 "$MANIFEST"
chgrp dai_admin "$MANIFEST" 2>/dev/null || true

# manifest 自己的雜湊 —— 這一行才是送出去存證的重點：
# 之後只要重算 manifest 的 sha256，跟 VM1 上收到的那一行比對，
# 就知道 VM4 上的 manifest 有沒有被動過。
MANIFEST_HASH="$(sha256sum "$MANIFEST" | awk '{print $1}')"

logger -t 'dai/log-integrity' \
    "MANIFEST date=${TARGET_DATE} files=${#FILES[@]} sha256=${MANIFEST_HASH} path=${MANIFEST}"

echo "[ OK ] ${TARGET_DATE}：${#FILES[@]} 個檔案，manifest=${MANIFEST}"
echo "       sha256=${MANIFEST_HASH}"
