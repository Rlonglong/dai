---
title: 部署手冊
---

# DAI 部署流程文件

> **目標**：從零開始，在四台 VM 上完整部署 DAI 平台（採用 security-hardened 版本的 image 與 compose 設定）
>
> **重要**：本文件一律使用 **security-hardened 版本**的 compose（原檔名 `docker-compose_vmX_secure.yml`，非 `docker-compose_vmX.yml`）。強化版包含 `read_only` root filesystem、`cap_drop: ALL`、`seccomp`、非 root 使用者等設定，細節見部署包內的 `secure_report/` 目錄。
>
> 拆成四個部署包之後，每台 VM 上就只有自己那一份，檔名統一為 `docker-compose.yml`（見下方「部署目錄與指令慣例」）。

---

## VM 角色與 IP 對照

| VM | 角色 | 正式部署時更新 |
|----|------|--------------|
| VM1 | BCP Pipeline（SQL Server 資料搬移）| 更新 VM1 部署根目錄的 `.env` |
| VM3 | GitLab + Container Registry + Dependency-Track + Nginx + **GitLab Runner CI/CD** | 更新 VM3 部署根目錄的 `.env` |
| VM4 | infra-db (PostgreSQL) + Dagster | 更新 VM4 部署根目錄的 `.env` |
| VM5 | Keycloak（含 LDAP 聯邦）+ Nginx + Superset | 更新 VM5 部署根目錄的 `.env` |

---

## 部署順序總覽

```
[Phase 0] 所有 VM 基礎準備（Docker、OS 套件、部署包、IP、TLS、目錄權限）
[Phase 1] VM4：啟動 infra-db（PostgreSQL 必須最先啟動）+ Dagster
[Phase 2] VM5：啟動 Keycloak
          └─ 2-1: 啟動 Keycloak
          └─ 2-2: 建立 Realm 與 Clients（dagster / superset / gitlab / dependency-track）
          └─ 2-3: 設定 LDAP User Federation（串接公司 LDAP）
          └─ 2-4: 啟動 nginx、kc_access、superset
[Phase 3] VM3：啟動 GitLab + dtrack + Container Registry
          └─ 3-1: 啟動 nginx / dtrack / GitLab
          └─ 3-2: GitLab 匯入自簽 CA 憑證
          └─ 3-3: GitLab OIDC 設定（已內建，通常可跳過）
          └─ 3-4: dtrack admin 密碼 + OIDC 設定
          └─ 3-5: 註冊 GitLab Runner CI / CD
          └─ 3-6: 安裝 gitleaks 到 GitLab 容器（給 Phase 4D 的 hook 用）
          └─ 3-7: 驗證 Container Registry（與 GitLab 共用 domain，port 5050）
[Phase 4] 版控與 CI/CD 同步（跨 VM1 / VM3 / VM4）
          └─ 4A: 三台 VM 建立 gitlab_runner 帳號與免密碼 SSH
          └─ 4B: 安裝 post-deploy 腳本與 sudoers
          └─ 4C: 建立兩個 GitLab repo 並推上初始程式碼
          └─ 4D: 安裝伺服器端 pre-receive hook（★機密外洩的真正防線★）
          └─ 4E: 分支保護、MR Approvals、CODEOWNERS、Variables、環境隔離
          └─ 4F: 兩個排程（每日雜湊對帳 + 每季定期弱掃）
          └─ 4G: 首次部署
          └─ 4H: 通知開發人員安裝本地 hook
          └─ 4I: Dependency-Track 接上 CI/CD（推送掃描 + 每季弱掃）
[Phase 5] VM1：啟動 BCP Pipeline
[Phase 6] 所有 VM：部署 rsyslog 日誌集中轉發
```

> 📘 **日後維運看這裡**：本文件是**一次性的建置流程**。
> 建好之後的日常操作（怎麼改東西、怎麼上線、每天要看什麼）在
> [`docs/`](./docs/README.md)：
> - [Dagster 維運手冊](./docs/Dagster維運手冊/README.md) — 資料流程怎麼運作、怎麼改
> - [GitLab 維運手冊](./docs/GitLab維運手冊/README.md) — 怎麼把改動安全送上正式機

## 提供檔案
```
deploy_package_vm1.tar.gz
deploy_package_vm3.tar.gz
deploy_package_vm4.tar.gz
deploy_package_vm5.tar.gz
```

**每台 VM 只會拿到自己那一份**，解開之後就是那台機器的完整部署目錄。

---

## 部署目錄與指令慣例 ★先看這一節★

### 解開之後長這樣

```
<部署根目錄>/                    ← 以 VM3 為例：/run/media/root/D/deploy
├── docker-compose.yml          ← 這台 VM 的 secure compose
├── .env                        ← 這台 VM 的環境變數
├── certs/                      ← TLS 憑證
├── workspace/                  ← 各服務的設定檔與資料掛載點
└── ...
```

`.env` 跟 `docker-compose.yml` **放在同一層**，`docker compose` 會自動讀同層的 `.env`，
所以指令不用再帶 `-f` 和 `--env-file`：

```bash
cd <部署根目錄>
docker compose up -d <服務名>
```

> ⚠️ **打包成四份時要一起處理的兩件事，沒做的話下面所有指令都會失敗：**
>
> 1. **檔名**：`docker-compose_vmX_secure.yml` → `docker-compose.yml`、
>    `env/vmX.env` → `.env`。
>    （不改名的話，每一行指令都要補回 `-f docker-compose_vmX_secure.yml`）
> 2. **相對路徑**：compose 檔從 `docker-compose/` 往上搬一層之後，
>    裡面的 bind mount 路徑要跟著改（`../workspace/xxx` → `./workspace/xxx`、
>    `../certs/xxx` → `./certs/xxx`），否則會掛到不存在的目錄。

### 各 VM 的部署根目錄

| VM | 部署根目錄 | 說明 |
|----|-----------|------|
| VM1 | `/run/media/root/D/deploy` | 資料碟掛在 `/run/media/root/D` |
| VM3 | `/run/media/root/D/deploy` | 同上 |
| VM4 | `/data/deploy` | 較早申請的機器，資料碟掛在 `/data` |
| VM5 | `/run/media/root/D/deploy` | 同上 |

> 📌 **`deploy` 上面那一層是磁碟掛載點，會因機器而異。**
> VM1 / VM3 / VM5 是同一批申請的，資料碟都掛在 `/run/media/root/D`；
> VM4 是較早申請的，掛在 `/data`。
> **未來重新申請機器時掛載點可能會變，部署前先用 `df -h` 確認實際有空間的磁碟在哪，
> 再把 `deploy` 建在它底下**，並同步更新 `.env` 裡的路徑變數。

**本文以下所有指令，除非另外註明，都假設你已經 `cd` 到該 VM 的部署根目錄。**

---

## Phase 0：所有 VM 基礎準備

### 0-1. 安裝 Docker

請先將安裝檔傳入正式環境，以進行離線安裝，確定以下四種檔案（請自行帶入欲安裝的版本號）已在正式環境。
以下指令都需要 root 權限（直接用 root 或每行加 `sudo`）。

```bash
# RHEL 9+
dnf localinstall \
containerd.io-*.*.*-*.el9.x86_64.rpm \
docker-ce-cli-*.*.*-*.el9.x86_64.rpm \
docker-ce-*.*.*-*.el9.x86_64.rpm \
docker-compose-plugin-*.*.*-*.el9.x86_64.rpm
```

以此方式驗證成功:
```bash
docker --version
docker compose version      # ★ 要有這個，compose plugin 才有裝到
```
應該看到版本號，如 `Docker version 29.6.1, build 8900f1d` 與 `Docker Compose version v2.x.x`。

> `docker compose`（有空格）是 compose plugin，`docker-compose`（有橫線）是舊的獨立執行檔。
> 本文一律用前者，舊版指令不保證行為相同。

### 0-2. 啟動 Docker
```bash
systemctl start docker      # 啟動 Docker 服務
systemctl enable docker     # 開機時自動啟動 Docker 服務
systemctl status docker     # 確認 Docker 狀態
# 最後應該看到輸出有綠色的 Active: active (running)
```

以此方式驗證成功: 
```bash
docker version
```
應該看到版本號，如
```
Client: Docker Engine - Community
 Version:           29.6.1
 ...

Server: Docker Engine - Community
 Engine:
  Version:          29.6.1
  ...
```

### 0-3. 安裝作業系統套件

離線環境一樣先把 rpm 帶進來用 `dnf localinstall`；連得到內部 yum repo 的話直接 `dnf install`。

**四台 VM 都要裝：**

| 套件 | 用在哪 |
|------|--------|
| `acl` | `setfacl`／`getfacl`，Phase 4A、Phase 5-6 的目錄授權 |
| `rsync` | Phase 4 的 CD 部署（VM1／VM3／VM4 一定要） |
| `openssh-clients` | `ssh`／`ssh-keygen`／`ssh-keyscan`，Phase 4A、Phase 5-1 |
| `policycoreutils-python-utils` | `semanage`，RHEL SELinux 設定（見文末補充） |
| `rsyslog` | Phase 6 日誌集中 |
| `tar`、`gzip` | 解部署包 |

```bash
dnf install -y acl rsync openssh-clients policycoreutils-python-utils rsyslog tar gzip
```

**VM1 額外要裝 Python 3.11**（BCP Pipeline 的腳本跑在 host 上，不在容器裡）：

```bash
# 離線安裝（版本號自行帶入）
dnf localinstall \
  python3.11-*.el9.x86_64.rpm \
  python3.11-libs-*.el9.x86_64.rpm \
  python3.11-pip-*.el9.noarch.rpm \
  python3.11-setuptools-*.el9.noarch.rpm

# 連得到 repo 的話
dnf install -y python3.11 python3.11-pip
```

驗證：
```bash
python3.11 --version                       # 應印出 Python 3.11.x
python3.11 -m venv --help > /dev/null && echo "venv OK"
```

> **為什麼只有 VM1 要裝 Python**：VM3／VM4／VM5 的服務全部跑在容器裡，
> 套件烘焙在映像檔中，host 不需要 Python。
> 只有 VM1 的清洗腳本是由 Dagster 透過 SSH 叫起來、**直接跑在 VM1 的 host 上**，
> 所以 VM1 必須有自己的 Python 3.11 與 venv（Phase 5-2）。
>
> Phase 2-2 解析 Keycloak token 時會用到 `python3`，那是 RHEL 9 內建的
> `/usr/bin/python3`（3.9），不需要另外安裝。

**VM1 還需要 SQL Server 的 ODBC 驅動**（`pyodbc` 要連 MS SQL Server 用）：

```bash
dnf localinstall msodbcsql18-*.rpm unixODBC-*.rpm
odbcinst -q -d      # 應列出 [ODBC Driver 18 for SQL Server]
```

### 0-4. 傳送部署包並解開

```bash
# 在你的操作機上，傳送 deploy package 至各 VM（以 VM3 為例）
scp deploy_package_vm3.tar.gz rhel@<VM3_IP>:/tmp/

# 到 VM3 上解開到部署根目錄
mkdir -p /run/media/root/D/deploy
tar -xzf /tmp/deploy_package_vm3.tar.gz -C /run/media/root/D/deploy --strip-components=1
rm -f /tmp/deploy_package_vm3.tar.gz
```

> `--strip-components=1` 是假設 tar 包最外層有一層目錄（例如 `deploy_package_vm3/`）。
> 先用 `tar -tzf deploy_package_vm3.tar.gz | head` 看一下結構，
> 如果打包時就是從內容開始的，這個參數要拿掉。

**VM4 的路徑不一樣：**
```bash
mkdir -p /data/deploy
tar -xzf /tmp/deploy_package_vm4.tar.gz -C /data/deploy --strip-components=1
```

**解開後確認結構正確：**
```bash
cd <部署根目錄>
ls -la          # 應該看到 docker-compose.yml、.env、certs/、workspace/
```

### 0-5. 更新各 VM 的 IP 設定

**可以用指令或是 vim/nano 直接進去改**\
**每台 VM 上，將 `.env` 裡的 IP 換成正式環境實際 IP：**

```bash
# 四台 VM 都在自己的部署根目錄執行，指令完全相同
cd <部署根目錄>

sed -i "s/VM3_IP=.*/VM3_IP=<VM3實際IP>/" .env
sed -i "s/VM4_IP=.*/VM4_IP=<VM4實際IP>/" .env
sed -i "s/VM5_IP=.*/VM5_IP=<VM5實際IP>/" .env
# VM1 的 .env 另外還有 MSSQL_* 等連線資訊，見 Phase 5-3
```

改完確認：
```bash
grep -E '^VM[0-9]_IP=' .env
```

