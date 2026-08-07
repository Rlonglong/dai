# 10 · CI Pipeline 設定詳解

`.gitlab-ci.yml` 每個 job 在做什麼、為什麼這樣設，以及**四道資安關卡怎麼裝**。

---

## 1. 先回答一個問題：那兩段設定，哪一段才是我要的？

導入前手上有兩段既有設定，它們是**不同層級的東西**，不是二選一：

| | 第一段（`.gitlab-ci.yml`） | 第二段（shell 腳本） |
|---|---|---|
| 跑在哪 | **GitLab 伺服器上的 runner** | **開發者自己的電腦** |
| 什麼時候跑 | 東西**已經推上 GitLab 之後** | `git commit` 之前 |
| 用的 gitleaks 指令 | `gitleaks detect --no-git --source .` | `gitleaks protect --staged` |
| 擋得住什麼 | MR 合併 | commit 產生 |
| **能防止金鑰進 remote repo 嗎** | ❌ **不能** | ⚠️ 只能防「這一個 commit」，且可被 `--no-verify` 繞過 |

所以核心需求「**掃完才能 push 上去、不是只擋在 MR 前面**」，
**兩段都不夠**——第二段是 pre-commit（管 commit，不管 push），
第一段是 CI（東西已經在伺服器上了）。

缺的是中間兩層：

```
第二段有 →  [1] pre-commit    本機，掃 staged
缺       →  [2] pre-push      本機，掃「整批要推出去的 commit」
缺 ★    →  [3] pre-receive   VM3 伺服器端，★繞不過，push 直接被拒★
第一段有 →  [4] CI pipeline   最後防線 + 稽核
```

這次的做法是四層都補齊，而且**四層跑同一支腳本、同一份設定**：

```
ci/check_secrets.sh  ←──┬── ci/hooks/pre-commit
                        ├── ci/hooks/pre-push
                        ├── gitlab_workspace/server_hooks/pre-receive
                        └── .gitlab-ci.yml 的 secret-scanning job
        ↓
   .gitleaks.toml（唯一一份規則）
```

好處：不會出現「本地過了但 CI 擋」這種讓人抓狂又浪費時間的狀況。

---

## 2. 第 3 關（pre-receive）為什麼是關鍵

git 收 push 時有一個**隔離區（quarantine）**機制：

```
開發者 git push
     ↓
物件寫進 GIT_QUARANTINE_PATH（暫存，還不算數）
     ↓
GitLab 執行 pre-receive hook
     ↓
   ┌──────────────────┬────────────────────────┐
   ↓ exit 0           ↓ exit 非 0
物件併入 repo         quarantine 整批丟棄
ref 前進              ref 不動
                      ★物件從未進入 repo★
```

被第 3 關擋下來時：

| | 被 pre-receive 擋 | 被 CI 抓到（第 4 關） |
|---|---|---|
| 金鑰進 remote repo 了嗎 | ❌ 沒有 | ✅ 進了 |
| 要重寫歷史嗎 | 不用 | **要**（`git filter-repo`） |
| 要通知全員重新 clone 嗎 | 不用 | **要** |
| 開發者要做什麼 | `git rebase -i` 改掉本地 commit | 走完整的資安事件處理流程 |
| 金鑰要作廢嗎 | **要**（寫進 commit 就當作外洩） | 要 |

---

## 3. 安裝 pre-receive hook（VM3）

### 3-1. 找出 custom hooks 目錄

GitLab 15 之後，server hooks 由 gitaly 管：

```bash
# 在 VM3
docker exec gitlab grep -n "custom_hooks_dir" /etc/gitlab/gitlab.rb
# 沒有這行的話，用預設值：/var/opt/gitlab/gitaly/custom_hooks
```

### 3-2. 放 gitleaks 執行檔與預設設定

> 📴 **離線環境說明**：hook 與 gitleaks 執行時都**不需要任何對外連線**。
> gitleaks 是靜態編譯的單一執行檔，掃描邏輯是純正規表示式比對，
> 規則全部來自 `.gitleaks.toml`，不查線上資料庫、不回傳資料。
> 唯一需要網路的是「在外面把 tar.gz 下載下來帶進內網」這一步。


```bash
# 在 VM3，把 gitleaks binary 與設定送進 GitLab 容器
docker cp gitleaks        gitlab:/usr/local/bin/gitleaks
docker exec gitlab chmod 755 /usr/local/bin/gitleaks
docker exec gitlab /usr/local/bin/gitleaks version    # 確認跑得起來

# 預設設定（當 repo 裡沒帶 .gitleaks.toml 時的 fallback）
docker cp .gitleaks.toml  gitlab:/etc/gitlab/gitleaks.toml
```

