# 附錄 C · 新的 repo 要納入 CI/CD

> 這份文件在回答：**又要開一個新的 GitLab repo，怎麼讓它跟現有兩個一樣
> 有 lint、有資安掃描、有部署、有雜湊對帳。**

---

## 1. 先確認：這個 repo 需要哪幾種能力

不是每個新 repo 都需要全套。先勾一勾：

| 能力 | 需要的話要做什麼 | 不需要的話 |
|---|---|---|
| 程式碼品質檢查（black / flake8 / bandit / sqlfluff） | 複製 `common/` | — |
| 機密掃描（gitleaks） | 複製 `common/`（伺服器端 hook 是全域的，自動生效） | 沒得選，一定有 |
| 套件弱點掃描（D-Track） | 設 `DTRACK_*` 變數 | `.gitlab-ci.yml` 拿掉 sca job |
| **自動部署到正式機** | 設 `DEPLOY_*` 變數 + 目標機準備 | `.gitlab-ci.yml` 拿掉 deploy / verify job |
| 每日雜湊對帳 | 跟部署一起 | 同上 |

> 📌 **伺服器端的 pre-receive hook 是全域的**，裝在 GitLab 容器裡，
> 所有專案自動生效。新 repo 不用另外做什麼，push 含金鑰一樣會被擋。

---

## 2. 建立 repo

```
GitLab → 左上 + → New project → Create blank project
  Project name : <名稱>
  Visibility   : Private
  ☐ Initialize repository with a README   ← ★不要勾★
  → Create project
```

不勾 README 是因為第 4 步要推一個乾淨的初始 commit。

---

## 3. 複製 CI/CD 素材

素材集中在本 repo 的 [`cicd_template/`](../../../deploy_package_vm3/cicd_template/README.md)。

```bash
# 在本 repo 底下
cd cicd_template

# 先看會做什麼
./install.sh ~/work/<新repo> common --dry-run

# 確認沒問題再實際複製
./install.sh ~/work/<新repo> common
```

`common` profile 會複製：

```
ci/                  所有 pipeline 與 hook 腳本
.gitleaks.toml       機密偵測規則
.flake8 / .sqlfluff / pyproject.toml    各工具設定
```

**還缺三個檔案要自己準備**（因為每個 repo 都不一樣）：

| 檔案 | 怎麼生 |
|---|---|
| `.gitlab-ci.yml` | 從 `cicd_template/dagster-workspace/` 或 `bcp-scripts/` 挑一份接近的複製過去改 |
| `.gitignore` | 同上 |
| `deploy_exclude.txt` | **要部署才需要**。同上，並依第 5 節逐行檢查 |

```bash
# 以 bcp-scripts 為底比較常見（它的 SOURCE_DIR="."，結構單純）
cp cicd_template/bcp-scripts/{.gitlab-ci.yml,.gitignore,deploy_exclude.txt} ~/work/<新repo>/
```

---

## 4. 改 `.gitlab-ci.yml`

至少要檢查這幾處：

```yaml
variables:
  SOURCE_DIR: "."          # ← repo 根目錄就是部署內容 → "."
                           #    repo 底下某個子目錄才是 → 寫那個目錄名

deploy:production:
  variables:
    DEPLOY_PATH: "..."     # ← 目標機上的絕對路徑
    POST_DEPLOY_CMD: "..." # ← 目標機上的 post-deploy 腳本（沒有就整行刪掉）
  environment:
    name: production
```

**不需要部署的 repo**：把 `deploy:*` 與 `verify:*` 幾個 job 整段刪掉，
保留 lint / test / security 就好。

---

## 5. `deploy_exclude.txt` 逐行檢查（★要部署才做，但很重要★）

這份清單同時是「不傳清單」與「**刪除保護清單**」——
`rsync --delete` 不會刪掉被 exclude 的檔案。

**漏一行的後果是：下次部署直接洗掉正式機上的那個檔案。**

三類一定要列：

```
# 1. 正式機上人工建立、不進版控的機密
.env
.env.*

# 2. 開發用、正式機不需要的（SOURCE_DIR="." 時特別重要）
ci/
docs/
.gitlab-ci.yml
.gitleaks.toml
.flake8
pyproject.toml
deploy_exclude.txt
README.md

# 3. 正式機自己會產生的執行期產物
logs/
output/
__pycache__/
.git/
.sync_manifest.sha256
```

