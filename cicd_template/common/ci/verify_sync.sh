#!/usr/bin/env bash
# =============================================================================
# ci/verify_sync.sh —— 同步完整性稽核（雜湊對帳）
# =============================================================================
# 什麼時候會跑：
#   1. 每次 CD 部署完，馬上跑一次（deploy_rsync.sh 最後一步）
#   2. GitLab 排程 pipeline，每天固定時間跑一次（$CI_PIPELINE_SOURCE == "schedule"）
#
# 它在回答一個問題：
#   「GitLab 上 main 分支的內容，跟正式機上實際跑的檔案，現在還是同一份嗎？」
#
# 抓得到的情況：
#   - rsync 傳到一半斷線，只同步了部分檔案
#   - 有人直接 ssh 上正式機改檔案（最常見，也最危險）
#   - 磁碟毀損、檔案被其他程序覆寫
#   - 有人在正式機上塞了 repo 裡沒有的檔案
#
# 抓不到的情況（要知道邊界在哪）：
#   - 被排除的檔案（.env、target/、logs/）本來就不比對
#   - 「main 分支本身被塞了壞東西」不是這支的守備範圍，那是 MR review + gitleaks 的事
#
# 需要的環境變數：跟 deploy_rsync.sh 同一組
# 用法：ci/verify_sync.sh
# 離開碼：0 = 一致；1 = 不一致（pipeline 會紅燈）；2 = 環境/連線問題
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_cmd ssh
require_vars DEPLOY_HOST DEPLOY_USER DEPLOY_PATH DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS SOURCE_DIR

ROOT="$(repo_root)"
EXCLUDE_FILE="${ROOT}/deploy_exclude.txt"
MANIFEST_SCRIPT="${ROOT}/ci/sync_manifest.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

install -m 600 "$DEPLOY_SSH_KEY"     "${WORK}/id_deploy"
install -m 644 "$DEPLOY_KNOWN_HOSTS" "${WORK}/known_hosts"

ssh_run() {
    ssh -i "${WORK}/id_deploy" \
        -o UserKnownHostsFile="${WORK}/known_hosts" \
        -o StrictHostKeyChecking=yes \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"
}

section "完整性稽核 · ${SOURCE_DIR}/ ⟷ ${DEPLOY_HOST}:${DEPLOY_PATH}"

# --- 來源端（GitLab runner 上的 checkout）------------------------------------
log_info "計算來源端雜湊..."
bash "$MANIFEST_SCRIPT" "${ROOT}/${SOURCE_DIR}" "$EXCLUDE_FILE" > "${WORK}/local.txt" \
    || die "來源端雜湊計算失敗"

# --- 目標端（透過 ssh 執行同一支腳本）----------------------------------------
# 腳本和排除清單都是這次現送過去的，不依賴目標機上有沒有留舊版本。
# 兩端跑的是**同一份程式碼、同一份規則**，才不會出現「規則版本不同算出不同答案」
# 的假警報 —— 稽核工具自己誤報，比不做稽核更浪費人力。
log_info "計算目標端雜湊（遠端執行）..."
RTMP="/tmp/.dai_verify_$$"
ssh_run "mkdir -p '${RTMP}' && chmod 700 '${RTMP}'" || die "無法在目標機建立暫存目錄"
cleanup_remote() { ssh_run "rm -rf '${RTMP}'" >/dev/null 2>&1 || true; }

ssh_run "cat > '${RTMP}/sync_manifest.sh'"   < "$MANIFEST_SCRIPT" || { cleanup_remote; die "腳本傳送失敗"; }
ssh_run "cat > '${RTMP}/deploy_exclude.txt'" < "$EXCLUDE_FILE"    || { cleanup_remote; die "排除清單傳送失敗"; }

if ! ssh_run "bash '${RTMP}/sync_manifest.sh' '${DEPLOY_PATH}' '${RTMP}/deploy_exclude.txt'" \
        > "${WORK}/remote.txt" 2>"${WORK}/remote_err.txt"; then
    cat "${WORK}/remote_err.txt" >&2
    cleanup_remote
    die "目標端雜湊計算失敗（常見原因：gitlab_runner 對 ${DEPLOY_PATH} 沒有讀取權限）"