### 0-6. 確認 compose 檔可以正確解析

改完 `.env`、動過 compose 檔的相對路徑之後，**先驗證再啟動**。
這一步會把 `.env` 的變數代進去、把所有相對路徑展開成絕對路徑，
是最快能抓到「變數沒填」「路徑搬錯層」的方法：

```bash
cd <部署根目錄>
docker compose config > /dev/null && echo "compose 可解析"

# 確認掛載路徑指到對的地方（應該全部在部署根目錄底下，而且都存在）
docker compose config | grep -E 'source:|device:'
```

看到 `variable is not set. Defaulting to a blank string` 的警告就是 `.env` 有漏；
看到路徑指到部署根目錄以外的地方，就是相對路徑沒跟著搬層。

<!-- ### 0-7. 設定 /etc/hosts（測試環境）或申請 DNS（正式環境）

> **正式環境**：向 IT 申請 DNS A 記錄，指向對應 VM IP。
> **測試環境**：在每台 VM 及使用者電腦的 `/etc/hosts` 加入以下對應。

```
<VM3_IP>  gitlab.dai.post.gov.tw
<VM3_IP>  dtrack.dai.post.gov.tw
<VM4_IP>  dagster-login
<VM5_IP>  auth.dai.post.gov.tw
<VM5_IP>  superset.dai.post.gov.tw
<VM5_IP>  dagster.dai.post.gov.tw
```

**每台 VM 都需要加入**，因為各 VM 的容器在呼叫 HTTPS 服務時需要能解析 domain。

> Container Registry **不需要**額外的 domain（與 GitLab 共用 `gitlab.dai.post.gov.tw`，僅 port 不同，見 Phase 3-D）。 -->

### 0-8. 準備 TLS 憑證

憑證放在部署根目錄的 `certs/` 底下（**四台 VM 都要有**，各服務都需要驗證彼此的 TLS）：

```
<部署根目錄>/certs/
  GRCA3.crt               # CA 根憑證
  GCA3.crt                # 中繼憑證
  dai_202606.crt          # Domain 憑證
  dai_202606.key          # 私鑰
  fullchain_202606.crt    # 憑證鏈
```

憑證鏈的組法（**順序不能反**：伺服器憑證 → 中繼 → 根）：
```bash
cd <部署根目錄>/certs
cat dai_202606.crt GCA3.crt GRCA3.crt > fullchain_202606.crt
```

> ⚠️ **檔名在部署包裡必須跟 `.env`、compose 檔、nginx 設定裡寫的完全一致。**
> `202606` 是憑證到期年月，換憑證時這串會變，屆時要一起改的地方：
> `.env`、`certs/` 底下的檔名、nginx 設定、Phase 3-5 的 runner 憑證連結。

**私鑰權限要收緊**（不收的話 nginx 可能拒絕載入）：
```bash
chmod 600 dai_202606.key
chmod 644 GRCA3.crt GCA3.crt dai_202606.crt fullchain_202606.crt
```

憑證準備好之後，要把 CA 根憑證放進 VM 的信任清單裡面（**四台 VM 都要做**）：
```bash
cp <部署根目錄>/certs/GRCA3.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust extract
systemctl restart docker
```

驗證：
```bash
trust list | grep -i -A2 GRCA3        # 應該找得到
curl -I https://gitlab.dai.post.gov.tw/users/sign_in    # Phase 3 起來後不該再需要 -k
```

> 這一步只讓 **host** 信任該 CA。GitLab 與 dtrack 容器有自己的 trust store，
> 還要另外匯入，見 Phase 3-2（GitLab）與 Phase 3-4（dtrack）。

### 0-9. Dagster 工作目錄權限（VM4）

`dai/dagster:v2.7` 明確以 **UID 10001**（非 root）執行，且 root filesystem 為 `read_only: true`。Host 端掛載給 Dagster 的目錄必須讓 UID 10001 可寫，否則容器會在啟動時出現 `Permission denied`：

```bash
# 在 VM4 執行
cd /data/deploy
chown -R 10001:10001 ./workspace/dagster_workspace
chown -R 10001:10001 ./workspace/dagster_home
```

> 實際目錄名以 `.env` 裡的路徑變數為準，先用 `grep -i dagster .env` 確認。

### 0-10. BCP Pipeline 資料目錄權限（VM1）

`dai/bcp_pipeline` 在 secure compose 中明確以 **UID:GID 1000:1000** 執行，需確保 `workspace/data` 目錄擁有者一致：

```bash
# 在 VM1 執行
cd /run/media/root/D/deploy
chown -R 1000:1000 ./workspace/data
```

### 0-11. 初始設定檔權限（VM5）

Superset 容器以非 root 身分讀這兩個設定檔，權限不足會啟動失敗：

```bash
# 在 VM5 執行
cd /run/media/root/D/deploy
chmod 644 ./workspace/superset_config.py
chmod 644 ./workspace/custom_sso_security_manager.py
```

## Phase 1：VM4 — PostgreSQL + Dagster

```bash
# 在 VM4 執行
cd /data/deploy

# 步驟 1：啟動 infra-db（PostgreSQL）
docker compose up -d infra-db

# 步驟 2：等待 infra-db healthy（約 20 秒）
watch -n 2 "docker compose ps infra-db"
# 確認出現 (healthy) 後按 Ctrl+C

# 步驟 3：啟動其餘 VM4 服務
docker compose up -d dagster-login dagster-code dagster-webserver dagster-daemon
```

**驗證：**
```bash
docker compose ps                                  # 五個服務都在，infra-db 是 (healthy)
docker exec infra-db psql -U "$(grep '^INFRA_DB_USER=' .env | cut -d= -f2)" -c '\l'
# 應列出 keycloak / dtrack / superset / dagster / keycloak_access_db
```

