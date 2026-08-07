# python_env 離線安裝手冊

本目錄包含在**無網路的 RHEL 9 (x86_64)** 主機上，離線安裝 Python 3.11、`dai/bcp_pipeline:v1.2` 所需的 Python 套件、以及 MS SQL Server 的 `bcp` 工具所需的所有檔案。

所有安裝檔皆在 `registry.access.redhat.com/ubi9/ubi` 容器（與 RHEL 9 ABI / repo 內容相容）中下載，可直接搬到 RHEL 9 機器上安裝，**不需要目標機器連網**。

```
python_env/
├── py/                          # Python 3.11 (RHEL9 官方 RPM)
│   └── *.rpm                                # python3.11 本體 + pip/setuptools/wheel/devel + 相依套件
├── req/                         # dai/bcp_pipeline:v1.2 的 Python 套件
│   ├── requirements.txt                     # 從映像檔取出的原始需求清單（未變更版本）
│   ├── *.whl                                # 對應 cp311 / manylinux（RHEL9 相容）的 wheel 檔
│   └── install_requirements.sh              # 安裝腳本
├── bcp/                         # MS SQL Server bcp 工具
│   ├── msodbcsql18-*.rpm / mssql-tools18-*.rpm / unixODBC*.rpm ...
│   └── install_bcp.sh                       # 安裝腳本
└── README.md                    # 本手冊
```

> `build_tmp/` 內是產生以上檔案所用的下載腳本，僅供之後需要更新版本時參考，部署時不需要複製到目標主機。

---

## 為什麼選 Python 3.11 而不是自行編譯 3.10？

- RHEL 9 / UBI 9 官方倉庫（AppStream）本身就有 `python3.11`（3.11.13）套件，可直接用 `dnf download` 抓 RPM，**不需要在目標機上編譯**，也沒有原本用原始碼編譯 3.10 時遇到的 `readline-devel`（RHEL9 因 GPLv3 授權問題未提供）需要用 libedit 補救的問題。
- 已驗證 `req/requirements.txt`（17 個套件、版本皆未變動）在 cp311 上**全部都有對應的 manylinux wheel**，可直接離線安裝，不需要改版本、也不需要在目標機上編譯任何 C 擴充套件。
- `bcp` / `msodbcsql18` 是獨立的原生工具，與 Python 版本無關，兩者可任意搭配。

已在乾淨的 UBI9 容器中做過端對端驗證：安裝 python3.11 RPM → 安裝 bcp RPM → 用 whl 離線安裝 requirements.txt → import 全部套件成功 → `pyodbc.drivers()` 可看到 `ODBC Driver 18 for SQL Server` → `bcp -v` 正常執行。

---

## 前置需求

- 目標主機：RHEL 9.x，x86_64
- 有 root / sudo 權限（安裝 RPM 需要）
- 使用 `scp` / `rsync` / USB 等方式，把整個 `python_env` 目錄複製到目標主機

---

## Part 1：安裝 Python 3.11

```bash
cd python_env/py
sudo dnf install -y ./*.rpm

# 驗證
python3.11 --version        # 應輸出 Python 3.11.13
python3.11 -m pip --version
```

包含的 RPM：

| 套件 | 說明 |
|---|---|
| `python3.11` | Python 直譯器本體 |
| `python3.11-libs` | 共用函式庫 (libpython3.11.so) |
| `python3.11-pip` / `python3.11-pip-wheel` | pip |
| `python3.11-setuptools` / `python3.11-setuptools-wheel` | setuptools |
| `python3.11-wheel` / `python3.11-wheel-wheel` | wheel |
| `python3.11-devel` | 標頭檔（若之後需要編譯其他 C 擴充套件才用得到） |
| `mpdecimal`、`libnsl2`、`libtirpc`、`libxcrypt-compat`、`pkgconf*` 等 | 上述套件的相依函式庫 |

> 若目標機已有網路可連到內部 RHEL 鏡像站，也可以直接 `dnf install python3.11 python3.11-pip`；這裡準備的 RPM 是給完全離線環境使用。

---

## Part 2：安裝 dai/bcp_pipeline:v1.2 所需的 Python 套件

`req/requirements.txt` 以 `dai/bcp_pipeline:v1.2` 映像的
`/app/requirements_bcp_pipeline.txt` 為底，**版本未做任何修改**，
再補上 VM1 腳本實際會 import、但原映像清單沒列到的四個
（`pymssql`、`openpyxl`、`python-dotenv`、`et_xmlfile`）。
共 **17 個套件**，全部都已確認有 cp311 對應 wheel：

