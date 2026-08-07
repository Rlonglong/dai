# 截圖索引

這個資料夾放 D-Track 與 Superset 手冊用的截圖。
命名規則比照 `docs/Dagster維運手冊/日常維運/images/`：`<兩位數編號>_<用途>.png`。

編號分段：**01–08 給 D-Track、11–17 給 Superset**，中間留空號方便日後插入。

擷取時的版本：**Dependency-Track v4.14.2**、**Apache Superset 6.1.0**。

---

## D-Track

| 檔名 | 畫面 | 用在哪 |
|---|---|---|
| `01_dtrack_login.png` | 登入頁，紅框是 **OpenID**（Keycloak SSO）按鈕；`admin` 藏在 More options | [03 · 第 1 節](../03_D-Track_看懂弱點報告.md#1-登入) |
| `02_dtrack_dashboard.png` | 全域 Dashboard，紅框是各嚴重度分佈 | [03 · 第 5 節](../03_D-Track_看懂弱點報告.md#5-維運人員每天每季看什麼) |
| `03_dtrack_collection_overview.png` | Collection Project「Infra Vulnerability Track」的 Overview | [03 · 第 6 節](../03_D-Track_看懂弱點報告.md#6-基礎設施映像檔也在掃collection-project) |
| `04_dtrack_collection_projects.png` | 同上的 Collection Projects 清單（`dt_apiserver:v2.1`、`gitlab:v1.3`） | [03 · 第 6 節](../03_D-Track_看懂弱點報告.md#6-基礎設施映像檔也在掃collection-project) |
| `05_dtrack_audit_vulnerabilities.png` | 專案的 Audit Vulnerabilities 清單，含 Component / Severity / Analyzer / Analysis / Suppressed 欄與 Reanalyze 按鈕 | [03 · 第 4 節](../03_D-Track_看懂弱點報告.md#4-進到一個專案要看什麼)、[04 · 第 4 節](../04_弱掃紅燈與MR被卡住的解除流程.md#4--看懂是什麼) |
| `06_dtrack_vulnerability_detail.png` | 單一 CVE 詳情頁，Overview 文末寫著修補版本 | [03 · 第 4 節](../03_D-Track_看懂弱點報告.md#4-進到一個專案要看什麼)、[04 · 第 4 節](../04_弱掃紅燈與MR被卡住的解除流程.md#4--看懂是什麼) |
| `07_dtrack_refresh_metrics.png` | Overview 上 `Last Measurement` 旁的 ⟳ 重算圖示（紅框），與「A refresh has been requested」提示 | [03 · 第 7 節](../03_D-Track_看懂弱點報告.md#7-三個容易誤解的地方) |
| `08_dtrack_teams.png` | Administration → Access Management → Teams，含 `System SBOM Uploaders` | [進階調整 · 10 · 第 2 節](../../進階調整/10_D-Track_專案_API_Key_與擋門門檻.md#2-api-key) |

## Superset

| 檔名 | 畫面 | 用在哪 |
|---|---|---|
| `11_superset_login.png` | 登入頁，紅框是 **Sign in with Keycloak** | [01 · 第 1 節](../01_Superset_使用手冊.md#1-登入) |
| `12_superset_dashboard.png` | 一個 Dashboard（Big Number / Bar Chart / Pivot Table） | [01 · 第 3 節](../01_Superset_使用手冊.md#3-看別人做好的-dashboard) |
| `13_superset_sqllab.png` | SQL Lab，紅框是上方 **SQL** 選單（SQL Lab / Saved Queries / Query History） | [01 · 第 4 節](../01_Superset_使用手冊.md#4-用-sql-lab-查資料) |
| `14_superset_chart_editor.png` | Chart 編輯畫面，紅框是 X-axis / Metrics / Dimensions / Update chart / Save | [01 · 第 5-2 節](../01_Superset_使用手冊.md#5-2-選圖表類型並拉欄位) |
| `15_superset_dashboard_edit.png` | Dashboard 編輯模式，右側 Charts / Layout elements 面板 | [01 · 第 6 節](../01_Superset_使用手冊.md#6-做一個-dashboard) |
| `16_superset_new_dataset.png` | New dataset 頁，Database / Schema / Table 三個下拉 | [01 · 第 5-1 節](../01_Superset_使用手冊.md#5-1-先有-dataset) |
| `17_superset_list_roles.png` | Settings → Security → List Roles，右側是完整 Settings 選單 | [02 · 第 3 節](../02_Superset_資料庫連線與權限.md#3-權限模型) |

---

## 補新截圖時

1. **去識別化**：不可以有真實個資、帳號、IP、API Key、密碼
2. **解析度**：寬度 1400px 上下即可，不要整個 4K 螢幕截下來
3. **標註**：用紅框標出「要看的那一個」，不要整張圖丟上來
4. **編號**：D-Track 接 `09`、Superset 接 `18`；插在中間的話後面的要一起改
5. **同步更新**：本檔的表格、文件裡的 「圖片語法那一行」，以及圖說文字
6. **版本**：UI 會隨版本改。升級 D-Track / Superset 之後回來看這份，
   確認哪些畫面要重截，並更新本檔開頭記的版本號
