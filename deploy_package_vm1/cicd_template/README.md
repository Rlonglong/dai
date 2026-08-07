# cicd_template（VM1 版）—— 建 `bcp-scripts` repo 用的素材

這是 VM3 那份 [`cicd_template/`](../../deploy_package_vm3/cicd_template/README.md) 的**子集**，
只留下建 `bcp-scripts` 這個 repo 需要的部分（`common/` + `bcp-scripts/`）。

放在 VM1 的包裡，是因為 `bcp-scripts` repo 的程式碼是從
**VM1 上現有的 `/home/bcp_runner/scripts/`** 初始化的 —— 素材跟程式碼在同一台，
不用在兩台機器之間搬。

> 完整的設計說明（為什麼要集中維護、規則改了怎麼同步）在 VM3 那份 README，
> 這裡只講怎麼用。

---

## 怎麼用

```bash
# 在 VM1，用你自己的帳號（不是 bcp_runner）
mkdir -p ~/bcp-scripts-init && cd ~/bcp-scripts-init

# 1. 程式碼：這個 repo 的根目錄本身就是 scripts/ 的內容（SOURCE_DIR="."）
cp -r /home/bcp_runner/scripts/* .

# 2. CI/CD 素材 → 複製到 repo 根目錄
git init -b main
/run/media/root/D/deploy/cicd_template/install.sh . bcp-scripts --dry-run   # 先看會做什麼
/run/media/root/D/deploy/cicd_template/install.sh . bcp-scripts             # 確認後實際複製
```

複製進去之後 repo 根目錄應該有這些（**開頭是點的那幾個最容易被忽略，一定要在**）：

```
.gitignore          .gitleaks.toml      .flake8         .sqlfluff
.gitlab-ci.yml      pyproject.toml      deploy_exclude.txt
ci/                 requirements.txt
（以及從 /home/bcp_runner/scripts/ 複製過來的所有 .py 與 clean_functions/）
```

確認一下：
```bash
ls -A | grep -E '^\.' 
```

---

## ★ `.gitignore` 與 `deploy_exclude.txt` 兩份都要在 ★

這是最容易漏、而且漏了會出事的一組：

| | `.gitignore` | `deploy_exclude.txt` |
|---|---|---|
| 管什麼 | 什麼**進版控** | rsync **不傳、也不刪**什麼 |
| 誰在讀 | git | `ci/deploy_rsync.sh` 的 `--exclude-from` |
| 漏掉會怎樣 | 機密與執行期產物被 commit 進 repo | rsync 的 `--delete` 把正式機上的檔案洗掉 |

CD 跑的是 `rsync -a --delete --checksum --exclude-from=deploy_exclude.txt`，
`--delete` 的語意是「repo 沒有的，正式機上也不該有」。
VM1 上人工建立的東西之所以活得下來，靠的就是 `deploy_exclude.txt`。

> `/home/bcp_runner/.env` 本身是安全的 —— 它在 `scripts/` **外面**，
> 根本不在 rsync 的傳輸範圍內。`deploy_exclude.txt` 裡那幾行 `.env`
> 是防止有人不小心在 repo 或 `scripts/` 裡**也**放一份。

---

## 第一次 commit 之前一定要掃過

`bcp-scripts` 的第一個 commit 是從**一直在跑的正式機**上原封不動複製過來的，
是最容易夾帶金鑰的一次：

```bash
find . -name '.env' -o -name '*.key' -o -name '*.pem'   # 有東西跑出來就先刪掉

ci/install_hooks.sh        # 先裝 hook，第一個 commit 就會被掃
ci/check_secrets.sh tree
ci/check_secrets.sh history
```

掃出東西的話**不要只是刪檔案再 commit**（歷史裡還在），
直接 `rm -rf .git` 重來。

完整步驟見
[附錄 B · bcp-scripts repo 建立步驟](../../docs/GitLab維運手冊/附錄/B_bcp-scripts_repo建立步驟.md)。
