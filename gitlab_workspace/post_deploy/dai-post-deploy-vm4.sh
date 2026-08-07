#!/usr/bin/env bash
# =============================================================================
# dai-post-deploy-vm4.sh —— VM4 部署收尾（在 VM4 上以 root 執行）
# =============================================================================
# 安裝位置：/usr/local/sbin/dai-post-deploy-vm4.sh   （root:root 0755）
#
# 為什麼要一支固定腳本、而不是讓 CD 直接下 sudo chown？
#   如果 sudoers 寫 `gitlab_runner ALL=(root) NOPASSWD: /bin/chown`，
#   等於把整台機器送給任何拿到那把部署金鑰的人（chown 任意檔案 = root）。
#   改成「只放行這一支參數固定的腳本」，權限邊界就縮到剛好夠用。
#
#   /etc/sudoers.d/dai-gitlab-runner ：
#       gitlab_runner ALL=(root) NOPASSWD: /usr/local/sbin/dai-post-deploy-vm4.sh
#       Defaults!/usr/local/sbin/dai-post-deploy-vm4.sh !requiretty
#
#   ★ 腳本本身必須是 root 擁有、其他人不可寫 ★
#     否則 gitlab_runner 可以改腳本內容，等於還是拿到 root。
#       chown root:root /usr/local/sbin/dai-post-deploy-vm4.sh
#       chmod 755       /usr/local/sbin/dai-post-deploy-vm4.sh
#
# 做兩件事：
#   1. 把檔案擁有者改回 UID 10001（Dagster 容器的執行身分）
#   2. 重新產生 dbt manifest.json（Dagster 靠它才看得到新模型）
# =============================================================================

set -Eeuo pipefail

# ★ 這些值刻意寫死在腳本裡，不從呼叫端接參數 ★
#   接參數的話，gitlab_runner 就能指定任意路徑，等於繞回「萬用 chown」。
WORKSPACE="/data/deploy/workspace/dagster_workspace"
DAGSTER_UID=10001
DAGSTER_GID=10001
DBT_IMAGE="${DAI_DBT_IMAGE:-dai/dagster:v2.7}"
DBT_NETWORK="${DAI_DBT_NETWORK:-docker-compose_vm4-network}"
LOG_TAG="dai/post-deploy"

log() { echo "[post-deploy-vm4] $*"; logger -t "$LOG_TAG" -p user.info "DAI|INFO|vm4|$*" 2>/dev/null || true; }
err() { echo "[post-deploy-vm4] ERROR: $*" >&2; logger -t "$LOG_TAG" -p user.err "DAI|ERROR|vm4|$*" 2>/dev/null || true; }

[[ $EUID -eq 0 ]] || { err "必須以 root 執行（透過 sudo）"; exit 1; }
[[ -d "$WORKSPACE" ]] || { err "找不到工作目錄：${WORKSPACE}"; exit 1; }

# -----------------------------------------------------------------------------
# 1. 權限：Dagster 容器是以 UID 10001 跑的，rsync 過來的檔案屬於 gitlab_runner，
#    不改回去容器會 Permission denied（README Phase 0-7 講的就是這件事）
# -----------------------------------------------------------------------------
log "chown -R ${DAGSTER_UID}:${DAGSTER_GID} ${WORKSPACE}"
chown -R "${DAGSTER_UID}:${DAGSTER_GID}" "$WORKSPACE"

# 目錄 750 / 檔案 640：同群組可讀，其他人完全不可讀。
# 這裡面有 SQL 邏輯與表結構，不是公開資訊。
find "$WORKSPACE" -type d -exec chmod 750 {} +
find "$WORKSPACE" -type f -exec chmod 640 {} +

# .env 再收緊一階：只有擁有者能讀
if [[ -f "${WORKSPACE}/dagster_code/.env" ]]; then
    chmod 600 "${WORKSPACE}/dagster_code/.env"
    log "已收緊 dagster_code/.env 權限為 600"
else
    err "警告：${WORKSPACE}/dagster_code/.env 不存在，Dagster 會連不上資料庫。"
    err "      這個檔案不進版控、也不由 CD 部署，需要人工建立（見部署手冊 Phase 1）。"
fi
if [[ -f "${WORKSPACE}/dbt_project/profiles.yml" ]]; then
    chmod 600 "${WORKSPACE}/dbt_project/profiles.yml"
else
    err "警告：${WORKSPACE}/dbt_project/profiles.yml 不存在，dbt 會無法執行。"
fi

# -----------------------------------------------------------------------------
# 2. 重新產生 dbt manifest
#    dbt parse 只解析專案、不連資料庫、不執行 SQL，所以在部署階段跑是安全的。
#    Dagster 是讀 target/manifest.json 產生 dbt 資產的 —— 沒重產的話，
#    新加的模型在 UI 上根本不存在（見 04_新增一支dbt模型.md）。
# -----------------------------------------------------------------------------
log "重新產生 dbt manifest（dbt parse）"
if ! docker image inspect "$DBT_IMAGE" >/dev/null 2>&1; then
    err "找不到映像檔 ${DBT_IMAGE}，跳過 manifest 重產。"
    err "新模型不會出現在 Dagster UI，需人工處理（見 04_新增一支dbt模型.md 的附註）。"
    exit 1
fi

docker run --rm \
    -u "${DAGSTER_UID}:${DAGSTER_GID}" \
    -v "${WORKSPACE}/dbt_project:/app/workspace/dbt_project" \
    -w /app/workspace/dbt_project \
    --network "$DBT_NETWORK" \
    "$DBT_IMAGE" \
    dbt parse --profiles-dir . \
    || { err "dbt parse 失敗 —— 通常是模型語法錯、ref() 指到不存在的模型，或 sources.yml 沒登記。"; exit 1; }

[[ -f "${WORKSPACE}/dbt_project/target/manifest.json" ]] \
    || { err "dbt parse 跑完了但沒有產生 manifest.json，請人工確認"; exit 1; }

chown -R "${DAGSTER_UID}:${DAGSTER_GID}" "${WORKSPACE}/dbt_project/target"
log "manifest.json 已更新（$(date -r "${WORKSPACE}/dbt_project/target/manifest.json" '+%F %T')）"

log "完成。接下來請到 Dagster UI 執行 Reload definitions。"
