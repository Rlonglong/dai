#!/usr/bin/env bash
# =============================================================================
# cicd_template/install.sh —— 把 CI/CD 素材一次複製進目標 repo
# =============================================================================
# 用法：
#   ./install.sh <目標repo路徑> <profile>
#
#   <profile> 可以是：
#     dagster-workspace   Dagster 程式與 dbt 專案（部署到 VM4）
#     bcp-scripts         VM1 的執行腳本（部署到 VM1）
#     common              只複製共用的部分（新 repo 剛起步時用）
#
# 例：
#   ./install.sh ~/work/dagster-workspace dagster-workspace
#   ./install.sh ~/work/bcp-scripts       bcp-scripts
#
# 選項：
#   --dry-run    只印出會做什麼，不真的複製
#   --force      目標已存在且內容不同時，直接覆蓋（預設會停下來問）
#
# 這支腳本做的事很單純：複製檔案 + chmod +x。
# 它不會 git add、不會 commit —— 複製完請自己看 git diff 再決定要不要進版控。
# =============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info() { echo "${BLU}[INFO]${RST}  $*"; }
ok()   { echo "${GRN}[ OK ]${RST}  $*"; }
warn() { echo "${YLW}[WARN]${RST}  $*"; }
die()  { echo "${RED}[FAIL]${RST}  $*" >&2; exit 1; }

DRY_RUN=0
FORCE=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        -*)        die "不認得的選項：$a" ;;
        *)         ARGS+=("$a") ;;
    esac
done

(( ${#ARGS[@]} == 2 )) || die "用法：$0 <目標repo路徑> <dagster-workspace|bcp-scripts|common> [--dry-run] [--force]"

TARGET="${ARGS[0]%/}"
PROFILE="${ARGS[1]}"

[[ -d "$TARGET" ]] || die "目標目錄不存在：${TARGET}"
[[ -d "${TARGET}/.git" ]] || warn "${TARGET} 看起來不是 git repo，還是會複製，但請確認路徑對不對"

case "$PROFILE" in
    dagster-workspace|bcp-scripts|common) ;;
    *) die "profile 只能是 dagster-workspace / bcp-scripts / common，收到：${PROFILE}" ;;
esac

[[ "$PROFILE" == "common" ]] || [[ -d "${SRC}/${PROFILE}" ]] \
    || die "找不到 profile 目錄：${SRC}/${PROFILE}"

echo
echo "============================================================"
echo "  來源  ： ${SRC}"
echo "  目標  ： ${TARGET}"
echo "  profile： ${PROFILE}"
(( DRY_RUN )) && echo "  模式  ： DRY-RUN（不會真的複製）"
echo "============================================================"
echo

# -----------------------------------------------------------------------------
# 複製一個檔案／目錄，並在覆蓋前確認
# -----------------------------------------------------------------------------
copy_one() {
    local src="$1" rel="$2"
    local dst="${TARGET}/${rel}"

    if [[ -e "$dst" ]] && ! diff -rq "$src" "$dst" >/dev/null 2>&1; then
        if (( FORCE )); then
            warn "覆蓋（內容不同）：${rel}"
        else
            warn "目標已存在且內容不同：${rel}"
            echo "         比對：diff -ru '${dst}' '${src}'"
            echo "         要覆蓋請加 --force，或先自己合併"
            SKIPPED+=("$rel")
            return 0
        fi
    fi

    if (( DRY_RUN )); then
        echo "         [DRY-RUN] ${rel}"
    else
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        echo "         ${rel}"
    fi
    COPIED+=("$rel")
}

COPIED=()
SKIPPED=()

# -----------------------------------------------------------------------------
# 1. 共用部分（三種 profile 都要）
# -----------------------------------------------------------------------------
info "共用檔案（ci/ 與各工具設定）"
copy_one "${SRC}/common/ci"             "ci"
copy_one "${SRC}/common/.gitleaks.toml" ".gitleaks.toml"
copy_one "${SRC}/common/.flake8"        ".flake8"
copy_one "${SRC}/common/.sqlfluff"      ".sqlfluff"
copy_one "${SRC}/common/pyproject.toml" "pyproject.toml"

# -----------------------------------------------------------------------------
# 2. 該 repo 專屬的部分
# -----------------------------------------------------------------------------
if [[ "$PROFILE" != "common" ]]; then
    echo
    info "${PROFILE} 專屬檔案"
    while IFS= read -r -d '' f; do
        copy_one "$f" "$(basename "$f")"
    done < <(find "${SRC}/${PROFILE}" -maxdepth 1 -mindepth 1 -print0)
fi

# -----------------------------------------------------------------------------
# 3. 執行權限
# -----------------------------------------------------------------------------
if (( ! DRY_RUN )); then
    chmod +x "${TARGET}"/ci/*.sh "${TARGET}"/ci/hooks/* 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 4. 結果
# -----------------------------------------------------------------------------
echo
ok "複製完成：${#COPIED[@]} 項"
if (( ${#SKIPPED[@]} )); then
    echo
    warn "以下 ${#SKIPPED[@]} 項因為內容不同而跳過（沒有覆蓋）："
    printf '         - %s\n' "${SKIPPED[@]}"
fi

cat <<NEXT

接下來：

  cd ${TARGET}
  git status                  # 看看多了／改了什麼
  git diff                    # ★ 進版控前一定要自己看過 ★
  ci/install_hooks.sh         # 裝本機 git hook（每個開發者各自要做）
  ci/install_hooks.sh --check # 確認裝好了

  git add -A && git commit -m "chore: 更新 CI/CD 素材"

NEXT

if [[ "$PROFILE" == "dagster-workspace" ]]; then
cat <<'HINT'
  ⚠️ dagster-workspace 還要確認 CI/CD Variables 有設 DTRACK_IMAGE，
     否則 sca-dtrack 會失敗（它的套件在映像檔裡，不是 requirements.txt）。

HINT
fi
if [[ "$PROFILE" == "bcp-scripts" ]]; then
cat <<'HINT'
  ⚠️ bcp-scripts 的 requirements.txt 要跟 VM1 的 venv 一致：
       在 VM1：source /run/media/root/D/python_env/dai_venv/bin/activate
               python -m pip freeze > requirements.txt
     不一致的話，SCA 掃的是紙上的環境。

HINT
fi