> ⚠️ **GitLab 容器重建後這些會消失**（`/usr/local/bin` 不在 volume 裡）。
> 所以要把它做進 `docker-compose_vm3_secure.yml` 的 volume 掛載，
> 或寫進自訂的 `Dockerfile.gitlab`。做法見本文 3-5。

### 3-3. 安裝為全域 hook（所有專案自動生效）

```bash
docker exec gitlab mkdir -p /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d

docker cp gitlab_workspace/server_hooks/pre-receive \
          gitlab:/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks

docker exec gitlab chmod 755 \
    /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks
docker exec gitlab chown git:git \
    /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/10-gitleaks
```

`pre-receive.d/` 底下的所有腳本會依檔名順序執行，任何一支回傳非 0 就拒絕 push。
用 `10-` 開頭是留空間給以後可能加的其他檢查。

### 3-4. 驗證它真的有在擋

**這一步不能跳過。** 一個沒驗證過的資安控制，等於沒有。

```bash
# 在你自己的電腦上，隨便一個測試專案
git checkout -b test/pre-receive-hook

cat > leak_test.txt <<'EOF'
DB_PASS=ThisIsAFakePasswordForTesting123
EOF

git add leak_test.txt
git commit --no-verify -m "test: 驗證 pre-receive hook"    # 故意跳過本地 hook
git push --no-verify -u origin test/pre-receive-hook       # 故意跳過本地 hook
```

**預期輸出**：

```
remote:
remote:   ref refs/heads/test/pre-receive-hook 發現 1 個疑似金鑰：
remote:     [1] dai-db-connection-password  leak_test.txt:1
remote:         commit a3f2b91c4e05  by rlong
remote:
remote: ================================================================================
remote: ❌ [DAI] Push 被拒絕：偵測到 1 個疑似機密資訊
remote: ================================================================================
...
To https://gitlab.dai.post.gov.tw/xxx/yyy.git
 ! [remote rejected] test/pre-receive-hook -> test/pre-receive-hook (pre-receive hook declined)
error: failed to push some refs
```

看到 `[remote rejected]` 就是成功了。

**確認物件真的沒進去**：

```bash
# 在 VM3
docker exec gitlab gitlab-rails runner \
  'puts Project.find_by_full_path("<group>/<project>").repository.branch_names.grep(/test/)'
# 應該沒有 test/pre-receive-hook
```

清理：

```bash
git reset --hard HEAD~1
git checkout main && git branch -D test/pre-receive-hook
```

### 3-5. 讓它在容器重建後還在

在 `docker-compose_vm3_secure.yml` 的 gitlab 服務加掛載：

```yaml
services:
  gitlab:
    volumes:
      # ... 既有的 ...
      - ./workspace/gitlab/gitleaks:/usr/local/bin/gitleaks:ro
      - ./workspace/gitlab/gitleaks.toml:/etc/gitlab/gitleaks.toml:ro
      - ./workspace/gitlab/server_hooks:/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d:ro
```

然後把三個檔案放進 VM3 的 `workspace/gitlab/` 底下並納入部署包。

> 🔒 掛 `:ro` 是刻意的：hook 是安全控制，容器內的程序不該能改它。

---

## 4. 每個 CI job 在做什麼

### lint stage —— 只掃「這次動到的檔案」

| Job | 指令 | 範圍 |
|---|---|---|
| `format-check` | `ci/lint.sh format` → `black --check` | 變動的 `.py` |
| `lint-check` | `ci/lint.sh style` → `flake8` | 變動的 `.py` |
| `sql-lint` | `ci/lint.sh sql` → `sqlfluff lint` | 變動的 `.sql` |

**為什麼不掃全庫？**

既有程式碼是在導入 lint 之前寫的（現況 flake8 全庫約 150 個 warning，
black 有 10 個檔案需要重排）。整庫開嚴格模式的話，**每個 MR 都會紅**，
而且紅的原因跟這次改動無關。三天之內大家就會學會忽略紅燈，
那這個閘門就等於不存在了。

所以採「新帳新算」：**你動到的檔案要乾淨**。

想一次整乾淨（建議導入第一週做）：

```bash
ci/format_all.sh
git checkout -b chore/format-all
git commit -am "chore: 全庫套用 black / sqlfluff 格式（無邏輯改動）"
```

做完之後可以在 `.gitlab-ci.yml` 的 `variables` 加 `LINT_ALL_FILES: "1"`
改成掃全庫。

> ⚠️ 這個原則**只適用品質檢查**。
> 資安檢查（gitleaks / SCA）永遠是全庫全歷史，沒有「新帳新算」這回事。

