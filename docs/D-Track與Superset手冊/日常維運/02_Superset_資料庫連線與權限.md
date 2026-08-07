# 02 · Superset · 資料庫連線與權限

> 對象：**Superset 管理員**。
> 這份文件在回答：怎麼接一個新資料庫、怎麼決定誰看得到什麼。

---

## 1. 接一個新的資料庫連線

### 1-1. 事前準備（★先做這一步★）

**在資料庫端建一個唯讀帳號給 Superset 用。**

Superset 是展示層，沒有任何理由需要寫入權限。
用一個有寫入權限的帳號接上去，等於任何一個能進 SQL Lab 的人都能改資料。

```sql
-- PostgreSQL 範例
CREATE USER superset_ro WITH PASSWORD '<強密碼>';
GRANT CONNECT ON DATABASE <資料庫> TO superset_ro;
GRANT USAGE ON SCHEMA <schema> TO superset_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA <schema> TO superset_ro;
-- 之後新建的表也要能讀
ALTER DEFAULT PRIVILEGES IN SCHEMA <schema> GRANT SELECT ON TABLES TO superset_ro;
```

```sql
-- SQL Server 範例
CREATE LOGIN superset_ro WITH PASSWORD = '<強密碼>';
USE [<資料庫>];
CREATE USER superset_ro FOR LOGIN superset_ro;
ALTER ROLE db_datareader ADD MEMBER superset_ro;
```

**防火牆**：需要開通 `VM5 → <資料庫主機>:<port>`。

### 1-2. 在 Superset 建立連線

```
Settings → Database Connections → + Database
  1. 選資料庫類型（PostgreSQL / Microsoft SQL Server / …）
  2. 填連線資訊，或直接用 SQLAlchemy URI
  3. 按 Test Connection ← ★一定要按，成功了再存★
  4. Connect
```

SQLAlchemy URI 格式：

```
postgresql+psycopg2://superset_ro:<密碼>@<主機>:5432/<資料庫>
mssql+pyodbc://superset_ro:<密碼>@<主機>:1433/<資料庫>?driver=ODBC+Driver+18+for+SQL+Server&Encrypt=yes&TrustServerCertificate=yes
```

> 📸 **待補截圖**：Database Connections 頁面與 + Database 對話框，
> 標出 Test Connection 按鈕。

### 1-3. Advanced 分頁的四個開關

| 選項 | 建議 | 為什麼 |
|---|---|---|
| **Expose database in SQL Lab** | ✅ 開 | 不開的話 SQL Lab 選不到這個資料庫 |
| **Allow CREATE TABLE AS / CTAS** | ❌ 關 | 唯讀帳號本來就做不到，開了只是誤導 |
| **Allow DML** | ❌ **一定要關** | 開了等於允許在 SQL Lab 下 UPDATE / DELETE |
| **Asynchronous query execution** | 視情況 | 要跑長查詢才需要，需要 Celery worker 才會生效 |

### 1-4. 驗證

```
SQL Lab → 選新建的 Database → 隨便查一張表
SELECT 1;              -- 先確認連得到
SELECT COUNT(*) FROM <某張表> ;
```

再驗一次**寫不進去**（應該要失敗）：

```sql
CREATE TABLE superset_write_test (id int);
-- 預期：permission denied，這才是對的
```

---

## 2. 主機名稱解析不到的話

VM5 的容器 `dns:` 被限定在公司 DNS（見部署手冊 Phase 2-1，
`10.10.43.1` / `10.10.43.2`），這是 glibc DNS 弱點的圍堵措施。

```bash
# 在 VM5 確認 Superset 容器解不解得到那台資料庫
docker exec superset getent hosts <資料庫主機名稱>
```

解不到的話兩個選擇：

1. 請 IT 把該主機名稱加進公司 DNS 區域（**建議**）
2. 連線設定直接填 IP（缺點：資料庫換機時要改設定）

> 測試環境（如 multipass）連不到公司網段是預期的，要在正式環境才驗得出來。

---

## 3. 權限模型

Superset 的權限分兩層，**兩層都要對，使用者才看得到東西**：

