# 11 · CD · rsync 部署機制

合併進 `main` 之後，程式碼怎麼從 GitLab 跑到正式機上。

---

## 1. 整體流程

```
main 分支有新 commit
     ↓
VM3 的 CD runner（以 gitlab_runner 身分執行）
     ↓
ci/deploy_rsync.sh
     │
     ├─ 1. 建立 SSH 環境（把 CI 變數裡的私鑰寫成 600 的暫存檔）
     ├─ 2. 連線測試（連不到就早點失敗，不要傳到一半才爆）
     ├─ 3. rsync -a --delete --checksum --exclude-from=deploy_exclude.txt
     ├─ 4. ssh 執行 post_deploy 腳本（chown + 重產 manifest）
     └─ 5. 立刻對一次雜湊
```

---

## 2. rsync 參數逐一說明

```bash
rsync -a --delete --checksum \
      --human-readable --itemize-changes \
      --exclude-from=deploy_exclude.txt \
      -e "ssh -i <key> -o StrictHostKeyChecking=yes ..." \
      dagster_workspace/  gitlab_runner@VM4:/data/deploy/workspace/dagster_workspace/
```

| 參數 | 為什麼 |
|---|---|
| `-a` | 保留權限、時間、符號連結 |
| `--delete` | **repo 裡刪掉的檔案，正式機上也要刪掉**。沒有這個的話，正式機會慢慢累積一堆已經廢棄的舊模型，而且它們還會被 dbt 撿去跑 |
| `--checksum` | 只看內容、不看 mtime。CI 每次都是全新 checkout，mtime 一定跟正式機不同，用預設的 size+mtime 判斷會**每次全量重傳** |
| `--exclude-from` | 排除清單，同時也是**刪除保護清單**（見下一節） |
| `--itemize-changes` | 讓 pipeline log 看得出到底改了什麼，出事時可以回頭查 |
| `-e "ssh ..."` | 指定金鑰與 known_hosts |

### 來源路徑結尾的 `/` 很重要

```bash
rsync -a dagster_workspace/  target/     # ✅ 把「內容」放進 target/
rsync -a dagster_workspace   target/     # ❌ 變成 target/dagster_workspace/
```

腳本裡是 `"${ROOT}/${SOURCE_DIR}/"`，結尾有 `/`。改的時候不要弄掉。

### StrictHostKeyChecking=yes

不要為了「方便」改成 `no` 或 `accept-new`。

