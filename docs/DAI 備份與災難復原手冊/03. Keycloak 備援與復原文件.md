# Keycloak 備援與復原文件（Docker Compose 部署）

**適用範圍**：本文件適用於以 Docker Compose 部署的 Keycloak 容器，隸屬 nexflow/DAI 多 VM 架構中的 VM5。
**架構前提**：Keycloak metadata DB 使用共用 Postgres 容器 `infra-db`（volume: `infra-db-data`），資料庫名稱 `keycloak`，使用者 `kc_user`，與其他元件（如 Superset）共用同一個 Postgres instance、各自獨立 DB/user。目前線上有 `master` 與一個自訂 realm 兩個 realm。Keycloak 版本 26.6.4。
**維護者**：CY
**最後更新**：2026-08-05

---

## 1. 備份策略總覽

### 1.1 與 GitLab / Superset 備份策略的差異

Keycloak 有三種匯出/備份手段，涵蓋範圍差異很大，先整理清楚，避免誤用：

| 方式 | 涵蓋範圍 | 限制 |
|---|---|---|
| Admin Console「Partial export」/ Admin REST API `partial-export` | Realm 設定、group、role、client 定義 | **不含** user、**不含** client secret（顯示為遮罩星號） |
| CLI `kc.sh export`（完整匯出） | 含 user 密碼雜湊、client secret 明文、完整 realm 資料 | 必須**停機**執行（官方文件要求所有節點先停止，避免與運行中實例產生一致性問題） |
| `pg_dump` 資料庫層級邏輯備份 | **全部**，包含 token 簽章金鑰（realm key）、client secret、LDAP federation 設定 | 不需停機，執行期間即可備份 |

因此本文件採用**`pg_dump` 作為主要備份手段**，Admin REST API 的 partial export 作為輔助的人類可讀版控層（精神上與 Superset 的 `export-assets` 相同）。CLI 完整匯出因為需要停機且會產出高機敏 JSON 檔案，不建議作為例行備份手段，僅在特定情境（如版本遷移、跨環境搬遷）才使用。

### 1.2 職責分工

| 項目 | 備份方式 | 負責單位 |
|---|---|---|
| VM 主機層級（磁碟快照） | 定期主機備份 | 公司 VM 管理團隊 |
| `infra-db-data` volume 整體快照 | 隨 VM 快照涵蓋，但**不建議**作為唯一復原手段（同 Superset 文件 1.3 節理由） | 公司 VM 管理團隊 |
| `keycloak` DB（realm、client、user、role、federation、signing key） | `pg_dump` 邏輯備份，僅針對此單一 DB | 本文件範圍 |
| `vm5.env`（含 `KC_DB_*` 連線設定等） | 檔案備份 | 與 Superset 文件共用同一份備份產出，見 3.2 節說明 |
| Realm 人類可讀版本（不含 secret） | Admin REST API partial export + GitLab 版控 | 本文件範圍（選用） |

### 1.3 為什麼 `pg_dump` 對 Keycloak 而言足夠完整

跟 Superset 的 `SECRET_KEY` 或 GitLab 的 `gitlab-secrets.json` 不同，Keycloak 的 token 簽章金鑰（realm key）本身就**存在資料庫裡**（`component`/`component_config` 相關資料表），不是外部檔案。這代表：

- `pg_dump` 備份還原後，既有的 signing key 會完整保留，**不會**觸發「所有 token 失效、使用者被迫重新登入」的狀況（這是只用 Admin Console partial export 還原時才會遇到的問題，因為那個管道本來就不含 key）。
- 也不需要像 Superset 那樣另外管理一把外部機密才能讓還原後的資料「可用」——DB 備份本身就是自足的。

風險方向反而相反：如果你為了方便版控去用 CLI 完整匯出（含明文 client secret、密碼雜湊），那份 JSON 檔案本身就變成高機敏檔案，其機密等級等同 `gitlab-secrets.json`，存放與存取權限需要同等級管控，且**不能**像 partial export 那樣直接 commit 進 GitLab。

