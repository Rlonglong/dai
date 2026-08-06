# 13 · Variables 與環境隔離

**需求**：正式跟測試用同一個 GitLab，但**碰得到的東西完全不同**——
測試只能連測試 DB，正式才碰得到 VM1 / VM3 / VM4 / VM5。

---

## 1. 靠三件事達成，缺一不可

| 機制 | 做什麼 | 漏掉的後果 |
|---|---|---|
| **保護分支** | `main` 禁止直接 push，只能透過 MR 進來 | 任何人可以直接把程式碼推上正式機 |
| **Protected 變數** | 正式環境的連線資訊只有在**保護分支**上跑的 job 拿得到 | 隨便開個分支就能讀到正式 DB 密碼 |
| **Environment scope** | 同一個變數名在 `production` / `staging` 有不同值 | 得為每個環境取不同的變數名，容易寫錯 |

結果：

```
功能分支 / develop                 main（保護分支）
      │                                 │
      ▼                                 ▼
 staging scope 的變數              production scope 的變數
      │                                 │
      ▼                                 ▼
   測試 DB                          正式 DB
   測試機                        VM1 / VM3 / VM4 / VM5
```

**在功能分支上跑的 job 拿不到 production 變數**——不是「拿到但不該用」，
是 GitLab 根本不會注入。所以就算有人在測試分支寫了「rsync 到正式機」，
也會因為 `DEPLOY_HOST` 是空字串而在 `require_vars` 那一步直接失敗。

---

## 2. 建立 Environments

GitLab UI → 專案 → **Operate → Environments → New environment**

| Name | Deployment tier | 說明 |
|---|---|---|
| `production` | Production | 正式機 |
| `staging` | Staging | 測試機 |

名稱要跟 `.gitlab-ci.yml` 裡 `environment: name:` 寫的完全一致。

---

## 3. 設定 Variables

Settings → **CI/CD → Variables → Add variable**

### 每一個變數的三個必勾項

```
[✓] Protect variable      只有保護分支（main）上的 job 拿得到
[✓] Mask variable         值不會出現在 job log 裡
[  ] Expand variable reference   通常不用勾
Environment scope: production   或 staging
```

> ⚠️ **Mask 的限制**：GitLab 要求被 mask 的值至少 8 個字元、
> 且只能是 Base64 字元集（不能有空白、換行）。
> 私鑰這種多行內容 mask 不了 —— 所以私鑰要用 **File 型別**，
> File 型別的變數不會被 echo 到 log 裡。

### 兩個 repo 共同需要的

| Key | Type | Protected | Masked | production 值 | staging 值 |
|---|---|---|---|---|---|
| `DEPLOY_HOST` | Variable | ✅ | ✅ | VM4/VM1 正式 IP | 測試機 IP |
| `DEPLOY_USER` | Variable | ✅ | ❌ | `gitlab_runner` | `gitlab_runner` |
| `DEPLOY_SSH_KEY` | **File** | ✅ | —(File) | 正式機的私鑰 | 測試機的私鑰 |
| `DEPLOY_KNOWN_HOSTS` | **File** | ✅ | —(File) | 正式機 host key | 測試機 host key |
| `DTRACK_URL` | Variable | ✅ | ❌ | `https://dtrack.dai.post.gov.tw` | 同左 |
| `DTRACK_API_KEY` | Variable | ✅ | ✅ | D-Track API Key | 同左（或測試專用 key） |

> ★ **正式與測試一定要用不同的 SSH 金鑰對** ★
> 共用的話，拿到測試金鑰的人就能登入正式機，環境隔離等於沒做。

### `dagster-workspace` 專屬

| Key | Type | Protected | Masked | production | staging |
|---|---|---|---|---|---|
| `DTRACK_IMAGE` | Variable | ✅ | ❌ | `gitlab.dai.post.gov.tw:5050/<group>/dagster:v2.7` | 同左 |

`DEPLOY_PATH` 和 `POST_DEPLOY_CMD` 寫在 `.gitlab-ci.yml` 的 job `variables:` 裡
（那些不是機密，寫在版控裡比較看得出來部署到哪）。

### `bcp-scripts` 專屬

沒有額外的（它有 `requirements.txt`，SCA 不需要 `DTRACK_IMAGE`）。

---

## 4. 資料庫連線怎麼隔離

**這一點常被誤解**：CI/CD Variables 裡**沒有**資料庫密碼，也不該有。

DB 連線走的是各機器上的 `.env` 檔：

| 環境 | 檔案 | 誰建立 | 進版控？ |
|---|---|---|---|
| 正式 VM4 | `/data/deploy/workspace/dagster_workspace/dagster_code/.env` | 部署時人工建立 | ❌ |
| 正式 VM1 | `/home/bcp_runner/.env` | 部署時人工建立 | ❌ |
| 測試 VM4 | `/data/deploy_test/workspace/dagster_workspace/dagster_code/.env` | 同上 | ❌ |
| 測試 VM1 | 測試機的 `/home/bcp_runner/.env` | 同上 | ❌ |

