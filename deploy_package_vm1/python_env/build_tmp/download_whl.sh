#!/bin/bash
# 在 UBI9 容器內執行：下載 requirements.txt 所需之 RHEL9 (manylinux) 相容 whl
set -euo pipefail

OUT=/output
REQ=/req/requirements.txt

echo ">>> 安裝 python3.11 + pip 作為下載工具"
dnf install -y python3.11 python3.11-pip >/dev/null
python3.11 -m pip install --upgrade pip >/dev/null

echo ">>> 下載 whl (目標: cp310 / manylinux, x86_64, RHEL9)"
python3.11 -m pip download \
    -r "$REQ" \
    --dest "$OUT" \
    --python-version 310 \
    --implementation cp \
    --abi cp310 \
    --platform manylinux_2_28_x86_64 \
    --platform manylinux_2_34_x86_64 \
    --platform manylinux2014_x86_64 \
    --platform linux_x86_64 \
    --only-binary=:all: \
    --no-cache-dir

echo ">>> 下載結果："
ls -la "$OUT"