```
cffi==2.0.0
cryptography==49.0.0
dagster-pipes==1.13.11
et_xmlfile==2.0.0
numpy==2.2.6
openpyxl==3.1.5
packaging==26.2
pandas==2.3.3
pycparser==3.0
pymssql==2.3.11
pyodbc==5.3.0
python-dateutil==2.9.0.post0
python-dotenv==1.2.2
pytz==2026.2
six==1.17.0
typing_extensions==4.15.0
tzdata==2026.2
```

> ⚠️ 這份清單要跟 `bcp-scripts` repo 根目錄的 `requirements.txt`
> **保持一致**（那一份是 D-Track 弱掃的依據）。
> 兩邊不一致的話，掃的是紙上的環境而不是真正在跑的環境，見部署手冊 Phase 4I。
>
> `req/` 底下的 `.whl` 檔數量必須跟這份清單一樣多，少一個就會離線安裝失敗。

`req/*.whl` 是對應 **cp311 + manylinux（RHEL9 相容）+ x86_64** 的 wheel 檔，已下載齊全，無需連網也不需要編譯（`cryptography`、`numpy`、`pandas`、`pyodbc`、`cffi` 等含 C 擴充套件的套件都已是預編譯好的 wheel）。

### 安裝方式

```bash
cd python_env/req
./install_requirements.sh          # 預設使用 PATH 上的 python3.11
# 或指定路徑
./install_requirements.sh python3.11
```

或手動執行：

```bash
python3.11 -m pip install --no-index --find-links python_env/req -r python_env/req/requirements.txt
```

> 建議在虛擬環境中安裝，避免污染系統 Python：
> ```bash
> python3.11 -m venv /opt/venv
> source /opt/venv/bin/activate
> pip install --no-index --find-links python_env/req -r python_env/req/requirements.txt
> ```

---

## Part 3：安裝 bcp（MS SQL Server 批次匯入工具）

`bcp/` 內含 Microsoft 官方 RHEL9 repo 下載的 RPM，版本與 `dai/bcp_pipeline:v1.2` 映像內建的 **mssql-tools18 / msodbcsql18 18.6.2.1-1** 一致：

- `msodbcsql18-18.6.2.1-1.x86_64.rpm` — ODBC Driver 18 for SQL Server
- `mssql-tools18-18.6.2.1-1.x86_64.rpm` — 內含 `bcp`、`sqlcmd`
- `unixODBC*.rpm`、`pkgconf*.rpm` — 相依套件

### 安裝方式

```bash
cd python_env/bcp
sudo ./install_bcp.sh
```

或手動執行：

```bash
cd python_env/bcp
sudo ACCEPT_EULA=Y dnf install -y ./*.rpm
```

安裝完成後，`bcp` 位於 `/opt/mssql-tools18/bin/bcp`，將其加入 PATH：

```bash
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
source ~/.bashrc
bcp -v
```

### 使用 bcp 快速將資料寫入 MS SQL Server 範例

```bash
# 從 CSV 匯入資料到 dbo.MyTable，逗號分隔、UTF-8、第一列非標題
bcp dbo.MyTable in data.csv \
    -S <SQL_SERVER_HOST>,1433 \
    -d <DATABASE_NAME> \
    -U <USERNAME> -P <PASSWORD> \
    -c -t"," -r"\n" \
    -C 65001 \
    -b 10000          # 每 10000 筆 commit 一次，加快大量匯入速度
```

若 SQL Server 憑證為自簽章導致連線失敗，可加上信任憑證參數：

```bash
bcp dbo.MyTable in data.csv -S host,1433 -d mydb -U sa -P '******' \
    -c -t"," -C 65001 -b 10000
```

---

## 建議安裝順序

```bash
cd python_env
sudo dnf install -y ./py/*.rpm                 # 1. Python 3.11
sudo ./bcp/install_bcp.sh                       # 2. bcp / msodbcsql18
./req/install_requirements.sh python3.11        # 3. Python 套件（需要 Python 3.11 已安裝）
```

## 驗證整體安裝

```bash
python3.11 --version
python3.11 -c "import pyodbc, pandas, numpy, cryptography; print('python 套件 OK')"
python3.11 -c "import pyodbc; print(pyodbc.drivers())"   # 應看到 'ODBC Driver 18 for SQL Server'
bcp -v
```
