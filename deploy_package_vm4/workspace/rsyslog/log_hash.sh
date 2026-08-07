#!/usr/bin/env bash
# =============================================================================
# DAI 每日 log 完整性 hash 計算腳本
# 執行位置：VM4
# cron 排程：55 23 * * * /opt/dai/scripts/log_hash.sh >> /var/log/dai-log-integrity/hash_cron.log 2>&1
# =============================================================================
set -euo pipefail

LOG_DIR="/var/log/dai"
INTEGRITY_DIR="/var/log/dai-integrity"
DATE=$(date +%Y-%m-%d)
DATETIME=$(date -Iseconds)
SOURCE_HOST=$(hostname)
SOURCE_IP=$(hostname -I | awk '{print $1}')
MANIFEST_FILE="${INTEGRITY_DIR}/${DATE}.sha256"

mkdir -p "${INTEGRITY_DIR}"
chmod 750 "${INTEGRITY_DIR}"

echo "[$(date -Iseconds)] log_hash.sh started"

# -----------------------------------------------------------------------------
# 1. 計算所有 log 檔案 SHA-256
# -----------------------------------------------------------------------------
{
  echo "# NexFlow Log Integrity Manifest"
  echo "# Date: ${DATE}"
  echo "# Generated: ${DATETIME}"
  echo "# Source: ${SOURCE_HOST} (${SOURCE_IP})"
  echo "#"
  # 只計算當日及昨日的 log 檔（避免遺漏跨午夜寫入）
  YESTERDAY=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
  find "${LOG_DIR}" -type f \( -name "${DATE}.log" -o -name "${YESTERDAY}.log" \) \
    | sort \
    | while read -r logfile; do
        if [ -r "${logfile}" ]; then
          sha256sum "${logfile}"
        fi
      done
  echo "#"
} > "${MANIFEST_FILE}"

# 計算 manifest 本身的 master hash
MASTER_HASH=$(sha256sum "${MANIFEST_FILE}" | awk '{print $1}')
echo "# MASTER_HASH: ${MASTER_HASH}" >> "${MANIFEST_FILE}"

chmod 640 "${MANIFEST_FILE}"

# -----------------------------------------------------------------------------
# 2. 透過 rsyslog 傳送至 VM1（nexflow-client.conf 負責轉發）
# -----------------------------------------------------------------------------
FILE_COUNT=$(grep -c "^[a-f0-9]\{64\}" "${MANIFEST_FILE}" || true)

# 傳送 manifest header
logger -t "dai/log-integrity" -p local0.notice \
  "MANIFEST_START|DATE=${DATE}|SOURCE=${SOURCE_HOST}|FILES=${FILE_COUNT}|MASTER_HASH=${MASTER_HASH}"

# 逐行傳送 hash 記錄（跳過註解行）
grep "^[a-f0-9]\{64\}" "${MANIFEST_FILE}" | while IFS= read -r line; do
  logger -t "dai/log-integrity" -p local0.info "HASH|${DATE}|${line}"
done

# 傳送 manifest 結束標記
logger -t "dai/log-integrity" -p local0.notice \
  "MANIFEST_END|DATE=${DATE}|SOURCE=${SOURCE_HOST}|MASTER_HASH=${MASTER_HASH}"

echo "[$(date -Iseconds)] log_hash.sh completed: ${FILE_COUNT} files, master=${MASTER_HASH}"
echo "[$(date -Iseconds)] Manifest: ${MANIFEST_FILE}"
