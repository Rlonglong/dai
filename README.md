---
title: 部署手冊
---

# DAI 部署流程文件

> **目標**：從零開始，在四台 VM 上完整部署 DAI 平台（採用 security-hardened 版本的 image 與 compose 設定）
>
> **重要**：本文件一律使用 `*_secure.yml` compose 檔案（非 `docker-compose_vmX.yml` 原始版本）。`_secure.yml` 是資安弱點圍堵後的版本，包含 `read_only` root filesystem、`cap_drop: ALL`、`seccomp`、非 root 使用者等強化設定，細節見 `secure_report/` 目錄。

---

## VM 角色與 IP 對照

| VM | 角色 | 正式部署時更新 |
|----|------|--------------|
| VM1 | BCP Pipeline（SQL Server 資料搬移）| 更新 `env/vm1.env` |
| VM3 | GitLab + Container Registry + Dependency-Track + Nginx | 更新 `env/vm3.env` |
| VM4 | infra-db (PostgreSQL) + Dagster + GitLab Runner CD | 更新 `env/vm4.env` |
| VM5 | Keycloak（含 LDAP 聯邦）+ Nginx + Superset | 更新 `env/vm5.env` |

---

## 部署順序總覽

```
[Phase 0] 所有 VM 基礎準備（Docker、檔案、IP、hosts、TLS、VM 規格）
[Phase 1] VM4：啟動 infra-db（PostgreSQL 必須最先啟動）
[Phase 2] VM5：啟動 Keycloak
          └─ 2A: 建立 Keycloak Clients（dagster / superset / gitlab / dependency-track）
          └─ 2B: 設定 LDAP User Federation（串接公司 LDAP）
          └─ 2C: 啟動 nginx、kc_access、superset
[Phase 3] VM3：啟動 GitLab + dtrack + Container Registry
          └─ 3A: GitLab 初始化 CA 憑證 + OIDC 設定
          └─ 3B: dtrack admin 密碼 + OIDC 設定
          └─ 3C: 註冊 GitLab Runner CI
          └─ 3D: 驗證 Container Registry（與 GitLab 共用 domain，port 5050）
[Phase 4] VM4：註冊 GitLab Runner CD
[Phase 5] VM1：啟動 BCP Pipeline
[Phase 6] 所有 VM：部署 rsyslog 日誌集中轉發
```

## 提供檔案
```
deploy_package_vm1.tar.gz
deploy_package_vm3.tar.gz
deploy_package_vm4.tar.gz
deploy_package_vm5.tar.gz
```

---


## Phase 0：所有 VM 基礎準備

### 0-1. 安裝 Docker
請先將安裝檔傳入正式環境，以進行離線安裝，確定以下四種檔案（請自行帶入欲安裝的版本號）已在正式環境。
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
```
應該看到版本號，如 `Docker version 29.6.1, build 8900f1d`.

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

### 0-3. 傳送部署包至各 VM

```bash
# 傳送 deploy package 至各 VM（以 VM3 為例，其他 VM 同樣步驟）
scp deploy_package_vm3.tar.gz rhel@vm3:/deploy_package

# 在 VM 解壓縮 deploy package
```

### 0-4. 更新各 VM 的 IP 設定

**可以用指令或是 vim/nano 直接進去改**\
**每台 VM 上，將 env 檔裡的 IP 換成正式環境實際 IP：**
```bash
# VM3 上執行 (/run/media/root/D/deploy)
sed -i "s/VM3_IP=.*/VM3_IP=<VM3實際IP>/" ./env/vm3.env
sed -i "s/VM4_IP=.*/VM4_IP=<VM4實際IP>/" ./env/vm3.env
sed -i "s/VM5_IP=.*/VM5_IP=<VM5實際IP>/" ./env/vm3.env

# VM4 上執行（/data/deploy）
sed -i "s/VM3_IP=.*/VM3_IP=<VM3實際IP>/" ./env/vm4.env
sed -i "s/VM4_IP=.*/VM4_IP=<VM4實際IP>/" ./env/vm4.env
sed -i "s/VM5_IP=.*/VM5_IP=<VM5實際IP>/" ./env/vm4.env

