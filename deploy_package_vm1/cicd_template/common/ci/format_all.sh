#!/usr/bin/env bash
# =============================================================================
# ci/format_all.sh —— 一次性：把全庫整成 black / sqlfluff 格式
# =============================================================================
# 什麼時候用：
#   導入 CI 的第一週，開一個「只有格式化、沒有任何邏輯改動」的 MR。
#   之後就不需要再跑了，日常靠 hook 與 CI 維持。
#
# 為什麼要單獨開一個 MR：
#   格式化會動到幾千行，跟功能改動混在一起的話 review 根本看不出重點。
#   分開之後 reviewer 可以直接確認「這個 MR 只有排版」，快速放行。
#
# ★ 跑之前 ★
#   1. 確認工作目錄是乾淨的（git status）
#   2. 跑完務必 review diff，尤其是 sqlfluff fix 的部分
#   3. dbt 模型格式化後，建議挑幾支 dbt compile 比對編譯結果沒變
#
# 用法：
#   ci/format_all.sh          # 實際修改檔案
#   ci/format_all.sh --check  # 只看有多少檔案需要動，不修改
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ROOT="$(repo_root)"
cd "$ROOT"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

if [[ $CHECK_ONLY -eq 0 ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        die "工作目錄不乾淨。請先 commit 或 stash，再跑全庫格式化 ——
     否則格式化的改動會跟你手上的改動混在一起，分不開。"
    fi
fi

section "全庫格式化 $([[ $CHECK_ONLY -eq 1 ]] && echo '（僅檢查）')"

mapfile -t PY_FILES < <(git ls-files -- '*.py' | grep -v '^\._' || true)
mapfile -t SQL_FILES < <(git ls-files -- 'dagster_workspace/dbt_project/*.sql' \
                                        'dagster_workspace/dbt_project/**/*.sql' | grep -v '^\._' || true)

log_info "Python：${#PY_FILES[@]} 個檔案"
log_info "SQL   ：${#SQL_FILES[@]} 個檔案"

if ((${#PY_FILES[@]} > 0)) && command -v black >/dev/null 2>&1; then
    if [[ $CHECK_ONLY -eq 1 ]]; then
        black --check "${PY_FILES[@]}" || true
    else
        black "${PY_FILES[@]}"
        log_ok "black 完成"
    fi
fi

if ((${#SQL_FILES[@]} > 0)) && command -v sqlfluff >/dev/null 2>&1; then
    if [[ $CHECK_ONLY -eq 1 ]]; then
        sqlfluff lint --processes 1 "${SQL_FILES[@]}" || true
    else
        # --force：不要每個檔案都問一次
        sqlfluff fix --processes 1 --force "${SQL_FILES[@]}" || \
            log_warn "sqlfluff fix 有部分檔案修不掉，請看上面的訊息手動處理"
        log_ok "sqlfluff 完成"
    fi
fi

if [[ $CHECK_ONLY -eq 0 ]]; then
    echo "" >&2
    cat >&2 <<'EOF'
--------------------------------------------------------------------------------
接下來：
  1. git diff --stat            看動到哪些檔案
  2. git diff                   ★一定要看過★ 特別是 sqlfluff 改的 SQL
  3. 挑幾支 dbt 模型 compile 一次，確認編譯結果跟格式化前一樣
  4. git checkout -b chore/format-all
     git commit -am "chore: 全庫套用 black / sqlfluff 格式（無邏輯改動）"
  5. 開 MR，標題註明「純格式化」，方便 reviewer 快速確認
--------------------------------------------------------------------------------
EOF
fi