CD 通道能寫入正式機的程式碼目錄——如果被中間人接管，
攻擊者可以直接把任意程式碼寫上 VM4 / VM1。
`known_hosts` 由 `DEPLOY_KNOWN_HOSTS` 這個 File 型別變數提供，
內容取得方式見 [附錄 A](../附錄/A_gitlab_runner帳號與SSH金鑰.md#4-取得-known_hosts)。

---

## 3. 排除清單 = 刪除保護清單（★最重要的一節★）

```
deploy_exclude.txt
```

**rsync 的 `--delete` 不會刪掉被 `--exclude` 排除的檔案。**
（會刪的是 `--delete-excluded`，我們刻意不用。）

所以這份清單同時在做兩件事：

1. **不傳**：repo 裡沒有的東西不會被推過去
2. **不刪**：正式機上有、但被排除的東西會活下來

第 2 點是 `.env` 和 `profiles.yml` 得以存活的唯一原因。

### 漏一行的後果

```
deploy_exclude.txt 裡漏掉 dagster_code/.env
     ↓
rsync --delete 執行
     ↓
「repo 裡沒有 .env，但正式機上有」→ 判定為多餘的檔案 → 刪掉
     ↓
Dagster 連不上資料庫，整條線停擺
```

**改這個檔案的 MR 一定要有人認真 review。**

### 現在保護了哪些

| 路徑 | 為什麼不能被刪 |
|---|---|
| `dagster_code/.env` | 資料庫連線帳密，人工建立，不進版控 |
| `dbt_project/profiles.yml` | 同上 |
| `dbt_project/target/` | dbt 編譯產出，部署後重產 |
| `dbt_project/logs/` | dbt 執行 log |
| `dagster_home/storage/` | **Dagster 的 run 歷史與 sensor cursor**。刪掉等於清空所有執行紀錄，sensor 會從頭重掃 |
| `dagster_home/schedules/` | 排程狀態 |

### 新增一種執行期產物時

**兩份都要改**：

| 檔案 | 管什麼 | 路徑基準 |
|---|---|---|
| `.gitignore` | 什麼進版控 | repo 根目錄 |
| `deploy_exclude.txt` | rsync 不傳、不刪 | `dagster_workspace/` |

只改一邊的話：

- 只改 `.gitignore` → 檔案不進版控，但 rsync 會把正式機上那份**刪掉**
- 只改 `deploy_exclude.txt` → 檔案會被 commit 進 repo（可能夾帶機密）

### 怎麼驗證排除清單是對的

**部署前一定要先 dry-run**：

```bash
ci/deploy_rsync.sh --dry-run
```

逐行看輸出，特別注意 `deleting` 開頭的行：

```
deleting dbt_project/models/OLD_MODEL.sql      ← 這個對，repo 裡確實刪了
deleting dagster_code/.env                     ← ★★★ 停！排除清單有問題 ★★★
```

---

## 4. post-deploy 腳本

rsync 完之後，透過 ssh 在目標機上執行：

```bash
sudo /usr/local/sbin/dai-post-deploy-vm4.sh      # VM4
sudo /usr/local/sbin/dai-post-deploy-vm1.sh      # VM1
```

### 為什麼要一支固定腳本，而不是直接下 sudo chown

如果 sudoers 寫成：

```
gitlab_runner ALL=(root) NOPASSWD: /bin/chown       # ❌ 千萬不要
```

那等於把整台機器送給任何拿到部署金鑰的人——
可以 `chown` 任意檔案，包括 `/etc/shadow`、`/etc/sudoers`。

改成只放行一支**參數寫死在腳本裡**的固定腳本：

```
gitlab_runner ALL=(root) NOPASSWD: /usr/local/sbin/dai-post-deploy-vm4.sh
```

權限邊界就縮到「只能 chown 那一個目錄」。

> 🔒 腳本本身必須 `root:root 0755`。
> 如果 `gitlab_runner` 改得動腳本內容，那還是等於拿到 root。

### VM4 的 post-deploy 做什麼

| 步驟 | 為什麼 |
|---|---|
| `chown -R 10001:10001` | Dagster 容器以 UID 10001 執行，rsync 過來的檔案屬於 `gitlab_runner`，不改的話容器 Permission denied（部署手冊 Phase 0-7 說的就是這件事） |
| 目錄 750 / 檔案 640 | 裡面有 SQL 邏輯與表結構，不是公開資訊 |
| `.env` / `profiles.yml` 收到 600 | 機密檔案只有擁有者能讀 |
| `dbt parse` | 重產 `manifest.json`。Dagster 靠它產生 dbt 資產——沒重產的話新模型在 UI 上根本不存在 |

### VM1 的 post-deploy 做什麼

| 步驟 | 為什麼 |
|---|---|
| `chown -R bcp_runner:bcp_runner` | 腳本由 `bcp_runner` 執行（Dagster 從 VM4 ssh 進來就是這個身分） |
| 750 / 640 | 這些腳本讀得到 `/home/bcp_runner/.env` |
| `python -m compileall` | **用 VM1 實際的 Python 版本**再編一次。CI runner 跟 VM1 的 Python 版本不見得一樣，版本相關的語法問題只有這裡驗得出來 |

> 💡 VM1 的腳本刻意**不給執行位元**（只有 `.sh` 例外）。
> Dagster Pipes 是用 `python xxx.py` 呼叫的，不靠 shebang，
> 少一個執行位元就少一條被誤用的路徑。

---

## 5. Rollback

CD 沒有內建 rollback 按鈕。要退版的話：

### 方法 A：revert（建議）

```bash
git checkout main && git pull
git revert <出問題的 merge commit> -m 1
git push origin main       # main 是保護分支，要 Maintainer 才推得動
                           # 或一樣開一個 MR
```

好處：歷史完整，看得出「上了又退」這件事發生過。

### 方法 B：重跑舊的 pipeline

GitLab UI → CI/CD → Pipelines → 找到上一個好的 pipeline → `deploy:production` job → Retry

**注意**：這只會把「那個 commit 的檔案」推上去，
但 `main` 分支還是壞的。下次有人合併 MR 時又會把壞的推回去。
所以這只能當**緊急止血**，事後一定要補 revert。

### 方法 C：從備份還原

只有在前兩者都不行時（例如 GitLab 本身掛了）。
部署前的備份見 [附錄 A · 首次接管既有目錄](../附錄/A_gitlab_runner帳號與SSH金鑰.md)。

---

## 6. 兩個 repo 的 SOURCE_DIR 不一樣

| repo | `SOURCE_DIR` | 意思 |
|---|---|---|
| `dagster-workspace` | `dagster_workspace` | repo 裡的**子目錄**才是部署單位（根目錄還有 `docs/`、`ci/`） |
| `bcp-scripts` | `.` | **repo 根目錄本身**就是 `/home/bcp_runner/scripts/` 的內容 |

因為這個差別，`bcp-scripts` 的 `deploy_exclude.txt` **必須**把
`ci/`、`docs/`、`.gitlab-ci.yml`、`README.md` 排除掉，
否則這些工具檔會被推到 VM1 上去。範本已經寫好了，見
[`gitlab_workspace/repo_templates/bcp_scripts_repo/deploy_exclude.txt`](../../../gitlab_workspace/repo_templates/bcp_scripts_repo/deploy_exclude.txt)。

---

## 7. resource_group 與 interruptible

```yaml
deploy:production:
  interruptible: false
  resource_group: production-vm4
```

| 設定 | 防止什麼 |
|---|---|
| `interruptible: false` | 部署跑到一半被新的 pipeline 取消，留下「同步到一半」的狀態 |
| `resource_group` | 兩個 deploy job 同時對同一台機器 rsync，互相踩踏 |

這兩個都不要拿掉。

---

## 8. 為什麼是「VM3 推」而不是「VM4 拉」

| | rsync 推（現在的做法） | git pull（另一種常見做法） |
|---|---|---|
| 正式機需要裝 git 嗎 | ❌ 不用 | ✅ 要 |
| 正式機需要能連 GitLab 嗎 | ❌ 不用 | ✅ 要（多開一條防火牆） |
| 正式機上有 `.git` 目錄嗎 | ❌ 沒有 | ✅ 有（多一份完整程式碼歷史躺在正式機上） |
| 誰決定部署時機 | GitLab（集中控制） | 正式機（要另外排程或裝 agent） |
| 部署紀錄在哪 | GitLab pipeline，完整 | 要自己做 |

推的模式讓正式機保持「純執行環境」——上面只有正在跑的那一版程式碼，
沒有版控歷史、沒有對 GitLab 的連線。爆炸半徑比較小。

代價是要開 VM3 → VM1/VM4 的 22 port，並且好好保管那兩把私鑰。

---

## 相關文件

- 金鑰怎麼建、怎麼輪替 → [附錄 A](../附錄/A_gitlab_runner帳號與SSH金鑰.md)
- 雜湊對帳 → [12_同步完整性稽核](./12_同步完整性稽核.md)
- 部署失敗排查 → [14_疑難排解](./14_疑難排解.md)
