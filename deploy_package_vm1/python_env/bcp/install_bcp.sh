#!/bin/bash
# 在離線 RHEL 9 主機上安裝 bcp / sqlcmd (mssql-tools18 + msodbcsql18)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "請以 root 或 sudo 執行此腳本" >&2
    exit 1
fi

ACCEPT_EULA=Y dnf install -y "$DIR"/*.rpm

echo ""
echo "安裝完成。請將以下路徑加入 PATH："
echo '  export PATH="$PATH:/opt/mssql-tools18/bin"'
echo ""
/opt/mssql-tools18/bin/bcp -v
