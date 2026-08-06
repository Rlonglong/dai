# bcp-scripts repo · 建置範本

VM1 `/home/bcp_runner/scripts/` 這份程式碼要有**自己的 GitLab repo**，
跟 `dagster_workspace` 是兩條各自獨立的 CI/CD 線。

這個資料夾放的是「建那個 repo 時要複製過去的檔案」，不是那個 repo 本身。

---

## 為什麼要拆兩個 repo，而不是放同一個？

| 理由 | 說明 |
|---|---|
| **部署目標不同** | 一個推 VM4、一個推 VM1，混在一起就得在同一條 pipeline 裡判斷「這次改了誰」，很容易漏推或誤推 |
| **改動頻率不同** | dbt 模型幾乎天天改；VM1 腳本改一次就穩定很久。綁在一起會讓 VM1 每天被無謂地重推 |
| **權限範圍不同** | VM1 腳本碰得到明碼資料與解密金鑰，review 的人應該不完全是同一批 |
| **爆炸半徑** | VM1 腳本推壞 = 資料進不來；dbt 模型推壞 = 名單算錯。兩者要能各自 rollback |

代價是「新增一張資料表」這種事要開兩個 MR（見
[03_新增一張資料表](../../docs/Dagster維運手冊/日常維運/03_新增一張資料表.md)）。
這是刻意的取捨——寧可多開一個 MR，也不要讓兩台機器的部署互相綁死。

---

## 建立步驟

### 1. 在 GitLab 建 repo

GitLab UI → New project → Blank project
- 名稱：`bcp-scripts`
- 群組：跟 `dagster-workspace` 同一個群組
- **不要**勾 "Initialize repository with a README"

### 2. 從 VM1 現有的檔案初始化

```bash
# 在 VM1 上，用你自己的帳號（不是 bcp_runner）
mkdir -p ~/bcp-scripts-init && cd ~/bcp-scripts-init

# 先複製這個範本資料夾裡的設定檔過來
#   .gitignore  .gitleaks.toml  .gitlab-ci.yml  deploy_exclude.txt
#   requirements.txt  .flake8  bandit.yaml  pyproject.toml  ci/

# 再把 VM1 上的腳本複製進來
cp -r /home/bcp_runner/scripts/* .

# ★★★ 最重要的一步：確認沒有把機密帶進來 ★★★
# .env 應該在 /home/bcp_runner/.env（scripts/ 的外面），但還是要確認：
find . -name '.env' -o -name '*.key' -o -name '*.pem'
# 有東西跑出來就先刪掉，那些永遠不進版控

git init -b main
ci/install_hooks.sh          # 先裝 hook，第一個 commit 就會被掃
git add -A
git commit -m "chore: 從 VM1 現有腳本初始化 repo"
```

### 3. 第一次 push 之前先自己掃一次

```bash
# 這一步不能跳過。第一次 commit 是最容易夾帶金鑰的一次
# （因為是從「一直有在跑的正式機」上原封不動複製過來的）
ci/check_secrets.sh tree
ci/check_secrets.sh history
```

掃出東西的話：**不要只是刪檔案再 commit**。歷史裡還在。
直接把 `.git` 刪掉重來一次（反正這時候還沒 push）：

```bash
rm -rf .git
# 修掉問題檔案後，回到步驟 2 的 git init 重做
```

### 4. 推上去

```bash
git remote add origin https://gitlab.dai.post.gov.tw/<group>/bcp-scripts.git
git push -u origin main
```

### 5. 設定分支保護與 CI/CD Variables

跟 `dagster_workspace` 完全一樣的做法，見
[04_帳號_權限_分支保護](../../docs/GitLab維運手冊/日常維運/04_帳號_權限_分支保護.md)
與 [13_Variables與環境隔離](../../docs/GitLab維運手冊/進階調整/13_Variables與環境隔離.md)。

本 repo 專屬的變數值：

| 變數 | production | staging |
|---|---|---|
| `DEPLOY_HOST` | VM1 正式機 IP | VM1 測試機 IP |
| `DEPLOY_USER` | `gitlab_runner` | `gitlab_runner` |
| `DEPLOY_PATH` | `/home/bcp_runner/scripts` | `/home/bcp_runner/scripts` |
| `POST_DEPLOY_CMD` | `sudo /usr/local/sbin/dai-post-deploy-vm1.sh` | 同左 |
| `SOURCE_DIR` | `.`（整個 repo 就是要推的內容） | 同左 |

> ⚠️ `SOURCE_DIR=.` 跟 `dagster_workspace` repo 不一樣。
> 那邊是「repo 裡的一個子目錄」才是部署單位（因為 repo 根目錄還有 docs/、ci/）；
> 這邊 repo 根目錄本身就是 `/home/bcp_runner/scripts/` 的內容。
> 所以這個 repo 的 `deploy_exclude.txt` **必須**把 `ci/`、`docs/`、`.gitlab-ci.yml`
> 這些排除掉，否則會被推到 VM1 上去。已經寫在範本裡了。

### 6. 把 VM1 上原本的資料夾接管過來

```bash
# 在 VM1，以 root
# 先備份，萬一 rsync 排除清單有漏可以救回來
tar czf /root/bcp_scripts_backup_$(date +%F).tar.gz /home/bcp_runner/scripts

# 部署腳本安裝
install -o root -g root -m 755 dai-post-deploy-vm1.sh /usr/local/sbin/
echo 'gitlab_runner ALL=(root) NOPASSWD: /usr/local/sbin/dai-post-deploy-vm1.sh' \
  > /etc/sudoers.d/dai-gitlab-runner
echo 'Defaults!/usr/local/sbin/dai-post-deploy-vm1.sh !requiretty' \
  >> /etc/sudoers.d/dai-gitlab-runner
chmod 440 /etc/sudoers.d/dai-gitlab-runner
visudo -c          # 一定要驗，sudoers 寫錯會鎖死 sudo

# 讓 gitlab_runner 寫得進去
setfacl -R -m u:gitlab_runner:rwx /home/bcp_runner/scripts
setfacl -d -m u:gitlab_runner:rwx /home/bcp_runner/scripts
```

### 7. 第一次部署務必先 dry-run

```bash
# 在 GitLab 上把 deploy job 改成手動觸發，或先在 runner 上：
DEPLOY_HOST=... DEPLOY_USER=gitlab_runner DEPLOY_PATH=/home/bcp_runner/scripts \
DEPLOY_SSH_KEY=... DEPLOY_KNOWN_HOSTS=... SOURCE_DIR=. \
  ci/deploy_rsync.sh --dry-run
```

**逐行看過 dry-run 的輸出**，特別注意有沒有 `deleting` 開頭的行。
那代表「VM1 上有、repo 裡沒有」的檔案會被刪掉——
如果那是還沒進版控的東西（例如手改的臨時腳本），先把它補進 repo 再部署。

---

## 這個資料夾裡有什麼

| 檔案 | 說明 |
|---|---|
| `.gitignore` | 版控排除；比 dagster 那份更嚴，因為 VM1 碰得到明碼資料 |
| `deploy_exclude.txt` | rsync 排除／刪除保護 |
| `.gitlab-ci.yml` | CI/CD pipeline |
| `requirements.txt` | 套件清單（取自部署手冊 Phase 5.2 的實際盤點） |

`ci/`、`.gitleaks.toml`、`.flake8`、`bandit.yaml`、`pyproject.toml`
直接從 `dagster_workspace` repo 複製過去即可，內容完全相同——
**兩個 repo 的檢查規則刻意保持一致**，開發者換 repo 不需要重新學一套。
