# DAI 文件總索引

這個資料夾放**所有維運文件**。

> 📌 為什麼文件在這裡，而不是跟程式碼放在一起？
> `dagster_workspace/` 整個資料夾會被 CD 用 rsync 推到 VM4，
> 手冊與截圖不是執行期需要的東西，留在裡面只會讓部署包變大、
> 也會把內部文件推到正式機上。
> 所以文件全部集中在 `docs/`，**不進部署範圍**。

---

## 三份文件，各回答不同的問題

| 你想知道 | 看哪一份 |
|---|---|
| **這套系統怎麼從零建起來？** | [部署手冊（repo 根目錄 README.md）](../README.md) |
| **資料流程怎麼運作？我要改一支模型怎麼改？** | [Dagster 維運手冊](./Dagster維運手冊/README.md) |
| **改完怎麼安全地送上正式機？** | [GitLab 維運手冊](./GitLab維運手冊/README.md) |

```
從零建置              日常改東西              把改動送上線
   │                     │                      │
部署手冊    ─────▶  Dagster維運手冊  ─────▶  GitLab維運手冊
README.md            docs/Dagster維運手冊/     docs/GitLab維運手冊/
（一次性）            （天天用）                （天天用）
```

---

## 依角色

### 我是維運人員（每天監控）

1. [Dagster維運手冊 · 00_系統架構總覽](./Dagster維運手冊/00_系統架構總覽.md) — 先建立全貌
2. [Dagster維運手冊 · 01_維運人員_每日操作手冊](./Dagster維運手冊/日常維運/01_維運人員_每日操作手冊.md) — 每天看排程
3. [GitLab維運手冊 · 02_維運人員_每日檢查](./GitLab維運手冊/日常維運/02_維運人員_每日檢查.md) — 每天看 pipeline 與雜湊對帳

### 我是開發人員（改模型、加資料表）

1. [Dagster維運手冊 · 00_系統架構總覽](./Dagster維運手冊/00_系統架構總覽.md)
2. [Dagster維運手冊 · 01_資料夾結構說明](./Dagster維運手冊/01_資料夾結構說明.md)
3. [GitLab維運手冊 · 03_本地環境設定與提交前檢查](./GitLab維運手冊/日常維運/03_本地環境設定與提交前檢查.md) — **新機器第一件事**
4. [GitLab維運手冊 · 01_開發人員_日常開發流程](./GitLab維運手冊/日常維運/01_開發人員_日常開發流程.md)
5. 然後依你要做的事查 [Dagster維運手冊 · 日常維運](./Dagster維運手冊/README.md#日常維運)

### 我是系統／GitLab 管理員

1. [部署手冊](../README.md)
2. [GitLab維運手冊 · 00_架構與同步機制總覽](./GitLab維運手冊/00_架構與同步機制總覽.md)
3. [GitLab維運手冊 · 附錄 A · gitlab_runner 帳號與 SSH 金鑰](./GitLab維運手冊/附錄/A_gitlab_runner帳號與SSH金鑰.md)
4. [GitLab維運手冊 · 進階調整](./GitLab維運手冊/README.md#進階調整) 全部

---

## 資料夾結構

```
docs/
├── README.md                    ← 你正在看的這份
│
├── Dagster維運手冊/              ← 系統怎麼運作、怎麼改
│   ├── README.md
│   ├── 00_系統架構總覽.md
│   ├── 01_資料夾結構說明.md
│   ├── 日常維運/                 ← 照著做就好（含截圖）
│   ├── 進階調整/                 ← 要改程式碼才能達成
│   └── 附錄/
│
└── GitLab維運手冊/               ← 版控、CI/CD、同步、資安
    ├── README.md
    ├── 00_架構與同步機制總覽.md
    ├── 日常維運/
    ├── 進階調整/
    └── 附錄/
```

---

## 相關的非文件檔案

| 位置 | 內容 |
|---|---|
| [`.gitlab-ci.yml`](../.gitlab-ci.yml) | CI/CD pipeline 定義 |
| [`ci/`](../ci/) | pipeline 與 git hook 用的腳本 |
| [`deploy/`](../deploy/) | 要安裝到 VM1 / VM4 上的 post-deploy 腳本 |
| [`deploy_exclude.txt`](../deploy_exclude.txt) | rsync 排除／刪除保護清單 |
| [`.gitignore`](../.gitignore) | 版控排除清單 |
| [`.gitleaks.toml`](../.gitleaks.toml) | 機密偵測規則（本地 hook / 伺服器 hook / CI 共用同一份） |
| [`gitlab_templates/bcp_scripts_repo/`](../gitlab_templates/bcp_scripts_repo/) | 建立 `bcp-scripts` repo 的範本 |
