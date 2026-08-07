# 截圖清單

這個資料夾放 D-Track 與 Superset 手冊用的截圖。
命名規則比照 `docs/Dagster維運手冊/日常維運/images/`：`<兩位數編號>_<用途>.png`。

---

## 待補清單

在文件裡已經用 `📸 **待補截圖**` 標好位置了，補上圖之後把那行換成
`![說明](./images/<檔名>.png)` 這種寫法。

### D-Track

| 編號 | 檔名 | 畫面 | 要標出來的東西 | 用在哪 |
|---|---|---|---|---|
| 01 | `01_dtrack_login.png` | 登入頁 | **Login with OpenID Connect** 按鈕 | [03 · 第 1 節](../03_D-Track_看懂弱點報告.md#1-登入) |
| 02 | `02_dtrack_project_overview.png` | 專案 Overview | Critical / High / Medium / Low 四個數字、趨勢圖 | [03 · 第 4 節](../03_D-Track_看懂弱點報告.md#4-進到一個專案要看什麼) |
| 03 | `03_dtrack_audit_list.png` | Audit Vulnerabilities 清單 | Component / Vulnerability / Severity / Analysis 四欄 | [03 · 第 4 節](../03_D-Track_看懂弱點報告.md#4-進到一個專案要看什麼)、[04 · 第 3 節](../04_弱掃紅燈與MR被卡住的解除流程.md#3--看懂是什麼) |
| 04 | `04_dtrack_vuln_detail.png` | 單筆弱點右側詳情面板 | **Fixed in** 欄位、Analysis 下拉、Details 輸入框、Suppress 勾選 | [04 · 路線 B](../04_弱掃紅燈與MR被卡住的解除流程.md#路線-b在-d-track-標記例外) |
| 05 | `05_dtrack_refresh_metrics.png` | 專案頁右上 ⋮ 選單 | **Refresh Metrics** 選項 | [04 · 第 5 節](../04_弱掃紅燈與MR被卡住的解除流程.md#5--讓-d-track-重算最常卡住的一步) |
| 06 | `06_dtrack_team_permissions.png` | Administration → Teams | 權限勾選清單、Create API Key 按鈕 | [進階調整 · 10 · 第 2 節](../../進階調整/10_D-Track_專案_API_Key_與擋門門檻.md#2-api-key) |

### Superset

| 編號 | 檔名 | 畫面 | 要標出來的東西 | 用在哪 |
|---|---|---|---|---|
| 11 | `11_superset_home.png` | 登入後首頁 | Dashboard 清單、上方選單列 | [01 · 第 1 節](../01_Superset_使用手冊.md#1-登入) |
| 12 | `12_superset_dashboard.png` | 一個 Dashboard | 篩選器、圖表右上 ⋮ 選單、☆ 最愛 | [01 · 第 3 節](../01_Superset_使用手冊.md#3-看別人做好的-dashboard) |
| 13 | `13_superset_sqllab.png` | SQL Lab | Database / Schema 下拉、Run 按鈕、結果區、Download to CSV | [01 · 第 4 節](../01_Superset_使用手冊.md#4-用-sql-lab-查資料) |
| 14 | `14_superset_chart_editor.png` | Chart 編輯畫面 | Metrics / Dimensions / Filters / Time range、Save | [01 · 第 5-2 節](../01_Superset_使用手冊.md#5-2-選圖表類型並拉欄位) |
| 15 | `15_superset_dashboard_edit.png` | Dashboard 編輯模式 | 右側 Charts 拖曳區、Add/Edit Filters | [01 · 第 6 節](../01_Superset_使用手冊.md#6-做一個-dashboard) |
| 16 | `16_superset_db_connection.png` | Database Connections + Database 對話框 | **Test Connection** 按鈕、Advanced 分頁 | [02 · 第 1-2 節](../02_Superset_資料庫連線與權限.md#1-2-在-superset-建立連線) |
| 17 | `17_superset_role_perms.png` | List Roles 的權限編輯 | `datasource access on [db].[dataset]` 這種項目長什麼樣 | [02 · 第 3-2 節](../02_Superset_資料庫連線與權限.md#3-2-讓-gamma-使用者看得到特定資料) |

---

## 截圖注意事項

1. **去識別化**：截圖裡不可以有真實的個資、帳號、IP、API Key、密碼。
   測試資料或打碼都可以。
2. **解析度**：寬度 1400px 上下即可，不要整個 4K 螢幕截下來。
3. **標註**：用紅框或紅箭頭標出「要看的那一個」，不要整張圖丟上來。
4. **版本**：UI 會隨版本改。截圖時在檔名或文件旁註明版本，
   之後升級才知道哪些要重截。
