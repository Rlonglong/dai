# 15 · Dependency-Track 與定期弱掃

套件弱點掃描（SCA）怎麼運作、每季的定期複掃怎麼設、掃出東西怎麼處理。

> D-Track 的**安裝**在部署手冊 Phase 3；這篇講的是**日後怎麼用它**。

---

## 1. 它在解決什麼問題

我們自己寫的程式碼有 flake8 / bandit 在管，但**真正的攻擊面大多在別人的程式碼裡** ——
`cryptography`、`pandas`、`pymssql` 這些套件，每一個都可能被公告 CVE。

Dependency-Track 的做法：

```
requirements.txt（或映像檔裡的套件清單）
        ↓  cyclonedx-py
      SBOM（bom.json）—— 一份「我用了哪些套件、哪個版本」的清單
        ↓  上傳
   Dependency-Track（VM3）
        ↓  比對 NVD / OSV / GitHub Advisory
   每個套件的 Critical / High / Medium / Low 數量
        ↓
   Critical / High > 0 → pipeline 紅燈，擋住合併
```

### 為什麼推送時掃過了還要定期掃

**因為弱點資料庫每天在長，但你的程式碼沒有變。**

```
2026-01-15  你 push 了 cryptography==49.0.0
            D-Track 掃描：0 Critical  ✅ 綠燈，合併上線

2026-03-02  某人公告 CVE-2026-XXXXX，影響 cryptography <= 49.1
            ← 你的程式碼一行都沒改，但它現在有一個 Critical 弱點
            ← 沒有任何 pipeline 會跑，沒有人會知道

2026-04-01  ★ 每季定期弱掃 ★ 用最新的資料庫重掃
            D-Track 掃描：1 Critical  ❌ 紅燈 → 有人去處理
```

D-Track 自己會持續重新評分，所以 3/2 那天它資料庫裡的數字其實就變了 ——
但**那只是一個沒有人會去看的網頁**。定期弱掃的價值是把它變成
「一次會紅燈的 pipeline」，有人收到通知、有紀錄可以拿給稽核看。

---

## 2. 兩種掃描的差別

| | 推送時（`sca-dtrack`） | 每季（`sca-dtrack-quarterly`） |
|---|---|---|
| 觸發 | MR / push / 合併 main | 排程（1/4/7/10 月 1 號 03:00） |
| 擋門標準 | **Critical + High** 就擋 | **Critical + High + Medium** 就擋 |
| 逾時等待 | 12 輪 × 5 秒 = 60 秒 | 36 輪 × 5 秒 = 3 分鐘 |
| artifacts 保留 | 1 週 | **1 年**（稽核用） |

**為什麼日常擋到 High、每季才擋 Medium？**

base image 的 OS 層套件（`glibc`、`libc-bin`…）已經由 `ci/dtrack_suppress_os.sh`
自動放行，所以擋到 High 不會灌爆數字；剩下的都是「我們自己選的套件」。

但如果連 Medium 也擋，一個不相干的套件出弱點會讓所有人的 MR 全部卡住，
最後大家會要求把這個 job 關掉 —— 那就什麼都沒有了。
所以日常擋到 High，**每季這一次專門用來清 Medium 的技術債**，
時間點固定、可以事先安排人力。

---

## 3. 設定每季排程

專案 → **Build → Pipeline schedules → New schedule**（兩個 repo 都要）

| 欄位 | 值 |
|---|---|
| Description | `每季定期弱掃（SCA + SAST + 全歷史 gitleaks）` |
| Interval Pattern | `0 3 1 */3 *` |
| Cron timezone | `Asia/Taipei` |
| Target branch | `main` |
| **Variables** | Key `SCHEDULE_TYPE` = Value `quarterly` |
| Activated | ✅ |

`0 3 1 */3 *` = **1、4、7、10 月的 1 號 03:00**。

選這個時間的理由：每季初、月初、凌晨三點（批次已經跑完，runner 閒著）。

> ⚠️ **`SCHEDULE_TYPE` 這個變數不能漏。**
> 每日對帳排程用的是 `SCHEDULE_TYPE=verify`。兩個排程都是
> `$CI_PIPELINE_SOURCE == "schedule"`，如果不用變數區分，
> 每天早上的對帳排程會把整套資安複掃也拉起來跑一遍
> （D-Track 每天被灌一次 SBOM），而每季的複掃又會去跑一次雜湊對帳。

### 每季這一跑會跑哪些 job