### 1.4 `vm5.env` 與 Superset 文件的關係

Keycloak 連線 `infra-db` 的設定（`KC_DB_URL`、`KC_DB_USERNAME`、`KC_DB_PASSWORD` 等）同樣是透過 `vm5.env` 帶入，`environment:` 區塊只列變數名稱做自我代換。這份檔案跟 Superset 文件裡處理的是**同一份檔案**，備份時不需要為 Keycloak 重複建立一次備份排程——直接沿用 Superset 文件 3.2 節產出的 `vm5.env` 備份即可，兩份文件共用同一組備份產出物。若之後確認 `vm5.env` 內確實混有多元件機密，建議依 Superset 文件待辦事項，把它獨立成一份「VM5 共用機密備份」文件，供本文件與 Superset 文件共同引用。

---

## 2. 資料實際存放位置

### 2.1 確認 Volume 掛載

```bash
docker inspect keycloak --format '{{ range .Mounts }}{{ .Source }} -> {{ .Destination }}{{ "\n" }}{{ end }}'
```

### 2.2 典型掛載結構

```yaml
services:
  keycloak:
    env_file:
      - ../env/vm5.env
    environment:
      - KC_DB=${KC_DB}
      - KC_DB_URL=${KC_DB_URL}
      - KC_DB_USERNAME=${KC_DB_USERNAME}
      - KC_DB_PASSWORD=${KC_DB_PASSWORD}
      - KC_HOSTNAME=${KC_HOSTNAME}
      - KC_BOOTSTRAP_ADMIN_USERNAME=${KC_BOOTSTRAP_ADMIN_USERNAME}
      - KC_BOOTSTRAP_ADMIN_PASSWORD=${KC_BOOTSTRAP_ADMIN_PASSWORD}
```

> 請對照你實際的 compose 檔案確認變數名稱是否一致，尤其 `KC_BOOTSTRAP_ADMIN_USERNAME`／`KC_BOOTSTRAP_ADMIN_PASSWORD` 是 Keycloak 26.x 的命名（舊版是 `KEYCLOAK_ADMIN`／`KEYCLOAK_ADMIN_PASSWORD`），你們是 26.6.4，應對應新命名。

### 2.3 重點路徑與位置

| 項目 | 位置 | 備註 |
|---|---|---|
| Metadata DB 實際資料 | `infra-db-data` volume → `infra-db` container 內 `/var/lib/postgresql/data`，DB 名稱 `keycloak` | 多元件共用，**不可**直接檔案層級複製當備份 |
| DB 連線設定、admin bootstrap 帳密 | `../env/vm5.env` | 與 Superset 共用同一份檔案，見 1.4 節 |
| Image 建置定義 | GitLab repo（自訂 multi-stage Dockerfile，含 UBI9 RPM patching） | 已由現行 GitLab 版控機制涵蓋，不在本文件備份範圍 |

> ⚠️ **`KC_BOOTSTRAP_ADMIN_USERNAME`／`KC_BOOTSTRAP_ADMIN_PASSWORD` 的作用範圍**：這組帳密**只在資料庫是全新、空的**時候才會生效，用來建立第一個 admin 帳號。若你是透過 `pg_dump`/`pg_restore` 復原（資料庫本身已有 `master` realm 的 admin 帳號），這組環境變數會被忽略，不影響復原結果，可以不用特別擔心它是否跟正式站同步。

---

## 3. 日常備份操作

### 3.1 Metadata DB 邏輯備份（僅針對 `keycloak` DB）

```bash
docker exec -t infra-db pg_dump -U kc_user -d keycloak -F c \
  -f /tmp/keycloak_db_$(date +%Y%m%d).dump

docker cp infra-db:/tmp/keycloak_db_$(date +%Y%m%d).dump ./keycloak-backup/
docker exec -t infra-db rm /tmp/keycloak_db_$(date +%Y%m%d).dump
```