**注意事項：**
- `infra-db` 首次啟動時執行 `workspace/init-infra-db.sql`，會建立所有資料庫（keycloak、dtrack、superset、dagster、keycloak_access_db）。確保此 SQL 檔在啟動前已存在於正確路徑。**這個 SQL 只在資料目錄是空的時候會跑**，如果第一次啟動失敗，要先把 PostgreSQL 的資料目錄清掉再重來，否則改了 SQL 也不會生效。
- `dagster-code` 必須先 healthy，`dagster-webserver` 和 `dagster-daemon` 才能啟動（compose 已設定 `depends_on` 健康依賴）。
- `dagster-login`（OAuth2 Proxy，Dagster SSO 對外邊界）會持續重試連線 Keycloak，直到 Phase 2 的 Keycloak 啟動後才會轉為正常狀態，屬預期行為，不需要特別處理。
- CD runner 已改到 VM3（跟 CI runner 同一台，見 Phase 3-5），VM4 不再需要 `gitlab-runner-cd`。改用 rsync 從 VM3 推送，VM4 只當接收端，上面不會有 `.git` 目錄、也不需要對 GitLab 的連線。理由見 [11_CD_rsync部署機制 · 第 8 節](./docs/GitLab維運手冊/進階調整/11_CD_rsync部署機制.md#8-為什麼是vm3-推而不是vm4-拉)。
- PostgreSQL 對外 Port 是 `5433`（非預設 5432），參數來自 `INFRA_DB_PORT=5433`。
- 務必先完成 Phase 0-9 的目錄權限設定，否則 `dagster-code` / `dagster-webserver` / `dagster-daemon` 會因為 `Permission denied` 啟動失敗。

---

## Phase 2：VM5 — Keycloak + Nginx + Superset

### 2-1. 啟動 Keycloak

```bash
# 在 VM5 執行
cd /run/media/root/D/deploy

docker compose up -d keycloak

# 等待 healthy（約 30~60 秒）
watch -n 3 "docker compose ps keycloak"
# 出現 (healthy) 後按 Ctrl+C
```

> **DNS 設定說明**：Keycloak 容器的 `dns:` 指向公司 DNS 伺服器（`10.10.43.1` / `10.10.43.2`，見 VM5 的 compose 檔），不是泛用的任意 DNS。這是為了讓 Keycloak 能解析公司內部主機名稱（例如 LDAP server），同時仍維持「明確釘選固定清單」的圍堵原則（CVE-2026-5435 / CVE-2026-6238 glibc DNS/TSIG 弱點圍堵措施的一部分）。若公司 DNS 伺服器 IP 不是 `10.10.43.1` / `10.10.43.2`，請在部署前修改此檔。

### 2-2. 建立 Keycloak Realm 及 Clients
這一步要建立其他元件透過 `keycloak` 登入時的設定，可以採用下方打 API 的方式或是進入 `keycloak` 網頁手動設定。
建立清單：
1. Realm: 建立 DAI 專用的 Realm，可以想成就是開一個新的專案用來管理 DAI 底下的系統。
2. Clients: 每個元件要連線到 `keycloak` 就需要在 `keycloak` 有一個對應的 `client`。所以會需要建立 `dagster`、`superset`、`gitlab`、`dependency-track` 這**四個**。

> Realm 名稱：`postoffice`
> Admin 帳號：`admin`，密碼：見部署根目錄 `.env` 中的 `KEYCLOAK_ADMIN_PASSWORD`

> ⚠️ **下面每個 client 的 `secret` 都是預設佔位字串**（`YourDagsterOidcSecret` 之類），
> **正式環境務必換成隨機值**，並與各服務設定裡的值一致：
> | client | 另一端要填在哪 |
> |---|---|
> | `dagster` | VM4 `.env` 的 OAuth2 Proxy client secret |
> | `superset` | VM5 `workspace/superset_config.py` |
> | `gitlab` | VM3 compose 的 `GITLAB_OMNIBUS_CONFIG`（見 Phase 3-3） |
> | `dependency-track` | Public client，無 secret |
>
> 產生隨機值：`python3 -c 'import secrets; print(secrets.token_urlsafe(32))'`

```bash
# 在 VM5 執行
cd /run/media/root/D/deploy

# 取得 Admin Token
KC_PASS=$(grep '^KEYCLOAK_ADMIN_PASSWORD=' .env | cut -d= -f2-)
KC_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 確認有拿到 token，沒拿到就不要往下做
[ -n "$KC_TOKEN" ] && echo "token OK" || echo "取得 token 失敗，檢查密碼與 8080 是否可連"

BASE="http://localhost:8080/admin/realms/postoffice/clients"

# 建立 Realm（若不存在）
curl -s -o /dev/null -X POST "http://localhost:8080/admin/realms" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  -d '{"realm":"postoffice","enabled":true,"displayName":"Post Office"}' || true

# 重新取得 token（建立 realm 後需重新驗證）
KC_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Client 1: dagster（Confidential）
curl -s -o /dev/null -X POST "$BASE" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" -d '{
  "clientId":"dagster","protocol":"openid-connect","publicClient":false,
  "secret":"YourDagsterOidcSecret","standardFlowEnabled":true,
  "redirectUris":["https://dagster.dai.post.gov.tw/oauth2/callback"]}'

# Client 2: superset（Confidential）
curl -s -o /dev/null -X POST "$BASE" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" -d '{
  "clientId":"superset","protocol":"openid-connect","publicClient":false,
  "secret":"YourSupersetOidcSecret","standardFlowEnabled":true,
  "redirectUris":["https://superset.dai.post.gov.tw/*"]}'

# Client 3: gitlab（Confidential）
curl -s -o /dev/null -X POST "$BASE" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" -d '{
  "clientId":"gitlab","protocol":"openid-connect","publicClient":false,
  "secret":"YourKeycloakGitlabSecret","standardFlowEnabled":true,
  "redirectUris":["https://gitlab.dai.post.gov.tw/users/auth/openid_connect/callback"]}'

# Client 4: dependency-track（Public + PKCE）
curl -s -o /dev/null -X POST "$BASE" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" -d '{
  "clientId":"dependency-track","protocol":"openid-connect","publicClient":true,
  "standardFlowEnabled":true,"attributes":{"pkce.code.challenge.method":"S256"},
  "redirectUris":["https://dtrack.dai.post.gov.tw/*"]}'

echo "Clients created."
```

**驗證四個 client 都建好了：**
```bash
curl -s "$BASE" -H "Authorization: Bearer $KC_TOKEN" \
  | python3 -c "import sys,json; print([c['clientId'] for c in json.load(sys.stdin)])"
# 應該看到 dagster / superset / gitlab / dependency-track 都在裡面
```

> 📌 **如果 `localhost:8080` 連不到**：表示 secure compose 沒有把 Keycloak 的 8080 對外
> 發佈（只走 nginx）。改用容器網路內部呼叫：
> ```bash
> docker exec keycloak curl -s -X POST \
>   "http://localhost:8080/realms/master/protocol/openid-connect/token" ...
> ```
> 或先確認 `docker compose ps keycloak` 的 PORTS 欄位實際開在哪個 port。

**建立測試使用者（選用，若改用 LDAP 聯邦則使用者改由 LDAP 同步）：**
同樣可以進入 `keycloak` 創建或是打下方 API。
```bash
curl -s -o /dev/null -X POST "http://localhost:8080/admin/realms/postoffice/users" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  -d '{"username":"testuser","enabled":true,
       "credentials":[{"type":"password","value":"testuser","temporary":false}],
       "firstName":"Test","lastName":"User","email":"testuser@dai.post.gov.tw"}'
echo "Test user created."
```

### 2-3. 設定 LDAP User Federation（串接公司 LDAP）

> Keycloak 容器的 DNS 已設定為公司可信任 DNS 伺服器（見 2-1），可正常解析公司內部 LDAP 主機名稱。以下步驟需要您提供公司 LDAP 實際連線資訊，下方標示 `<TODO:...>` 的欄位請替換為正式值。

**方式 A — Admin Console（建議，欄位多且需要逐一測試連線/驗證）：**

1. 登入 `https://auth.dai.post.gov.tw`（admin 帳號）
2. 左側選單 realm 切換到 `postoffice` → **User federation** → **Add Ldap providers**
3. 填入：

| 欄位 | 範例值 | 說明 |
|------|--------|------|
| UI Display Name | `Company LDAP` | 自訂顯示名稱 |
| Vendor | `Active Directory` | 依公司 LDAP 類型選擇 |
| Connection URL | `ldap://10.10.20.101:389` | 公司 LDAP server 位址 |
| Bind Type | `simple` | |
| Bind DN | `DAI_LDAP` | 服務帳號 DN |
| Bind Credential | `密碼` | |
| Edit Mode | `READ_ONLY` | 建議唯讀，避免 Keycloak 寫回 LDAP |
| Users DN | `OU=900000郵政總公司,OU=人資同步目錄,DC=chpost,DC=com,DC=tw` | 使用者搜尋基準 |
| Username LDAP attribute | AD: `sAMAccountName` | |
| RDN LDAP attribute | AD: `cn` | |
| UUID LDAP attribute | AD: `objectGUID` | |
| User Object Classes | AD: `person, organizationalPerson, user` | |
| Search Scope | `Subtree` | |

4. 點擊 **Test connection** 確認可連線、**Test authentication** 確認 Bind 帳密正確
5. 確認使用者出現在 **Users** 清單中，並可用 LDAP 帳密登入測試（GitLab / dtrack / Dagster / Superset 任一個都可驗證）

**方式 B — REST API（自動化部署用，需先備妥所有正式值）：**

```bash
# 在 VM5 執行（沿用 2-2 取得的 $KC_TOKEN，若已過期需重新取得）
curl -s -X POST "http://localhost:8080/admin/realms/postoffice/components" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" -d '{
  "name": "Company LDAP",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "parentId": "postoffice",
  "config": {
    "enabled": ["true"],
    "vendor": ["other"],
    "connectionUrl": ["<TODO: ldap://ldap.company.local:389>"],
    "usersDn": ["<TODO: ou=Users,dc=company,dc=com>"],
    "bindDn": ["<TODO: cn=svc-keycloak,ou=ServiceAccounts,dc=company,dc=com>"],
    "bindCredential": ["<TODO: 服務帳號密碼>"],
    "usernameLDAPAttribute": ["uid"],
    "rdnLDAPAttribute": ["uid"],
    "uuidLDAPAttribute": ["entryUUID"],
    "userObjectClasses": ["inetOrgPerson, organizationalPerson"],
    "authType": ["simple"],
    "editMode": ["READ_ONLY"],
    "searchScope": ["1"],
    "pagination": ["true"],
    "importEnabled": ["true"]
  }
}'
```

**驗證 LDAP 連線不受 DNS 圍堵影響：**
```bash
# 在 VM5 執行：確認 Keycloak 容器能解析 LDAP 的「主機名稱」
# （getent 只吃主機名稱，不能帶 port；填 IP 的話這個測試沒有意義）
docker exec keycloak getent hosts ldap.chpost.com.tw       # 換成公司 LDAP 實際主機名稱

# 再確認 389 port 真的通得到（getent 只驗 DNS，不驗連線）
docker exec keycloak bash -c 'cat < /dev/null > /dev/tcp/ldap.chpost.com.tw/389' \
  && echo "LDAP 389 可連線"
```

> Connection URL 若直接填 IP（例如 `ldap://10.10.20.101:389`），就不需要驗 DNS，
> 只要驗 389 port 通不通即可。填 IP 的缺點是 LDAP server 換機時要改設定。

### 2-4. 啟動其餘 VM5 服務

```bash
cd /run/media/root/D/deploy

docker compose up -d nginx kc_access

# superset 初始化（只需執行一次）
docker compose run --rm superset-init
# 等 superset-init 正常結束後（exit code 0），再啟動主服務
docker compose up -d superset
```

**驗證：**
```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://auth.dai.post.gov.tw/health/ready   # 200
curl -sk -o /dev/null -w "%{http_code}\n" https://superset.dai.post.gov.tw            # 302
```

**注意事項：**
- VM5 nginx 的 `dagster.dai.post.gov.tw` 反向代理設定指向 VM4:4180，需要 VM4 的 `dagster-login` 先在線上（Phase 1 已完成）。
- `superset-init` 是一次性初始化容器，完成後自動退出，再啟動 `superset`。第二次執行 init 時若 admin 帳號已存在會顯示錯誤但不影響結果（有 `|| true` 處理）。
- Superset 的日常操作、資料庫連線、權限與 SSO 對應，見 [D-Track 與 Superset 手冊](./docs/D-Track與Superset手冊/README.md)。
---

## Phase 3：VM3 — GitLab + Container Registry + Dependency-Track

### 3-1. 建立目錄並啟動服務

```bash
# 在 VM3 執行
cd /run/media/root/D/deploy

# 把 .env 讀進目前這個 shell，後面才用得到 ${GITLAB_HOME}
# （docker compose 會自己讀 .env，但你手打的指令不會）
set -a; . ./.env; set +a
echo "$GITLAB_HOME"          # 確認有值再往下做

mkdir -p "${GITLAB_HOME}"/{config,logs,data}

# 先啟動 nginx 和 dtrack（不依賴 GitLab）
docker compose up -d nginx dtrack-server

# 等 dtrack-server healthy（約 120 秒）
watch -n 5 "docker compose ps dtrack-server"

# dtrack-server healthy 後啟動 frontend
docker compose up -d dtrack-frontend

# 啟動 GitLab（初始化約 3~5 分鐘，視 VM 規格而定）
docker compose up -d gitlab
```

> 💡 **後面 Phase 3 / Phase 4 的每一段指令都假設你在 VM3 做過上面那行 `set -a; . ./.env; set +a`。**
> 換一個 terminal 或重新登入之後要再做一次。

**等待 GitLab 完成初始化：**
```bash
docker logs -f gitlab 2>&1 | grep -m1 "Reconfigured!"
# 出現 "gitlab Reconfigured!" 才表示完成
# 健康檢查需另外確認（見下方），Reconfigured 完成後 Puma 仍需數十秒到數分鐘
# preload 才會真正可服務，VM 記憶體不足時可能反覆卡在 preload
```

**確認 GitLab 真正可服務（而非只是 Reconfigured）：**
```bash
for i in $(seq 1 20); do
  CODE=$(curl -sk -o /dev/null -w "%{http_code}" https://localhost/users/sign_in -H "Host: gitlab.dai.post.gov.tw")
  echo "[$i] /users/sign_in: $CODE"
  [ "$CODE" = "200" ] && break
  sleep 15
done
```

### 3-2. GitLab — 匯入自簽 CA 憑證

GitLab 呼叫 Keycloak OIDC 時需驗證 TLS 憑證，使用自簽憑證時須加入 trusted-certs：

```bash
# 在 VM3 執行（已 cd 到部署根目錄、已 source .env）
mkdir -p "${GITLAB_HOME}/config/trusted-certs"
cp ./certs/GRCA3.crt "${GITLAB_HOME}/config/trusted-certs/dai-ca.crt"

docker exec gitlab gitlab-ctl reconfigure
# 約需 2 分鐘，完成後 GitLab 服務會自動重啟
```

**驗證 GitLab 真的信任了這張 CA**（下一步的 OIDC 就是靠它）：
```bash
docker exec gitlab openssl s_client -connect auth.dai.post.gov.tw:443 -brief < /dev/null 2>&1 \
  | grep -i "verification"
# 要看到 Verification: OK，出現 verify error 就是還沒吃到
```

### 3-3. GitLab — 設定 Keycloak OIDC SSO (可跳過)

這步已經寫在 compose 的 `GITLAB_OMNIBUS_CONFIG` 底下了，可以不執行。
```bash
# 在 VM3 執行：寫入 OIDC 設定到 gitlab.rb
cat >> ${GITLAB_HOME}/config/gitlab.rb << 'EOF'

gitlab_rails['omniauth_enabled'] = true
gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']
gitlab_rails['omniauth_sync_email_from_provider'] = 'openid_connect'
gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']
gitlab_rails['omniauth_providers'] = [
  {
    name: 'openid_connect',
    label: 'Keycloak SSO',
    args: {
      name: 'openid_connect',
      scope: ['openid','profile','email'],
      response_type: 'code',
      issuer: 'https://auth.dai.post.gov.tw/realms/postoffice',
      discovery: true,
      client_auth_method: 'query',
      uid_field: 'preferred_username',
      client_options: {
        identifier: 'gitlab',
        secret: 'YourKeycloakGitlabSecret',
        redirect_uri: 'https://gitlab.dai.post.gov.tw/users/auth/openid_connect/callback'
      }
    }
  }
]
EOF

docker exec gitlab gitlab-ctl reconfigure
```

> 此設定已內建在 compose 的 `GITLAB_OMNIBUS_CONFIG` 中（含 OIDC），通常不需要手動執行本步驟；僅在手動調整 OIDC 設定時才需要重新 `gitlab-ctl reconfigure`。
> `secret` 要跟 Phase 2-2 建立 `gitlab` client 時填的值一致。

**驗證 SSO 可用**：開 `https://gitlab.dai.post.gov.tw/users/sign_in`，
登入頁下方應出現 **Keycloak SSO** 按鈕，點下去會跳到 `auth.dai.post.gov.tw`。

### 3-4. dtrack — 修改 Admin 密碼並啟用 OIDC

**修改密碼（建議透過 UI 操作）：**
1. 登入 `https://dtrack.dai.post.gov.tw`（預設帳號：`admin` / `admin`）
2. Administration → Access Management → Change Password

**確認 OIDC 已啟用：**
```bash
curl -sk https://dtrack.dai.post.gov.tw/api/v1/oidc/available    # 應回 true
```

回 `false` 的話通常是 JVM 不信任自簽 CA，見下方。

> **重要**：dtrack 映像必須是 `dai/dt_apiserver:v2.1` 以上，此版本在建置時已將自簽 CA 匯入 JVM TrustStore（`keytool -import -cacerts`）。若使用其他版本映像，須手動匯入：
> ```bash
> docker cp ./certs/GRCA3.crt dtrack-server:/tmp/GRCA3.crt
> docker exec dtrack-server bash -c \
>   "keytool -import -trustcacerts -cacerts -storepass changeit -noprompt \
>    -alias dai-ca -file /tmp/GRCA3.crt"
> docker restart dtrack-server
> ```
> ⚠️ 這個做法**容器重建後就不見了**，長期要用 `Dockerfile.dt_apiserver` 重新編映像。
> 建議後續版本如果沒有重大改動，直接採用原本的 Dockerfile.dt_apiserver 進行編譯。

> D-Track 的日常操作（建 team、發 API Key、看弱點、標例外）見
> [D-Track 與 Superset 手冊](./docs/D-Track與Superset手冊/README.md)。
> 接上 CI/CD 的部分在 Phase 4I。
### 3-5. 啟動並註冊 GitLab Runner CI / CD

兩個 runner 都跑在 VM3 上，用 tag 區分職責：

| Runner | tag | 負責 |
|---|---|---|
| `gitlab-runner-ci` | `vm3,ci` | lint、test、gitleaks、bandit、D-Track |
| `gitlab-runner-cd` | `vm3,cd` | rsync 推到 VM1 / VM4、雜湊對帳 |

**Runner 要信任 GitLab 的自簽憑證**，所以先把憑證鏈放到 runner 讀得到的地方。
GitLab Runner 會去找**檔名等於 GitLab 主機名稱**的憑證檔：

```bash
# 在 VM3 執行（已 cd 到部署根目錄）
# 兩個 runner 各自的 certs 目錄都要有
for r in ci cd; do
  mkdir -p ./workspace/gitlab-runner-${r}/certs
  cp ./certs/fullchain_202606.crt \
     ./workspace/gitlab-runner-${r}/certs/gitlab.dai.post.gov.tw.crt
done

ls -l ./workspace/gitlab-runner-*/certs/     # 兩個都要有檔案，不是空的
```

> 這裡用 `cp` 不用 `ln -s`：憑證是**掛進容器裡**的，符號連結在容器內會指到不存在的路徑。
> 換憑證時記得這兩份要一起換。

```bash
docker compose up -d gitlab-runner-ci gitlab-runner-cd

# 在 GitLab UI：Admin Area → CI/CD → Runners → New instance runner
# 各取一組 Token 後分別 register：
docker exec gitlab-runner-ci gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.dai.post.gov.tw" \
  --token "<CI Runner Token>" \
  --executor "shell" \
  --description "vm3-ci-runner" \
  --tag-list "vm3,ci"

docker exec gitlab-runner-cd gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.dai.post.gov.tw" \
  --token "<CD Runner Token>" \
  --executor "shell" \
  --description "vm3-cd-runner" \
  --tag-list "vm3,cd,deploy"
```

**驗證兩個 runner 都註冊成功：**
```bash
docker exec gitlab-runner-ci gitlab-runner verify
docker exec gitlab-runner-cd gitlab-runner verify
# 應顯示 is alive；出現 x509 錯誤代表上面那份憑證沒放對
```
GitLab UI 的 Admin Area → CI/CD → Runners 也應該看到兩個綠點，tag 分別是 `vm3,ci` 與 `vm3,cd,deploy`。

**CD runner 需要額外的工具**（`ci/deploy_rsync.sh` 會用到 rsync 與 ssh）：

```bash
docker exec gitlab-runner-cd sh -c \
  "command -v rsync ssh || (apt-get update && apt-get install -y rsync openssh-client)"

# 確認裝好了
docker exec gitlab-runner-cd sh -c "rsync --version | head -1; ssh -V"
```

> ⚠️ 容器重建後 `apt-get` 裝的東西會消失。長期作法是做一個
> `Dockerfile.gitlab-runner-cd`（base image 加 `rsync openssh-client`），
> 跟現有的 `Dockerfile.keycloak`、`Dockerfile.dt_apiserver` 一樣納入映像建置流程。

> 📌 **CD runner 不需要掛載 `/home/gitlab_runner/.ssh`。**
> 部署用的私鑰與 known_hosts 是由 GitLab 的 **File 型別 CI/CD Variable**
> （`DEPLOY_SSH_KEY`／`DEPLOY_KNOWN_HOSTS`，見 Phase 4E）在 job 執行時寫成暫存檔，
> `ci/deploy_rsync.sh` 用完就刪。
> 把 host 上的私鑰掛進容器反而多開一個常駐的外洩面，**不要這樣做**。
> Phase 4A 在 VM3 上產的那兩把私鑰，用途是「產生出來之後貼進 GitLab Variable」。

### 3-6. 安裝 gitleaks 到 GitLab 容器（給伺服器端 hook 用）

Phase 4D 的 pre-receive hook 需要它，先裝好。

**gitleaks 執行檔哪裡來**：離線環境要事先從
[gitleaks releases](https://github.com/gitleaks/gitleaks/releases) 下載
`gitleaks_<版本>_linux_x64.tar.gz` 帶進來（**它是靜態編譯的單一執行檔，不需要安裝**）：

```bash
# 在 VM3，已 cd 到部署根目錄
tar -xzf /tmp/gitleaks_*_linux_x64.tar.gz -C /tmp gitleaks
install -m 755 /tmp/gitleaks ./workspace/gitlab/gitleaks
./workspace/gitlab/gitleaks version      # 先在 host 上確認跑得起來
```

送進 GitLab 容器：

```bash
docker cp ./workspace/gitlab/gitleaks gitlab:/usr/local/bin/gitleaks
docker exec gitlab chmod 755 /usr/local/bin/gitleaks
docker exec gitlab /usr/local/bin/gitleaks version    # 確認容器裡也跑得起來
```

> 開發者本機也要裝同一支（Phase 4H），版本盡量一致，
> 否則同一份 `.gitleaks.toml` 可能有規則語法不支援。

> 同樣要處理「容器重建就消失」的問題，作法見
> [GitLab維運手冊 · 10_CI_Pipeline設定詳解 · 3-5](./docs/GitLab維運手冊/進階調整/10_CI_Pipeline設定詳解.md#3-5-讓它在容器重建後還在)。

### 3-7. 驗證 Container Registry（與 GitLab 共用 domain）

Container Registry **與 GitLab 共用 `gitlab.dai.post.gov.tw` 同一個 domain**，不需另外申請/設定子網域，僅用不同 **port 5050** 區分（GitLab 官方支援的設定方式：同 domain 不同 port；GitLab 不支援把 Registry 用路徑掛在跟主站完全相同的 domain+port 下）。

```bash
# 驗證 Registry API（未認證請求應回 401，代表 vhost 正常）
curl -sk -o /dev/null -w "%{http_code}\n" https://gitlab.dai.post.gov.tw:5050/v2/
# 預期：401

# 開發者使用方式（docker login / push / pull）
docker login gitlab.dai.post.gov.tw:5050 -u <gitlab帳號> -p <Personal Access Token>
docker tag myimage:latest gitlab.dai.post.gov.tw:5050/<group>/<project>/myimage:latest
docker push gitlab.dai.post.gov.tw:5050/<group>/<project>/myimage:latest
```

> 防火牆需額外開通 VM3 的 **TCP 5050**。

---

## Phase 4：版控與 CI/CD 同步（VM1 / VM3 / VM4）

> 這個 Phase 建立的是**日後所有程式碼變更的唯一路徑**。建完之後，
> 沒有人應該再直接登入 VM1 / VM4 改檔案——改了會在隔天的雜湊對帳被抓出來。
>
> 建置細節與設計理由見 [GitLab 維運手冊](./docs/GitLab維運手冊/README.md)，
> 這裡只列建置步驟。

### 要同步的兩個東西

| repo | 內容 | 部署到 | 部署路徑 |
|---|---|---|---|
| `dagster-workspace` | Dagster 程式 + dbt 專案 | **VM4** | `/data/deploy/workspace/dagster_workspace/` |
| `bcp-scripts` | VM1 的執行腳本與清洗函式 | **VM1** | `/home/bcp_runner/scripts/` |

兩個各自獨立的 repo、各自獨立的 pipeline：合併進 `main` → 自動 rsync 推到對應正式機。

### 同步的方向

```
VM3（GitLab + CD runner，以 gitlab_runner 身分執行）
      │
      ├─ ~/.ssh/gitlab_to_vm4 ──rsync──▶ VM4 的 gitlab_runner
      └─ ~/.ssh/gitlab_to_vm1 ──rsync──▶ VM1 的 gitlab_runner
```

> 📌 這跟 Phase 5.1 的 `dagster_user → bcp_runner` 是**兩條完全獨立的 SSH 通道**。
> 不要共用金鑰：那條是「執行期指揮」，這條是「部署」，出事時要能分別停掉。

---

### 4A. 三台 VM 建立 `gitlab_runner` 帳號與免密碼 SSH

**VM4（接收端）：**

```bash
# 在 VM4，以 root
useradd -m -s /bin/bash gitlab_runner
mkdir -p /home/gitlab_runner/.ssh && chmod 700 /home/gitlab_runner/.ssh
chown -R gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh

# 讓 gitlab_runner 寫得進部署目錄
# （Dagster 容器是 UID 10001，兩個不同 UID 要共用同一個目錄，靠 ACL）
mkdir -p /data/deploy/workspace/dagster_workspace
setfacl -R -m u:gitlab_runner:rwx /data/deploy/workspace/dagster_workspace
setfacl -d -m u:gitlab_runner:rwx /data/deploy/workspace/dagster_workspace
#          ↑ -d 是 default ACL，之後 rsync 新建的目錄才會自動繼承
```

**VM1（接收端）：**

```bash
# 在 VM1，以 root
useradd -m -s /bin/bash gitlab_runner
mkdir -p /home/gitlab_runner/.ssh && chmod 700 /home/gitlab_runner/.ssh
chown -R gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh

setfacl -R -m u:gitlab_runner:rwx /home/bcp_runner/scripts
setfacl -d -m u:gitlab_runner:rwx /home/bcp_runner/scripts
```

**VM3（發送端，產金鑰）：**

```bash
# 在 VM3，以 root
useradd -m -s /bin/bash gitlab_runner
mkdir -p /home/gitlab_runner/.ssh && chmod 700 /home/gitlab_runner/.ssh
chown -R gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh

su - gitlab_runner
# 正式環境兩把、測試環境兩把 —— ★正式與測試不可共用金鑰★
ssh-keygen -t ed25519 -N "" -C "gitlab-cd-to-vm4-prod" -f ~/.ssh/gitlab_to_vm4
ssh-keygen -t ed25519 -N "" -C "gitlab-cd-to-vm1-prod" -f ~/.ssh/gitlab_to_vm1
ssh-keygen -t ed25519 -N "" -C "gitlab-cd-to-vm4-stg"  -f ~/.ssh/gitlab_to_vm4_stg
ssh-keygen -t ed25519 -N "" -C "gitlab-cd-to-vm1-stg"  -f ~/.ssh/gitlab_to_vm1_stg
chmod 600 ~/.ssh/gitlab_to_*
```

**派發公鑰**（以 VM4 為例，VM1 同樣做一次）：

```bash
# 在 VM3 印出公鑰
cat /home/gitlab_runner/.ssh/gitlab_to_vm4.pub

# 到 VM4，以 root —— ★不要用 ssh-copy-id★（它不會加下面的限制條件）
cat >> /home/gitlab_runner/.ssh/authorized_keys <<'EOF'
from="<VM3_IP>",restrict,pty ssh-ed25519 AAAAC3Nz...（貼上公鑰全文） gitlab-cd-to-vm4-prod
EOF
chmod 600 /home/gitlab_runner/.ssh/authorized_keys
chown gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh/authorized_keys
```

| 限制 | 作用 |
|---|---|
| `from="<VM3_IP>"` | 只接受從 VM3 來的連線，金鑰外流到別台機器也用不了 |
| `restrict` | 關掉 port / agent / X11 forwarding，這條通道不該能當跳板 |
| `pty` | `restrict` 會連 pty 一起關掉，但 `sudo` 需要，所以加回來 |

**取得 known_hosts**（CD 用 `StrictHostKeyChecking=yes`，不接受未知主機）：

```bash
# 在 VM3，以 gitlab_runner
ssh-keyscan -t ed25519,rsa <VM4_IP> > ~/.ssh/known_hosts_vm4
ssh-keyscan -t ed25519,rsa <VM1_IP> > ~/.ssh/known_hosts_vm1

# ★ 務必人工核對指紋 ★ ssh-keyscan 本身不驗真偽
# 在 VM4 上：ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
# 在 VM3 上：ssh-keygen -lf ~/.ssh/known_hosts_vm4
# 兩邊指紋一致才算數
```

**驗證：**

```bash
# 在 VM3，以 gitlab_runner
ssh -i ~/.ssh/gitlab_to_vm4 \
    -o UserKnownHostsFile=~/.ssh/known_hosts_vm4 \
    -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o BatchMode=yes \
    gitlab_runner@<VM4_IP> 'echo 登入成功; id'
```

沒跳密碼提示、直接印出結果就成功了。

**防火牆**需新增兩條：`VM3 → VM4:22`、`VM3 → VM1:22`。

> 📌 **這幾把金鑰接下來要做什麼**：
> 驗證通過之後，**私鑰內容**與 **known_hosts 內容**要貼進 GitLab 的
> File 型別 CI/CD Variable（`DEPLOY_SSH_KEY`／`DEPLOY_KNOWN_HOSTS`，見 4E）。
> 實際跑部署的是 CD runner 容器，它是從那兩個 Variable 拿到金鑰的，
> **不是**讀 VM3 host 上的 `/home/gitlab_runner/.ssh/`。
> ```bash
> # 取內容貼到 GitLab（★整份貼，含 BEGIN/END 那兩行★）
> cat /home/gitlab_runner/.ssh/gitlab_to_vm4
> cat /home/gitlab_runner/.ssh/known_hosts_vm4
> ```

---

### 4B. 安裝 post-deploy 腳本與 sudoers

rsync 過來的檔案屬於 `gitlab_runner`，但實際執行的是別的身分
（VM4 是 UID 10001、VM1 是 `bcp_runner`），所以部署後要 `chown` 回去。

**腳本從哪裡來**：兩支腳本都在 `dagster-workspace` repo 的
`gitlab_workspace/post_deploy/` 底下，也一起打包在 `deploy_package_vm3.tar.gz` 裡。
VM1 / VM4 上沒有這個 repo，所以要從 VM3 複製過去：

```bash
# 在 VM3，把腳本送到兩台目標機
scp /run/media/root/D/deploy/gitlab_workspace/post_deploy/dai-post-deploy-vm4.sh root@<VM4_IP>:/tmp/
scp /run/media/root/D/deploy/gitlab_workspace/post_deploy/dai-post-deploy-vm1.sh root@<VM1_IP>:/tmp/
```

**VM4：**

```bash
# 在 VM4，以 root
install -o root -g root -m 755 /tmp/dai-post-deploy-vm4.sh /usr/local/sbin/dai-post-deploy-vm4.sh

cat > /etc/sudoers.d/dai-gitlab-runner <<'EOF'
gitlab_runner ALL=(root) NOPASSWD: /usr/local/sbin/dai-post-deploy-vm4.sh
Defaults!/usr/local/sbin/dai-post-deploy-vm4.sh !requiretty
EOF
chmod 440 /etc/sudoers.d/dai-gitlab-runner
visudo -c        # ★一定要驗★ sudoers 寫錯會讓整台機器的 sudo 失效
```

**VM1：** 同樣做一次，換成 `/tmp/dai-post-deploy-vm1.sh`
（sudoers 檔裡的路徑也要跟著改成 `dai-post-deploy-vm1.sh`）。

**驗證 sudo 規則真的生效**（部署時 runner 是非互動執行，所以要用 `-n` 測）：

```bash
# 在 VM4，切成 gitlab_runner 測
su - gitlab_runner -c "sudo -n /usr/local/sbin/dai-post-deploy-vm4.sh --help" ; echo "exit=$?"
# 不能出現 "sudo: a password is required"
# 也不能出現 "not allowed to execute"

# 順便確認 gitlab_runner 不能拿它幹別的事（應該要被拒絕）
su - gitlab_runner -c "sudo -n /bin/chown root /etc/shadow" ; echo "exit=$?（應為非 0）"
```

> 腳本若沒有 `--help` 參數，改用 `sudo -n -l` 檢查授權清單：
> ```bash
> su - gitlab_runner -c "sudo -n -l"
> # 應該只列出那一支 dai-post-deploy-vmX.sh，沒有別的
> ```

> 🔒 **為什麼要一支參數寫死的固定腳本，而不是 `NOPASSWD: /bin/chown`**
> 後者等於把整台機器送給任何拿到部署金鑰的人——可以 `chown` 任意檔案，
> 包括 `/etc/shadow` 和 `/etc/sudoers`。
> 腳本本身也必須是 `root:root 0755`：`gitlab_runner` 改得動腳本 = 一樣拿到 root。

這兩支腳本會做：

| VM4 | VM1 |
|---|---|
| `chown -R 10001:10001` | `chown -R bcp_runner:bcp_runner` |
| 目錄 750 / 檔案 640、`.env` 收到 600 | 同左 |
| `dbt parse` 重產 `manifest.json` | `python -m compileall` 用 VM1 實際的 Python 版本驗語法 |

---

### 4C. 建立兩個 GitLab repo

GitLab UI → New project → Blank project（**不要**勾 Initialize with README）

- `dagster-workspace`
- `bcp-scripts`

**推上初始程式碼**（在**你自己的電腦**上做，不是在 VM 上）：

```bash
# dagster-workspace：本 repo 就是它
cd <你本機的 dagster-workspace 目錄>
git remote add origin https://gitlab.dai.post.gov.tw/<group>/dagster-workspace.git
git push -u origin main

# bcp-scripts：從 VM1 現有的檔案初始化
# 步驟見 gitlab_workspace/repo_templates/bcp_scripts_repo/README.md
```

> 📌 **這一步一定要排在 4E（分支保護）之前。**
> 4E 會把 `main` 設成「Allowed to push and merge = No one」，
> 設完之後就再也不能直接 `git push` 到 `main` 了。

> ⚠️ `bcp-scripts` 的第一個 commit 是從**一直在跑的正式機**上原封不動複製過來的，
> 是最容易夾帶金鑰的一次。push 之前務必先自己掃一次：
> ```bash
> ci/check_secrets.sh tree
> ci/check_secrets.sh history
> ```
> 掃出東西的話**不要只是刪檔案再 commit**（歷史裡還在），
> 直接 `rm -rf .git` 重來。

---

### 4D. 安裝伺服器端 pre-receive hook ★最關鍵的一步★

**這一步才是「掃完才能 push 上去」真正生效的地方。**

本地的 pre-commit / pre-push 可以用 `git push --no-verify` 繞過，
也可能根本沒安裝（新同事、新機器）。
CI 的 secret-scanning job 則是**東西已經推上 GitLab 之後**才跑的——
那時候金鑰早就在遠端物件庫裡，只能事後重寫歷史。

pre-receive hook 跑在 GitLab 主機上，利用 git 的 quarantine 機制：
**回傳非 0 → 整批物件直接丟棄、ref 不動，金鑰從頭到尾沒進過 repo。**

兩個要送進容器的檔案（`.gitleaks.toml` 與 `server_hooks/pre-receive`）都在
`deploy_package_vm3.tar.gz` 解開後的目錄裡：

```bash
# 在 VM3，cd 到部署根目錄（gitleaks 已在 Phase 3-6 裝好）
cd /run/media/root/D/deploy

# 預設規則檔（repo 沒帶 .gitleaks.toml 時的 fallback）
docker cp ./gitlab_workspace/.gitleaks.toml gitlab:/etc/gitlab/gitleaks.toml

docker exec gitlab mkdir -p /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d
docker cp ./gitlab_workspace/server_hooks/pre-receive \
          gitlab:/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks
docker exec gitlab chmod 755 /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks
docker exec gitlab chown git:git /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks

# 確認三個檔案都到位
docker exec gitlab ls -l /usr/local/bin/gitleaks \
                          /etc/gitlab/gitleaks.toml \
                          /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks
```

> ⚠️ `.gitleaks.toml` 在 repo 根目錄，打包 VM3 部署包時要記得把它一起帶進
> `gitlab_workspace/` 底下（或自行調整上面的來源路徑）。
> 這份是 **fallback**：repo 自己帶了 `.gitleaks.toml` 時以 repo 的為準。

放在 `custom_hooks/pre-receive.d/` 底下是**全域** hook，所有專案自動生效。

**必須驗證它真的有在擋**（沒驗證過的資安控制等於沒有）：

```bash
# 在你自己的電腦上
git checkout -b test/pre-receive-hook
echo 'DB_PASS=ThisIsAFakePasswordForTesting123' > leak_test.txt
git add leak_test.txt
git commit --no-verify -m "test: 驗證 pre-receive hook"    # 故意跳過本地 hook
git push --no-verify -u origin test/pre-receive-hook       # 故意跳過本地 hook
```

**預期**：

```
remote: ❌ [DAI] Push 被拒絕：偵測到 1 個疑似機密資訊
 ! [remote rejected] test/pre-receive-hook -> test/pre-receive-hook (pre-receive hook declined)
```

看到 `[remote rejected]` 就成功了。清理：

```bash
git reset --hard HEAD~1
git checkout main && git branch -D test/pre-receive-hook
```

> ⚠️ **容器重建後 `/usr/local/bin/gitleaks` 與 hook 會消失。**
> 長期作法是把三個檔案掛進 VM3 的 compose 檔（`:ro`），
> 見 [10_CI_Pipeline設定詳解 · 3-5](./docs/GitLab維運手冊/進階調整/10_CI_Pipeline設定詳解.md#3-5-讓它在容器重建後還在)。

---

### 4E. 分支保護、Variables、環境隔離

**正式與測試共用同一個 GitLab，靠三件事隔開**（缺一不可）：

| 機制 | 做什麼 |
|---|---|
| 保護分支 | `main` 禁止直接 push，只能透過 MR 進來 |
| Protected 變數 | 正式環境的連線資訊只有保護分支上的 job 拿得到 |
| Environment scope | 同一個變數名在 `production` / `staging` 有不同值 |

**分支保護**（兩個 repo 都要）：Settings → Repository → Protected branches

| Branch | Allowed to merge | Allowed to push and merge | Force push |
|---|---|---|---|
| `main` | **Maintainers** | **No one** | ❌ |
| `develop` | Developers + Maintainers | Developers + Maintainers | ❌ |

`main` 那列另外勾 **Require approval from code owners**。

**Merge Request Approvals（EE 功能，這是「一定要 code review」的強制點）：**

Settings → **Merge requests → Merge request approvals** → Add approval rule

| 設定 | 值 |
|---|---|
| Rule name | `正式環境 Code Review` |
| **Approvals required** | **1**（人手夠設 2） |
| Target branch | `main` |
| Eligible approvers | 開發團隊群組（別指定單一個人，會變瓶頸） |

同頁的 **Approval settings**，四個都要勾：

| 設定 | 不勾的後果 |
|---|---|
| **Prevent approval by author** | 作者自己 approve 自己，機制形同虛設 |
| **Prevent approvals by users who add commits** | 幫忙推過 commit 的人不算獨立審查者 |
| **Prevent editing approval rules in merge requests** | 作者可以在自己的 MR 裡把規則改成 0 人 |
| **Remove all approvals when commits are added** | ★可以先拿 approve、再偷偷加 commit★ |

同時勾選 **Pipelines must succeed** 與 **All threads must be resolved**。

**建立 `CODEOWNERS`**（repo 根目錄），讓高風險檔案一定要對的人看過：

```
*                            @dai-developers

# 動到部署與資安機制，一定要系統負責人審
/deploy_exclude.txt          @dai-maintainers
/.gitlab-ci.yml              @dai-maintainers
/.gitleaks.toml              @dai-maintainers
/ci/                         @dai-maintainers
/gitlab_workspace/           @dai-maintainers
```

`deploy_exclude.txt` 特別列出來的理由：**漏一行就會在下次部署洗掉正式機的 `.env`**。

> ★ **三層加起來** ★
> `Allowed to push and merge = No one`（不可能繞過 MR）
> ＋ `Approvals required ≥ 1` 與四個 Approval settings（一定要獨立的人審，且審完不能偷改）
> ＋ `CODEOWNERS`（高風險檔案要對的人審）
>
> 細節與驗證方式見
> [04_帳號_權限_分支保護](./docs/GitLab維運手冊/日常維運/04_帳號_權限_分支保護.md#3-code-review-的強制性ee-版)。

**CI/CD Variables**（Settings → CI/CD → Variables，每個都要勾 Protected）：

| Key | Type | Masked | Scope | 值 |
|---|---|---|---|---|
| `DEPLOY_HOST` | Variable | ✅ | production / staging | 目標機 IP |
| `DEPLOY_USER` | Variable | ❌ | 兩者 | `gitlab_runner` |
| `DEPLOY_SSH_KEY` | **File** | — | production / staging | 私鑰完整內容 |
| `DEPLOY_KNOWN_HOSTS` | **File** | — | production / staging | `known_hosts` 內容 |
| `DTRACK_URL` | Variable | ❌ | 兩者 | `https://dtrack.dai.post.gov.tw` |
| `DTRACK_API_KEY` | Variable | ✅ | 兩者 | D-Track API Key |
| `DTRACK_IMAGE` | Variable | ❌ | 兩者 | 僅 `dagster-workspace` 需要（它的套件在映像檔裡） |

> 私鑰是多行的，**一定要用 File 型別**，Variable 型別會壞掉且無法 mask。
>
> **`DEPLOY_PATH`、`SOURCE_DIR`、`POST_DEPLOY_CMD` 不用在這裡設**，
> 它們寫死在 [`.gitlab-ci.yml`](.gitlab-ci.yml) 的 job 裡（每個 repo、每個環境各自不同），
> 在這裡重設反而會蓋掉。
>
> **資料庫密碼不在這裡，也不該在這裡。** DB 連線走各機器上的 `.env`
> （VM4 `dagster_code/.env`、VM1 `/home/bcp_runner/.env`），
> 那兩個檔案不進版控、rsync 也不傳不刪。
> 所以 GitLab 被入侵也拿不到 DB 帳密。
> 隔離是靠「程式碼推到哪台機器，就吃那台機器的 `.env`」達成的。

**驗證隔離有效**：在功能分支跑 `echo "[${DEPLOY_HOST:-空}]"` 應該是空的，
在 `main` 上應該是 `[MASKED]`。驗完把測試用的 job 刪掉。

---

### 4F. 兩個排程：每日雜湊對帳 + 每季定期弱掃

GitLab UI → **Build → Pipeline schedules → New schedule**，
**兩個 repo 各建兩個排程**（共四個）。

#### 排程一：每日雜湊對帳

**在回答**：GitLab 上 `main` 的內容，跟正式機上實際在跑的檔案，還是同一份嗎？
抓得到「rsync 傳到一半」「有人直接 ssh 上機改檔案」「檔案被覆寫」。

| 欄位 | 值 |
|---|---|
| Description | `每日同步完整性稽核` |
| Interval Pattern | `30 8 * * *` |
| Cron timezone | `Asia/Taipei` |
| Target branch | `main`（一定要，才拿得到 production 變數） |
| **Variables** | `SCHEDULE_TYPE` = `verify` |
| Activated | ✅ |

**為什麼是 08:30**：要避開整個批次視窗，而且要落在有人上班的時段。

```
20:00 ├─ early_job 開始
00:00 ├─ 主批次（大部分程式集中在 00:00–06:00）
06:00 ├─ 批次大致結束
      │   ← 留 2.5 小時緩衝給延遲的尾巴
08:30 ★ 雜湊對帳 ★  ← 上班時間，紅燈當下就有人看到
```

07:00 太早（沒人上班，紅燈擺著沒人處理，批次延遲時還會跟尾巴重疊）；
18:00 之後太晚（發現問題來不及在當晚批次開跑前修好）。

> 💡 想多一道保險的話，再加一個 `0 19 * * *`：那是「今晚批次開跑前的最後確認」，
> 白天有人手改正式機的話在這裡就攔得下來。

#### 排程二：每季定期弱掃

**在回答**：程式碼沒改，但這三個月新公告的 CVE 有沒有打到我們？

| 欄位 | 值 |
|---|---|
| Description | `每季定期弱掃` |
| Interval Pattern | `0 3 1 */3 *` ← 1/4/7/10 月的 1 號 03:00 |
| Cron timezone | `Asia/Taipei` |
| Target branch | `main` |
| **Variables** | `SCHEDULE_TYPE` = `quarterly` |
| Activated | ✅ |

會跑 gitleaks 全歷史 + bandit + D-Track SBOM 複掃，
且**門檻比日常嚴（連 High 也擋）**。細節見下面的 Phase 4-I。

> ⚠️ **兩個排程的 `SCHEDULE_TYPE` 變數不能漏、不能設成一樣。**
> 兩者都是 `$CI_PIPELINE_SOURCE == "schedule"`，沒有變數區分的話，
> 每天早上的對帳排程會把整套資安複掃也拉起來跑（D-Track 每天被灌一次 SBOM），
> 每季的弱掃又會多跑一次雜湊對帳。

排程都不會觸發部署（deploy job 的 rules 只認 `main` 分支的 push）。

比對與掃描結果都會送進 rsyslog（tag `dai/gitlab-sync`），依 Phase 6 的架構
集中到 VM4 的 `/data/log/dai/` 並納入每日 log 雜湊存證。

---

### 4G. 首次部署

前面幾步都做完之後，第一次部署就是「在 GitLab 上把 pipeline 跑起來」而已：

```
GitLab UI → 專案 → Build → Pipelines → Run pipeline
  Branch: main
  → 等 deploy:production 綠燈
```

deploy job 會依序做完這四件事，任何一步失敗都會紅燈：

```
1. SSH 連線測試        連不到就早點失敗，不會傳到一半才爆
2. rsync 推送          --delete --checksum，以 repo 為準
3. post_deploy         chown + 權限收緊 + 重產 dbt manifest
4. 雜湊對帳            兩端內容必須一致
```

**部署完到 VM4 確認機密檔案還在：**

```bash
# 在 VM4
ls -l /data/deploy/workspace/dagster_workspace/dagster_code/.env
ls -l /data/deploy/workspace/dagster_workspace/dbt_project/profiles.yml
# 兩個都要在，權限應該是 600
```

這兩個檔案是 4C 之前人工建立的、不進版控，能在 `rsync --delete` 之下活下來
靠的是 [`deploy_exclude.txt`](./deploy_exclude.txt)：

> **rsync 的 `--delete` 不會刪掉被 `--exclude` 排除的檔案**
> （會刪的是 `--delete-excluded`，我們刻意不用）。
> 所以那份清單同時是「不傳清單」和「刪除保護清單」。
> **日後有人在那份清單裡漏掉一行，下一次部署就會洗掉正式機的帳密** ——
> 所以 4E 的 `CODEOWNERS` 特別把它列為必須 Maintainer 審核的檔案。

**最後到 Dagster UI 做一次 Reload definitions**，確認新的 manifest 被載入。

---

### 4H. 通知開發人員安裝本地 hook

每位開發者在自己的機器上，兩個 repo 各做一次：

```bash
ci/install_hooks.sh
ci/install_hooks.sh --check    # 確認
```

需要的工具：`gitleaks`（**必要**）、`black` `flake8` `bandit` `sqlfluff` `pip-audit`（選用）。
沒裝 gitleaks 的話 hook 會**擋下所有 commit/push**，而不是靜默放行。

詳見 [03_本地環境設定與提交前檢查](./docs/GitLab維運手冊/日常維運/03_本地環境設定與提交前檢查.md)。

---

### 4I. Dependency-Track：推送自動掃描 + 每季定期弱掃

D-Track 已在 Phase 3 裝好，這一步是**把它接上 CI/CD**。

#### 它在做什麼

我們自己寫的程式碼有 flake8 / bandit 在管，但**真正的攻擊面大多在別人的程式碼裡**——
`cryptography`、`pandas`、`pymssql` 每一個都可能被公告 CVE。

```
requirements.txt（或映像檔裡的套件清單）
        ↓  cyclonedx-py
      SBOM（bom.json）── 一份「我用了哪些套件、哪個版本」的清單
        ↓  上傳
   Dependency-Track（VM3）
        ↓  比對 NVD / OSV / GitHub Advisory
   Critical / High / Medium / Low 各幾個
        ↓
   Critical > 0 → pipeline 紅燈，擋住合併
```

#### 為什麼推送掃過了還要每季再掃

**因為弱點資料庫每天在長，但你的程式碼沒有變。**

```
2026-01-15  push cryptography==49.0.0 → 掃描 0 Critical ✅ 上線
2026-03-02  公告 CVE-2026-XXXXX，影響 cryptography <= 49.1
            ← 程式碼一行沒改，但它現在有一個 Critical
            ← 沒有任何 pipeline 會跑，沒有人會知道
2026-04-01  ★每季弱掃★ 用最新資料庫重掃 → 紅燈 → 有人去處理
```

D-Track 自己會持續重新評分，但**那只是一個沒有人會去看的網頁**。
每季弱掃的價值是把它變成「一次會紅燈的 pipeline」，有人收到通知、有紀錄可查。

| | 推送時 `sca-dtrack` | 每季 `sca-dtrack-quarterly` |
|---|---|---|
| 觸發 | MR / push / 合併 main | 排程（1/4/7/10 月 1 號 03:00） |
| 擋門標準 | **Critical > 0** | **Critical 或 High > 0** |
| artifacts 保留 | 1 週 | **1 年**（稽核用） |

> 日常不擋 High 是刻意的：一個不相干的套件出 High 就讓所有人的 MR 全卡住，
> 最後大家會要求把這個 job 關掉——那就什麼都沒有了。
> 日常只擋最嚴重的 Critical，**每季這一次專門用來清 High 的技術債**，
> 時間點固定、可以事先安排人力。

#### 步驟 1：建立 API Key

1. 登入 `https://dtrack.dai.post.gov.tw`
2. **Administration → Access Management → Teams** → 建 `gitlab-ci`
3. 權限只勾這四個（最小權限）：

| 權限 | 為什麼需要 |
|---|---|
| `BOM_UPLOAD` | 上傳 SBOM |
| `VIEW_PORTFOLIO` | 查專案 UUID |
| `VIEW_VULNERABILITY` | 讀弱點數量 |
| `PROJECT_CREATION_UPLOAD` | `autoCreate=true` 自動建專案 |

**不要**給 `PORTFOLIO_MANAGEMENT` 或 `ACCESS_MANAGEMENT` ——
CI 只需要上傳與讀取，不需要能刪專案或改權限。

4. 在該 team 底下 **Create API Key**

#### 步驟 2：填進 GitLab Variables

```
Settings → CI/CD → Variables
  DTRACK_URL      = https://dtrack.dai.post.gov.tw   （Protected）
  DTRACK_API_KEY  = odt_xxxxxxxx                      （Protected + Masked）
```

`dagster-workspace` 還要多一個：

```
  DTRACK_IMAGE = gitlab.dai.post.gov.tw:5050/<group>/<project>/dagster:v2.7
```

**為什麼**：兩個 repo 的 SBOM 來源不一樣。

| repo | 來源 | 原因 |
|---|---|---|
| `bcp-scripts` | `requirements.txt` | VM1 有自己的 venv，套件清單就在 repo 裡 |
| `dagster-workspace` | **映像檔** | 套件烘焙在 `dai/dagster` 映像檔裡，repo 沒有 requirements.txt |

`ci/build_sbom.sh` 會自動判斷；`dagster-workspace` 沒設 `DTRACK_IMAGE` 的話
**job 會直接失敗而不是跳過**。

> 📌 這是刻意的。如果只掃 repo 裡的檔案，`dagster-workspace` 會掃出「零個套件」
> 然後綠燈——完全是假的，真正在 VM4 上跑的那一堆套件一個都沒被檢查到。
> **一個靜默跳過的資安掃描，比沒有掃描更危險。**

#### 步驟 3：確認 `bcp-scripts` 的 requirements.txt 與 VM1 一致

```bash
# 在 VM1
source /run/media/root/D/python_env/dai_venv/bin/activate
python -m pip freeze > requirements.txt
```

走正常 MR 流程推上來。**不一致的話，掃的是紙上的環境，不是真正在跑的環境。**

#### 步驟 4：驗證

```
GitLab UI → Run pipeline（main）→ 看 sca-dtrack job 的 log
```

預期輸出：

```
=======================================
🛡️  資安掃描結果（bcp-scripts:main）
🔥 Critical : 0
🚨 High     : 2
⚠️  Medium   : 7
ℹ️  Low      : 12
   D-Track  : https://dtrack.dai.post.gov.tw/projects/a3f2b91c-...
=======================================
[ OK ]  SCA 檢查通過
```

到 D-Track 網頁確認 `dagster-workspace : main` 與 `bcp-scripts : main`
兩個專案都出現了。

#### 掃出弱點怎麼處理

1. 點 job log 裡的 D-Track 連結，看是哪個套件、哪個 CVE
2. 看 **Fixed in** 有沒有修補版本
3. 有的話改 `requirements.txt` → MR → 合併
   （**離線環境記得先把新版 wheel 帶進 `/run/media/root/D/python_env/req/`**）
4. 沒有修補版本、或確認我們沒用到那個弱點路徑 →
   在 D-Track 標記 `Not Affected` 並**在 Details 寫清楚理由**

> ⚠️ 標成 `Not Affected` 是一個**會讓紅燈變綠燈的動作**，應該跟改程式碼一樣被審視。
> 建議規定：標記例外要在 MR 或 Redmine 上留紀錄，不是自己點一點就算。
> 「為什麼我們不受這個 CVE 影響」是稽核一定會問的問題，半年後沒有人記得。

完整說明見
[15_D-Track定期弱掃](./docs/GitLab維運手冊/進階調整/15_D-Track定期弱掃.md)。

---

### Phase 4 檢查清單

```
[ ] VM1 / VM3 / VM4 都建好 gitlab_runner 帳號
[ ] VM1 / VM4 目標目錄設好 ACL（含 -d default ACL）
[ ] VM3 產好四把金鑰（正式 2 + 測試 2），正式與測試不共用
[ ] 公鑰已派發，且有 from= 與 restrict 限制
[ ] known_hosts 的指紋人工核對過
[ ] VM3 → VM4 / VM1 免密碼 SSH 驗證通過
[ ] 防火牆 VM3→VM4:22、VM3→VM1:22 已開通
[ ] post-deploy 腳本安裝好（root:root 0755），visudo -c 通過
[ ] sudo -n post_deploy 驗證通過
[ ] 兩個 GitLab repo 建好、初始程式碼推上去了
[ ] bcp-scripts 首次 commit 前掃過 gitleaks
[ ] ★ pre-receive hook 裝好，且用假金鑰實測過會被拒 ★
[ ] main 分支保護設好，Developer 按不到 Merge 鍵
[ ] ★ Approval Rules 設好：required ≥ 1，四個 Approval settings 都勾 ★
[ ] ★ 實測：作者自己 approve 按不下去；approve 後再 push 會清掉 approval ★
[ ] CODEOWNERS 建好，改 deploy_exclude.txt 會要求 Maintainer 審核
[ ] Pipelines must succeed / All threads resolved 都勾了
[ ] CI/CD Variables 設好（Protected + Masked + environment scope）
[ ] 隔離驗證：功能分支拿不到 DEPLOY_HOST
[ ] 兩個 repo 都設好每日雜湊對帳排程（30 8 * * *，SCHEDULE_TYPE=verify）
[ ] 兩個 repo 都設好每季弱掃排程（0 3 1 */3 *，SCHEDULE_TYPE=quarterly）
[ ] D-Track API Key 申請好、DTRACK_IMAGE 設好
[ ] 首次部署 deploy:production 綠燈
[ ] 部署後 VM4 上的 .env / profiles.yml 還在、權限 600
[ ] 開發人員都裝好本地 hook
```

---

## Phase 5：VM1 — BCP Pipeline
### 5.1 建立 VM4 到 VM1 SSH 免輸入密碼登陸

> 📌 **這條通道跟 Phase 4A 的 `gitlab_runner` 是兩回事，不要搞混、也不要共用金鑰：**
>
> | 通道 | 誰對誰 | 什麼時候用 | 做什麼 |
> |---|---|---|---|
> | 本節（`dagster_user` → `bcp_runner`） | VM4 → VM1 | **執行期**，每次 sensor 觸發 | Dagster 叫 VM1 跑腳本 |
> | Phase 4A（`gitlab_runner` → `gitlab_runner`） | VM3 → VM1 | **部署時**，合併 main 之後 | 把新版腳本 rsync 過去 |
>
> 分開的理由：用途、時機、風險都不同，出事時要能分別停掉其中一條。

先分別建立連線用 user，VM1:
```bash
# 建立被連線端帳號
useradd -m -s /bin/bash bcp_runner

# 設定一組密碼 (等一下 VM4 傳金鑰過來時會用到)
passwd bcp_runner
```

切換到 VM4:
```bash
# 建立跑 Dagster 的帳號
useradd -m -s /bin/bash dagster_user

# 切換成 dagster_user 帳號
su - dagster_user

# 產生 SSH 金鑰，使用 -f 參數精準指定你要的儲存路徑與檔名
ssh-keygen -t rsa -b 4096 -N "" -f /home/dagster_user/.ssh/dagster_to_vm1

# 將「這把特定的公鑰」派發到 VM1 (使用 -i 指定公鑰檔案)
# 這裡會要求你輸入剛剛在 VM1 設定的 bcp_runner 密碼
ssh-copy-id -i /home/dagster_user/.ssh/dagster_to_vm1.pub bcp_runner@<VM1_IP>
```

金鑰派發完成後，請在 VM4 的 dagster_user 帳號下，使用 -i 帶入私鑰來測試連線：

```bash
ssh -i /home/dagster_user/.ssh/dagster_to_vm1 bcp_runner@<VM1_IP>
```
如果沒有跳出密碼提示並成功進入 VM1，就代表設定成功了！

**收緊這把金鑰的權限**（`ssh-copy-id` 只會貼公鑰，不會加任何限制條件）：

```bash
# 在 VM1，以 root，編輯 /home/bcp_runner/.ssh/authorized_keys
# 在剛剛貼進去那一行的最前面補上限制：
#   from="<VM4_IP>",restrict,pty ssh-rsa AAAA... dagster_to_vm1
vim /home/bcp_runner/.ssh/authorized_keys

chmod 600 /home/bcp_runner/.ssh/authorized_keys
chown bcp_runner:bcp_runner /home/bcp_runner/.ssh/authorized_keys
```

限制條件的意義跟 Phase 4A 那張表一樣：`from=` 限來源 IP、`restrict` 關掉各種
forwarding、`pty` 補回互動終端。改完再測一次上面那行 `ssh -i ...` 確認還連得上。

**設完之後把 `bcp_runner` 的密碼關掉**（金鑰已經可以登入，留著密碼只是多一個破口）：
```bash
passwd -l bcp_runner        # 鎖定密碼登入
```

### 5.2 建立 Python 虛擬環境並安裝套件

> Python 3.11 本身在 **Phase 0-3** 就要裝好了，這裡只建 venv 跟裝套件。
> 先確認：`python3.11 --version`

建立虛擬環境
```bash
mkdir -p /run/media/root/D/python_env
python3.11 -m venv /run/media/root/D/python_env/dai_venv
```

啟動虛擬環境
```bash
source /run/media/root/D/python_env/dai_venv/bin/activate
```

離線安裝套件（`--no-index` 確保不會去外網找）
```bash
python -m pip install --no-index \
  --find-links=/run/media/root/D/python_env/req/ \
  /run/media/root/D/python_env/req/*.whl
```

> 啟動 venv 之後用 `python -m pip`，不要用 `pip3.11`。
> 後者有可能指到系統的 pip，套件會裝到 venv 外面去，
> 之後 `pip freeze` 產出的 `requirements.txt` 就跟實際跑的環境對不起來
> （SCA 掃描會因此掃錯環境，見 Phase 4I）。

驗證裝進去的是 venv 而不是系統：
```bash
which python pip                 # 兩個都要在 dai_venv/bin/ 底下
python -m pip list | head
```

依賴名單盤點(版本號以最新為準):
```bash
# pip3.11 list
Package           Version
----------------- -----------
cffi              2.0.0
cryptography      49.0.0
dagster-pipes     1.13.11
et_xmlfile        2.0.0
numpy             2.2.6
openpyxl          3.1.5
packaging         26.2
pandas            2.3.3
pip               22.3.1
pycparser         3.0
pymssql           2.3.11
pyodbc            5.3.0
python-dateutil   2.9.0.post0
python-dotenv     1.2.2
pytz              2026.2
setuptools        65.5.1
six               1.17.0
typing_extensions 4.15.0
tzdata            2026.2
wheel             0.38.4
```


### 5.3 建立 VM 1 連線設定
```bash
# 在 VM1 執行
cd /run/media/root/D/deploy

# 先填入 MS SQL Server 連線資訊
vim .env
# 填入 MSSQL_HOST, MSSQL_DB, MSSQL_USER, MSSQL_PASSWORD

# 執行測試
docker compose run --rm bcp_pipeline

# 預期輸出包含：
# All required packages OK
# Test PASSED
```

> 執行前務必完成 Phase 0-10 的 `workspace/data` 目錄權限設定（UID:GID 1000:1000），否則容器內非 root 使用者無法存取掛載的資料目錄。
>
> ⚠️ `.env` 裡有資料庫密碼，**權限要收到 600**：
> ```bash
> chmod 600 /run/media/root/D/deploy/.env
> ```


### 5.4 填入 VM1 連線資訊
填入以下環境變數
```bash
nano /home/bcp_runner/.env
```
```env
DB_SERVER=<連線資料庫IP>
DB_NAME=<連線資料庫名稱>
DB_USER=<連線資料庫使用者>
DB_PASS=<連線資料庫密碼>


FTP_HOST=<FTP連線IP>
FTP_USER=<FTP使用者>
FTP_PASS=<FTP密碼>


ZIP_PWD_T_TXN_PS=<T_TXN_PS壓縮密碼>
ZIP_PWD_T_TXN_PS_FIRST=<T_TXN_PS_FIRST壓縮密碼>
ZIP_PWD_T_CUST=<T_CUST壓縮密碼>
ZIP_PWD_T_CUST_PS=<T_CUST_PS壓縮密碼>


SOURCE_DB_SERVER=<外部資料庫IP>
SOURCE_DB_USER=<連線資料庫使用者>
SOURCE_DB_PASS=<連線資料庫密碼>
SOURCE_DECRYPT_KEY=<連線資料庫解密金鑰>
```

### 5.5 設定 VM1 加密金鑰
使用以下指令隨機生成具備強度之金鑰，並放入指定環境變數路徑中
```bash
echo "CSV_ENCRYPTION_KEY=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')" >> /home/bcp_runner/.env
```

**填完之後一定要收緊權限並確認擁有者**（這個檔案裡全部都是密碼）：

```bash
chown bcp_runner:bcp_runner /home/bcp_runner/.env
chmod 600 /home/bcp_runner/.env
ls -l /home/bcp_runner/.env      # 應為 -rw------- bcp_runner bcp_runner
```

> ⚠️ **`CSV_ENCRYPTION_KEY` 產生後請另外備份到公司的密碼保管機制。**
> 這把金鑰換掉之後，先前用舊金鑰加密的 CSV 就解不開了。
>
> 📌 `/home/bcp_runner/.env` **不進版控、也不在 rsync 範圍內**
> （部署目標是 `/home/bcp_runner/scripts/`，不含家目錄）。
> 這是刻意的：GitLab 被入侵也拿不到這些帳密。

### 5.6 賦予 bcp_runner 工作目錄權限
未來會以 bcp_runner 執行程式，因賦予它工作目錄使用權限，應確保正常情況 bcp_runner 不被任何人有權操作。
```bash
mkdir -p /run/media/root/D/data
setfacl -R -m u:bcp_runner:rwx /run/media/root/D/data
setfacl -d -m u:bcp_runner:rwx /run/media/root/D/data
```

---

## Phase 6：所有 VM — rsyslog 日誌集中

### 事前準備
要先在每台 VM 上建立 admin group，並把管理員使用者加入這個 group。
```bash
# 創建群組
sudo groupadd dai_admin

# 把使用者 alice 加入 dai_admin group
sudo usermod -aG dai_admin alice
# 確認使用者是否成功加入 dai_admin group
groups alice

```

### 6-1. 設定 journald 轉發（所有 VM 均需執行）

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo bash -c 'cat > /etc/systemd/journald.conf.d/dai_log.conf << EOF
[Journal]
ForwardToSyslog=yes
EOF'
sudo systemctl restart systemd-journald
```

> 此步驟必須先做，否則 `logger` 指令和 systemd 服務的 log 不會進入 rsyslog。

### 6-2. 部署 rsyslog 設定檔

> 📌 **命名一律用 `dai`。**
> 設定檔名、目錄、syslog tag、hash 腳本路徑全部是 `dai/*`、`/var/log/dai`、`/opt/dai`。
> 如果你手上的 `workspace/rsyslog/*.conf`、`workspace/scripts/log_hash.sh`、
> `workspace/logrotate/*` 裡面還留著舊的 `nexflow` 字樣，**要一起改掉**，
> 否則轉發規則會對不上（rsyslog 比對不到就是靜默丟棄，不會報錯）：
> ```bash
> grep -rn "nexflow" ./workspace/rsyslog/ ./workspace/scripts/ ./workspace/logrotate/
> # 有東西的話全部換成 dai 再往下做
> ```

**VM4（集中接收端）：**
```bash
# 在 VM4，已 cd 到部署根目錄 /data/deploy

# 建立 log 儲存目錄
sudo mkdir -p /data/log/dai
sudo chown root:dai_admin /data/log/dai
sudo chmod 750 /data/log/dai

sudo mkdir -p /data/log/dai-integrity
sudo chown root:dai_admin /data/log/dai-integrity
sudo chmod 750 /data/log/dai-integrity

# 部署設定
sudo cp ./workspace/rsyslog/vm4-server.conf \
  /etc/rsyslog.d/10-dai-server.conf
sudo cp ./workspace/rsyslog/vm4-integrity-forward.conf \
  /etc/rsyslog.d/25-dai-integrity-fwd.conf

# 驗證語法後重啟
sudo rsyslogd -N1 && sudo systemctl restart rsyslog
```

**VM1 / VM3 / VM5（轉發端）：**
```bash
# 如果本地 log 路徑不是在 /var/log 底下，需要建立 Bind Mount 綁訂到 /var/log
# 因為 SELinux 會擋不是 /var/log 路徑的 rsyslog 存取
# 這邊舉例真實 log 路徑是 /run/media/root/D/log/dai
# 要綁訂到 /var/log/dai
mkdir -p /run/media/root/D/log/dai /var/log/dai
mount --bind /run/media/root/D/log/dai /var/log/dai
# 綁定之後下這條指令，系統就會對這個路徑貼上合法的 log 標籤
restorecon -Rv /var/log/dai

# 複製設定並替換 VM4 IP（若需要）
sudo cp ./workspace/rsyslog/dai-client.conf \
  /etc/rsyslog.d/20-dai-client.conf
sudo sed -i "s/10.28.155.40/<VM4實際IP>/g" /etc/rsyslog.d/20-dai-client.conf

sudo rsyslogd -N1 && sudo systemctl restart rsyslog
```

> ⚠️ **`mount --bind` 重開機後會消失。** 要寫進 `/etc/fstab` 才會自動掛回來：
> ```bash
> echo "/run/media/root/D/log/dai /var/log/dai none bind 0 0" >> /etc/fstab
> mount -a && findmnt /var/log/dai      # 確認掛得起來
> ```
> 沒做這一步的話，重開機後 log 會寫到本機磁碟的 `/var/log/dai`，
> 而且**不會有任何錯誤訊息**，直到磁碟滿了才會發現。

**VM3 額外（GitLab log 檔案監控）：**
```bash
# 同樣需要綁定 log 位置到 /var/log 底下
# 這邊的路徑就是看 $GITLAB_HOME 的位置
mkdir -p /var/log/gitlab
mount --bind ${GITLAB_HOME}/logs /var/log/gitlab
restorecon -Rv /var/log/gitlab

sudo cp ./workspace/rsyslog/vm3-gitlab-imfile.conf \
  /etc/rsyslog.d/30-dai-gitlab-imfile.conf
sudo systemctl restart rsyslog
```

**VM1 額外（接收 hash manifest）：**

VM4 每天算完 log 雜湊之後，會把 manifest 轉發一份到 VM1 存放
（**存兩台**：VM4 上的紀錄如果被動過，VM1 上還有一份可以比對）。

```bash
# 在 VM1
sudo mkdir -p /var/log/dai-integrity
sudo chown root:dai_admin /var/log/dai-integrity
sudo chmod 750 /var/log/dai-integrity

sudo cp /run/media/root/D/deploy/workspace/rsyslog/vm1-integrity-server.conf \
  /etc/rsyslog.d/10-dai-integrity-server.conf
sudo rsyslogd -N1 && sudo systemctl restart rsyslog
```

> VM1 這一段**不需要**綁定 `/var/log/gitlab`——GitLab 不在 VM1 上。
> 它只是收 VM4 轉發過來的 manifest。
> 防火牆要開 `VM4 → VM1:514`（或設定檔裡實際用的 port）。

### 6-3. 部署每日 hash 腳本（VM4）

```bash
# 在 VM4，已 cd 到部署根目錄
sudo mkdir -p /opt/dai/scripts
sudo cp ./workspace/scripts/log_hash.sh /opt/dai/scripts/
sudo chmod 755 /opt/dai/scripts/log_hash.sh

sudo mkdir -p /var/log/dai-integrity

# 設定 cron（每天 23:55 執行）
sudo bash -c 'echo "55 23 * * * root /opt/dai/scripts/log_hash.sh \
  >> /var/log/dai-integrity/hash_cron.log 2>&1" \
  > /etc/cron.d/dai-hash'
sudo chmod 644 /etc/cron.d/dai-hash
```

**先手動跑一次確認會動**（不要等到隔天才發現 cron 是壞的）：
```bash
sudo /opt/dai/scripts/log_hash.sh && ls -l /var/log/dai-integrity/
```

### 6-4. 部署 logrotate（VM4）

```bash
sudo cp ./workspace/logrotate/dai /etc/logrotate.d/dai

# 驗證設定檔語法（-d 是 dry-run，不會真的輪替）
sudo logrotate -d /etc/logrotate.d/dai
```

### 6-5. 驗證跨 VM log 流向

```bash
# 在 VM3 送測試訊息
logger -t 'dai/verify-vm3' 'CROSS_VM_TEST'

# 在 VM4 確認是否收到（等 3 秒）
sleep 3
sudo find /data/log/dai/vm3-*/ -name '*.log' -exec sudo tail -1 {} \;
# 應輸出：DAI|<時間>|vm3|verify-vm3|NOTICE|CROSS_VM_TEST
```

**四台都要各測一次**（VM1 / VM3 / VM5 送、VM4 收；VM4 自己也送一次）：
```bash
# 在每一台上分別執行，<vmX> 換成該台代號
logger -t 'dai/verify-<vmX>' 'CROSS_VM_TEST'
```

收不到的排查順序：
1. `systemctl status rsyslog` 兩端都在跑嗎
2. `rsyslogd -N1` 設定檔語法過嗎
3. 防火牆 `<來源VM> → VM4:514` 開了嗎
4. `journalctl -u rsyslog -n 50` 有沒有寫不進目錄的錯誤（多半是 SELinux 或目錄權限）

---

## RHEL 正式環境補充設定

### SELinux（VM4 執行）
```bash
sudo semanage fcontext -a -t var_log_t "/data/log/dai(/.*)?"
sudo restorecon -Rv /data/log/dai/
```

> `semanage` 來自 `policycoreutils-python-utils`（Phase 0-3 已安裝）。
> 轉發端（VM1 / VM3 / VM5）的 log 目錄是用 `mount --bind` 掛到 `/var/log/` 底下的，
> 已經在 6-2 用 `restorecon` 貼過標籤，不需要再 `semanage`。

### firewalld（各 VM 對應開通）
> 完整跨 VM 防火牆規則（含來源/目的地 IP 對照表，已包含 Container Registry 5050 port 與 LDAP/DNS egress 規則）見 Redmine `DAI 跨 VM 防火牆開通及 DNS 申請`。

---

## 各服務健康檢查端點

| 服務 | URL | 預期回應 |
|------|-----|---------|
| GitLab | `https://gitlab.dai.post.gov.tw/users/sign_in` | `200`（登入頁） |
| Container Registry | `https://gitlab.dai.post.gov.tw:5050/v2/` | `401`（未認證，代表 vhost 正常） |
| dtrack API | `https://dtrack.dai.post.gov.tw/api/version` | JSON 含 `version` |
| dtrack OIDC | `https://dtrack.dai.post.gov.tw/api/v1/oidc/available` | `true` |
| Keycloak | `https://auth.dai.post.gov.tw/health/ready` | `{"status":"UP"}` |
| Dagster | `https://dagster.dai.post.gov.tw` | 302 跳轉至 Keycloak 登入 |
| Superset | `https://superset.dai.post.gov.tw` | 302 跳轉至 Keycloak 登入 |
| nginx VM3 | `https://gitlab.dai.post.gov.tw/healthz` | `ok` |
| nginx VM5 | `https://auth.dai.post.gov.tw/healthz` | `ok` |
| infra-db | `docker exec infra-db pg_isready -U $INFRA_DB_USER` | `accepting connections` |

---

## 已知 Image / Compose 修正（已內建，部署時不需要再處理，僅供了解原因）

下列問題已在 `dockerfile/` 與 `docker-compose/*_secure.yml` 中修正，若日後升級 image 版本或重新調整 secure compose，建議留意同樣的坑：

| 問題 | 根因 | 修正位置 |
|------|------|---------|
| Keycloak 啟動 `does not exist`（jackson-databind / opentelemetry-api） | CVE 修補時用 `rm -f` 刪除舊版 jar，但 Quarkus 預編譯 classpath manifest 仍引用舊檔名 | `Dockerfile.keycloak`：改用 `ln -sf` 保留舊檔名 |
| Keycloak `read_only` 環境下啟動失敗（`transformed-bytecode.jar: Read-only file system`） | jar 變動後 classpath 指紋改變，runtime 自動觸發 rebuild 但無寫入權限 | `Dockerfile.keycloak`：image build 階段預先執行 `kc.sh build --db=postgres --health-enabled=true --log-mdc-enabled=true`（build-time flag 須與 runtime 環境變數一致） |
| Dagster 容器 `mkdir: Permission denied` | UID 10001 對 host 掛載目錄無寫入權限 | 需手動 `chown -R 10001:10001`（見 Phase 0-9，無法烘焙進 image，需在部署時執行） |
| Dagster telemetry `Read-only file system` / `Permission denied` | `DAGSTER_DISABLE_TELEMETRY=1` 不完全生效，仍嘗試寫 `$HOME/.dagster` | VM4 compose：`tmpfs` 加 `/home/dagster:uid=10001,gid=10001` |
| GitLab Registry vhost `nginx [emerg] cannot load certificate` | `registry_external_url` 用 `https://` 觸發 omnibus 內建 TLS，預期憑證不存在 | VM3 compose：`registry_nginx['listen_https'] = false` |
| dagster-login 服務遺失 | secure compose 整理時遺漏（註解寫了「沿用原設定」卻沒搬過去） | 已補回 VM4 compose |
| dagster-code/webserver/daemon 重開機後不會自動回來 | 缺少 `restart: unless-stopped` | 已補回 VM4 compose |

---

## 常見問題排查

| 症狀 | 原因 | 解法 |
|------|------|------|
| GitLab SSO：`certificate verify failed` | GitLab Ruby 不信任自簽 CA | 將 `certs/GRCA3.crt` 複製到 `${GITLAB_HOME}/config/trusted-certs/`，執行 `gitlab-ctl reconfigure`（見 Phase 3-2） |
| dtrack OIDC available 回傳 `false` | JVM TrustStore 缺少自簽 CA | 確認映像版本為 `dai/dt_apiserver:v2.1` 以上；或手動 `keytool -import -cacerts` 後重啟（見 Phase 3-4） |
| VM4 收不到其他 VM rsyslog | `dirOwner="root"` 導致 chown 失敗 | 確認 `vm4-server.conf` 中 `dirOwner="syslog"`，不是 `root` |
| rsyslog 規則沒有觸發（NO MATCH） | 用了 `$programname`（只取 `/` 前的部分） | 改用 `$syslogtag contains "dai/"`；regex 用 `([a-zA-Z0-9_-]+)` |
| Dagster 容器 `Permission denied` 無法啟動 | host 掛載目錄擁有者不是 UID 10001 | 執行 Phase 0-9 的 `chown -R 10001:10001` |
| superset-init 報錯 `User already exists` | admin 帳號已建立（第二次初始化） | 正常現象，compose 裡有 `|| true` 處理，superset 服務可正常啟動 |
| GitLab `/users/sign_in` 持續 502，container healthcheck 卻顯示 healthy | Puma 仍在 `Preloading application`，container-level healthcheck（`/healthz`）跟 Rails app 是否真的能服務是兩回事；VM 規格不足時 Puma 會反覆卡住甚至被 OOM 影響 | 確認 VM3 記憶體足夠（GitLab + Registry + D-Track + 兩個 Runner 同機，8GB 會很吃緊）；用 `docker exec gitlab tail -f /var/log/gitlab/puma/current` 確認是否卡在同一行超過 2-3 分鐘 |
| `dtrack-server` 一直 unhealthy | API server 啟動慢 | healthcheck `start_period=120s`，等足時間；`docker logs dtrack-server` 確認有無 exception |
| GitLab Runner 無法連線 GitLab | Runner 不信任自簽 TLS | 確認 `workspace/gitlab-runner-{ci,cd}/certs/gitlab.dai.post.gov.tw.crt` 存在（內容為 `certs/fullchain_202606.crt`，見 Phase 3-5） |
| Registry `docker login` 失敗 `connection refused` | port 5050 未開通，或 nginx-vm3 沒有監聽 5050 | 確認 VM3 compose 的 nginx 服務有 `ports: - "5050:5050"`；確認防火牆已開通 5050 |
| Keycloak 無法連線 LDAP server（DNS 解析失敗） | `dns:` 設定的公司 DNS IP 不正確，或公司 LDAP 主機名稱不在該 DNS 區域內 | `docker exec keycloak getent hosts <LDAP主機名稱>` 確認解析結果；必要時改用 LDAP server 的 IP 字面值取代主機名稱 |
| multipass/SSH 連線逾時、`docker exec` 卡住 | Host 記憶體不足導致 VM 整體緩慢（GitLab 是最吃資源的服務） | 確認 VM3 規格足夠，正式環境若用實體/虛擬機通常不會有此問題，純測試環境（如 multipass）需注意 host 總資源是否超賣 |
| Superset SQL Lab 新增外部資料庫連線時主機名稱解析逾時 | `dns:` 限定的公司 DNS（10.10.43.1/.2）連不到，或該主機名稱不在公司 DNS 區域內 | `docker exec superset getent hosts <DB主機名稱>` 確認解析結果；測試環境（如 multipass）若連不到公司網段屬預期，需在正式環境驗證 |
| `docker exec superset ps aux` 顯示 `executable file not found` | Debian Trixie slim 極簡安裝，映像內沒有 `ps` 指令 | 改用 `docker exec superset sh -c "cat /proc/<pid>/cmdline"` 或直接讀 `/proc/[0-9]*/cmdline` 確認程序狀態 |
