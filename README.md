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
| VM3 | GitLab + Container Registry + Dependency-Track + Nginx + **GitLab Runner CI/CD** | 更新 `env/vm3.env` |
| VM4 | infra-db (PostgreSQL) + Dagster | 更新 `env/vm4.env` |
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
          └─ 3C: 註冊 GitLab Runner CI / CD
          └─ 3D: 驗證 Container Registry（與 GitLab 共用 domain，port 5050）
[Phase 4] 版控與 CI/CD 同步（★本次新增，跨 VM1 / VM3 / VM4★）
          └─ 4A: 三台 VM 建立 gitlab_runner 帳號與免密碼 SSH
          └─ 4B: 安裝 post-deploy 腳本與 sudoers
          └─ 4C: 建立兩個 GitLab repo 並推上初始程式碼
          └─ 4D: 安裝伺服器端 pre-receive hook（★機密外洩的真正防線★）
          └─ 4E: 設定分支保護、CI/CD Variables、環境隔離
          └─ 4F: 設定每日雜湊對帳排程
          └─ 4G: 首次部署（先 dry-run）
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
  up -d dagster-login dagster-code dagster-webserver dagster-daemon
```

**注意事項：**
- `infra-db` 首次啟動時執行 `workspace/init-infra-db.sql`，會建立所有資料庫（keycloak、dtrack、superset、dagster、keycloak_access_db）。確保此 SQL 檔在啟動前已存在於正確路徑。
- `dagster-code` 必須先 healthy，`dagster-webserver` 和 `dagster-daemon` 才能啟動（compose 已設定 `depends_on` 健康依賴）。
- `dagster-login`（OAuth2 Proxy，Dagster SSO 對外邊界）會持續重試連線 Keycloak，直到 Phase 2 的 Keycloak 啟動後才會轉為正常狀態，屬預期行為，不需要特別處理。
- CD runner 已改到 VM3（跟 CI runner 同一台，見 Phase 3-5），VM4 不再需要 `gitlab-runner-cd`。改用 rsync 從 VM3 推送，VM4 只當接收端，上面不會有 `.git` 目錄、也不需要對 GitLab 的連線。理由見 [11_CD_rsync部署機制 · 第 8 節](./docs/GitLab維運手冊/進階調整/11_CD_rsync部署機制.md#8-為什麼是vm3-推而不是vm4-拉)。
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
### 3-5. 啟動並註冊 GitLab Runner CI / CD

兩個 runner 都跑在 VM3 上，用 tag 區分職責：

| Runner | tag | 負責 |
|---|---|---|
| `gitlab-runner-ci` | `vm3,ci` | lint、test、gitleaks、bandit、D-Track |
| `gitlab-runner-cd` | `vm3,cd` | rsync 推到 VM1 / VM4、雜湊對帳 |

```bash
# 在 VM3 執行
cd ./certs
# 建立一個名為 gitlab.dai.post.gov.tw.crt 的連結，指向你的完整證書鏈
ln -s fullcert_202606.crt gitlab.dai.post.gov.tw.crt

cd ..
docker compose -f docker-compose_vm3_secure.yml --env-file ../env/vm3.env \
  up -d gitlab-runner-ci gitlab-runner-cd

# 在 GitLab UI：Admin Area > CI/CD > Runners > New instance runner
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

> Runner 的 CA 憑證已預先放在 `workspace/gitlab-runner-ci/certs/gitlab.dai.post.gov.tw.crt`，register 時能信任自簽 GitLab TLS 憑證。

**CD runner 需要額外的東西**（rsync、ssh、以 `gitlab_runner` 身分執行）：

```bash
# CD runner 的 shell executor 需要 rsync 與 ssh client
docker exec gitlab-runner-cd sh -c \
  "command -v rsync ssh || (apt-get update && apt-get install -y rsync openssh-client)"

# 掛載 gitlab_runner 的 .ssh（Phase 4A 會建立）
#   在 docker-compose_vm3_secure.yml 的 gitlab-runner-cd 服務加：
#     user: "<gitlab_runner 的 UID>:<GID>"
#     volumes:
#       - /home/gitlab_runner/.ssh:/home/gitlab_runner/.ssh:ro
```

