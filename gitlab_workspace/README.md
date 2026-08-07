# gitlab_workspace 資料夾結構說明

這裡是 **VM3（GitLab）** 這一側的全部設定與程式。
本檔只說明**哪個位置放什麼**；操作方式、日常維運、進階調整請看
[`GitLab維運手冊/`](./GitLab維運手冊/README.md)。

> 📦 **這整個資料夾會被打包進 `deploy_package_vm3.tar.gz`**，
> 跟 `dagster_workspace/` 整包放進 VM4 的 zip 是同樣的概念。
>
> 差別在於：`dagster_workspace/` 是**持續由 CD 用 rsync 同步**的執行期程式碼；
> `gitlab_workspace/` 是**一次性的建置素材** —— 部署時裝好 hook、裝好腳本、
> 建好 repo 就完成任務，之後不會再被自動覆蓋。所以手冊放在裡面沒有問題
> （`dagster_workspace/` 的手冊必須搬到 `docs/`，因為它會被 rsync 推到 VM4）。

---

## 快速定位：我要做的事情在哪裡

| 我想做的事 | 去哪裡 |
|---|---|
| 我要改程式碼並上線 | [GitLab維運手冊/日常維運/01_開發人員_日常開發流程.md](./GitLab維運手冊/日常維運/01_開發人員_日常開發流程.md) |
| 我每天要檢查什麼 | [GitLab維運手冊/日常維運/02_維運人員_每日檢查.md](./GitLab維運手冊/日常維運/02_維運人員_每日檢查.md) |
| 新機器怎麼設定、被 hook 擋住怎麼修 | [GitLab維運手冊/日常維運/03_本地環境設定與提交前檢查.md](./GitLab維運手冊/日常維運/03_本地環境設定與提交前檢查.md) |
| 新人加入 / 離職 / 分支保護怎麼設 | [GitLab維運手冊/日常維運/04_帳號_權限_分支保護.md](./GitLab維運手冊/日常維運/04_帳號_權限_分支保護.md) |
| 某個 CI job 在做什麼 | [GitLab維運手冊/進階調整/10_CI_Pipeline設定詳解.md](./GitLab維運手冊/進階調整/10_CI_Pipeline設定詳解.md) |
| rsync 參數 / 排除清單怎麼改 | [GitLab維運手冊/進階調整/11_CD_rsync部署機制.md](./GitLab維運手冊/進階調整/11_CD_rsync部署機制.md) |
| 雜湊對帳紅了怎麼查 | [GitLab維運手冊/進階調整/12_同步完整性稽核.md](./GitLab維運手冊/進階調整/12_同步完整性稽核.md) |
| 測試碰到正式 DB 了 | [GitLab維運手冊/進階調整/13_Variables與環境隔離.md](./GitLab維運手冊/進階調整/13_Variables與環境隔離.md) |
| D-Track 弱掃、每季定期掃 | [GitLab維運手冊/進階調整/15_D-Track定期弱掃.md](./GitLab維運手冊/進階調整/15_D-Track定期弱掃.md) |
| 出事了 | [GitLab維運手冊/進階調整/14_疑難排解.md](./GitLab維運手冊/進階調整/14_疑難排解.md) |
| 從零建置 | [部署手冊 Phase 4](../README.md) |

---

## 資料夾結構

```
gitlab_workspace/                    ← ★整包放進 deploy_package_vm3★
│
├── README.md                        ← 你正在看的這份
├── GitLab維運手冊/                   ← 所有文件（見下方）
│
├── server_hooks/
│   └── pre-receive                  ← ★最重要的一支★ 裝在 GitLab 容器裡，
│                                       push 含金鑰時直接拒絕，繞不過
│
├── post_deploy/                     ← 這兩支不是裝在 VM3，是複製到目標機
│   ├── dai-post-deploy-vm4.sh       ← 裝到 VM4 /usr/local/sbin/
│   └── dai-post-deploy-vm1.sh       ← 裝到 VM1 /usr/local/sbin/
│
├── repo_templates/
│   └── bcp_scripts_repo/            ← 建 bcp-scripts repo 時複製過去的檔案
│       ├── README.md                ← ★建立步驟寫在這★
│       ├── .gitlab-ci.yml
│       ├── .gitignore
│       ├── deploy_exclude.txt
│       └── requirements.txt
│
└── dtrack/                          ← D-Track 相關素材（API Key 申請、team 權限）
```

### 不在這個資料夾、但屬於同一套機制的東西

CI/CD 的**執行腳本**放在 repo 根目錄的 `ci/`，不在這裡。原因是它們必須
**跟著 git repo 一起被 checkout 到 runner 上**才跑得起來，而且開發者的本機
git hook 也要用同一份 —— 放進 `gitlab_workspace/` 反而會拿不到。

| 東西 | 位置 | 誰在用 |
|---|---|---|
| `ci/lib.sh` | repo 根目錄 | 其他所有腳本共用的函式 |
| `ci/check_secrets.sh` | repo 根目錄 | 本機 hook + 伺服器 hook + CI，**三邊共用同一支** |
| `ci/lint.sh` | repo 根目錄 | CI 的 lint / sast job |
| `ci/build_sbom.sh` | repo 根目錄 | CI 的 D-Track job |
| `ci/deploy_rsync.sh` | repo 根目錄 | CD 部署 |
| `ci/sync_manifest.sh` | repo 根目錄 | 雜湊對帳（兩端各跑一次） |
| `ci/verify_sync.sh` | repo 根目錄 | 雜湊對帳主流程 |
| `ci/install_hooks.sh` | repo 根目錄 | 開發者安裝本機 hook |
| `ci/format_all.sh` | repo 根目錄 | 一次性全庫格式化 |
| `ci/hooks/pre-commit`、`pre-push` | repo 根目錄 | 開發者本機 |
| `.gitlab-ci.yml` | repo 根目錄 | pipeline 定義 |
| `.gitleaks.toml` | repo 根目錄 | 機密偵測規則，四道關卡共用 |
| `deploy_exclude.txt` | repo 根目錄 | rsync 排除／刪除保護 |