# VM5 上執行 (/run/media/root/D/deploy)
sed -i "s/VM3_IP=.*/VM3_IP=<VM3實際IP>/" ./env/vm5.env
sed -i "s/VM4_IP=.*/VM4_IP=<VM4實際IP>/" ./env/vm5.env
sed -i "s/VM5_IP=.*/VM5_IP=<VM5實際IP>/" ./env/vm5.env
```

<!-- ### 0-5. 設定 /etc/hosts（測試環境）或申請 DNS（正式環境）

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

### 0-6. 準備 TLS 憑證

憑證放在：
```
deploy/certs/
  GRCA3.crt               # CA 根憑證
  dai_202606.crt         # Domain 憑證
  fullchain_202606.crt    # 憑證鏈（cat dai_202606.crt GCA3.crt GRCA3.crt > fullchain_202606.crt）
  dai_202606.key    # 私鑰
```
憑證準備好之後，要把 GRCA.crt 放在 VM 的信任清單裡面
```
cp GRCA3.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust extract
systemctl restart docker
```

> CA 根憑證，後續須將 `GRCA3.crt` 匯入 GitLab 和 dtrack 容器的 trust store（Phase 3 說明）。

### 0-7. Dagster 工作目錄權限（VM4）

`dai/dagster:v2.7` 明確以 **UID 10001**（非 root）執行，且 root filesystem 為 `read_only: true`。Host 端掛載給 Dagster 的目錄必須讓 UID 10001 可寫，否則容器會在啟動時出現 `Permission denied`：

```bash
# 在 VM4 執行
sudo chown -R 10001:10001 <dagster_workspace> # 見 vm4.env
```

### 0-8. BCP Pipeline 資料目錄權限（VM1）

`dai/bcp_pipeline` 在 secure compose 中明確以 **UID:GID 1000:1000** 執行，需確保 `workspace/data` 目錄擁有者一致：

```bash
# 在 VM1 執行
sudo chown -R 1000:1000 ~/deploy/workspace/data
```

### 0.9 初始設定檔權限

```bash
chmod 644 ./workspace/superset_config.py
chmod 644 ./workspace/custom_sso_security_manager.py
```

## Phase 1：VM4 — PostgreSQL + Dagster

```bash
# 在 VM4 執行
cd ./docker-compose

# 步驟 1：啟動 infra-db（PostgreSQL）
docker compose -f docker-compose_vm4_secure.yml --env-file ../env/vm4.env up -d infra-db

# 步驟 2：等待 infra-db healthy（約 20 秒）
watch -n 2 "docker compose -f docker-compose_vm4_secure.yml --env-file ../env/vm4.env ps infra-db"
# 確認出現 (healthy) 後按 Ctrl+C

# 步驟 3：啟動其餘 VM4 服務
docker compose -f docker-compose_vm4_secure.yml --env-file ../env/vm4.env \
  up -d dagster-login dagster-code dagster-webserver dagster-daemon gitlab-runner-cd
```

**注意事項：**
- `infra-db` 首次啟動時執行 `workspace/init-infra-db.sql`，會建立所有資料庫（keycloak、dtrack、superset、dagster、keycloak_access_db）。確保此 SQL 檔在啟動前已存在於正確路徑。
- `dagster-code` 必須先 healthy，`dagster-webserver` 和 `dagster-daemon` 才能啟動（compose 已設定 `depends_on` 健康依賴）。
- `dagster-login`（OAuth2 Proxy，Dagster SSO 對外邊界）會持續重試連線 Keycloak，直到 Phase 2 的 Keycloak 啟動後才會轉為正常狀態，屬預期行為，不需要特別處理。
- `gitlab-runner-cd` 此時容器啟動但尚未註冊，等 GitLab 在 Phase 3 啟動後再於 Phase 4 完成註冊。
- PostgreSQL 對外 Port 是 `5433`（非預設 5432），參數來自 `INFRA_DB_PORT=5433`。
- 務必先完成 Phase 0-6 的目錄權限設定，否則 `dagster-code` / `dagster-webserver` / `dagster-daemon` 會因為 `Permission denied` 啟動失敗。

---

## Phase 2：VM5 — Keycloak + Nginx + Superset

### 2-1. 啟動 Keycloak

```bash
# 在 VM5 執行
cd ./docker-compose