> ⚠️ 容器重建後 `apt-get` 裝的東西會消失。長期作法是做一個
> `Dockerfile.gitlab-runner-cd`（base image 加 `rsync openssh-client`），
> 跟現有的 `Dockerfile.keycloak`、`Dockerfile.dt_apiserver` 一樣納入映像建置流程。

### 3-6. 安裝 gitleaks 到 GitLab 容器（給伺服器端 hook 用）

Phase 4D 的 pre-receive hook 需要它，先裝好：

```bash
# 在 VM3
docker cp gitleaks       gitlab:/usr/local/bin/gitleaks
docker exec gitlab chmod 755 /usr/local/bin/gitleaks
docker exec gitlab /usr/local/bin/gitleaks version    # 確認跑得起來
```

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

---

### 4B. 安裝 post-deploy 腳本與 sudoers

rsync 過來的檔案屬於 `gitlab_runner`，但實際執行的是別的身分
（VM4 是 UID 10001、VM1 是 `bcp_runner`），所以部署後要 `chown` 回去。

**VM4：**

```bash
# 在 VM4，以 root
install -o root -g root -m 755 deploy/vm4/dai-post-deploy-vm4.sh /usr/local/sbin/

cat > /etc/sudoers.d/dai-gitlab-runner <<'EOF'
gitlab_runner ALL=(root) NOPASSWD: /usr/local/sbin/dai-post-deploy-vm4.sh
Defaults!/usr/local/sbin/dai-post-deploy-vm4.sh !requiretty
EOF
chmod 440 /etc/sudoers.d/dai-gitlab-runner
visudo -c        # ★一定要驗★ sudoers 寫錯會讓整台機器的 sudo 失效
```

**VM1：** 同樣做一次，換成 `deploy/vm1/dai-post-deploy-vm1.sh`。

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

**推上初始程式碼：**

```bash
# dagster-workspace：本 repo 就是它
git remote add origin https://gitlab.dai.post.gov.tw/<group>/dagster-workspace.git
git push -u origin main

# bcp-scripts：從 VM1 現有的檔案初始化
# 步驟見 gitlab_templates/bcp_scripts_repo/README.md
```

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

```bash
# 在 VM3（gitleaks 已在 Phase 3-6 裝好）
docker cp .gitleaks.toml gitlab:/etc/gitlab/gitleaks.toml

docker exec gitlab mkdir -p /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d
docker cp ci/server_hooks/pre-receive \
          gitlab:/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks
docker exec gitlab chmod 755 /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks
docker exec gitlab chown git:git /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks
```

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
> 長期作法是把三個檔案掛進 `docker-compose_vm3_secure.yml`（`:ro`），
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

Settings → Merge requests：勾選 **Pipelines must succeed** 與 **All threads must be resolved**。

