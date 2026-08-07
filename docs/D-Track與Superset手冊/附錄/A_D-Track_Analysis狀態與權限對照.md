# 附錄 A · D-Track Analysis 狀態與權限對照

---

## 1. Analysis 狀態一覽

在 **Project → Audit Vulnerabilities → 單筆弱點 → Analysis** 設定。

| 狀態 | 意思 | 會不會解除擋門 | 什麼時候用 |
|---|---|---|---|
| （空白） | 還沒有人看過 | ❌ | — |
| `In Triage` | 正在評估中 | ❌ **不會** | 剛接到、還沒判斷完 |
| `Exploitable` | 確認我們會被打到 | ❌ | 確認有風險，要排修 |
| `Not Affected` | 沒有用到觸發弱點的功能 | ✅ | 評估過確認不受影響 |
| `False Positive` | SBOM 認錯套件或版本 | ✅ | 掃描本身錯了 |
| `Resolved` | 已經修掉了 | ✅ | 升級完成後標記 |

> ⚠️ **`In Triage` 不會解除擋門**，這是最常見的誤會。
> 「我標了啊怎麼還是紅的」——八成就是標成這個。

### Suppress 這個勾選

除了狀態之外還有一個 **Suppress** 勾選框。

| | 效果 |
|---|---|
| 狀態設成 `Not Affected` / `False Positive` / `Resolved` | 該筆不列入擋門計數 |
| 額外勾 **Suppress** | 該筆在 UI 清單也被隱藏 |

實務上建議**兩個都做**：狀態表達「為什麼」，Suppress 讓清單保持乾淨。

### Details 欄位

**一定要寫。** 建議格式：

```
2026-08-07 王小明
本專案只用到 cryptography 的 Fernet 對稱加密，
未使用 CVE-2026-XXXXX 影響的 X.509 憑證解析路徑。
Redmine #1234
```

三個要素：**誰、什麼時候、根據什麼判斷**。
「為什麼我們不受這個 CVE 影響」是稽核一定會問的問題，
半年後沒有人記得。

---

## 2. 標記的作用範圍

Analysis 是綁在 **專案（project）+ 版本（version）+ 元件 + 弱點** 上的。

我們的 SBOM 上傳規則是：

```
專案名 = GitLab 專案名稱
版本   = 分支名稱
```

所以：

```
bcp-scripts : main               ← 在這裡標的例外
bcp-scripts : fix/bump-crypto    ← 不保證會自動套用到這裡
```

**功能分支的 MR 還是紅的話**，先確認 job log 裡印的是哪一個
`專案名:版本`，到**那一個** version 上標記。

> 📌 部署前建議在自己的環境實測一次：
> 在 `main` 標記後，開一個功能分支跑 MR，看那個 version 是不是也綠了。
> 結果如果是「會自動繼承」，這一節可以簡化；
> 如果是「不會」，就把「合併前要在該分支的 version 再標一次」寫進團隊流程。

---

## 3. Team 權限對照

**UI 路徑**：`Administration → Access Management → Teams`

### CI 用的 team（`System SBOM Uploaders`）

| 權限 | 用途 |
|---|---|
| `BOM_UPLOAD` | 上傳 SBOM |
| `VIEW_PORTFOLIO` | 查專案 UUID |
| `VIEW_VULNERABILITY` | 讀弱點數量與 findings 清單 |
| `PROJECT_CREATION_UPLOAD` | `autoCreate=true` 自動建專案 |
| **`VULNERABILITY_ANALYSIS`** | **自動放行 OS 層套件**（`ci/dtrack_suppress_os.sh`） |

> ⚠️ **`VULNERABILITY_ANALYSIS` 給 CI 是一個刻意的取捨。**
>
> 它是「能讓紅燈變綠燈」的權限，一般不該給自動化。我們給它，是因為：
>
> 1. **範圍寫死在程式碼裡**：`ci/dtrack_suppress_os.sh` 只處理
>    `pkg:deb/`、`pkg:rpm/`、`pkg:apk/` 三種 purl，
>    `pkg:pypi/` 這些「我們自己選的套件」一律不碰
> 2. **改那份程式碼要走 MR**，而 `ci/` 底下的檔案由 Maintainer 把關
> 3. **每一筆自動放行都在 Details 留下完整說明**（規則出處、時間、pipeline 連結）
>
> 不接受這個授權的話，設 `DTRACK_OS_SUPPRESS=0` 關掉自動放行，
> 這個權限就可以拿掉——代價是每次掃描被幾百個 OS 弱點淹沒。

**不要**給：

| 權限 | 為什麼不給 |
|---|---|
| `PORTFOLIO_MANAGEMENT` | CI 不需要能刪專案 |
| `ACCESS_MANAGEMENT` | CI 不需要能改權限 |
| `SYSTEM_CONFIGURATION` | CI 不需要能改系統設定 |

### 人用的 team ← 由 Keycloak 群組對應，不要手動加人

**權限統一在 Keycloak 管**：

```
Administration → Access Management → OpenID Connect Groups
  → 把 Keycloak 群組對應到 D-Track team
```

| Keycloak 群組 | D-Track Team | 權限 | 給誰 |
|---|---|---|---|
| `dai-viewer` | 唯讀 team | `VIEW_PORTFOLIO`、`VIEW_VULNERABILITY` | 一般開發人員、稽核 |
| `dai-security` | 資安 team | 上面兩個 + `VULNERABILITY_ANALYSIS` | 能決定標記例外的人（**人數要少**） |
| `dai-admin` | `Administrators` | 全部 | 系統管理員 |

> **「能把紅燈變綠燈」的權限要跟「能看」分開。**
> 人工標記例外是一個有安全影響的決定，應該只有少數幾個人做得到，
> 而且每一次都要有紀錄。

> ⚠️ **不要用 `Managed Users` 手動建帳號。**
> 那會變成一個不受 LDAP 管理的帳號，離職時不會被停用。
> `Managed Users` 底下應該只留救援用的 `admin`。

---

## 4. 完整權限清單（供設定時對照）

| 權限 | 大致作用 |
|---|---|
| `BOM_UPLOAD` | 上傳 SBOM |
| `VIEW_PORTFOLIO` | 看專案清單與詳情 |
| `VIEW_VULNERABILITY` | 看弱點資訊 |
| `VIEW_POLICY_VIOLATION` | 看政策違規 |
| `PROJECT_CREATION_UPLOAD` | 上傳時自動建專案 |
| `VULNERABILITY_ANALYSIS` | **標記 Analysis 狀態** |
| `POLICY_VIOLATION_ANALYSIS` | 標記政策違規的處理狀態 |
| `PORTFOLIO_MANAGEMENT` | 建立 / 修改 / 刪除專案 |
| `POLICY_MANAGEMENT` | 建立 / 修改政策 |
| `ACCESS_MANAGEMENT` | 管理 team、API Key、權限 |
| `SYSTEM_CONFIGURATION` | 改系統設定 |

> 權限項目會因 D-Track 版本略有增減，以你們實際版本的 UI 為準。

---

## 相關文件

- 弱掃紅燈處理流程 → [日常維運 · 04](../日常維運/04_弱掃紅燈與MR被卡住的解除流程.md)
- API Key 與門檻設定 → [進階調整 · 10](../進階調整/10_D-Track_專案_API_Key_與擋門門檻.md)
