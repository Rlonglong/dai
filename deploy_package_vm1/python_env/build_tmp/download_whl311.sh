#!/bin/bash
set -euo pipefail
OUT=/output
REQ=/req/requirements.txt

dnf install -y python3.11 python3.11-pip >/dev/null
python3.11 -m pip install --upgrade pip >/dev/null

python3.11 -m pip download \
    -r "$REQ" \
    --dest "$OUT" \
    --python-version 311 \
    --implementation cp \
    --abi cp311 \
    --platform manylinux_2_28_x86_64 \
    --platform manylinux_2_34_x86_64 \
    --platform manylinux2014_x86_64 \
    --platform linux_x86_64 \
    --only-binary=:all: \
    --no-cache-dir

ls -la "$OUT"