> ★ **關鍵設計：Developer 不能合併到 `main`** ★
> 這樣「有人 code review 過」就是硬性的，不是靠自律——
> 開發者自己開的 MR，自己按不下 Merge 鍵，一定要另一個人（Maintainer）來按。
>
> GitLab CE 沒有 Merge Request Approvals（那是 Premium），
> 上面這組設定是 CE 上能達到的等效控制。
> 有 Premium 授權的話再加 Approvals（最少 1 人 + 勾 Prevent approval by author），
> 見 [04_帳號_權限_分支保護](./docs/GitLab維運手冊/日常維運/04_帳號_權限_分支保護.md#3-關於-code-review-的強制性)。

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
> **資料庫密碼不在這裡，也不該在這裡。** DB 連線走各機器上的 `.env`
> （VM4 `dagster_code/.env`、VM1 `/home/bcp_runner/.env`），
> 那兩個檔案不進版控、rsync 也不傳不刪。
> 所以 GitLab 被入侵也拿不到 DB 帳密。
> 隔離是靠「程式碼推到哪台機器，就吃那台機器的 `.env`」達成的。

**驗證隔離有效**：在功能分支跑 `echo "[${DEPLOY_HOST:-空}]"` 應該是空的，
在 `main` 上應該是 `[MASKED]`。驗完把測試用的 job 刪掉。

---

### 4F. 每日雜湊對帳排程

**在回答**：GitLab 上 `main` 的內容，跟正式機上實際在跑的檔案，還是同一份嗎？

抓得到「rsync 傳到一半」「有人直接 ssh 上機改檔案」「檔案被覆寫」。

GitLab UI → Build → **Pipeline schedules → New schedule**（兩個 repo 都要）：

| 欄位 | 值 |
|---|---|
| Description | `每日同步完整性稽核` |
| Interval Pattern | `0 6 * * *` ← 早於當天第一批 Dagster 排程，發現問題還來得及處理 |
| Cron timezone | `Asia/Taipei` |
| Target branch | `main`（一定要，才拿得到 production 變數） |
| Activated | ✅ |

排程只會跑 `verify:production`，不會誤觸發部署。

除此之外，**每次 CD 部署完也會立刻對一次**（`deploy_rsync.sh` 最後一步），
不用等到隔天才發現同步不完整。

比對結果會送進 rsyslog（tag `dai/gitlab-sync`），依 Phase 6 的架構集中到
VM4 的 `/data/log/dai/` 並納入每日 log 雜湊存證。

---

### 4G. 首次部署（★先 dry-run★）

VM1 / VM4 上已經有正在跑的檔案，第一次讓 CD 接管時要特別小心：
`rsync --delete` 會把「repo 裡沒有」的檔案刪掉。

```bash
# 1. ★先備份★ 萬一排除清單有漏，這是唯一的救命索
#    在 VM4
tar czf /root/backup_before_cd_$(date +%F).tar.gz /data/deploy/workspace/dagster_workspace
#    在 VM1
tar czf /root/backup_before_cd_$(date +%F).tar.gz /home/bcp_runner/scripts

# 2. 記下機密檔案的雜湊，等下要核對它們有沒有活下來
sha256sum /data/deploy/workspace/dagster_workspace/dagster_code/.env
sha256sum /data/deploy/workspace/dagster_workspace/dbt_project/profiles.yml

# 3. ★一定要先 dry-run★
ci/deploy_rsync.sh --dry-run

# 4. 逐行檢查輸出，特別注意 deleting 開頭的行
#      deleting dbt_project/models/OLD_MODEL.sql   ← 這個對，repo 裡確實刪了
#      deleting dagster_code/.env                  ← ★停！排除清單有問題★

# 5. 確認無誤才真的跑（或在 GitLab 上觸發 deploy job）
ci/deploy_rsync.sh

# 6. 核對機密檔案還在、內容沒變
sha256sum /data/deploy/workspace/dagster_workspace/dagster_code/.env
```

`.env` 和 `profiles.yml` 能活下來，靠的是
[`deploy_exclude.txt`](./deploy_exclude.txt)——
**rsync 的 `--delete` 不會刪掉被 `--exclude` 排除的檔案**
（會刪的是 `--delete-excluded`，我們刻意不用）。
所以那份清單同時是「不傳清單」和「刪除保護清單」，**漏一行就會洗掉正式機的帳密**。

備份至少保留一個月。

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
[ ] Pipelines must succeed / All threads resolved 都勾了
[ ] CI/CD Variables 設好（Protected + Masked + environment scope）
[ ] 隔離驗證：功能分支拿不到 DEPLOY_HOST
[ ] 兩個 repo 都設好每日雜湊對帳排程
[ ] 首次部署前已備份，dry-run 檢查過
[ ] 首次部署後 .env / profiles.yml 的 sha256 沒變
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
