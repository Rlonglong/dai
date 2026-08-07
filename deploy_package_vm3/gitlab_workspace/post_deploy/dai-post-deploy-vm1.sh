#!/usr/bin/env bash
# =============================================================================
# dai-post-deploy-vm1.sh —— VM1 部署收尾（在 VM1 上以 root 執行）
# =============================================================================
# 安裝位置：/usr/local/sbin/dai-post-deploy-vm1.sh   （root:root 0755）
#
# sudoers（/etc/sudoers.d/dai-gitlab-runner）：
#     gitlab_runner ALL=(root) NOPASSWD: /usr/local/sbin/dai-post-deploy-vm1.sh
#     Defaults!/usr/local/sbin/dai-post-deploy-vm1.sh !requiretty
#
# ★ 路徑寫死在腳本裡，不接參數 ★
#   理由同 VM4 版本：能帶路徑的 chown 等於萬用 root。
#
# 做三件事：
#   1. 擁有者改回 bcp_runner（腳本是由 bcp_runner 執行的，Dagster 從 VM4 ssh 進來就是這個身分）
#   2. 收緊權限
#   3. 語法自我檢查（py_compile），避免推了一支語法錯的腳本上去，
#      要等當晚排程跑到才發現
# =============================================================================

set -Eeuo pipefail

SCRIPTS_DIR="/home/bcp_runner/scripts"
RUN_USER="bcp_runner"
RUN_GROUP="bcp_runner"
VENV="${DAI_VM1_VENV:-/run/media/root/D/python_env/dai_venv}"
LOG_TAG="dai/post-deploy"

log() { echo "[post-deploy-vm1] $*"; logger -t "$LOG_TAG" -p user.info "DAI|INFO|vm1|$*" 2>/dev/null || true; }
err() { echo "[post-deploy-vm1] ERROR: $*" >&2; logger -t "$LOG_TAG" -p user.err "DAI|ERROR|vm1|$*" 2>/dev/null || true; }

[[ $EUID -eq 0 ]] || { err "必須以 root 執行（透過 sudo）"; exit 1; }
[[ -d "$SCRIPTS_DIR" ]] || { err "找不到腳本目錄：${SCRIPTS_DIR}"; exit 1; }
id "$RUN_USER" >/dev/null 2>&1 || { err "使用者 ${RUN_USER} 不存在"; exit 1; }

# -----------------------------------------------------------------------------
# 1 + 2. 擁有者與權限
# -----------------------------------------------------------------------------
log "chown -R ${RUN_USER}:${RUN_GROUP} ${SCRIPTS_DIR}"
chown -R "${RUN_USER}:${RUN_GROUP}" "$SCRIPTS_DIR"

# 750/640：只有 bcp_runner（與同群組）碰得到。
# 這些腳本裡有資料處理邏輯與檔案路徑，且它們讀得到 /home/bcp_runner/.env。
find "$SCRIPTS_DIR" -type d -exec chmod 750 {} +
find "$SCRIPTS_DIR" -type f -exec chmod 640 {} +

# Dagster Pipes 是用 `python xxx.py` 呼叫的，不靠 shebang，
# 所以這裡不需要給執行位元 —— 少一個位元就少一條被誤用的路。
# 真的有需要直接執行的 .sh，才個別開。
while IFS= read -r -d '' sh_file; do
    chmod 750 "$sh_file"
    log "已給予執行權限：${sh_file#"$SCRIPTS_DIR"/}"
done < <(find "$SCRIPTS_DIR" -type f -name '*.sh' -print0)

# .env 不在這個目錄裡（在 /home/bcp_runner/.env），順手確認它還在且權限正確
if [[ -f /home/bcp_runner/.env ]]; then
    chown "${RUN_USER}:${RUN_GROUP}" /home/bcp_runner/.env
    chmod 600 /home/bcp_runner/.env
else
    err "警告：/home/bcp_runner/.env 不存在，腳本會拿不到 DB／FTP／ZIP 密碼。"
    err "      這個檔案不進版控、也不由 CD 部署，需人工建立（見部署手冊 Phase 5.4）。"
fi

# -----------------------------------------------------------------------------
# 3. 語法自我檢查
#    CI 上已經跑過 flake8，這裡再用「VM1 實際的 Python 版本」編一次：
#    CI runner 與 VM1 的 Python 版本不見得一樣，只有這裡驗得出版本相關的語法問題。
# -----------------------------------------------------------------------------
PY="python3"
[[ -x "${VENV}/bin/python" ]] && PY="${VENV}/bin/python"
log "以 ${PY} 檢查腳本語法（$("$PY" --version 2>&1)）"

if ! sudo -u "$RUN_USER" "$PY" -m compileall -q "$SCRIPTS_DIR" > /tmp/dai_compile.log 2>&1; then
    err "腳本語法檢查失敗，VM1 上的腳本可能無法執行："
    sed 's/^/       /' /tmp/dai_compile.log >&2
    rm -f /tmp/dai_compile.log
    err "請修好之後重新走一次 MR → main → CD。"
    exit 1
fi
rm -f /tmp/dai_compile.log

# compileall 會產生 __pycache__，它在 rsync 排除清單裡，但清掉比較乾淨
find "$SCRIPTS_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

log "完成。下一次 Dagster 觸發時就會用到新版腳本（不需要重啟任何服務）。"