### test stage

| Job | 說明 |
|---|---|
| `unit-tests` | 沒有 `tests/` 目錄就自動跳過。要開始寫測試時放進 `tests/` 就會被撿到 |
| `dbt-parse` | ★實用度最高★ 抓 `ref()` 指到不存在的模型、`sources.yml` 沒登記、Jinja 語法錯 |

`dbt parse` **不連資料庫**（只解析專案結構），所以在 CI 上跑是安全的。
目前設 `allow_failure: true`，因為 CI runner 上不一定有 dbt；
runner 裝好 dbt 之後建議改成 `false` 讓它擋門。

### security stage —— 全庫、全歷史

| Job | 說明 |
|---|---|
| `secret-scanning` | `tree`（現況）+ `history`（全歷史）兩趟 |
| `sast-bandit` | 變動的 `.py`，`-ll` 只看 medium 以上 |
| `sca-dtrack` | 產 SBOM → 上傳 D-Track → 等分析 → Critical 就擋門 |

#### sca-dtrack 的兩種來源

```
有 requirements.txt  →  cyclonedx-py requirements requirements.txt
                        （bcp-scripts repo 走這條）

沒有，但設了 DTRACK_IMAGE  →  docker run <image> pip freeze  →  產 SBOM
                        （dagster-workspace repo 走這條，
                          因為它的套件是烘焙在 dai/dagster 映像檔裡的）

兩者都沒有  →  ★job 直接失敗★
```

最後一項是刻意的。一個靜默跳過的資安掃描比沒有掃描更危險——
大家會以為它有在跑。

同理，等 D-Track 分析逾時也是**失敗**而不是放行。

設定 `DTRACK_IMAGE`：

```
Settings → CI/CD → Variables
  Key   : DTRACK_IMAGE
  Value : gitlab.dai.post.gov.tw:5050/<group>/<project>/dagster:v2.6
  Scope : production
```

要連 High 也擋：加 `DTRACK_FAIL_ON_HIGH = 1`。

---

## 5. rules 為什麼寫成那樣

```yaml
.rules_mr_and_push: &rules_mr_and_push
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_PIPELINE_SOURCE == "push" && $CI_OPEN_MERGE_REQUESTS == null
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

第二條的 `&& $CI_OPEN_MERGE_REQUESTS == null` 是在避免
**同一個 commit 同時跑兩條 pipeline**（branch pipeline + MR pipeline）。

沒有這個條件的話，開了 MR 之後每次 push 都會跑兩次完整的 CI，
runner 資源直接砍半，而且兩條 pipeline 的狀態會互相干擾。

---

## 6. GIT_DEPTH: 0 為什麼必要

```yaml
variables:
  GIT_DEPTH: 0
```

GitLab 預設淺複製（depth 20）。但這條 pipeline 有兩件事需要完整歷史：

| 需要完整歷史的地方 | 沒有的話會怎樣 |
|---|---|
| `changed_files()` 要算 `origin/main...HEAD` | 找不到共同祖先，退回比 `HEAD~1`，會漏掉檢查 |
| `gitleaks detect --log-opts` 掃 commit 範圍 | 掃不到範圍外的 commit |

代價是 clone 變慢。這個 repo 不大，可以接受。

---

## 7. 常見的調整

### 想加一個新的檢查

1. 在 `ci/lint.sh` 加一個 `do_xxx()` 函式
2. `.gitlab-ci.yml` 加一個 job 呼叫 `ci/lint.sh xxx`
3. **如果它也該在本地跑**，在 `ci/hooks/pre-push` 加一段
4. 先設 `allow_failure: true` 跑一週，看看誤判率，再改成擋門

### 想暫時關掉某個 job

**不要註解掉。** 改成：

```yaml
some-job:
  allow_failure: true      # TODO(2026-09-01, rlong): XXX 修好後改回 false
```

註解掉的 job 會被遺忘；`allow_failure` 至少在 MR 上還看得到黃色警告。

### runner 上缺工具

```bash
# 在 VM3
docker exec -it gitlab-runner-ci bash
source ~/.venv/bin/activate
pip install --no-index --find-links=/wheels black flake8 bandit sqlfluff cyclonedx-bom
```

要讓它在容器重建後還在的話，得做進自訂 image
（跟 gitleaks 一樣的問題，見 3-5）。

---

## 相關文件

- CD 的部分 → [11_CD_rsync部署機制](./11_CD_rsync部署機制.md)
- 變數怎麼設 → [13_Variables與環境隔離](./13_Variables與環境隔離.md)
- 開發者視角 → [03_本地環境設定與提交前檢查](../日常維運/03_本地環境設定與提交前檢查.md)
