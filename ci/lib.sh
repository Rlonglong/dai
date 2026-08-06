#!/usr/bin/env bash
# =============================================================================
# ci/lib.sh —— CI/CD 腳本共用函式
# =============================================================================
# 用法：在其他腳本開頭 `source "$(dirname "$0")/lib.sh"`
# 這個檔案只定義函式與變數，不做任何事，可以安全地重複 source。
# =============================================================================

# shellcheck shell=bash

# --- 嚴格模式：任何一步失敗就停，未定義變數視為錯誤，pipeline 中間失敗也算失敗 ---
set -Eeuo pipefail

# rsyslog tag：跟系統其他元件維持同一個命名空間（見 18_Log分流與資安.md）
: "${DAI_LOG_TAG:=dai/gitlab-sync}"

_c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_yellow=$'\033[33m'
_c_green=$'\033[32m'; _c_blue=$'\033[36m'

_emit() {
    # $1=level  $2=priority(for logger)  $3...=message
    local level="$1" prio="$2"; shift 2
    local msg="$*"
    printf '%s\n' "$msg" >&2
    # 送一份到 rsyslog，才會被集中到 VM4 的 /data/log/dai 並納入每日 hash 存證
    if command -v logger >/dev/null 2>&1; then
        logger -t "$DAI_LOG_TAG" -p "user.${prio}" \
            "DAI|${level}|${CI_PROJECT_NAME:-local}|${CI_COMMIT_SHORT_SHA:-nogit}|${msg}" 2>/dev/null || true
    fi
}

log_info()  { _emit INFO  info    "${_c_blue}[INFO]${_c_reset}  $*"; }
log_ok()    { _emit OK    info    "${_c_green}[ OK ]${_c_reset}  $*"; }
log_warn()  { _emit WARN  warning "${_c_yellow}[WARN]${_c_reset}  $*"; }
log_error() { _emit ERROR err     "${_c_red}[FAIL]${_c_reset}  $*"; }

die() { log_error "$*"; exit 1; }

section() {
    printf '\n%s\n' "================================================================================" >&2
    printf ' %s\n' "$*" >&2
    printf '%s\n\n' "================================================================================" >&2
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "找不到指令：$1（請確認 runner 環境或 PATH）"
}

repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

# -----------------------------------------------------------------------------
# changed_files —— 算出「這次要檢查哪些檔案」
# -----------------------------------------------------------------------------
# 為什麼不整庫掃？
#   既有程式碼是在導入 lint 之前寫的，整庫開嚴格模式會讓所有 MR 一律紅燈，
#   結果就是大家開始習慣性 skip。所以品質類檢查（black/flake8/sqlfluff/bandit）
#   只擋「你這次動到的檔案」，資安類檢查（gitleaks/SCA）才是全庫全歷史。
#   全庫一次性整乾淨的作法見 ci/format_all.sh。
#
# 用法：changed_files [<base-ref>]
# 依序嘗試：MR 目標分支 → push 的 before sha → 預設分支 → 上一個 commit
# -----------------------------------------------------------------------------
changed_files() {
    local base="${1:-}"
    local default_branch="${CI_DEFAULT_BRANCH:-main}"

    if [[ -z "$base" ]]; then
        if [[ -n "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-}" ]]; then
            base="origin/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}"
        elif [[ -n "${CI_COMMIT_BEFORE_SHA:-}" && "${CI_COMMIT_BEFORE_SHA}" != "0000000000000000000000000000000000000000" ]]; then
            base="${CI_COMMIT_BEFORE_SHA}"
        elif git rev-parse --verify --quiet "origin/${default_branch}" >/dev/null; then
            base="origin/${default_branch}"
        else
            base="HEAD~1"
        fi
    fi

    if ! git rev-parse --verify --quiet "$base" >/dev/null; then
        log_warn "算不出比較基準 '${base}'（可能是 shallow clone，CI 請設 GIT_DEPTH: 0），改用 HEAD~1"
        base="HEAD~1"
        git rev-parse --verify --quiet "$base" >/dev/null || { echo ""; return 0; }
    fi

    # --diff-filter=ACMR：只要新增/複製/修改/改名的檔案，刪掉的不用檢查
    # 三個點：以共同祖先為基準，不會把 target 分支上別人的改動算進來
    git diff --name-only --diff-filter=ACMR "${base}...HEAD" 2>/dev/null \
        || git diff --name-only --diff-filter=ACMR "${base}" HEAD
}

# 從檔案清單裡挑出某個副檔名，並濾掉 AppleDouble（._foo.py）與不存在的檔案
filter_ext() {
    local ext="$1"; shift
    local f
    for f in "$@"; do
        [[ "$(basename "$f")" == ._* ]] && continue
        [[ "$f" == *".${ext}" ]] || continue
        [[ -f "$f" ]] || continue
        printf '%s\n' "$f"
    done
}

# -----------------------------------------------------------------------------
# run_check —— 跑一個檢查，失敗時把輸出縮排印出來，訊息格式與本地 hook 一致
# -----------------------------------------------------------------------------
run_check() {
    local label="$1"; shift
    printf -- '--------------------------------------------------------\n' >&2
    printf -- '  > 檢查: %s\n' "$label" >&2
    printf -- '--------------------------------------------------------\n' >&2

    local output status=0
    output="$("$@" 2>&1)" || status=$?

    if [[ $status -ne 0 ]]; then
        log_error "${label} 失敗。"
        printf '%s\n' "$output" | sed 's/^/| /' >&2
        return "$status"
    fi
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
    log_ok "${label} 通過。"
    return 0
}

# 檢查必要的環境變數都有值（用於 CD / D-Track 這種一定要有設定的 job）
require_vars() {
    local missing=() v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    if ((${#missing[@]})); then
        die "缺少必要的 CI/CD Variable：${missing[*]}
     設定位置：GitLab → Settings → CI/CD → Variables
     正式環境的變數請勾選 Protected + Masked，並用 environment scope 區隔 staging / production
     （見 docs/GitLab維運手冊/進階調整/13_Variables與環境隔離.md）"
    fi
}