docker compose -f docker-compose_vm5_secure.yml --env-file ../env/vm5.env up -d keycloak

# 等待 healthy（約 30~60 秒）
watch -n 3 "docker compose -f docker-compose_vm5_secure.yml --env-file ../env/vm5.env ps keycloak"
# 出現 (healthy) 後按 Ctrl+C
```

> **DNS 設定說明**：Keycloak 容器的 `dns:` 指向公司 DNS 伺服器（`10.10.43.1` / `10.10.43.2`，見 `docker-compose_vm5_secure.yml`），不是泛用的任意 DNS。這是為了讓 Keycloak 能解析公司內部主機名稱（例如 LDAP server），同時仍維持「明確釘選固定清單」的圍堵原則（CVE-2026-5435 / CVE-2026-6238 glibc DNS/TSIG 弱點圍堵措施的一部分）。若公司 DNS 伺服器 IP 不是 `10.10.43.1` / `10.10.43.2`，請在部署前修改此檔。

### 2-2. 建立 Keycloak Realm 及 Clients
這一步要建立其他元件透過 `keycloak` 登入時的設定，可以採用下方打 API 的方式或是進入 `keycloak` 網頁手動設定。
建立清單：
1. Realm: 建立 DAI 專用的 Realm，可以想成就是開一個新的專案用來管理 DAI 底下的系統。
2. Clients: 每個元件要連線到 `keycloak` 就需要在 `keycloak` 有一個對應的 `client`。所以會需要建立 `gitlab`, `superset`, `dagster`, `dependency-track` 這三個，詳細建立方式參考 `keycloak_management.md`。
> Realm 名稱：`postoffice`
> Admin 帳號：`admin`，密碼：見 `env/vm5.env` 中 `KEYCLOAK_ADMIN_PASSWORD`

```bash
# 在 VM5 執行，取得 Admin Token
KC_PASS=$(grep KEYCLOAK_ADMIN_PASSWORD ~/deploy_test/env/vm5.env | cut -d= -f2)
KC_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

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
  "secret":"PQGOjCiQ9lNIy46PRoqgsjEU1b2MVcYD","standardFlowEnabled":true,
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
# 在 VM5 執行：確認 Keycloak 容器能解析 LDAP 主機名稱
docker exec keycloak getent hosts 10.10.20.101:389
```

### 2-4. 啟動其餘 VM5 服務

```bash
docker compose -f docker-compose_vm5_secure.yml --env-file ../env/vm5.env up -d nginx kc_access

# superset 初始化（只需執行一次）
docker compose -f docker-compose_vm5_secure.yml --env-file ../env/vm5.env run --rm superset-init
# 等 superset-init 正常結束後（exit code 0），再啟動主服務
docker compose -f docker-compose_vm5_secure.yml --env-file ../env/vm5.env up -d superset
```

**注意事項：**
- VM5 nginx 的 `dagster.dai.post.gov.tw` 反向代理設定指向 VM4:4180，需要 VM4 的 `dagster-login` 先在線上（Phase 1 已完成）。
- `superset-init` 是一次性初始化容器，完成後自動退出，再啟動 `superset`。第二次執行 init 時若 admin 帳號已存在會顯示錯誤但不影響結果（有 `|| true` 處理）。
---

## Phase 3：VM3 — GitLab + Container Registry + Dependency-Track

### 3-1. 建立目錄並啟動服務

```bash
# 在 VM3 執行
sudo mkdir -p ${GITLAB_HOME} # 參考 ./env/vm3.env

cd ./docker-compose

# 先啟動 nginx 和 dtrack（不依賴 GitLab）
docker compose -f docker-compose_vm3_secure.yml --env-file ../env/vm3.env up -d nginx dtrack-server