```
第一層：角色（Role）          能不能進某個功能（SQL Lab、建 Chart、管理設定）
第二層：資料來源（Datasource） 看不看得到某個 Dataset
```

### 3-1. 內建角色

| 角色 | 能做什麼 | 給誰 |
|---|---|---|
| `Admin` | 全部，包含改設定、管理使用者 | 系統管理員（**盡量少人**） |
| `Alpha` | 建 / 改所有 Dataset、Chart、Dashboard，不能改系統設定 | 開發人員 |
| `Gamma` | **只能看被授權的資料**，可以自己做 Chart / Dashboard | 業務單位 |
| `sql_lab` | 可以用 SQL Lab（**要跟上面的角色搭配一起給**） | 需要自己撈資料的人 |

> `Gamma` 是預設給一般使用者的角色，它**預設看不到任何 Dataset**，
> 要另外授權（見 3-2）。這是刻意的：預設看不到，比預設全看得到安全。

### 3-2. 讓 Gamma 使用者看得到特定資料

**做法 A：自訂角色（建議，好管理）**

```
Settings → List Roles → + Role
  Name: 稽核室
  Permissions: 加入
    - datasource access on [dai-postgres].[vd_ATM異常提領](id:12)
    - datasource access on [dai-postgres].[每日詐欺名單](id:15)
  → Save

Settings → List Users → 編輯使用者 → Roles 加上「Gamma」與「稽核室」
```

**做法 B：Dashboard 層級授權**

Superset 較新的版本支援直接把 Dashboard 分享給角色
（Dashboard → Edit properties → Roles）。
使用者仍需要有底層 Dataset 的權限才看得到數字。

> 📸 **待補截圖**：List Roles 的權限編輯畫面，標出 `datasource access on ...` 那種項目長什麼樣。

### 3-3. 建議的角色規劃

| 使用者類型 | 角色組合 |
|---|---|
| 系統管理員 | `Admin` |
| 開發人員 | `Alpha` + `sql_lab` |
| 業務單位（要自己撈） | `Gamma` + `sql_lab` + `<自訂資料角色>` |
| 業務單位（只看 Dashboard） | `Gamma` + `<自訂資料角色>` |

---

## 4. 使用者從哪裡來

**使用者不是在 Superset 建的。** 走 Keycloak SSO 的流程是：

```
使用者第一次用 SSO 登入
      ▼
Superset 自動建立一個本機使用者紀錄（帳號、姓名、email 來自 Keycloak）
      ▼
依 custom_sso_security_manager.py 的對應規則指派角色
```

所以：

- **不要**在 Superset 手動建帳號（`Settings → List Users → +`），
  那會變成一個不受 LDAP 管理的帳號，離職時不會被停用
- 要調整角色，改 Keycloak 的群組／角色對應，
  或改 `custom_sso_security_manager.py` 的對應邏輯
  （見 [進階調整 · 11](../進階調整/11_Superset_SSO與設定檔.md)）

### 離職 / 轉調

1. LDAP 帳號停用 → 該使用者就登不進來了（**這是主要手段**）
2. Superset 上的使用者紀錄可以留著（保留他建立的 Chart 的擁有者資訊）
3. 如果他是某些 Dashboard 的唯一 Owner，記得**先改 Owner** 再處理

---

## 5. 管理員檢查清單

新接一個資料庫時：

```
[ ] 資料庫端已建立唯讀帳號，實測寫不進去
[ ] 防火牆 VM5 → 資料庫主機:port 已開通
[ ] 主機名稱在 Superset 容器裡解析得到（或改用 IP）
[ ] Test Connection 通過
[ ] Allow DML 沒有勾
[ ] Expose in SQL Lab 有勾（如果要開放 SQL Lab）
[ ] 建好對應的自訂角色，並實際用一個 Gamma 帳號登入驗證看得到／看不到
[ ] 連線密碼有記錄在公司的密碼保管機制
```

---

## 相關文件

- 一般使用者怎麼用 → [01_Superset_使用手冊](./01_Superset_使用手冊.md)
- SSO 與設定檔細節 → [進階調整 · 11](../進階調整/11_Superset_SSO與設定檔.md)
- 部署與啟動 → [部署手冊 Phase 2-4](../../../README.md)
