# cicd_template —— CI/CD 素材集中放這裡

**這個 repo 不會被直接執行。** 它是文件與素材的來源，
真正在跑 pipeline 的是 GitLab 上的兩個 repo。

這個資料夾把「**每個 repo 都要有、而且必須放在 repo 根目錄**」的檔案集中管理，
用一支 `install.sh` 複製過去，避免兩個 repo 的設定各自長歪。

---

## 為什麼要這樣做

`.gitlab-ci.yml`、`.gitleaks.toml`、`.flake8`、`pyproject.toml` 這些檔案
**工具是固定去 repo 根目錄找的**，搬到子目錄就失效：

| 檔案 | 誰在讀 | 放錯地方的後果 |
|---|---|---|
| `.gitlab-ci.yml` | GitLab | pipeline 完全不會跑 |
| `.gitleaks.toml` | gitleaks（本機 hook / 伺服器 hook / CI 三邊共用） | 每個呼叫點都要補 `-c` |
| `.flake8` | flake8 | 只認 repo 根的 `.flake8` / `setup.cfg` / `tox.ini` |
| `.sqlfluff` | sqlfluff | 由檔案往上找到 repo 根 |
| `pyproject.toml` | black | 同上 |
| `deploy_exclude.txt` | `ci/deploy_rsync.sh` | rsync 少了刪除保護清單，**下次部署會洗掉正式機的 `.env`** |

所以做法是：**在這裡集中維護 → 用指令複製到各 repo 的根目錄**。
改規則時改這裡一份，再同步出去，兩個 repo 不會各自漂移。

---

## 資料夾結構

```
cicd_template/
├── README.md                 ← 你正在看的這份
├── install.sh                ← ★一次複製到目標 repo★
│
├── common/                   ← 兩個 repo 完全一樣的部分
│   ├── ci/                   ← pipeline 與 git hook 的腳本
│   │   ├── lib.sh                共用函式
│   │   ├── check_secrets.sh      機密掃描（本機 hook / 伺服器 hook / CI 三邊共用）
│   │   ├── lint.sh               black / flake8 / bandit / sqlfluff
│   │   ├── format_all.sh         一次性全庫格式化
│   │   ├── build_sbom.sh         產 SBOM → D-Track → 決定擋不擋門
│   │   ├── dtrack_suppress_os.sh libc* 自動放行
│   │   ├── dtrack_inherit_analysis.sh  把 main 上標過的例外帶到目前分支
│   │   ├── deploy_rsync.sh       CD 部署
│   │   ├── sync_manifest.sh      雜湊清單
│   │   ├── verify_sync.sh        同步完整性稽核
│   │   ├── install_hooks.sh      開發者安裝本機 hook
│   │   ├── bandit.yaml           bandit 規則
│   │   └── hooks/{pre-commit,pre-push}
│   ├── .gitleaks.toml        機密偵測規則
│   ├── .flake8
│   ├── .sqlfluff
│   └── pyproject.toml        black 設定
│
├── dagster-workspace/        ← 部署到 VM4 的那個 repo 專屬
│   ├── .gitlab-ci.yml
│   ├── .gitignore
│   └── deploy_exclude.txt
│
└── bcp-scripts/              ← 部署到 VM1 的那個 repo 專屬
    ├── .gitlab-ci.yml
    ├── .gitignore
    ├── deploy_exclude.txt
    └── requirements.txt
```

**為什麼 `.gitlab-ci.yml` 與 `deploy_exclude.txt` 分開放**：
兩個 repo 的部署目標、`SOURCE_DIR`、排除清單都不同，
硬要共用一份反而會推錯機器。

---

## 怎麼用

### 複製到現有的兩個 repo

```bash
# 在這個 repo 底下
cd cicd_template

# 先看會做什麼（不會真的動檔案）
./install.sh ~/work/dagster-workspace dagster-workspace --dry-run

# 確認沒問題再實際複製
./install.sh ~/work/dagster-workspace dagster-workspace
./install.sh ~/work/bcp-scripts       bcp-scripts
```

複製完到目標 repo：

```bash
cd ~/work/dagster-workspace
git status
git diff              # ★ 進版控前一定要自己看過 ★
git add -A && git commit -m "chore: 更新 CI/CD 素材"
# 開 MR 走正常流程（main 不能直接 push）
```

> `install.sh` **只複製檔案，不會 git add、不會 commit**。
> 目標檔案已存在且內容不同時會停下來提醒，要覆蓋請加 `--force`。

### 之後有新的 repo 要納管

步驟寫在
[GitLab維運手冊 · 附錄 C · 新 repo 納入 CI/CD](../docs/GitLab維運手冊/附錄/C_新repo納入CICD.md)。

---

## 改了規則之後要記得同步

這裡的檔案改了，**兩個 repo 不會自動更新**。流程是：

```
1. 在本 repo 改 cicd_template/ 底下的檔案 → 開 MR → 合併
2. 對每一個目標 repo 跑一次 install.sh
3. 各自開 MR → 合併
```

> 🔁 建議**每季弱掃的時候順便對一次**：
> ```bash
> ./install.sh ~/work/dagster-workspace dagster-workspace --dry-run
> ./install.sh ~/work/bcp-scripts       bcp-scripts       --dry-run
> ```
> `--dry-run` 不會動到檔案，但會把「內容不同」的項目列出來，
> 等於一次漂移檢查。

---

## 相關文件

| 你想知道 | 看哪一份 |
|---|---|
| 每支腳本在做什麼 | [GitLab維運手冊 · 10_CI_Pipeline設定詳解](../docs/GitLab維運手冊/進階調整/10_CI_Pipeline設定詳解.md) |
| rsync 排除清單怎麼改 | [GitLab維運手冊 · 11_CD_rsync部署機制](../docs/GitLab維運手冊/進階調整/11_CD_rsync部署機制.md) |
| 新 repo 怎麼納管 | [GitLab維運手冊 · 附錄 C](../docs/GitLab維運手冊/附錄/C_新repo納入CICD.md) |
| `bcp-scripts` 當初怎麼建的 | [GitLab維運手冊 · 附錄 B](../docs/GitLab維運手冊/附錄/B_bcp-scripts_repo建立步驟.md) |
| 弱掃擋門與解除 | [D-Track與Superset手冊 · 04](../docs/D-Track與Superset手冊/日常維運/04_弱掃紅燈與MR被卡住的解除流程.md) |