驗證方式見
[11_CD_rsync部署機制 · 怎麼驗證排除清單是對的](../進階調整/11_CD_rsync部署機制.md#怎麼驗證排除清單是對的)。

---

## 6. 推上初始 commit

**★ 一定要在設分支保護之前做 ★**（設完就不能直接 push `main` 了）

```bash
cd ~/work/<新repo>

# 從既有正式機的檔案初始化的話，★先自己掃一次★
ci/check_secrets.sh tree
ci/check_secrets.sh history

git init && git add -A
git commit -m "chore: 初始化 repo 與 CI/CD 設定"
git remote add origin https://gitlab.dai.post.gov.tw/<group>/<新repo>.git
git push -u origin main
```

> ⚠️ 從**一直在跑的正式機**上複製過來的第一個 commit 最容易夾帶金鑰。
> 掃出東西的話**不要只是刪檔案再 commit**（歷史裡還在），
> 直接 `rm -rf .git` 重來。

---

## 7. 設定 GitLab（照這個順序）

### 7-1. 分支保護

```
該 project → Settings → Repository → 展開 Protected branches → Add protected branch
```

| Branch | Allowed to merge | Allowed to push and merge | Force push |
|---|---|---|---|
| `main` | **Maintainers** | **No one** | ❌ |

### 7-2. Merge checks

```
該 project → Settings → Merge requests
```

- Merge method：**Merge commit**
- Merge checks：勾 **Pipelines must succeed**、**All threads must be resolved**
- **不要勾**「Skipped pipelines are considered successful」

完整說明見 [04_帳號_權限_分支保護](../日常維運/04_帳號_權限_分支保護.md)。

### 7-3. CI/CD Variables

```
該 project → Settings → CI/CD → 展開 Variables
  → ★確認加在 Project variables，不是 Group variables (inherited)★
```

| Key | Type | Masked | Scope | 需要嗎 |
|---|---|---|---|---|
| `DTRACK_URL` | Variable | ❌ | `*` | 要掃套件弱點就要 |
| `DTRACK_API_KEY` | Variable | ✅ | `*` | 同上 |
| `DTRACK_IMAGE` | Variable | ❌ | `*` | 套件在映像檔裡才要 |
| `DEPLOY_HOST` | Variable | ✅ | production | 要部署才要 |
| `DEPLOY_USER` | Variable | ❌ | `*` | 同上，值是 `gitlab_runner` |
| `DEPLOY_SSH_KEY` | **File** | — | production | 同上 |
| `DEPLOY_KNOWN_HOSTS` | **File** | — | production | 同上 |

全部勾 **Protect variable**。

### 7-4. 排程（要掃套件弱點就要設）

```
該 project → Build → Pipeline schedules → New schedule
```

| | 每日對帳 | 每季弱掃 |
|---|---|---|
| Interval Pattern | `30 8 * * *` | `0 3 1 */3 *` |
| Cron timezone | `Asia/Taipei` | `Asia/Taipei` |
| Target branch | `main` | `main` |
| Variables | `SCHEDULE_TYPE` = `verify` | `SCHEDULE_TYPE` = `quarterly` |

> ⚠️ `SCHEDULE_TYPE` **不能漏、不能兩個設成一樣**，
> 否則兩種排程會互相觸發對方的 job。

---

## 8. 目標機準備（要部署才做）

在目標機上，以 root：

```bash
# 1. 建帳號
useradd -m -s /bin/bash gitlab_runner
mkdir -p /home/gitlab_runner/.ssh && chmod 700 /home/gitlab_runner/.ssh
chown -R gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh

# 2. 讓它寫得進部署目錄
mkdir -p <部署目錄>
setfacl -R -m u:gitlab_runner:rwx <部署目錄>
setfacl -d -m u:gitlab_runner:rwx <部署目錄>      # -d 是 default ACL，新建的目錄才會繼承

# 3. 派發公鑰（★不要用 ssh-copy-id★，它不會加限制條件）
cat >> /home/gitlab_runner/.ssh/authorized_keys <<'EOF'
from="<VM3_IP>",restrict,pty ssh-ed25519 AAAA...（貼上公鑰全文） <說明>
EOF
chmod 600 /home/gitlab_runner/.ssh/authorized_keys
chown gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh/authorized_keys
```

金鑰怎麼產、known_hosts 怎麼取，見
[附錄 A · gitlab_runner 帳號與 SSH 金鑰](./A_gitlab_runner帳號與SSH金鑰.md)。

**防火牆**要開 `VM3 → 目標機:22`。

---

## 9. 驗證

```
[ ] 開一個測試 MR，pipeline 全綠
[ ] 用 Developer 帳號測：Merge 鍵按不下去
[ ] 測 git push main：被 remote rejected
[ ] 假金鑰測 pre-receive：git push --no-verify 被拒絕
[ ] Run pipeline（main）→ deploy job 綠燈
[ ] 目標機上檔案都在、擁有者對、.env 還在
[ ] 手動跑一次兩個排程，確認各自只拉起該跑的 job
[ ] D-Track 上出現 <新repo>:main 這個專案
```

pre-receive 的實測方式見
[10_CI_Pipeline設定詳解 · 3-4](../進階調整/10_CI_Pipeline設定詳解.md#3-4-驗證它真的有在擋)。

---

## 10. 之後怎麼保持同步

`cicd_template/` 改了之後，**各 repo 不會自動更新**：

```bash
cd cicd_template
./install.sh ~/work/<新repo> common --dry-run   # 先看差異
./install.sh ~/work/<新repo> common             # 再實際複製
# 然後在該 repo 開 MR
```

> 🔁 建議每季弱掃的時候順便對一次 `--dry-run`，
> 它會把「內容不同」的項目列出來，等於一次漂移檢查。

---

## 相關文件

- 素材本身 → [`cicd_template/README.md`](../../../deploy_package_vm3/cicd_template/README.md)
- `bcp-scripts` 當初怎麼建的 → [附錄 B](./B_bcp-scripts_repo建立步驟.md)
- 分支保護與 Merge checks → [04_帳號_權限_分支保護](../日常維運/04_帳號_權限_分支保護.md)
- pipeline 每個 job 在做什麼 → [10_CI_Pipeline設定詳解](../進階調整/10_CI_Pipeline設定詳解.md)
