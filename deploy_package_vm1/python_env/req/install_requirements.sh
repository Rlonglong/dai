#!/bin/bash
# 在離線 RHEL 9 主機上安裝 requirements.txt 所需的 Python 套件
# 用法: ./install_requirements.sh [python執行檔路徑]
set -euo pipefail

PYTHON_BIN="${1:-python3.11}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$PYTHON_BIN" -m pip install \
    --no-index \
    --find-links "$DIR" \
    -r "$DIR/requirements.txt"

echo "requirements.txt 套件安裝完成"
