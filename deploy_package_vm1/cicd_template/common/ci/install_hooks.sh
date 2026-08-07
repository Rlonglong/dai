#!/usr/bin/env bash
# =============================================================================
# ci/install_hooks.sh —— 安裝本地 git hooks（每位開發者 clone 完跑一次）
# =============================================================================
# 用法：
#   ci/install_hooks.sh              安裝
#   ci/install_hooks.sh --check      只檢查有沒有裝好（CI 或稽核用）
#   ci/install_hooks.sh --uninstall  移除
#
# 做法是設定 core.hooksPath 指向 ci/hooks/，不是把檔案複製進 .git/hooks/。
# 好處：hook 內容跟著 repo 一起版控，改了大家 git pull 就同步生效，
#       不會出現「有人的機器上還是三個月前的舊 hook」。
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ROOT="$(repo_root)"
HOOKS_REL="ci/hooks"
MODE="${1:-install}"

case "$MODE" in
    --uninstall)
        git -C "$ROOT" config --unset core.hooksPath 2>/dev/null || true
        log_ok "已移除 hooks 設定（改回使用 .git/hooks/）"
        exit 0
        ;;
    --check)
        current="$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || echo "")"
        if [[ "$current" != "$HOOKS_REL" ]]; then
            die "本機還沒安裝 git hooks（core.hooksPath = '${current:-未設定}'）
     請執行：ci/install_hooks.sh"
        fi
        log_ok "git hooks 已正確安裝"
        exit 0
        ;;
    install) ;;
    *) die "未知的參數：$MODE" ;;
esac

section "安裝 DAI git hooks"

chmod +x "${ROOT}/${HOOKS_REL}"/* "${ROOT}/ci"/*.sh
git -C "$ROOT" config core.hooksPath "$HOOKS_REL"
log_ok "core.hooksPath → ${HOOKS_REL}"

# -----------------------------------------------------------------------------
# 檢查外部工具在不在。缺工具時 hook 會印警告然後跳過那一項，
# 所以這裡先講清楚，免得有人以為「都沒報錯 = 都有掃」。
# -----------------------------------------------------------------------------
echo "" >&2
printf '  %-10s %s\n' "工具" "狀態" >&2
printf '  %-10s %s\n' "----" "----" >&2
missing_critical=0
for tool in gitleaks flake8 bandit sqlfluff black pip-audit; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '  %-12s ✅ %s\n' "$tool" "$(command -v "$tool")" >&2
    else
        printf '  %-12s ❌ 未安裝\n' "$tool" >&2
        [[ "$tool" == "gitleaks" ]] && missing_critical=1
    fi
done
echo "" >&2

if [[ $missing_critical -eq 1 ]]; then
    log_error "缺少 gitleaks —— 這是唯一不可缺的工具，沒有它 hook 會直接擋下所有 commit/push。"
    cat >&2 <<'EOF'

  安裝方式（離線環境請先把 binary 帶進來）：
      # 從內部檔案伺服器 / 光碟取得 gitleaks binary
      install -m 755 gitleaks ~/.local/bin/gitleaks
      # 或指定路徑
      export GITLEAKS_BIN=/opt/tools/gitleaks     # 建議寫進 ~/.bashrc

EOF
    exit 1
fi

cat >&2 <<'EOF'
安裝完成。從現在開始：

  git commit  →  掃 staged 內容（gitleaks + flake8/bandit/sqlfluff）
  git push    →  掃「整批要推出去的 commit」+ 工作目錄現況

  ★ 就算你用 --no-verify 繞過，VM3 的 pre-receive hook 還是會把 push 擋掉 ★
    那一關掃的是同一份 .gitleaks.toml，結果一定一致。

品質檢查誤判、真的趕時間時：
      DAI_SKIP_QUALITY=1 git push       ← 只跳過 flake8/bandit/sqlfluff/black
                                           gitleaks 永遠會跑
EOF