# 等 dtrack-server healthy（約 120 秒）
watch -n 5 "docker compose -f docker-compose_vm3_secure.yml --env-file ../env/vm3.env ps dtrack-server"

# dtrack-server healthy 後啟動 frontend
docker compose -f docker-compose_vm3_secure.yml --env-file ../env/vm3.env up -d dtrack-frontend

# 啟動 GitLab（初始化約 3~5 分鐘，視 VM 規格而定）
docker compose -f docker-compose_vm3_secure.yml --env-file ../env/vm3.env up -d gitlab
```

**等待 GitLab 完成初始化：**
```bash
docker logs -f gitlab 2>&1 | grep -m1 "Reconfigured!"
# 出現 "gitlab Reconfigured!" 才表示完成
# 健康檢查需另外確認（見下方），Reconfigured 完成後 Puma 仍需數十秒到數分鐘
# preload 才會真正可服務，VM 規格不足時可能反覆卡在 preload（見 Phase 0 VM 規格表）
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
# 在 VM3 執行
sudo cp ../certs/GRCA3.crt \
  ${GITLAB_HOME}/config/trusted-certs/dai-ca.crt

docker exec gitlab gitlab-ctl reconfigure
# 約需 2 分鐘，完成後 GitLab 服務會自動重啟
```

### 3-3. GitLab — 設定 Keycloak OIDC SSO (可跳過)

這步已經寫在 `docker-compose_vm3_secure.yml` 底下了，可以不執行。
```bash
# 在 VM3 執行：寫入 OIDC 設定到 gitlab.rb
cat >> /srv/gitlab/config/gitlab.rb << 'EOF'

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

> 此設定已內建在 `docker-compose_vm3_secure.yml` 的 `GITLAB_OMNIBUS_CONFIG` 中（含 OIDC），通常不需要手動執行本步驟；僅在手動調整 OIDC 設定時才需要重新 `gitlab-ctl reconfigure`。

### 3-4. dtrack — 修改 Admin 密碼並啟用 OIDC

**修改密碼（建議透過 UI 操作）：**
1. 登入 `https://dtrack.dai.post.gov.tw`（預設帳號：`admin` / `admin`）
2. Administration > Access Management > Change Password

> **重要**：dtrack 映像必須是 `dai/dt_apiserver:v2.1`以上，此版本在建置時已將自簽 CA 匯入 JVM TrustStore（`keytool -import -cacerts`）。若使用其他版本映像，須手動匯入：
> ```bash
> docker cp ./certs/GRCA3.crt dtrack-server:/tmp/GRCA3.crt
> docker exec dtrack-server bash -c \
>   "keytool -import -trustcacerts -cacerts -storepass changeit -noprompt \
>    -alias dai-ca -file /tmp/GRCA3.crt"
> docker restart dtrack-server
> ```
> 建議後續版本如果沒有重大改動，直接採用原本的 Dockerfile.dt_apiserver 進行編譯。
### 3-5. 啟動並註冊 GitLab Runner CI

```bash
# 在 VM3 執行
cd ./certs
# 建立一個名為 gitlab.dai.post.gov.tw.crt 的連結，指向你的完整證書鏈
ln -s fullcert_202606.crt gitlab.dai.post.gov.tw.crt

cd ..
docker compose -f docker-compose_vm3_secure.yml --env-file ../env/vm3.env up -d gitlab-runner-ci

# 在 GitLab UI：Admin Area > CI/CD > Runners > New instance runner
# 複製 Token 後執行 register：
docker exec gitlab-runner-ci gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.dai.post.gov.tw" \
  --token "<從GitLab取得的Token>" \
  --executor "shell" \
  --description "vm3-ci-runner" \
  --tag-list "vm3,ci"
```

> Runner 的 CA 憑證已預先放在 `workspace/gitlab-runner-ci/certs/gitlab.dai.post.gov.tw.crt`，register 時能信任自簽 GitLab TLS 憑證。

### 3-6. 驗證 Container Registry（與 GitLab 共用 domain）

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

