#!/usr/bin/env bash
# =============================================================================
# ci/sync_manifest.sh —— 產生一份「這個目錄現在長什麼樣」的雜湊清單
# =============================================================================
# 同一支腳本會在兩邊各跑一次，輸出格式一模一樣，才能直接 diff：
#   來源端：GitLab runner 上剛 checkout 出來的 dagster_workspace/
#   目標端：VM4 上 /data/deploy/workspace/dagster_workspace/（透過 ssh 執行）
#
# 用法：
#   ci/sync_manifest.sh <root_dir> <exclude_file>
#
# 輸出（stdout，已依路徑排序）：
#   <sha256>  <相對路徑>
#   ...
#   TOTAL <檔案數> <整份清單的 sha256>
#
# 設計上的兩個重點：
#   1. 排除規則跟 rsync 用的是**同一份 deploy_exclude.txt**。
#      不然「被排除、本來就不該一致」的檔案（.env、target/）會天天報假警。
#   2. 只比對檔案內容，不比 mtime/權限。rsync -a 會保留 mtime，但 VM4 上
#      dbt 執行、chown 都可能動到 metadata，拿那些來比會一直誤判。
#
# 這支腳本刻意只用 POSIX 工具（find/sha256sum/sed/sort），
# 因為它要能在 VM1/VM4 上以受限的 gitlab_runner 身分執行，那邊沒有 python 生態。
# =============================================================================

set -Eeuo pipefail

ROOT="${1:?用法: sync_manifest.sh <root_dir> <exclude_file>}"
EXCLUDE_FILE="${2:?用法: sync_manifest.sh <root_dir> <exclude_file>}"

[[ -d "$ROOT" ]] || { echo "ERROR: 目錄不存在: $ROOT" >&2; exit 2; }
[[ -f "$EXCLUDE_FILE" ]] || { echo "ERROR: 排除清單不存在: $EXCLUDE_FILE" >&2; exit 2; }

# 先轉成絕對路徑再 cd，否則相對路徑會在 cd 之後失效
EXCLUDE_FILE="$(cd "$(dirname "$EXCLUDE_FILE")" && pwd)/$(basename "$EXCLUDE_FILE")"

cd "$ROOT"

# -----------------------------------------------------------------------------
# 把 deploy_exclude.txt 轉成 find 的 -path 判斷式
#   rsync 的規則：結尾有 / = 只比對目錄；沒有 / = 檔案或目錄都算
# -----------------------------------------------------------------------------
prune_args=()
name_args=()
while IFS= read -r line; do
    line="${line%%#*}"                     # 去掉註解
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue

    if [[ "$line" == */ ]]; then
        # 目錄：整棵剪掉
        prune_args+=( -path "./${line%/}" -o -path "./${line%/}/*" -o )
    elif [[ "$line" == */* ]]; then
        # 帶路徑的檔案樣式
        prune_args+=( -path "./${line}" -o )
    else
        # 純檔名樣式（__pycache__、*.pyc、._* ...）：任何層級都算
        name_args+=( -name "$line" -o )
        prune_args+=( -path "./*/${line}" -o -path "./${line}" -o )
    fi
done < "$EXCLUDE_FILE"

# 收尾把多餘的 -o 拿掉
[[ ${#prune_args[@]} -gt 0 ]] && unset 'prune_args[${#prune_args[@]}-1]'
[[ ${#name_args[@]}  -gt 0 ]] && unset 'name_args[${#name_args[@]}-1]'

build_expr() {
    if [[ ${#prune_args[@]} -gt 0 && ${#name_args[@]} -gt 0 ]]; then
        printf '%s\0' '(' "${prune_args[@]}" -o "${name_args[@]}" ')'
    elif [[ ${#prune_args[@]} -gt 0 ]]; then
        printf '%s\0' '(' "${prune_args[@]}" ')'
    elif [[ ${#name_args[@]} -gt 0 ]]; then
        printf '%s\0' '(' "${name_args[@]}" ')'
    fi
}
mapfile -d '' -t EXCL < <(build_expr)

# -----------------------------------------------------------------------------
# 列檔案 → 逐檔 sha256 → 排序
#   LC_ALL=C：兩台機器 locale 可能不同，排序結果必須完全一致才能 diff
# -----------------------------------------------------------------------------
if [[ ${#EXCL[@]} -gt 0 ]]; then
    find . "${EXCL[@]}" -prune -o -type f -print0
else
    find . -type f -print0
fi \
    | LC_ALL=C sort -z \
    | xargs -0 -r -n 64 sha256sum \
    | sed 's|  \./|  |' \
    | LC_ALL=C sort -k2 \
    > /tmp/.dai_manifest.$$ 2>/dev/null

count="$(wc -l < /tmp/.dai_manifest.$$ | tr -d ' ')"
overall="$(sha256sum < /tmp/.dai_manifest.$$ | cut -d' ' -f1)"

cat /tmp/.dai_manifest.$$
printf 'TOTAL %s %s\n' "$count" "$overall"
rm -f /tmp/.dai_manifest.$$