這兩個檔案都在 `.gitignore` 和 `deploy_exclude.txt` 裡，
所以：**CD 不會傳、不會刪、也看不到它們**。

隔離是靠「**程式碼推到哪台機器，就吃那台機器的 `.env`**」達成的：

```
main 合併 → DEPLOY_HOST = 正式 VM4 → 程式碼落在正式 VM4 → 讀正式 VM4 的 .env → 正式 DB
develop  → DEPLOY_HOST = 測試 VM4 → 程式碼落在測試 VM4 → 讀測試 VM4 的 .env → 測試 DB
```

> 💡 這個設計的好處：**CI/CD 系統本身從來不持有資料庫密碼**。
> GitLab 被入侵也拿不到 DB 帳密，只拿得到 SSH 部署金鑰
> （那個要靠金鑰輪替與 `from=` 限制來降低影響）。

---

## 5. 驗證隔離真的有效

設定完務必跑一次。**沒驗證過的隔離等於沒有隔離。**

### 5-1. 功能分支拿不到 production 變數

暫時加一個 job：

```yaml
debug-vars:
  stage: lint
  tags: [vm3, ci]
  script:
    - echo "DEPLOY_HOST is [${DEPLOY_HOST:-<空>}]"
    - echo "CI_COMMIT_REF_PROTECTED = ${CI_COMMIT_REF_PROTECTED}"
  rules:
    - when: always
```

| 在哪跑 | 預期輸出 |
|---|---|
| 功能分支 | `DEPLOY_HOST is [<空>]`、`CI_COMMIT_REF_PROTECTED = false` |
| `main` | `DEPLOY_HOST is [[MASKED]]`、`CI_COMMIT_REF_PROTECTED = true` |

驗完**記得把這個 job 刪掉**。

### 5-2. Developer 看不到 Variables

用 Developer 權限的帳號進 Settings → CI/CD，
應該**看不到** Variables 區塊（那需要 Maintainer）。

### 5-3. Masked 真的有遮

看任何一個 job 的 log，搜尋你設的值。應該只看到 `[MASKED]`。

沒遮到的話，通常是值不符合 mask 的字元限制（有空白、太短）。
GitLab 在儲存時會警告，但如果當初忽略了警告，值就會裸奔在 log 裡。

### 5-4. 測試分支推不到正式機

在 `develop` 分支上手動觸發 `deploy:staging`，
確認 job log 裡的目標 IP 是**測試機**。

---

## 6. 常見的坑

| 症狀 | 原因 | 解法 |
|---|---|---|
| `main` 上的 deploy job 說「缺少必要的 CI/CD Variable」 | 變數勾了 Protected 但 `main` 沒設成保護分支 | Settings → Repository → Protected branches 加上 `main` |
| staging 的 job 拿到 production 的值 | Environment scope 設成 `*`（全部） | 改成明確的 `production` / `staging` |
| 值出現在 job log 裡 | 沒勾 Masked，或值不符合字元限制 | 補勾；多行內容改用 File 型別 |
| 改了變數但 job 還是拿到舊值 | pipeline 是舊的 | 重跑 pipeline（變數是執行當下才注入的） |
| File 型別變數的內容多了一個換行 | GitLab 會自動補結尾換行 | SSH 私鑰可以接受；`known_hosts` 也可以 |
| 私鑰權限錯誤 `UNPROTECTED PRIVATE KEY FILE` | File 變數落地的暫存檔權限是 644 | `ci/deploy_rsync.sh` 已經用 `install -m 600` 複製一份，不要改掉那行 |

---

## 7. 變數盤點表（建議印出來貼在交接本）

```
專案：dagster-workspace                     最後檢查：____/__/__

Key                  Type      Prot  Mask  Scope        最後輪替
-------------------  --------  ----  ----  -----------  ----------
DEPLOY_HOST          Variable   ✓     ✓    production   ____/__/__
DEPLOY_HOST          Variable   ✓     ✓    staging      ____/__/__
DEPLOY_USER          Variable   ✓     ✗    production   ____/__/__
DEPLOY_SSH_KEY       File       ✓     -    production   ____/__/__  ← 建議半年輪替
DEPLOY_SSH_KEY       File       ✓     -    staging      ____/__/__
DEPLOY_KNOWN_HOSTS   File       ✓     -    production   ____/__/__
DTRACK_URL           Variable   ✓     ✗    production   ____/__/__
DTRACK_API_KEY       Variable   ✓     ✓    production   ____/__/__  ← 建議半年輪替
DTRACK_IMAGE         Variable   ✓     ✗    production   ____/__/__
```

有人離職且曾經是 Maintainer 時，**上表所有 Masked / File 的項目都要輪替**
（Maintainer 有辦法把 masked 變數 echo 出來）。
見 [04_帳號_權限_分支保護 · 離職](../日常維運/04_帳號_權限_分支保護.md#離職--轉調)。