## Phase 4：VM4 — 註冊 GitLab Runner CD

```bash
# 在 VM4 執行
cd ./certs
# 建立一個名為 gitlab.dai.post.gov.tw.crt 的連結，指向你的完整證書鏈
ln -s fullcert_202606.crt gitlab.dai.post.gov.tw.crt

# 在 GitLab UI 另外取得一組 Runner Token（建議獨立的 CD runner）
cd ..
docker exec gitlab-runner-cd gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.dai.post.gov.tw" \
  --token "<CD Runner Token>" \
  --executor "shell" \
  --description "vm4-cd-runner" \
  --tag-list "vm4,cd,deploy"
```

> CD Runner 掛載 `/var/run/docker.sock`，可在 CI/CD pipeline 中執行 `docker compose up` 完成自動部署。


---

## Phase 5：VM1 — BCP Pipeline
### 5.1 建立 VM4 到 VM1 SSH 免輸入密碼登陸
先跟別建立連線用 user，VM1:
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

### 5.2 安裝 python 所需套件
建立名為 myenv 的虛擬環境
```bash
python3.11 -m venv /run/media/root/D/python_env/dai_venv
```

啟動虛擬環境
```bash
source /run/media/root/D/python_env/dai_venv/bin/activate
```

確保 pip 套件相依性不會去外網找
```
pip3.11 install --no-index --find-links=/run/media/root/D/python_env/req/ /run/media/root/D/python_env/req/*.whl
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
# 先填入 MS SQL Server 連線資訊
vim ~/deploy/env/vm1.env
# 填入 MSSQL_HOST, MSSQL_DB, MSSQL_USER, MSSQL_PASSWORD

# 執行測試
cd ~/deploy/docker-compose
docker compose -f docker-compose_vm1_secure.yml --env-file ../env/vm1.env run --rm bcp_pipeline

# 預期輸出包含：
# All required packages OK
# Test PASSED
```

> 執行前務必完成 Phase 0-7 的 `workspace/data` 目錄權限設定（UID:GID 1000:1000），否則容器內非 root 使用者無法存取掛載的資料目錄。


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

**VM4（集中接收端）：**
```bash
# 建立 log 儲存目錄
sudo mkdir -p /data/log/dai
sudo chown root:dai_admin /data/log/dai
sudo chmod 750 /data/log/dai

sudo mkdir -p /data/log/dai-integrity
sudo chown root:dai_admin /data/log/dai
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
mount --bind /run/media/root/D/log/dai /var/log/dai
# 綁定之後下這條指令，系統就會對這個路徑貼上合法的 log 標籤
restorecon -Rv /var/log/dai

# 複製設定並替換 VM4 IP（若需要）
sudo cp ./workspace/rsyslog/dai-client.conf \
  /etc/rsyslog.d/20-dai-client.conf
sudo sed -i "s/10.28.155.40/<VM4實際IP>/g" /etc/rsyslog.d/20-nexflow-client.conf

sudo rsyslogd -N1 && sudo systemctl restart rsyslog
```

**VM3 額外（GitLab log 檔案監控）：**
```bash
# 同樣需要綁定 log 位置到 /var/log 底下
# 這邊的路徑就是看 $GITLAB_HOME 的位置
mount --bind /run/media/root/D/deploy/workspace/gitlab_workspace/logs /var/log/gitlab
restorecon -Rv /var/log/gitlab

sudo cp ./workspace/rsyslog/vm3-gitlab-imfile.conf \
  /etc/rsyslog.d/30-nexflow-gitlab-imfile.conf
sudo systemctl restart rsyslog
```

**VM1（接收 hash manifest）：**
```bash
# 同樣需要綁定 log 位置到 /var/log 底下
# 這邊的路徑就是看 $GITLAB_HOME 的位置
mount --bind /run/media/root/D/deploy/workspace/gitlab_workspace/logs /var/log/gitlab
restorecon -Rv /var/log/gitlab
sudo mkdir -p /var/log/nexflow-integrity
sudo chmod 750 /var/log/nexflow-integrity
sudo cp ~/deploy_test/workspace/rsyslog/vm1-integrity-server.conf \
  /etc/rsyslog.d/10-nexflow-integrity-server.conf
sudo systemctl restart rsyslog
```

