# GitLab 備援與復原文件（Docker Compose 部署）

**適用範圍**：本文件適用於以 Docker Compose 部署的 GitLab EE（Omnibus 架構）容器，隸屬 DAI 中的 VM3。
**維護者**：CY
**最後更新**：2026-08-04

---

## 1. 備份策略總覽

### 1.1 職責分工

| 項目 | 備份方式 | 負責單位 |
|---|---|---|
| VM 主機層級（磁碟快照） | 定期主機備份 | 公司 VM 管理團隊 |
| GitLab Repository 資料 | 隨 VM 快照涵蓋（不重複另做） | 公司 VM 管理團隊 |
| GitLab DB Metadata（group、成員、權限、protected branch 等） | `gitlab-backup` 應用層備份 | 本文件範圍 |
| `/etc/gitlab/gitlab.rb`（主設定檔） | 檔案備份 | 本文件範圍 |
| `/etc/gitlab/gitlab-secrets.json`（加密金鑰） | 檔案備份 | 本文件範圍 |

### 1.2 為何需要自行備份

GitLab 的 group 設定、成員權限、CI/CD 變數、protected branch 規則等，並非獨立設定檔，而是儲存在內建 **PostgreSQL 資料庫**中。VM 層級的磁碟快照理論上能涵蓋這些資料，但存在風險：
- **金鑰遺失風險**：`gitlab-secrets.json` 內含資料庫加密金鑰，CI/CD variables、2FA secret、OAuth token 等欄位皆以此金鑰加密儲存。若此檔案遺失，即使 DB 備份完整救回，加密欄位仍無法解密，等同資料半損毀。此檔案必須獨立備份，不可只依賴單一來源。

因此本文件的備份範圍聚焦於：**應用層 metadata 備份 + 兩個關鍵設定檔**，作為 VM 快照之外的第二道保險，並用於獨立的復原演練。

---

## 2. 資料實際存放位置

### 2.1 確認 Volume 掛載

執行前務必先確認實際的 docker-compose 掛載設定，不同環境路徑可能不同：

```bash
docker inspect gitlab --format '{{ range .Mounts }}{{ .Source }} -> {{ .Destination }}{{ "\n" }}{{ end }}'
```

### 2.2 標準掛載結構（Omnibus Image）

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ee:<version>
    volumes:
      - /srv/gitlab/config:/etc/gitlab      # gitlab.rb, gitlab-secrets.json, TLS 憑證
      - /srv/gitlab/data:/var/opt/gitlab    # DB 檔案、repo、backups、uploads
      - /srv/gitlab/logs:/var/log/gitlab
```

### 2.3 容器內重要子路徑（`/var/opt/gitlab` 下）

| 路徑 | 內容 | 是否需另外備份 |
|---|---|---|
| `git-data/repositories` | 實際 bare repo | 否（VM 快照涵蓋） |
| `gitlab-rails/uploads` | 使用者上傳檔案 | 否（VM 快照涵蓋） |
| `gitlab-rails/shared/artifacts` | CI/CD artifacts | 否（VM 快照涵蓋） |
| `gitlab-rails/shared/registry` | Container registry（若有開啟） | 否（VM 快照涵蓋） |
| `postgresql/data` | DB 原始檔案 | **不可**直接複製此目錄當備份，須透過 `gitlab-backup` 邏輯備份 |
| `backups` | `gitlab-backup create` 產出的 tar 檔案，預設輸出位置 | 是（此文件核心備份對象） |

> ⚠️ **注意**：`postgresql/data` 屬於資料庫運行中的原始檔案，直接檔案層級複製（如 `cp -r`）容易產生不一致或損毀的備份，務必透過 `gitlab-backup` 的邏輯備份機制。

---

## 3. 日常備份操作

### 3.1 應用層 Metadata 備份（跳過已由 VM 快照涵蓋的部分）

```bash
docker exec -t gitlab gitlab-backup create \
  SKIP=artifacts,registry,repositories,builds,lfs,uploads \
  BACKUP=meta_$(date +%Y%m%d)