此指令執行期間 Keycloak 服務**不需要停機**，`pg_dump` 對運行中的資料庫做一致性快照即可。

### 3.2 `vm5.env` 備份（沿用 Superset 文件，不重複建立）

如 1.4 節所述，直接使用 Superset 備援文件 3.2 節產出的 `vm5.env` 備份即可，兩份文件共用同一份備份排程與產出物。若尚未建立該排程，請參考 Superset 文件補上，不需要在此另開一套。

### 3.3 人類可讀 Realm 匯出（選用，建議搭配 GitLab 版控）

透過 Admin REST API 匯出 realm 設定（不含 user、不含 client secret，適合安心版控）：

```bash
# 取得 admin token
TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=<admin_user>" \
  -d "password=<admin_password>" \
  -d "grant_type=password" | jq -r '.access_token')

# 匯出自訂 realm（含 client、group、role，不含 user、不含 secret）
curl -s -X POST \
  "http://localhost:8080/admin/realms/<your-realm>/partial-export?exportClients=true&exportGroupsAndRoles=true" \
  -H "Authorization: Bearer $TOKEN" \
  -o ./keycloak-backup/realm_export_$(date +%Y%m%d).json
```

這份 JSON 可以直接 commit 進 GitLab，用 `git diff` 追蹤 realm/client/role 設定的變更歷程，作法與 Superset 的 `export-assets` 精神一致，適合做**設定變更稽核**，而非做為完整復原的唯一依據（因為不含 user 與 secret）。

### 3.4 完整 CLI 匯出（不建議例行使用，僅特定情境）

若因版本遷移或跨環境搬遷需要含 user 密碼雜湊、client secret 明文的完整匯出：

```bash
docker exec -it keycloak /opt/keycloak/bin/kc.sh export \
  --dir /tmp/export --realm <your-realm> --users realm_file
docker cp keycloak:/tmp/export ./keycloak-full-export/
```

> ⚠️ 執行前務必確認：
> - 官方文件要求執行匯出前**所有 Keycloak 節點需先停止**，避免一致性問題。單一容器架構下即代表 Keycloak 服務會短暫中斷。
> - 匯出結果**含明文 client secret 與密碼雜湊**，機密等級等同 `gitlab-secrets.json`，不可與一般設定檔混放，也不可直接 commit 進版控。
> - 此手段**不建議**排入例行備份排程，3.1 節的 `pg_dump` 已完整涵蓋相同資料且不需停機，此手段僅保留給版本遷移等特定情境使用。

### 3.5 備份存放建議

- `keycloak_db` dump 為核心備份，建議每日一次排程，重大 realm/client 設定異動後手動加做一次。
- `vm5.env` 備份頻率與存放位置比照 Superset 文件既有排程，不重複建立。
- 3.3 節的 realm export JSON 可依 commit 頻率決定，例如每次有明顯 client/role 異動時執行並 commit。
- 3.4 節的完整 CLI 匯出僅在需要時執行，產出檔案存放位置需比照最高機密等級管控，且不建議長期保留多份（用完即刪，降低外洩曝險）。

---

## 4. 復原演練程序

### 4.1 演練原則

- 於獨立測試環境進行，**不可**復用正式 `infra-db` container，避免影響其他共用此 Postgres instance 的元件（如 Superset）。
- 測試用 Postgres container 只需初始化 `kc_user` / `keycloak`，不需要完整複製其他元件的 DB。
- Keycloak（Quarkus 發行版）啟動時會**自動偵測並執行 DB schema migration**，不像 Superset 需要額外下 `superset db upgrade` 指令；但仍建議測試用 image 版本與正式站一致，避免版本落差帶來未預期的 migration 行為。

### 4.2 兩種復原方式的差異