### 6-3. 部署每日 hash 腳本（VM4）

```bash
sudo mkdir -p /opt/nexflow/scripts
sudo cp ~/deploy_test/workspace/scripts/log_hash.sh /opt/nexflow/scripts/
sudo chmod +x /opt/nexflow/scripts/log_hash.sh

# 設定 cron（每天 23:55 執行）
sudo bash -c 'echo "55 23 * * * root /opt/nexflow/scripts/log_hash.sh \
  >> /var/log/nexflow-integrity/hash_cron.log 2>&1" \
  > /etc/cron.d/nexflow-hash'
```

### 6-4. 部署 logrotate（VM4）

```bash
sudo cp ~/deploy_test/workspace/logrotate/nexflow /etc/logrotate.d/nexflow
```

### 6-5. 驗證跨 VM log 流向

```bash
# 在 VM3 送測試訊息
logger -t 'nexflow/verify-vm3' 'CROSS_VM_TEST'

# 在 VM4 確認是否收到（等 3 秒）
sleep 3
sudo find /var/log/nexflow/vm3-*/ -name '*.log' -exec sudo tail -1 {} \;
# 應輸出：NEXFLOW|<時間>|vm3-test|verify-vm3|NOTICE|CROSS_VM_TEST
```

---

## RHEL 正式環境補充設定

### SELinux（VM4 執行）
```bash
sudo semanage fcontext -a -t var_log_t "/var/log/nexflow(/.*)?"
sudo restorecon -Rv /var/log/nexflow/
```

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
| infra-db | `docker exec infra-db pg_isready -U segora_admin` | `accepting connections` |

---

## 已知 Image / Compose 修正（已內建，部署時不需要再處理，僅供了解原因）

下列問題已在 `dockerfile/` 與 `docker-compose/*_secure.yml` 中修正，若日後升級 image 版本或重新調整 secure compose，建議留意同樣的坑：

| 問題 | 根因 | 修正位置 |
|------|------|---------|
| Keycloak 啟動 `does not exist`（jackson-databind / opentelemetry-api） | CVE 修補時用 `rm -f` 刪除舊版 jar，但 Quarkus 預編譯 classpath manifest 仍引用舊檔名 | `Dockerfile.keycloak`：改用 `ln -sf` 保留舊檔名 |
| Keycloak `read_only` 環境下啟動失敗（`transformed-bytecode.jar: Read-only file system`） | jar 變動後 classpath 指紋改變，runtime 自動觸發 rebuild 但無寫入權限 | `Dockerfile.keycloak`：image build 階段預先執行 `kc.sh build --db=postgres --health-enabled=true --log-mdc-enabled=true`（build-time flag 須與 runtime 環境變數一致） |
| Dagster 容器 `mkdir: Permission denied` | UID 10001 對 host 掛載目錄無寫入權限 | 需手動 `chown -R 10001:10001`（見 Phase 0-6，無法烘焙進 image，需在部署時執行） |
| Dagster telemetry `Read-only file system` / `Permission denied` | `DAGSTER_DISABLE_TELEMETRY=1` 不完全生效，仍嘗試寫 `$HOME/.dagster` | `docker-compose_vm4_secure.yml`：`tmpfs` 加 `/home/dagster:uid=10001,gid=10001` |
| GitLab Registry vhost `nginx [emerg] cannot load certificate` | `registry_external_url` 用 `https://` 觸發 omnibus 內建 TLS，預期憑證不存在 | `docker-compose_vm3_secure.yml`：`registry_nginx['listen_https'] = false` |
| dagster-login 服務遺失 | secure compose 整理時遺漏（註解寫了「沿用原設定」卻沒搬過去） | 已補回 `docker-compose_vm4_secure.yml` |
| dagster-code/webserver/daemon 重開機後不會自動回來 | 缺少 `restart: unless-stopped` | 已補回 `docker-compose_vm4_secure.yml` |

