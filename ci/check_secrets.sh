#!/usr/bin/env bash
# =============================================================================
# ci/check_secrets.sh —— gitleaks 統一入口
# =============================================================================
# 本地 hook、伺服器端 pre-receive、CI job 全都呼叫這一支，
# 規則（.gitleaks.toml）與判讀方式只有一份，不會出現「本地過了但 CI 擋」。
#
# 用法：
#   ci/check_secrets.sh staged                  # pre-commit：只掃 staged 內容
#   ci/check_secrets.sh range <base> <head>     # pre-push / pre-receive：掃 commit 範圍
#   ci/check_secrets.sh unpushed <head>         # pre-push：掃「還沒進 remote 的所有 commit」
#   ci/check_secrets.sh tree                    # CI：掃工作目錄現況
#   ci/check_secrets.sh history                 # CI：掃全部 git 歷史（最慢，排程用）
#
# 環境變數：
#   GITLEAKS_BIN  gitleaks 執行檔路徑（預設找 PATH 上的 gitleaks）
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

GITLEAKS_BIN="${GITLEAKS_BIN:-$(command -v gitleaks || true)}"
CONFIG="$(repo_root)/.gitleaks.toml"

if [[ -z "$GITLEAKS_BIN" || ! -x "$GITLEAKS_BIN" ]]; then
    die "找不到 gitleaks 執行檔。
     設定方式：export GITLEAKS_BIN=/path/to/gitleaks
     或把它放進 PATH。安裝方式見 gitlab_workspace/GitLab維運手冊/日常維運/03_本地環境設定與提交前檢查.md"
fi

MODE="${1:-tree}"
REPORT="$(mktemp -t gitleaksXXXXXX).json"
# shellcheck disable=SC2064
trap "rm -f '$REPORT'" EXIT

common=( --config "$CONFIG" --report-format json --report-path "$REPORT" --no-banner --redact )

case "$MODE" in
    staged)
        # protect --staged：只看 index 裡還沒 commit 的內容
        "$GITLEAKS_BIN" protect --staged "${common[@]}" >/dev/null 2>&1 || true
        scope="已 staged 的變更"
        ;;
    range)
        base="${2:?用法: check_secrets.sh range <base> <head>}"
        head="${3:?用法: check_secrets.sh range <base> <head>}"
        "$GITLEAKS_BIN" detect --source "$(repo_root)" \
            --log-opts="--no-merges ${base}..${head}" "${common[@]}" >/dev/null 2>&1 || true
        scope="commit 範圍 ${base:0:12}..${head:0:12}"
        ;;
    unpushed)
        head="${2:-HEAD}"
        # 「reachable from HEAD 但不在任何 remote 分支上」= 這次要推出去的東西
        "$GITLEAKS_BIN" detect --source "$(repo_root)" \
            --log-opts="--no-merges ${head} --not --remotes=origin" "${common[@]}" >/dev/null 2>&1 || true
        scope="尚未推送的 commit"
        ;;
    tree)
        "$GITLEAKS_BIN" detect --no-git --source "$(repo_root)" "${common[@]}" >/dev/null 2>&1 || true
        scope="工作目錄現況"
        ;;
    history)
        "$GITLEAKS_BIN" detect --source "$(repo_root)" "${common[@]}" >/dev/null 2>&1 || true
        scope="全部 git 歷史"
        ;;
    *)
        die "未知的模式：$MODE（可用：staged / range / unpushed / tree / history）"
        ;;
esac

# -----------------------------------------------------------------------------
# 判讀報告
#   gitleaks 的 exit code 在不同版本/模式下不一致（而且我們上面用 `|| true` 吞掉了），
#   所以一律以「報告檔裡有沒有 finding」為準，這是唯一可靠的判斷依據。
# -----------------------------------------------------------------------------
count=0
if [[ -s "$REPORT" ]]; then
    count="$(python3 - "$REPORT" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    # 報告壞掉時當成「有問題」，寧可誤擋也不要漏掉
    print(-1); sys.exit(0)
print(len(data) if isinstance(data, list) else 0)
PY
)"
fi

if [[ "$count" == "-1" ]]; then
    die "gitleaks 報告無法解析，視為檢查失敗（掃描範圍：${scope}）"
fi

if [[ "$count" -gt 0 ]]; then
    log_error "Gitleaks 掃描失敗！在「${scope}」發現 ${count} 個疑似金鑰。"
    echo "" >&2
    python3 - "$REPORT" <<'PY' >&2
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    findings = json.load(fh)
for i, f in enumerate(findings, 1):
    print(f"  [{i}] {f.get('RuleID', '?')}")
    print(f"      檔案  : {f.get('File', '?')}:{f.get('StartLine', '?')}")
    if f.get("Commit"):
        print(f"      commit: {f['Commit'][:12]}  作者: {f.get('Author', '?')}")
    print(f"      內容  : {f.get('Secret', '(redacted)')}")
    print()
PY
    cat >&2 <<'EOF'
[怎麼修]
  1. 先把金鑰「作廢並換掉」——已經寫進 git 的東西就當作已外洩，改檔案不等於安全。
  2. 從程式碼移除，改讀環境變數（VM4 走 dagster_code/.env，VM1 走 /home/bcp_runner/.env）。
  3. 如果已經 commit 了，歷史也要清：
         git filter-repo --path <檔案> --invert-paths
     清完要強制推送，並通知所有人重新 clone。
  4. 確定是誤判（例如範本裡的假值），改 .gitleaks.toml 的 allowlist，
     用最小範圍的 regex 並在 MR 說明理由——不要整個路徑放行。

[不要這樣做]
  用 --no-verify 繞過本地 hook 沒有用：VM3 的 pre-receive hook 會在伺服器端再擋一次，
  push 會直接被拒絕，東西根本進不了遠端 repo。
EOF
    exit 1
fi

log_ok "Gitleaks 掃描完畢，未發現金鑰（掃描範圍：${scope}）。"