| 方式 | 還原範圍 | 適用情境 |
|---|---|---|
| `pg_restore`（DB dump 還原） | 完整還原，含 signing key、client secret、user、federation 設定 | 完整災難復原，效果等同回到備份當下的完整狀態，且不強制使用者重新登入 |
| Admin REST API `partial-import`（3.3 節產出的 JSON） | Realm/client/role 定義，**不含** user、**不含** secret | 單純想復原某個 client/role 設定誤刪誤改，不影響其他資料 |

正式的復原演練建議以 `pg_restore` 路徑為主，`partial-import` 作為輔助驗證用途。

### 4.3 演練步驟（以 `pg_restore` 完整復原為主）

**Step 1：於正式站建立演練用備份**

```bash
docker exec -t infra-db pg_dump -U kc_user -d keycloak -F c \
  -f /tmp/drill_keycloak_$(date +%Y%m%d).dump
docker cp infra-db:/tmp/drill_keycloak_$(date +%Y%m%d).dump ./drill-config/
```

`vm5.env` 直接沿用 Superset 演練時已備份的那份，不需要重複複製。

**Step 2：建立獨立測試用 Postgres container**

```sql
CREATE USER kc_user WITH PASSWORD '<與正式站對齊或測試用密碼>';
CREATE DATABASE keycloak OWNER kc_user;
```

**Step 3：還原 metadata DB**

```bash
docker cp ./drill-config/drill_keycloak_20260805.dump new-infra-db:/tmp/
docker exec -it new-infra-db pg_restore -U kc_user -d keycloak \
  --clean --if-exists /tmp/drill_keycloak_20260805.dump
```

**Step 4：建立測試用 Keycloak container**

啟動 `new-keycloak` container，`env_file` 指向演練用的 `vm5.env`（或依 Superset 文件 4.3 節建議，僅抽取必要變數的精簡版），並將 `KC_DB_URL` 指向 `new-infra-db` 上的 `keycloak` DB。容器啟動時會自動執行 schema migration 並套用現有資料，不需額外指令。

**Step 5：重啟並驗證**

登入 Web 介面（`https://<test-host>/admin`），逐項確認：

- [ ] 可用正式站既有的 admin 帳密登入 `master` realm（驗證 signing key 隨 DB 完整還原，未被重置）
- [ ] 自訂 realm 是否存在，其下 client、group、role 是否完整
- [ ] GitLab、Superset 的 OIDC client 定義是否存在，client secret 是否可正常使用（可在測試環境用該 client 走一次 OIDC 登入流程驗證）
- [ ] LDAP federation 設定是否存在，連線測試是否正常（若測試環境可連到相同 LDAP 來源）
- [ ] 既有使用者是否能正常登入（間接驗證密碼雜湊與 realm key 完整還原）

### 4.4 演練紀錄表（建議每次演練填寫）

| 演練日期 | 備份檔版本 | 還原耗時 | Signing key 驗證結果 | 驗證結果 | 問題紀錄 |
|---|---|---|---|---|---|

---

## 5. 待辦與後續事項

- [ ] 確認 `vm5.env` 中 `KC_DB_*`、`KC_BOOTSTRAP_ADMIN_*` 等變數的實際名稱，與 2.2 節範例校對
- [ ] 建立排程腳本：`pg_dump keycloak` + 保留天數輪替（`vm5.env` 沿用 Superset 排程，不重複）
- [ ] 建立 Admin REST API partial export 排程並 commit 進 GitLab，作為可讀版控稽核層
- [ ] 首次復原演練排程與紀錄，包含 OIDC 登入與 LDAP federation 的實際驗證
- [ ] 待確認 `vm5.env` 是否為 VM5 全元件共用機密清單後，將其獨立為單一文件，供 Superset、Keycloak 共同引用
- [ ] 待 Keycloak 演練完成後，依相同精神但個別調整細節，處理 Dependency-Track（API-based project/policy export）