fi
cleanup_remote

# --- 比對 ---------------------------------------------------------------------
local_total="$(grep '^TOTAL ' "${WORK}/local.txt"  | tail -1)"
remote_total="$(grep '^TOTAL ' "${WORK}/remote.txt" | tail -1)"

log_info "來源端: ${local_total}"
log_info "目標端: ${remote_total}"

if [[ "$local_total" == "$remote_total" ]]; then
    log_ok "完整性驗證通過：兩端內容一致（${local_total#TOTAL }）"
    exit 0
fi

# --- 不一致：把差異列出來，而不是只說「不一樣」-------------------------------
log_error "完整性驗證失敗：${DEPLOY_HOST}:${DEPLOY_PATH} 與 GitLab main 分支不一致"
echo "" >&2

grep -v '^TOTAL ' "${WORK}/local.txt"  | LC_ALL=C sort > "${WORK}/l.sorted"
grep -v '^TOTAL ' "${WORK}/remote.txt" | LC_ALL=C sort > "${WORK}/r.sorted"

awk '{print $2}' "${WORK}/l.sorted" | LC_ALL=C sort > "${WORK}/l.names"
awk '{print $2}' "${WORK}/r.sorted" | LC_ALL=C sort > "${WORK}/r.names"

only_local="$(LC_ALL=C comm -23 "${WORK}/l.names" "${WORK}/r.names")"
only_remote="$(LC_ALL=C comm -13 "${WORK}/l.names" "${WORK}/r.names")"
both="$(LC_ALL=C comm -12 "${WORK}/l.names" "${WORK}/r.names")"

if [[ -n "$only_local" ]]; then
    echo "  ▸ 只有 GitLab 有、正式機缺少（同步沒完成）：" >&2
    printf '%s\n' "$only_local" | sed 's/^/      /' >&2
    echo "" >&2
fi

if [[ -n "$only_remote" ]]; then
    echo "  ▸ 只有正式機有、GitLab 沒有（有人直接在機器上加檔案，或排除清單漏了）：" >&2
    printf '%s\n' "$only_remote" | sed 's/^/      /' >&2
    echo "" >&2
fi

changed=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    lh="$(awk -v p="$f" '$2==p{print $1; exit}' "${WORK}/l.sorted")"
    rh="$(awk -v p="$f" '$2==p{print $1; exit}' "${WORK}/r.sorted")"
    [[ "$lh" != "$rh" ]] && changed+="      ${f}"$'\n'
done <<< "$both"

if [[ -n "$changed" ]]; then
    echo "  ▸ 兩邊都有但內容不同（★最可疑：有人直接改了正式機★）：" >&2
    printf '%s' "$changed" >&2
    echo "" >&2
fi

cat >&2 <<EOF
--------------------------------------------------------------------------------
[要怎麼處理]
  1. 先確認不是有人在正式機上手改：
        ssh ${DEPLOY_USER}@${DEPLOY_HOST}
        ls -la --time-style=full-iso ${DEPLOY_PATH}
     對照上面「內容不同」的清單，看 mtime 落在什麼時候、當時是誰上機。
  2. 確定正式機那份不用留 → 重跑一次 CD job，rsync --delete 會把它拉回一致。
  3. 正式機那份是「還沒進版控的緊急修補」→ 先把它抓回本地、走正常 MR 流程補上，
     再重跑 CD。直接重跑會把修補洗掉。
  4. 是排除清單漏了（例如新增了一種執行期產物）→ 同時更新
        deploy_exclude.txt   （rsync 不傳、不刪）
        .gitignore           （不進版控）
     兩份都要改，只改一邊會在下一次稽核繼續報。

這次的比對結果已經送進 rsyslog（tag: ${DAI_LOG_TAG}），
會被集中到 VM4 的 /data/log/dai 並納入每日雜湊存證。
--------------------------------------------------------------------------------
EOF

exit 1