```

此指令產出的備份檔主要為 DB dump，包含所有 group、member、權限、protected branch 等設定，體積遠小於完整備份。

### 3.2 關鍵設定檔備份

```bash
docker cp gitlab:/etc/gitlab/gitlab.rb ./gitlab-config-backup/
docker cp gitlab:/etc/gitlab/gitlab-secrets.json ./gitlab-config-backup/
```

### 3.3 備份存放建議

- Metadata 備份 tar 檔 + 兩個設定檔，建議打包後存放至與主機分開的隔離區（如 VM1 資料交換區），避免單點故障。
- 建議排程頻率：每日或每次重大權限異動後執行一次。
- 建議保留策略：至少保留最近 7 份，並定期抽樣做復原驗證（見第 4 節）。

### 3.4 補充做法：可讀性版控（選用）

`gitlab-backup` 產出的 tar 檔為二進位格式，無法直接 diff 或追蹤變更歷程。若需要人類可讀、可版控比對的權限異動紀錄，可另外撰寫排程腳本，透過 GitLab API（`python-gitlab` 套件）將 group 階層、成員權限、protected branch 規則匯出為 YAML/JSON，commit 至獨立的設定管理 repo。此作法不取代 `gitlab-backup`，僅作為額外的稽核與追蹤層，方便掌握「誰、何時、改了什麼權限」。

---

## 4. 復原演練程序

### 4.1 演練原則

- 務必在**獨立測試環境**進行（不同 port / 不同 `external_url`），避免影響正式站。
- Image 版本須與正式站**完全一致**。air-gapped 環境下，先確認對應版本的 image 已同步至內部 registry，流程與現行 Trivy/Skopeo pinned image 機制一致。
- GitLab restore 對版本差異非常敏感，版本不符可能導致還原失敗。

### 4.2 演練步驟

**Step 1：於正式站建立備份**

```bash
docker exec -t gitlab gitlab-backup create BACKUP=drill_$(date +%Y%m%d)
docker cp gitlab:/etc/gitlab/gitlab-secrets.json ./drill-config/
docker cp gitlab:/etc/gitlab/gitlab.rb ./drill-config/
docker cp gitlab:/var/opt/gitlab/backups/drill_20260804_XXXXXX_gitlab_backup.tar ./drill-config/
```

**Step 2：建立全新測試容器**

使用相同 image tag，掛載全新、乾淨的 volume（不可沿用正式站資料）。

**Step 3：還原設定檔並 reconfigure**

```bash
docker cp ./drill-config/gitlab.rb new-gitlab:/etc/gitlab/
docker cp ./drill-config/gitlab-secrets.json new-gitlab:/etc/gitlab/
docker exec -it new-gitlab gitlab-ctl reconfigure
```

**Step 4：放入備份 tar 並設定擁有者**

```bash
docker cp ./drill-config/drill_20260804_XXXXXX_gitlab_backup.tar \
  new-gitlab:/var/opt/gitlab/backups/
docker exec -it new-gitlab chown git:git \
  /var/opt/gitlab/backups/drill_20260804_XXXXXX_gitlab_backup.tar
```

**Step 5：停止相關服務並執行還原**

```bash
docker exec -it new-gitlab gitlab-ctl stop puma
docker exec -it new-gitlab gitlab-ctl stop sidekiq
docker exec -it new-gitlab gitlab-backup restore BACKUP=drill_20260804
```

> 過程中會出現數次確認提示（覆蓋 DB、覆蓋 repo），需人工輸入 `yes` 確認。

**Step 6：重啟並驗證**

```bash
docker exec -it new-gitlab gitlab-ctl restart
docker exec -it new-gitlab gitlab-rake gitlab:check SANITIZE=true
```

登入 Web 介面，逐項確認：

- [ ] Group 階層是否完整
- [ ] 成員權限是否正確
- [ ] Protected branch 規則是否存在
- [ ] CI/CD variables 是否可正常解密（驗證 secrets.json 是否對應正確）
- [ ] Project 清單是否完整

### 4.3 演練紀錄表（建議每次演練填寫）

| 演練日期 | 備份檔版本 | 還原耗時 | 驗證結果 | 問題紀錄 |
|---|---|---|---|---|
| | | | | |

---

## 5. 待辦與後續事項

- [ ] 與公司 VM 管理團隊確認快照機制是否具備資料庫一致性協調
- [ ] 建立排程腳本：`gitlab-backup`（SKIP metadata）+ 設定檔複製 + 保留天數輪替
- [ ] （選用）撰寫 GitLab API 權限匯出腳本，串接現有 GitLab 版控流程
- [ ] 首次復原演練排程與紀錄
