#!/bin/bash
# 在 UBI9 容器內執行：編譯 Python 3.10 並打包所有離線安裝所需檔案
set -euo pipefail

PY_VER="3.10.20"
PREFIX="/opt/python3.10"
OUT=/output

mkdir -p "$OUT/rpms" "$OUT/src"

echo ">>> [1/6] 安裝編譯依賴套件 (dnf install)"
dnf install -y \
    gcc gcc-c++ make wget tar xz findutils perl-core \
    openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel \
    sqlite-devel ncurses-devel libedit-devel tk-devel \
    libuuid-devel expat-devel

echo ">>> [2/6] 下載並記錄所有相關 RPM (含相依套件) 供離線安裝使用"
dnf install -y dnf-utils
dnf download --resolve --destdir="$OUT/rpms" \
    gcc gcc-c++ make wget tar xz findutils perl-core \
    openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel \
    sqlite-devel ncurses-devel libedit-devel tk-devel \
    libuuid-devel expat-devel

echo ">>> RHEL9 無 readline-devel (GPLv3)，建立 libedit 相容 symlink 供 readline 模組編譯"
mkdir -p /usr/include/readline
ln -sf /usr/include/editline/readline.h /usr/include/readline/readline.h
ln -sf /usr/include/editline/readline.h /usr/include/readline/history.h

echo ">>> [3/6] 下載 Python $PY_VER 原始碼"
cd /tmp
wget -q "https://www.python.org/ftp/python/${PY_VER}/Python-${PY_VER}.tgz"
cp "Python-${PY_VER}.tgz" "$OUT/src/"
tar xzf "Python-${PY_VER}.tgz"
cd "Python-${PY_VER}"

echo ">>> [4/6] 編譯安裝 Python $PY_VER 到 $PREFIX (make altinstall)"
./configure --prefix="$PREFIX" --enable-shared --enable-optimizations \
    LDFLAGS="-Wl,-rpath=$PREFIX/lib"
make -j"$(nproc)"
make altinstall

echo ">>> [5/6] 驗證安裝"
"$PREFIX/bin/python3.10" --version
"$PREFIX/bin/pip3.10" --version

echo ">>> [6/6] 打包編譯結果 (relocatable tarball)"
tar czf "$OUT/python-${PY_VER}-rhel9-x86_64.tar.gz" -C "$(dirname $PREFIX)" "$(basename $PREFIX)"

echo "DONE"
ls -la "$OUT" "$OUT/rpms" "$OUT/src"
