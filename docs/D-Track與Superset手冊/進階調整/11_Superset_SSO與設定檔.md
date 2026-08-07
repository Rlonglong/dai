# 11 · Superset · SSO 與設定檔

> 對象：**要調整 Superset 設定或角色對應的人**。
> 檔案位置：VM5 部署根目錄的 `workspace/superset_config.py` 與
> `workspace/custom_sso_security_manager.py`。

---

## 1. 兩個設定檔各自負責什麼

| 檔案 | 負責 |
|---|---|
| `superset_config.py` | Superset 本身的設定：資料庫、快取、Feature Flag、**OAuth provider 定義** |
| `custom_sso_security_manager.py` | **登入之後**怎麼從 Keycloak 的資訊決定這個人是誰、給什麼角色 |

改完**都要重啟容器**才生效：

```bash
# 在 VM5
cd /run/media/root/D/deploy
docker compose restart superset
docker compose logs -f superset      # 看有沒有 Python 語法錯誤
```

> ⚠️ 這兩個檔案的權限要是 `644`（見部署手冊 Phase 0-12）。
> 改完如果容器起不來，先確認權限沒被改掉。

---

## 2. SSO 流程

```
使用者 → https://superset.dai.post.gov.tw
   │
   ├─ 沒有 session → 導向 Keycloak
   │                    │
   │            Keycloak 驗證（後面接公司 LDAP）
   │                    │
   │            帶著 authorization code 回到
   │            https://superset.dai.post.gov.tw/oauth-authorized/keycloak
   │
   ├─ Superset 用 code 換 token，取得使用者資訊
   │        （username / email / firstname / lastname / roles）
   │
   ├─ custom_sso_security_manager.py 決定：
   │        這個人是誰？第一次來的話要建帳號嗎？給哪些角色？
   │
   └─ 進入 Superset
```

### 對應到 Keycloak 的設定

部署手冊 Phase 2-2 建立的 `superset` client：

| Keycloak 欄位 | 值 |
|---|---|
| Client ID | `superset` |
| Client authentication | On（Confidential） |
| Client Secret | 要跟 `superset_config.py` 裡的一致 |
| Valid redirect URIs | `https://superset.dai.post.gov.tw/*` |

> 🔑 **Secret 對不上是最常見的 SSO 失敗原因**，
> 錯誤訊息通常是 `invalid_client` 或直接跳回登入頁沒有提示。
> 兩邊比對一次：Keycloak client 的 Credentials 分頁 vs `superset_config.py`。

---

## 3. 角色怎麼對應

### 我們採用的做法：Keycloak 群組 → Superset 角色

**權限統一在 Keycloak 管**，Superset 這邊只負責「翻譯」：

```python
# superset_config.py
AUTH_USER_REGISTRATION = True          # 第一次 SSO 登入時自動建立本機使用者紀錄
AUTH_USER_REGISTRATION_ROLE = "Gamma"  # 沒對應到任何群組時的最低權限（看不到任何資料）

AUTH_ROLES_MAPPING = {
    # Keycloak 群組名稱          : Superset 角色
    "dai-superset-admin":  ["Admin"],
    "dai-superset-dev":    ["Alpha", "sql_lab"],
    "dai-superset-user":   ["Gamma", "sql_lab"],
    "dai-superset-viewer": ["Gamma"],
    # 各單位的資料角色（在 Superset 上用 List Roles 建好，這裡對應過去）
    "dai-superset-稽核室":  ["稽核室"],
}
AUTH_ROLES_SYNC_AT_LOGIN = True        # 每次登入都以 Keycloak 為準重算角色
```

要讓這個對應成立，Keycloak 那邊必須把群組資訊放進 token：

```
Keycloak Admin Console → realm postoffice
  → Client scopes → 建一個 groups mapper（Mapper Type: Group Membership）
  → Token Claim Name: groups，勾 Add to ID token / Add to access token
  → Clients → superset → Client scopes → 把該 scope 加進去
```

`custom_sso_security_manager.py` 負責從 token 裡把 `groups` 這個 claim 讀出來
交給 Flask-AppBuilder 比對 `AUTH_ROLES_MAPPING`。