---

## 常見問題排查

| 症狀 | 原因 | 解法 |
|------|------|------|
| GitLab SSO：`certificate verify failed` | GitLab Ruby 不信任自簽 CA | 將 `ca.crt` 複製到 `/srv/gitlab/config/trusted-certs/`，執行 `gitlab-ctl reconfigure` |
| dtrack OIDC available 回傳 `false` | JVM TrustStore 缺少自簽 CA | 確認映像版本為 `dai/dt_apiserver:v2.0`；或手動 `keytool -import -cacerts` 後重啟 |
| VM4 收不到其他 VM rsyslog | `dirOwner="root"` 導致 chown 失敗 | 確認 `vm4-server.conf` 中 `dirOwner="syslog"`，不是 `root` |
| rsyslog 規則沒有觸發（NO MATCH） | 用了 `$programname`（只取 `/` 前的部分） | 改用 `$syslogtag contains "nexflow/"`；regex 用 `([a-zA-Z0-9_-]+)` |
| Dagster 容器 `Permission denied` 無法啟動 | host 掛載目錄擁有者不是 UID 10001 | 執行 Phase 0-6 的 `chown -R 10001:10001` |
| superset-init 報錯 `User already exists` | admin 帳號已建立（第二次初始化） | 正常現象，compose 裡有 `|| true` 處理，superset 服務可正常啟動 |
| GitLab `/users/sign_in` 持續 502，container healthcheck 卻顯示 healthy | Puma 仍在 `Preloading application`，container-level healthcheck（`/healthz`）跟 Rails app 是否真的能服務是兩回事；VM 規格不足時 Puma 會反覆卡住甚至被 OOM 影響 | 確認 VM3 至少 6 vCPU / 8GB RAM（見 Phase 0 規格表）；用 `docker exec gitlab tail -f /var/log/gitlab/puma/current` 確認是否卡在同一行超過 2-3 分鐘 |
| `dtrack-server` 一直 unhealthy | API server 啟動慢 | healthcheck `start_period=120s`，等足時間；`docker logs dtrack-server` 確認有無 exception |
| GitLab Runner 無法連線 GitLab | Runner 不信任自簽 TLS | 確認 `workspace/gitlab-runner-{ci,cd}/certs/gitlab.dai.post.gov.tw.crt` 存在（內容為 `ca.crt`） |
| Registry `docker login` 失敗 `connection refused` | port 5050 未開通，或 nginx-vm3 沒有監聽 5050 | 確認 `docker-compose_vm3_secure.yml` 的 nginx 服務有 `ports: - "5050:5050"`；確認防火牆已開通 5050 |
| Keycloak 無法連線 LDAP server（DNS 解析失敗） | `dns:` 設定的公司 DNS IP 不正確，或公司 LDAP 主機名稱不在該 DNS 區域內 | `docker exec keycloak getent hosts <LDAP主機名稱>` 確認解析結果；必要時改用 LDAP server 的 IP 字面值取代主機名稱 |
| multipass/SSH 連線逾時、`docker exec` 卡住 | Host 記憶體不足導致 VM 整體緩慢（GitLab 是最吃資源的服務） | 確認 VM3 規格足夠（Phase 0 規格表），正式環境若用實體/虛擬機通常不會有此問題，純測試環境（如 multipass）需注意 host 總資源是否超賣 |
| Superset SQL Lab 新增外部資料庫連線時主機名稱解析逾時 | `dns:` 限定的公司 DNS（10.10.43.1/.2）連不到，或該主機名稱不在公司 DNS 區域內 | `docker exec superset getent hosts <DB主機名稱>` 確認解析結果；測試環境（如 multipass）若連不到公司網段屬預期，需在正式環境驗證 |
| `docker exec superset ps aux` 顯示 `executable file not found` | Debian Trixie slim 極簡安裝，映像內沒有 `ps` 指令 | 改用 `docker exec superset sh -c "cat /proc/<pid>/cmdline"` 或直接讀 `/proc/[0-9]*/cmdline` 確認程序狀態 |