| Job | 做什麼 |
|---|---|
| `secret-scanning` | gitleaks 掃**全樹 + 全部 git 歷史** |
| `sast-bandit` | Python 資安規則 |
| `sca-dtrack-quarterly` | SBOM → D-Track → Critical/High/Medium 擋門 |

**不會**跑 deploy，也**不會**跑雜湊對帳（那是每日排程的事）。

---

## 4. 兩個 repo 的 SBOM 來源不一樣

`ci/build_sbom.sh` 會自動判斷：

| repo | 來源 | 為什麼 |
|---|---|---|
| `bcp-scripts` | `requirements.txt` | VM1 有自己的 venv，套件清單就在 repo 裡 |
| `dagster-workspace` | **映像檔**（`DTRACK_IMAGE` 變數） | 它的套件是烘焙在 `dai/dagster` 映像檔裡的，repo 裡沒有 requirements.txt |

`dagster-workspace` 要設這個變數：

```
Settings → CI/CD → Variables
  Key   : DTRACK_IMAGE
  Value : gitlab.dai.post.gov.tw:5050/<group>/<project>/dagster:v2.6
  Scope : production   （Protected ✅）
```

腳本會 `docker run <image> python -m pip freeze` 取得真實的套件清單再產 SBOM。

> 📌 **要掃的是「真正在跑的東西」。**
> 如果只掃 repo 裡的檔案，`dagster-workspace` 會掃出「零個套件」然後綠燈，
> 完全是假的 —— 真正在 VM4 上執行的那一堆套件一個都沒被檢查到。
>
> 所以兩者都沒有的時候，`build_sbom.sh` 是**直接讓 job 失敗**而不是跳過。
> 一個靜默跳過的資安掃描，比沒有掃描更危險。

### `bcp-scripts` 的 requirements.txt 要跟 VM1 一致

```bash
# 在 VM1
source /run/media/root/D/python_env/dai_venv/bin/activate
pip freeze > requirements.txt
```

然後走正常 MR 流程推上來。**不一致的話，掃的是紙上的環境，不是真正在跑的環境。**

---

## 5. 掃出弱點怎麼處理

> 👉 **完整的一步一步解除流程**（含 metrics 要 Refresh、例外綁在哪個 version、
> 緊急放行的做法與代價）在
> [D-Track與Superset手冊 · 04_弱掃紅燈與MR被卡住的解除流程](../../D-Track與Superset手冊/日常維運/04_弱掃紅燈與MR被卡住的解除流程.md)。
> 這一節只講重點。


pipeline 紅燈時，job log 長這樣：

```
=======================================
🛡️  資安掃描結果（bcp-scripts:main）
🔥 Critical : 1
🚨 High     : 3
⚠️  Medium   : 7
ℹ️  Low      : 12
   D-Track  : https://dtrack.dai.post.gov.tw/projects/a3f2b91c-...
=======================================
[FAIL]  偵測到 1 個 Critical 弱點 → 阻擋 Pipeline
```

### 步驟

1. **點那個 D-Track 連結**，看是哪個套件、哪個 CVE
2. 看 **Affected Versions** 與 **Fixed in**
3. 決定怎麼修：

| 情況 | 做法 |
|---|---|
| 有修補版本，升級不影響相容性 | 改 `requirements.txt` 的版本 → MR → 合併。**離線環境記得先把新版 wheel 帶進 VM1** |
| 有修補版本，但升級會壞 | 先在測試環境驗證，排時間升級。期間在 Redmine 開票追蹤 |
| 沒有修補版本 | 評估我們有沒有用到那個弱點路徑（見下方） |
| 確認用不到弱點功能 | 在 D-Track 標記 **Not Affected** 並寫理由（見下方） |

### 在 D-Track 標記例外

Project → Audit Vulnerabilities → 該弱點 → 設定 **Analysis**：

| 狀態 | 什麼時候用 |
|---|---|
| `Not Affected` | 我們沒有用到觸發弱點的那個功能 |
| `False Positive` | SBOM 認錯套件或版本 |
| `Resolved` | 已經升級修掉了 |
| `In Triage` | 還在評估（**這個不會解除擋門**） |

> ⚠️ **一定要在 Details 欄寫清楚理由。**
> 「為什麼我們不受這個 CVE 影響」是稽核一定會問的問題，
> 半年後沒有人記得。寫清楚是誰、什麼時候、根據什麼判斷的。
>
> 標成 `Not Affected` 之後那個弱點就不再列入擋門計數 —— 這是一個
> **會讓紅燈變綠燈的動作**，所以應該跟改程式碼一樣被審視。
> 建議規定：標記例外要在 MR 或 Redmine 上留紀錄，不是自己點一點就算。

---

