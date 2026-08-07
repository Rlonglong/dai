# 10 · D-Track · 專案、API Key 與擋門門檻

> 對象：**要調整 CI 設定或 D-Track 設定的人**。
> 改之前先看懂現在的邏輯——這幾個設定改錯會讓資安掃描靜默失效。

---

## 1. 專案怎麼命名（不要手動改）

`ci/build_sbom.sh` 上傳 SBOM 時用這兩個值：

```bash
PROJECT_NAME="${CI_PROJECT_NAME}"          # GitLab 專案名稱
PROJECT_VERSION="${CI_COMMIT_REF_NAME}"    # 分支名稱
```

搭配 `autoCreate=true`，**專案不存在時 D-Track 會自動建**。

所以 D-Track 上會長出這些：

```
bcp-scripts : main                  ← 正式機在跑的那一版
bcp-scripts : fix/bump-crypto       ← 某個 MR
dagster-workspace : main
dagster-workspace : feature/xxx
```

> ⚠️ **不要在 D-Track 網頁上手動改專案名稱或版本。**
> 下次 CI 跑的時候會照原本的名字再建一個新的，你會得到兩份、而且只有一份是活的。

**清理舊分支的專案**：合併後的功能分支專案不會自己消失，
半年清一次即可（Projects → 勾選 → Delete），不影響 `main`。

---

## 2. API Key

### 建立

```
Administration → Access Management → Teams → + Create Team
  Name: gitlab-ci
```

權限**只勾這四個**（最小權限）：

| 權限 | 為什麼需要 |
|---|---|
| `BOM_UPLOAD` | 上傳 SBOM |
| `VIEW_PORTFOLIO` | 查專案 UUID |
| `VIEW_VULNERABILITY` | 讀弱點數量 |
| `PROJECT_CREATION_UPLOAD` | `autoCreate=true` 自動建專案 |

**不要**給 `PORTFOLIO_MANAGEMENT` 或 `ACCESS_MANAGEMENT`——
CI 只需要上傳與讀取，不需要能刪專案或改權限。

然後在該 team 底下 **Create API Key**。

> 📸 **待補截圖**：Teams 頁面的權限勾選清單，以及 Create API Key 的位置。

### 填進 GitLab

```
每個 repo → Settings → CI/CD → Variables
  DTRACK_URL      = https://dtrack.dai.post.gov.tw    （Protected）
  DTRACK_API_KEY  = odt_xxxxxxxx                       （Protected + Masked）
```

`dagster-workspace` 還要多一個：

```
  DTRACK_IMAGE = gitlab.dai.post.gov.tw:5050/<group>/<project>/dagster:v2.7
```

### 輪替

API Key 外洩或人員異動時：

1. D-Track 上該 team → 刪掉舊 Key → Create 新的
2. 更新兩個 repo 的 `DTRACK_API_KEY` variable
3. 手動觸發一次 pipeline 確認還能上傳

---

## 3. 調整擋門門檻

門檻由 `ci/build_sbom.sh` 的兩個環境變數控制：

| 變數 | 預設 | 效果 |
|---|---|---|
| （無條件） | — | **Critical > 0 一律擋**，不能關 |
| `DTRACK_FAIL_ON_HIGH` | `0` | 設 `1` 時 **High > 0 也擋** |
| `DTRACK_POLL_MAX` | `12` | 等分析完成的輪數（每輪 5 秒） |

現在的設定寫在 `.gitlab-ci.yml`：

```yaml
sca-dtrack:                    # 推送 / MR 時跑
  script: [ci/build_sbom.sh]   # 不設 DTRACK_FAIL_ON_HIGH → 只擋 Critical

sca-dtrack-quarterly:          # 每季排程 / 手動
  variables:
    DTRACK_FAIL_ON_HIGH: "1"   # ← High 也擋
    DTRACK_POLL_MAX: "36"      # ← 全量重新分析比較慢，給到 180 秒
```

### 想讓 High 也擋住日常 MR

在 `sca-dtrack` 加上同樣的變數：

```yaml
sca-dtrack:
  variables:
    DTRACK_FAIL_ON_HIGH: "1"
```

> ⚠️ **先想清楚再改。** 日常不擋 High 是刻意的決定：
> 一個不相干的套件出 High 就讓所有人的 MR 全卡住，
> 最後的結果通常不是「大家都很認真修弱點」，
> 而是「有人來要求把這個 job 關掉」——那就什麼都沒有了。
>
> 建議先連續兩季把 High 清到接近 0，再考慮打開。