---

## 每一支程式在做什麼

### 資安檢查（四道關卡，共用 `ci/check_secrets.sh` 與 `.gitleaks.toml`）

| 檔案 | 跑在哪 | 何時 | 擋得住嗎 |
|---|---|---|---|
| `ci/hooks/pre-commit` | 開發者本機 | `git commit` | 可被 `--no-verify` 繞過 |
| `ci/hooks/pre-push` | 開發者本機 | `git push` | 可被 `--no-verify` 繞過 |
| **`server_hooks/pre-receive`** | **VM3 GitLab 容器** | **push 到達伺服器、寫進 repo 之前** | **繞不過** |
| `.gitlab-ci.yml` 的 `secret-scanning` | VM3 runner | push 成功之後 | 只能算稽核，已經太晚 |

第三道靠 git 的 quarantine 機制：hook 回傳非 0 → 整批物件丟棄、ref 不動，
**金鑰從頭到尾沒有進過 repo**，不需要事後 `git filter-repo` 清歷史。

### 品質檢查

| 檔案 | 檢查什麼 | 範圍 |
|---|---|---|
| `ci/lint.sh format` | black 排版 | **只掃本次變動的 `.py`** |
| `ci/lint.sh style` | flake8 | 同上 |
| `ci/lint.sh sast` | bandit 資安規則 | 同上 |
| `ci/lint.sh sql` | sqlfluff | **只掃本次變動的 `.sql`** |
| `ci/format_all.sh` | 一次性全庫格式化 | 全庫（導入時跑一次） |

> 品質檢查刻意只掃變動的檔案。既有程式碼是在導入 lint 之前寫的，
> 整庫開嚴格模式會讓每個 MR 都紅燈，最後大家只會學會忽略紅燈。
> **資安檢查不適用這個原則** —— 那是全庫全歷史。

### 部署與稽核

| 檔案 | 做什麼 |
|---|---|
| `ci/deploy_rsync.sh` | rsync 推到 VM1/VM4 → ssh 跑 post_deploy → 立刻驗雜湊 |
| `post_deploy/dai-post-deploy-vm4.sh` | chown 給 UID 10001、收緊權限、`dbt parse` 重產 manifest |
| `post_deploy/dai-post-deploy-vm1.sh` | chown 給 bcp_runner、收緊權限、用 VM1 的 Python 驗語法 |
| `ci/sync_manifest.sh` | 產生「這個目錄現在長什麼樣」的 sha256 清單（兩端各跑一次） |
| `ci/verify_sync.sh` | 比對兩端清單，列出差異並分類 |

### 弱點掃描

| 檔案 | 做什麼 |
|---|---|
| `ci/build_sbom.sh` | 產 SBOM → 上傳 D-Track → 等分析 → 依 Critical/High 決定擋不擋門 |

推送時擋 Critical；**每季定期複掃**連 High 一起擋（見
[15_D-Track定期弱掃](./GitLab維運手冊/進階調整/15_D-Track定期弱掃.md)）。

---

## 手冊資料夾

```
GitLab維運手冊/
├── README.md                          ← 手冊索引：誰該讀哪一篇
├── 00_架構與同步機制總覽.md             ← 先看這篇建立全貌
│
├── 日常維運/                            ← 照著做就好，不用懂內部機制
│   ├── 01_開發人員_日常開發流程.md
│   ├── 02_維運人員_每日檢查.md
│   ├── 03_本地環境設定與提交前檢查.md
│   └── 04_帳號_權限_分支保護.md
│
├── 進階調整/                            ← 要改 pipeline 或伺服器設定
│   ├── 10_CI_Pipeline設定詳解.md
│   ├── 11_CD_rsync部署機制.md
│   ├── 12_同步完整性稽核.md
│   ├── 13_Variables與環境隔離.md
│   ├── 14_疑難排解.md
│   └── 15_D-Track定期弱掃.md
│
└── 附錄/
    └── A_gitlab_runner帳號與SSH金鑰.md
```

---

## 兩個排程

| 排程 | Cron | 變數 | 跑什麼 |
|---|---|---|---|
| 每日對帳 | `30 8 * * *` | `SCHEDULE_TYPE=verify` | 雜湊對帳 |
| 每季弱掃 | `0 3 1 */3 *` | `SCHEDULE_TYPE=quarterly` | gitleaks 全歷史 + bandit + D-Track |

> ⚠️ **兩個排程都必須設 `SCHEDULE_TYPE` 變數。**
> 沒設的話兩種排程會互相觸發對方的 job：每天早上的對帳會把整套資安複掃
> 也拉起來跑，D-Track 每天被灌一次 SBOM。

---

## 部署時這個資料夾的東西各去哪裡

| 來源 | 目的地 | 怎麼裝 |
|---|---|---|
| `server_hooks/pre-receive` | VM3 GitLab 容器 `/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks` | `docker cp` + `chmod 755` |
| `post_deploy/dai-post-deploy-vm4.sh` | **VM4** `/usr/local/sbin/` | `install -o root -g root -m 755` |
| `post_deploy/dai-post-deploy-vm1.sh` | **VM1** `/usr/local/sbin/` | 同上 |
| `repo_templates/bcp_scripts_repo/*` | 新建的 `bcp-scripts` GitLab repo | `cp` 進去後 commit |
| `GitLab維運手冊/` | 留在 VM3 供查閱 | 不用裝 |

完整步驟見 [部署手冊 Phase 4](../README.md)。
