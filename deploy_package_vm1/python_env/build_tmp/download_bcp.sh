#!/bin/bash
# 在 UBI9 容器內執行：下載 RHEL9 版 mssql-tools18 (bcp) + msodbcsql18 及相依 RPM
set -euo pipefail

OUT=/output

echo ">>> 設定 Microsoft 套件庫"
curl -s -o /etc/yum.repos.d/mssql-release.repo https://packages.microsoft.com/config/rhel/9/prod.repo
dnf install -y dnf-utils >/dev/null

echo ">>> 匯入 GPG key"
rpm --import https://packages.microsoft.com/keys/microsoft.asc

echo ">>> 下載 msodbcsql18 / mssql-tools18 及所有相依套件 (含 unixODBC)"
dnf download --resolve --arch=x86_64,noarch --destdir="$OUT" \
    msodbcsql18.x86_64 mssql-tools18.x86_64 unixODBC.x86_64 unixODBC-devel.x86_64

echo ">>> 下載結果："
ls -la "$OUT"
