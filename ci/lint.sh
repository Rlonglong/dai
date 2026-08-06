#!/usr/bin/env bash
# =============================================================================
# ci/lint.sh —— CI 的品質檢查（跟本地 hook 跑同一套規則）
# =============================================================================
# 用法：
#   ci/lint.sh format     black  --check
#   ci/lint.sh style      flake8
#   ci/lint.sh sast       bandit
#   ci/lint.sh sql        sqlfluff
#   ci/lint.sh all        以上全部
#
# ★ 只檢查「這次 MR / push 動到的檔案」★
#   既有程式碼是在導入 lint 之前寫的（flake8 目前全庫約 150 個 warning），
#   整庫開嚴格模式會讓每個 MR 都紅燈，最後大家只會學會忽略紅燈。
#   所以品質類檢查採「新帳新算」：你動到的檔案要乾淨。
#   資安類檢查（gitleaks / SCA）不適用這個原則，那些是全庫全歷史。
#
#   想一次把全庫整乾淨：ci/format_all.sh（建議單獨開一個純格式化的 MR）
#
# 環境變數：
#   LINT_ALL_FILES=1   改成掃全庫（導入完成後可以打開）
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ROOT="$(repo_root)"
cd "$ROOT"

WHAT="${1:-all}"

PY_SCOPE="dagster_workspace ci"
SQL_SCOPE="dagster_workspace/dbt_project"

if [[ "${LINT_ALL_FILES:-0}" == "1" ]]; then
    log_warn "LINT_ALL_FILES=1：改為掃描全庫"
    mapfile -t PY_FILES  < <(git ls-files -- '*.py'  | grep -v '^\._' || true)
    mapfile -t SQL_FILES < <(git ls-files -- "${SQL_SCOPE}/**/*.sql" "${SQL_SCOPE}/*.sql" | grep -v '^\._' || true)
else
    mapfile -t ALL_CHANGED < <(changed_files || true)
    if ((${#ALL_CHANGED[@]} == 0)); then
        log_info "這次沒有檔案變動，品質檢查略過。"
        exit 0
    fi
    log_info "本次變動 ${#ALL_CHANGED[@]} 個檔案"
    mapfile -t PY_FILES  < <(filter_ext py  "${ALL_CHANGED[@]}")
    mapfile -t SQL_FILES < <(filter_ext sql "${ALL_CHANGED[@]}")
fi

log_info "待檢查：Python ${#PY_FILES[@]} 個、SQL ${#SQL_FILES[@]} 個"

rc=0

do_format() {
    ((${#PY_FILES[@]} == 0)) && { log_info "沒有 .py 變動，略過 black"; return 0; }
    need_cmd black
    run_check "Python 排版 (black)" black --check --diff "${PY_FILES[@]}" || {
        cat >&2 <<'EOF'
  [怎麼修] 在本地執行：
      black <上面列出的檔案>
  第一次導入時，既有檔案本來就不是 black 格式，動到就得整檔格式化。
  想一次做完：ci/format_all.sh，並單獨開一個「只有格式化」的 MR 讓 review 好看。
EOF
        return 1
    }
}

do_style() {
    ((${#PY_FILES[@]} == 0)) && { log_info "沒有 .py 變動，略過 flake8"; return 0; }
    need_cmd flake8
    run_check "Python 語法與品質 (flake8)" flake8 "${PY_FILES[@]}"
}

do_sast() {
    ((${#PY_FILES[@]} == 0)) && { log_info "沒有 .py 變動，略過 bandit"; return 0; }
    need_cmd bandit
    run_check "Python 資安掃描 (bandit)" bandit -q -c bandit.yaml -ll "${PY_FILES[@]}"
}

do_sql() {
    ((${#SQL_FILES[@]} == 0)) && { log_info "沒有 .sql 變動，略過 sqlfluff"; return 0; }
    need_cmd sqlfluff
    run_check "SQL 語法規範 (sqlfluff)" sqlfluff lint --processes 1 "${SQL_FILES[@]}" || {
        cat >&2 <<'EOF'
  [怎麼修] 大部分規則可以自動修：
      sqlfluff fix --processes 1 <檔案>
  修完一定要自己看 diff —— fix 會動到 SQL 語意上無關但視覺上很大的地方。
EOF
        return 1
    }
}

case "$WHAT" in
    format) do_format || rc=1 ;;
    style)  do_style  || rc=1 ;;
    sast)   do_sast   || rc=1 ;;
    sql)    do_sql    || rc=1 ;;
    all)
        do_format || rc=1
        do_style  || rc=1
        do_sast   || rc=1
        do_sql    || rc=1
        ;;
    *) die "未知的檢查項目：$WHAT（可用：format / style / sast / sql / all）" ;;
esac

[[ $rc -eq 0 ]] && log_ok "品質檢查通過" || log_error "品質檢查未通過"
exit $rc
