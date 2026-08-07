# DAI 文件總索引

這個資料夾放**所有維運文件**。

> 📌 為什麼文件在這裡，而不是跟程式碼放在一起？
> `dagster_workspace/` 整個資料夾會被 CD 用 rsync 推到 VM4，
> 手冊與截圖不是執行期需要的東西，留在裡面只會讓部署包變大、
> 也會把內部文件推到正式機上。
> 所以文件全部集中在 `docs/`，**不進部署範圍**。

---

## 四份文件，各回答不同的問題

| 你想知道 | 看哪一份 |
|---|---|
| **這套系統怎麼從零建起來？** | [部署手冊（repo 根目錄 README.md）](../README.md) |
| **資料流程怎麼運作？我要改一支模型怎麼改？** | [Dagster 維運手冊](./Dagster維運手冊/README.md) |
| **改完怎麼安全地送上正式機？** | [GitLab 維運手冊](./GitLab維運手冊/README.md) |
| **弱點掃描紅燈怎麼解？報表怎麼做？** | [D-Track 與 Superset 手冊](./D-Track與Superset手冊/README.md) |
| **東西壞了怎麼救回來？** | [DAI 備份與災難復原手冊](./DAI%20備份與災難復原手冊/) |

```
從零建置              日常改東西              把改動送上線
   │                     │                      │
部署手冊    ─────▶  Dagster維運手冊  ─────▶  GitLab維運手冊
README.md            docs/Dagster維運手冊/     docs/GitLab維運手冊/
（一次性）            （天天用）                （天天用）
                                                    │
                                          資安擋門了 / 要看報表
                                                    ▼
                                        D-Track與Superset手冊
                                        docs/D-Track與Superset手冊/
```

---

## 依角色

### 我是維運人員（每天監控）

1. [Dagster維運手冊 · 00_系統架構總覽](./Dagster維運手冊/00_系統架構總覽.md) — 先建立全貌
2. [Dagster維運手冊 · 01_維運人員_每日操作手冊](./Dagster維運手冊/日常維運/01_維運人員_每日操作手冊.md) — 每天看排程
3. [GitLab維運手冊 · 02_維運人員_每日檢查](./GitLab維運手冊/日常維運/02_維運人員_每日檢查.md) — 每天看 pipeline 與雜湊對帳
4. [D-Track與Superset手冊 · 03_D-Track_看懂弱點報告](./D-Track與Superset手冊/日常維運/03_D-Track_看懂弱點報告.md) — 每天確認 main 的 Critical 是 0

### 我是開發人員（改模型、加資料表）

1. [Dagster維運手冊 · 00_系統架構總覽](./Dagster維運手冊/00_系統架構總覽.md)
2. [Dagster維運手冊 · 01_資料夾結構說明](./Dagster維運手冊/01_資料夾結構說明.md)
3. [GitLab維運手冊 · 03_本地環境設定與提交前檢查](./GitLab維運手冊/日常維運/03_本地環境設定與提交前檢查.md) — **新機器第一件事**
4. [GitLab維運手冊 · 01_開發人員_日常開發流程](./GitLab維運手冊/日常維運/01_開發人員_日常開發流程.md)
5. 然後依你要做的事查 [Dagster維運手冊 · 日常維運](./Dagster維運手冊/README.md#日常維運)
6. MR 被資安掃描擋住時 → [D-Track與Superset手冊 · 04_弱掃紅燈與MR被卡住的解除流程](./D-Track與Superset手冊/日常維運/04_弱掃紅燈與MR被卡住的解除流程.md)

### 我是業務單位（只是要看報表）

1. [D-Track與Superset手冊 · 01_Superset_使用手冊](./D-Track與Superset手冊/日常維運/01_Superset_使用手冊.md)

### 我是系統／GitLab 管理員

1. [部署手冊](../README.md)
2. [GitLab維運手冊 · 00_架構與同步機制總覽](./GitLab維運手冊/00_架構與同步機制總覽.md)
3. [GitLab維運手冊 · 附錄 A · gitlab_runner 帳號與 SSH 金鑰](./GitLab維運手冊/附錄/A_gitlab_runner帳號與SSH金鑰.md)
4. [GitLab維運手冊 · 進階調整](./GitLab維運手冊/README.md#進階調整) 全部
5. [DAI 備份與災難復原手冊](./DAI%20備份與災難復原手冊/) — **建置完成後就該讀，不要等到出事**

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
├── D-Track與Superset手冊/        ← 弱點掃描與報表這兩套 UI 系統
│   ├── README.md
│   ├── 00_兩套系統總覽.md
│   ├── 日常維運/                 ← 照著做就好（含截圖）
│   ├── 進階調整/
│   └── 附錄/
│
├── DAI 備份與災難復原手冊/        ← 各服務的備份與復原程序
│   ├── 01. GitLab 備援與復原文件.md
│   ├── 02. Superset 備援與復原文件.md
│   ├── 03. Keycloak 備援與復原文件.md
│   └── 04. Dependency-Track 備援與復原文件.md
│
└── GitLab維運手冊/               ← 版控、CI/CD、同步稽核、資安檢查
    ├── README.md
    ├── 00_架構與同步機制總覽.md
    ├── 日常維運/
    ├── 進階調整/
    └── 附錄/
```

> 📌 **所有手冊都集中在 `docs/`。**
> 兩個 workspace 目錄各有各的部署命運——`dagster_workspace/` 會被 CD 用 rsync
> 持續同步到 VM4，`gitlab_workspace/` 會被打包進 VM3 的部署包——
> 手冊放在裡面就會跟著被推到正式機上，而且散在兩個地方也不好找。
> 所以文件一律放 `docs/`，**不進任何部署範圍**。

---

## 相關的非文件檔案

> 📌 **這個 repo 不會被直接執行。** CI/CD 素材集中在
> [`cicd_template/`](../cicd_template/README.md)，
> 用 `install.sh` 複製到 GitLab 上真正在跑的兩個 repo。

| 位置 | 內容 |
|---|---|
| [`cicd_template/`](../cicd_template/README.md) | **CI/CD 素材總集**，含 `install.sh` 一次複製到目標 repo |
| [`cicd_template/common/ci/`](../cicd_template/common/ci) | pipeline 與 git hook 用的腳本（兩個 repo 共用） |
| [`cicd_template/common/.gitleaks.toml`](../cicd_template/common/.gitleaks.toml) | 機密偵測規則（本機 hook / 伺服器 hook / CI 共用同一份） |
| [`cicd_template/dagster-workspace/`](../cicd_template/dagster-workspace) | `dagster-workspace` repo 專屬：`.gitlab-ci.yml`、`.gitignore`、`deploy_exclude.txt` |
| [`cicd_template/bcp-scripts/`](../cicd_template/bcp-scripts) | `bcp-scripts` repo 專屬：同上 + `requirements.txt` |
| [`gitlab_workspace/server_hooks/pre-receive`](../gitlab_workspace/server_hooks/pre-receive) | 裝在 VM3 GitLab 容器裡的伺服器端 hook |
| [`gitlab_workspace/post_deploy/`](../gitlab_workspace/post_deploy) | 要安裝到 VM1 / VM4 上的 post-deploy 腳本 |
| [`dagster_workspace/`](../dagster_workspace) | Dagster 程式與 dbt 專案（會被 CD rsync 到 VM4） |
| [`.gitignore`](../.gitignore) | **本 repo 自己的**版控排除清單 |

> 新 repo 要納入 CI/CD 的完整步驟，見
> [GitLab維運手冊 · 附錄 C](./GitLab維運手冊/附錄/C_新repo納入CICD.md)。