## 6. 取得 D-Track API Key

1. 登入 `https://dtrack.dai.post.gov.tw`
2. **Administration → Access Management → Teams**
3. 建一個 team（例如 `gitlab-ci`），權限勾：

| 權限 | 為什麼需要 |
|---|---|
| `BOM_UPLOAD` | 上傳 SBOM |
| `VIEW_PORTFOLIO` | 查專案 UUID |
| `VIEW_VULNERABILITY` | 讀弱點數量 |
| `PROJECT_CREATION_UPLOAD` | `autoCreate=true` 自動建專案 |

**不要**給 `PORTFOLIO_MANAGEMENT` 或 `ACCESS_MANAGEMENT` ——
CI 只需要上傳與讀取，不需要能刪專案或改權限。

4. 在該 team 底下 **Create API Key**，複製後填進 GitLab：

```
Settings → CI/CD → Variables
  Key      : DTRACK_API_KEY
  Value    : odt_xxxxxxxxxxxx
  Protected: ✅
  Masked   : ✅
```

> 這把 key 也要納入輪替（建議半年一次，或有 Maintainer 離職時立刻換）。
> 見 [13_Variables與環境隔離 · 變數盤點表](./13_Variables與環境隔離.md#7-變數盤點表建議印出來貼在交接本)。

---

## 7. 專案在 D-Track 裡怎麼命名

`build_sbom.sh` 上傳時用：

```
projectName    = $CI_PROJECT_NAME       例：bcp-scripts
projectVersion = $CI_COMMIT_REF_NAME    例：main
```

所以 D-Track 上會看到 `bcp-scripts : main`、`dagster-workspace : main`，
以及各個功能分支的版本。

**功能分支的專案版本會越積越多**，建議每季複掃後順手清理：
Projects → 篩掉 `main` 以外、且最後更新超過三個月的版本 → Delete。

---

## 8. 常見問題

| 症狀 | 原因 | 解法 |
|---|---|---|
| `產不出 SBOM` | 沒有 `requirements.txt` 也沒設 `DTRACK_IMAGE` | 設 `DTRACK_IMAGE`（見第 4 節） |
| `上傳沒有拿到 token` | API Key 錯，或 team 少了 `BOM_UPLOAD` 權限 | 檢查權限勾選 |
| `查不到專案 UUID` | `autoCreate` 沒生效（缺 `PROJECT_CREATION_UPLOAD`） | 補權限，或先在 UI 手動建專案 |
| `等待 D-Track 分析逾時` | dtrack-server 忙或掛了 | `docker logs dtrack-server`；調高 `DTRACK_POLL_MAX` |
| 掃出一堆 Low/Medium 但沒擋門 | 設計如此 | 每季複掃會擋 Medium；Low 進 Redmine 排期 |
| 每季排程沒跑 | 忘了設 `SCHEDULE_TYPE=quarterly` | 到 Schedules 補變數 |
| 每季排程把對帳也跑了 | 同上，變數沒設對 | 兩個排程的變數不能一樣 |
| 升級套件後 VM1 跑不起來 | 離線環境沒有新版 wheel | 先把 wheel 帶進 `/run/media/root/D/python_env/req/` 再升級 |

---

## 9. 每季複掃的檢查清單

```
季度：____年 第__季      執行人：________

[ ] 排程有自動觸發（Pipelines 篩 Schedules）
[ ] secret-scanning 綠燈
[ ] sast-bandit 綠燈
[ ] sca-dtrack-quarterly 結果：
        dagster-workspace  Critical ___  High ___  Medium ___
        bcp-scripts        Critical ___  High ___  Medium ___
[ ] 紅燈的項目已建立 Redmine 追蹤票：____________
[ ] 標為 Not Affected 的弱點都有寫理由
[ ] bom.json artifact 已下載存檔（稽核用）
[ ] 順手清掉 D-Track 上三個月沒更新的分支版本
```

---

## 相關文件

- **解除流程（紅燈了怎麼辦）** → [D-Track與Superset手冊 · 04](../../D-Track與Superset手冊/日常維運/04_弱掃紅燈與MR被卡住的解除流程.md)
- D-Track 網頁怎麼看 → [D-Track與Superset手冊 · 03](../../D-Track與Superset手冊/日常維運/03_D-Track_看懂弱點報告.md)

- CI 各 job 說明 → [10_CI_Pipeline設定詳解](./10_CI_Pipeline設定詳解.md)
- 變數怎麼設 → [13_Variables與環境隔離](./13_Variables與環境隔離.md)
- 排查 → [14_疑難排解](./14_疑難排解.md)
