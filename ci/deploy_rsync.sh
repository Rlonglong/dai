#!/usr/bin/env bash
# =============================================================================
# ci/deploy_rsync.sh —— CD：把程式碼用 rsync 推到目標機
# =============================================================================
# 只在「合併進 main」之後跑（規則寫在 .gitlab-ci.yml）。
#
# 需要的 CI/CD Variables（正式環境請勾 Protected + Masked，
# 並用 environment scope 分開 staging / production）：
#
#   DEPLOY_HOST      目標機 IP 或主機名（VM4 或 VM1）
#   DEPLOY_USER      目標機上的帳號，固定用 gitlab_runner
#   DEPLOY_PATH      目標機上的絕對路徑
#                      VM4: /data/deploy/workspace/dagster_workspace
#                      VM1: /home/bcp_runner/scripts
#   DEPLOY_SSH_KEY   私鑰內容（File 型別的 Variable）
#   DEPLOY_KNOWN_HOSTS  目標機的 host key（File 型別）★不要用 StrictHostKeyChecking=no★
#   SOURCE_DIR       要推的來源目錄（本 repo 是 dagster_workspace）
#   POST_DEPLOY_CMD  （選用）部署後在目標機上執行的指令，
#                    例：sudo /usr/local/sbin/dai-post-deploy-vm4.sh
#
# 用法：ci/deploy_rsync.sh [--dry-run]
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

need_cmd rsync
need_cmd ssh
require_vars DEPLOY_HOST DEPLOY_USER DEPLOY_PATH DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS SOURCE_DIR

ROOT="$(repo_root)"
EXCLUDE_FILE="${ROOT}/deploy_exclude.txt"
[[ -f "$EXCLUDE_FILE" ]] || die "找不到排除清單：${EXCLUDE_FILE}"
[[ -d "${ROOT}/${SOURCE_DIR}" ]] || die "來源目錄不存在：${ROOT}/${SOURCE_DIR}"

# -----------------------------------------------------------------------------
# SSH 設定
#   GitLab 的 File 型別 Variable 會把內容寫成暫存檔，$DEPLOY_SSH_KEY 是那個檔案的路徑。
#   權限一定要 600，否則 ssh 會直接拒用。
# -----------------------------------------------------------------------------
SSH_DIR="$(mktemp -d)"
trap 'rm -rf "$SSH_DIR"' EXIT
install -m 600 "$DEPLOY_SSH_KEY"     "${SSH_DIR}/id_deploy"
install -m 644 "$DEPLOY_KNOWN_HOSTS" "${SSH_DIR}/known_hosts"

# StrictHostKeyChecking=yes：認 known_hosts，不接受未知的主機金鑰。
# 這是防中間人的關鍵，正式環境不要為了「方便」改成 no。
SSH_CMD="ssh -i ${SSH_DIR}/id_deploy \
    -o UserKnownHostsFile=${SSH_DIR}/known_hosts \
    -o StrictHostKeyChecking=yes \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=15"

TARGET="${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/"

section "CD · 部署 ${SOURCE_DIR}/ → ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/"
log_info "commit    : ${CI_COMMIT_SHA:-unknown} (${CI_COMMIT_REF_NAME:-local})"
log_info "environment: ${CI_ENVIRONMENT_NAME:-未指定}"

# -----------------------------------------------------------------------------
# 先連線測試：與其讓 rsync 傳一半才失敗，不如先確認通得到
# -----------------------------------------------------------------------------
$SSH_CMD "${DEPLOY_USER}@${DEPLOY_HOST}" "test -d '${DEPLOY_PATH}'" \
    || die "SSH 連線失敗，或目標目錄不存在：${DEPLOY_PATH}
     檢查順序：
       1. VM3 到 ${DEPLOY_HOST} 的 22 port 防火牆有沒有開
       2. 目標機上有沒有 gitlab_runner 這個帳號、~/.ssh/authorized_keys 有沒有這把公鑰
       3. DEPLOY_KNOWN_HOSTS 的內容是不是目標機現在的 host key
       4. 目標目錄有沒有先建好、gitlab_runner 有沒有寫入權限（setfacl）
     見 gitlab_workspace/GitLab維運手冊/附錄/A_gitlab_runner帳號與SSH金鑰.md"

# -----------------------------------------------------------------------------
# rsync
#   -a            保留權限/時間/連結
#   --delete      目標端多出來的檔案要刪掉，才能真正做到「以 repo 為準」
#   --exclude-from  排除清單；★--delete 不會刪被排除的檔案★
#                 （那是 --delete-excluded 的行為，我們刻意不用）
#                 .env 和 profiles.yml 的存活就是靠這個機制
#   --checksum    不看 mtime，只看內容。CI 每次都是全新 checkout，
#                 mtime 一定跟目標端不同，用預設的 size+mtime 會每次全量重傳
#   --human-readable --itemize-changes  讓 pipeline log 看得出到底改了什麼
# -----------------------------------------------------------------------------
RSYNC_OPTS=(
    -a --delete --checksum
    --human-readable --itemize-changes
    --exclude-from="$EXCLUDE_FILE"
    -e "$SSH_CMD"
)
[[ $DRY_RUN -eq 1 ]] && RSYNC_OPTS+=( --dry-run ) && log_warn "DRY-RUN 模式：不會真的寫入目標機"

log_info "開始同步..."
rsync "${RSYNC_OPTS[@]}" "${ROOT}/${SOURCE_DIR}/" "$TARGET" || die "rsync 失敗"
log_ok "rsync 完成"

if [[ $DRY_RUN -eq 1 ]]; then
    log_warn "DRY-RUN 結束，未執行 post-deploy、未驗證雜湊。"
    exit 0
fi

# -----------------------------------------------------------------------------
# post-deploy（在目標機上跑）
#   VM4：chown 回 UID 10001（Dagster 容器的執行身分）+ 重產 dbt manifest
#   VM1：chown 回 bcp_runner + 補執行權限
#   為了不給 gitlab_runner 萬用 sudo，目標機上是一支 root 擁有的固定腳本，
#   sudoers 只放行那一支。細節見 gitlab_workspace/post_deploy/dai-post-deploy-vm4.sh 開頭的說明。
# -----------------------------------------------------------------------------
if [[ -n "${POST_DEPLOY_CMD:-}" ]]; then
    section "CD · post-deploy"
    log_info "在 ${DEPLOY_HOST} 上執行：${POST_DEPLOY_CMD}"
    $SSH_CMD "${DEPLOY_USER}@${DEPLOY_HOST}" "${POST_DEPLOY_CMD}" \
        || die "post-deploy 失敗（程式碼已同步，但收尾動作沒做完，請人工確認）"
    log_ok "post-deploy 完成"
fi

# -----------------------------------------------------------------------------
# 部署後立刻對一次雜湊
#   不是等隔天排程才發現同步不完整 —— 那時候 Dagster 可能已經用錯的程式碼跑了一整晚。
# -----------------------------------------------------------------------------
section "CD · 部署後完整性驗證"
"${ROOT}/ci/verify_sync.sh" \
    || die "部署後雜湊比對不一致！程式碼可能只同步了一半，請立刻人工確認 ${DEPLOY_HOST}:${DEPLOY_PATH}"

log_ok "部署完成並通過完整性驗證：${DEPLOY_HOST}:${DEPLOY_PATH}"