> 📌 **不要在 Superset 上手動指派角色**，`AUTH_ROLES_SYNC_AT_LOGIN=True`
> 會在下次登入時把手動加的角色洗掉，而且不會有任何提示。
> 群組規劃見
> [日常維運 · 02 · 第 4 節](../日常維運/02_Superset_資料庫連線與權限.md#4-使用者與權限統一在-keycloak-管)。

### `AUTH_ROLES_SYNC_AT_LOGIN` 的取捨

| 設定 | 效果 | 風險 |
|---|---|---|
| `True` | 每次登入都以 Keycloak 為準重算角色 | **在 Superset 手動加的角色會被洗掉** |
| `False` | 只在第一次註冊時指派 | Keycloak 那邊移除權限，Superset 這邊不會跟著收回 |

**我們選 `True`**：權限的唯一真相在 Keycloak，Superset 只是反映它。

> ⚠️ 用 `True` 的話，**自訂資料角色也一定要放進 `AUTH_ROLES_MAPPING`**，
> 否則管理員在 Superset 上手動加的角色下次登入就不見了，
> 而且不會有任何提示——只會收到使用者說「我昨天還看得到」。

---

## 4. 常用設定

### 查詢逾時

```python
SUPERSET_WEBSERVER_TIMEOUT = 300          # gunicorn worker 逾時（秒）
SQLLAB_TIMEOUT = 300                      # SQL Lab 查詢逾時
SQLLAB_ASYNC_TIME_LIMIT_SEC = 600         # 非同步查詢（需要 Celery）
```

改大之前先想清楚：查詢慢通常代表**缺索引或該做彙總表**，
把逾時調大只是把問題往後推，而且會佔住 worker 影響其他人。

### 結果快取

```python
CACHE_CONFIG = {
    "CACHE_TYPE": "RedisCache",
    "CACHE_DEFAULT_TIMEOUT": 300,
    ...
}
```

快取會讓「資料明明更新了但圖表沒變」，使用者可以用 **⋮ → Force refresh** 繞過。
批次是每天跑的話，`CACHE_DEFAULT_TIMEOUT` 設幾分鐘到一小時都合理。

### Feature Flags

```python
FEATURE_FLAGS = {
    "DASHBOARD_RBAC": True,        # Dashboard 可以直接指定角色
    "EMBEDDED_SUPERSET": False,    # 不需要嵌到別的系統就關著
    "ALERT_REPORTS": False,        # 要寄信通知才開，需要 Celery + SMTP
}
```

> 每開一個 Feature Flag 就多一份要維護的東西，
> **沒有明確需求就不要開**。

---

## 5. 改設定的標準流程

```
1. 先在測試環境或非尖峰時段改
2. 備份現有設定：cp superset_config.py superset_config.py.$(date +%F)
3. 改
4. docker compose restart superset
5. docker compose logs -f superset  ← 看有沒有 traceback
6. 實際登入驗證：用一個一般使用者帳號，不要只用 admin 測
7. 沒問題再把備份刪掉
```

> ⚠️ `superset_config.py` 是 Python，**語法錯誤會讓容器起不來**（不是降級運作）。
> 改完一定要看 log 確認。

---

## 6. 疑難排解

| 症狀 | 可能原因 | 怎麼查 |
|---|---|---|
| 點 SSO 之後跳回登入頁，沒有錯誤訊息 | client secret 不符 | 比對 Keycloak Credentials 與設定檔 |
| `redirect_uri_mismatch` | Keycloak 的 Valid redirect URIs 沒涵蓋 | 改成 `https://superset.dai.post.gov.tw/*` |
| 登入成功但沒有任何選單 | 沒拿到角色，或角色沒有權限 | `Settings → List Users` 看該使用者實際的 Roles |
| 昨天看得到、今天看不到 | `AUTH_ROLES_SYNC_AT_LOGIN=True` 把手動加的角色洗掉了 | 把該角色加進 `AUTH_ROLES_MAPPING` |
| 容器起不來 | 設定檔語法錯誤或權限不對 | `docker compose logs superset`；確認檔案是 644 |
| TLS 憑證驗證失敗 | 容器不信任自簽 CA | 確認 Phase 0-9 的 CA 有匯入，必要時重建映像 |

更多症狀見 [12_疑難排解](./12_疑難排解.md)。

---

## 相關文件

- 資料庫連線與角色規劃 → [日常維運 · 02](../日常維運/02_Superset_資料庫連線與權限.md)
- Keycloak client 怎麼建 → [部署手冊 Phase 2-2](../../../README.md)
- Superset 怎麼啟動 → [部署手冊 Phase 2-4](../../../README.md)
