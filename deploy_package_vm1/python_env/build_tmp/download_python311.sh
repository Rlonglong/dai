#!/bin/bash
# 在 UBI9 容器內執行：下載官方 RHEL9 python3.11 RPM 套件（含相依套件）供離線安裝
set -euo pipefail

OUT=/output
mkdir -p "$OUT"

echo ">>> 下載 python3.11 及相依 RPM (含 pip / setuptools / wheel / devel)"
dnf install -y dnf-utils >/dev/null
dnf download --resolve --arch=x86_64,noarch --destdir="$OUT" \
    python3.11 python3.11-pip python3.11-pip-wheel python3.11-libs \
    python3.11-setuptools python3.11-setuptools-wheel python3.11-wheel python3.11-wheel-wheel \
    python3.11-devel

echo ">>> 下載結果："
ls -la "$OUT"