### 想暫時放寬（緊急）

**不要改檔案**，用手動觸發時帶變數：

```
Run pipeline → Variables → DTRACK_FAIL_ON_HIGH = 0
```

只影響那一次執行，不會留下永久的設定漏洞。
放行的原則與必須留的紀錄見
[日常維運 · 04 · 第 7 節](../日常維運/04_弱掃紅燈與MR被卡住的解除流程.md#7-緊急放行最後手段)。

---

## 4. 兩個 repo 的 SBOM 來源

| repo | 來源 | 判斷方式 |
|---|---|---|
| `bcp-scripts` | `requirements.txt` | repo 裡有這個檔案就用它 |
| `dagster-workspace` | 映像檔 `$DTRACK_IMAGE` | repo 裡沒有 requirements.txt，改抓映像檔裡的套件清單 |

兩個都沒有的話，`ci/build_sbom.sh` **直接讓 job 失敗**：

```
產不出 SBOM：repo 裡沒有 requirements.txt，也沒有設定 DTRACK_IMAGE。
```

> 📌 **這是刻意的，不要改成「跳過」。**
> 只掃 repo 裡的檔案的話，`dagster-workspace` 會掃出「零個套件」然後綠燈——
> 完全是假的，真正在 VM4 上跑的那一堆套件一個都沒被檢查到。
> **一個靜默跳過的資安掃描，比沒有掃描更危險。**

### `bcp-scripts` 的 requirements.txt 要跟 VM1 一致

```bash
# 在 VM1
source /run/media/root/D/python_env/dai_venv/bin/activate
python -m pip freeze > requirements.txt
```

走正常 MR 流程推上來。**不一致的話，掃的是紙上的環境，不是真正在跑的環境。**

---

## 5. 每季排程設定

兩個 repo **各建兩個排程**（共四個）。這裡只講弱掃那個，
雜湊對帳那個見 [GitLab維運手冊 · 12](../../../gitlab_workspace/GitLab維運手冊/進階調整/12_同步完整性稽核.md)。

```
GitLab UI → Build → Pipeline schedules → New schedule
```

| 欄位 | 值 |
|---|---|
| Description | `每季定期弱掃` |
| Interval Pattern | `0 3 1 */3 *` ← 1/4/7/10 月的 1 號 03:00 |
| Cron timezone | `Asia/Taipei` |
| Target branch | `main` |
| **Variables** | `SCHEDULE_TYPE` = `quarterly` |
| Activated | ✅ |

> ⚠️ **`SCHEDULE_TYPE` 不能漏、不能跟每日對帳排程設成一樣。**
> 兩者都是 `$CI_PIPELINE_SOURCE == "schedule"`，沒有變數區分的話，
> 每天早上的對帳排程會把整套資安複掃也拉起來跑（D-Track 每天被灌一次 SBOM），
> 每季的弱掃又會多跑一次雜湊對帳。

### 驗證排程設定正確

不要等三個月。設完之後直接手動跑一次：

```
Pipeline schedules → 該排程右邊的 ▶ (Play) 按鈕
  → 確認只有 sca-dtrack-quarterly 跑起來
  → 確認 verify job 沒有被拉起來
```

---

## 6. artifacts 保留期限

| job | 保留 | 為什麼 |
|---|---|---|
| `sca-dtrack` | 1 週 | 日常用，過期就沒意義 |
| `sca-dtrack-quarterly` | **1 年** | **稽核用**：要能證明某季掃過、掃到什麼 |

`bom.json` 是那次掃描的完整套件清單，稽核問「去年 Q3 你們用的是哪一版」時，
這是唯一拿得出來的證據。**不要為了省空間把它改短。**

---

## 相關文件

- 掃出東西怎麼處理 → [日常維運 · 04](../日常維運/04_弱掃紅燈與MR被卡住的解除流程.md)
- 弱點報告怎麼看 → [日常維運 · 03](../日常維運/03_D-Track_看懂弱點報告.md)
- CI pipeline 全貌 → [GitLab維運手冊 · 10_CI_Pipeline設定詳解](../../../gitlab_workspace/GitLab維運手冊/進階調整/10_CI_Pipeline設定詳解.md)
- 弱掃設計理由 → [GitLab維運手冊 · 15_D-Track定期弱掃](../../../gitlab_workspace/GitLab維運手冊/進階調整/15_D-Track定期弱掃.md)
