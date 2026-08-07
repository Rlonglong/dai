# Trivy Image 弱點資料庫更新手冊

**適用範圍**：air-gapped 環境下，透過重新 build `dai/trivy` image 的方式更新 Trivy 弱點資料庫（trivy-db、trivy-java-db）。
**Base image**：`dai/trivy:v1.0`（固定 pin 版本，每次更新資料庫皆以此為 base，不隨意更動）。
**維護者**：CY
**最後更新**：2026-08-06

---

## 0. 流程總覽

整體流程分五個階段，其中「下載」跟「驗證」必須在**有網路連線的環境**執行，其餘階段在**氣隙環境**內完成：

```
[有網路環境]                          [VM1 資料交換區]        [氣隙環境]
下載 trivy-db / trivy-java-db  ──►   傳輸  ──►  解壓至 security/vulner_db/  ──►  docker build  ──►  驗證  ──►  retag 上傳內部 registry  ──►  更新部署參照
   │
   └─ 簽章驗證（cosign）
```

> ⚠️ 這份 Dockerfile 只處理「弱點資料庫」的更新，**不處理 Trivy 二進位本體版本**（那是 `dai/trivy:v1.0` 這個 base image 本身的事）。兩者是獨立的更新週期，見第 6 節說明，不要混為一談。

---

## 1. 前置需求（有網路連線的環境）

需要一台可以連上網路、且已安裝 `trivy` CLI 的機器（版本建議與 `dai/trivy:v1.0` 內建的 Trivy 版本一致或至少不低於它，避免資料庫 schema 版本不相容，見第 7 節）。

```bash
trivy --version
```

若尚未安裝，依你們現行的簽章驗證慣例，安裝時也應驗證下載的 Trivy 二進位本身（見第 3 節事件背景）。

---

## 2. 下載弱點資料庫

Trivy 的弱點資料庫分兩個獨立的 OCI artifact：主資料庫（`trivy-db`）跟 Java 相依套件索引庫（`trivy-java-db`），需要分開下載。

### 2.1 下載主資料庫

```bash
TRIVY_TEMP_DIR=$(mktemp -d)
trivy --cache-dir "$TRIVY_TEMP_DIR" image --download-db-only
tar -cf ./db.tar.gz -C "$TRIVY_TEMP_DIR/db" metadata.json trivy.db
rm -rf "$TRIVY_TEMP_DIR"
```

### 2.2 下載 Java 索引資料庫

```bash
TRIVY_TEMP_DIR=$(mktemp -d)
trivy --cache-dir "$TRIVY_TEMP_DIR" image --download-java-db-only
tar -cf ./javadb.tar.gz -C "$TRIVY_TEMP_DIR/java-db" metadata.json trivy-java.db
rm -rf "$TRIVY_TEMP_DIR"
```

執行完後，解壓這兩個 tar.gz，會分別得到：

```
db/
├── metadata.json
└── trivy.db

java-db/
├── metadata.json
└── trivy-java.db
```

這兩組檔案就是 Dockerfile 裡 `COPY` 指令要放進去的內容，對應到你 Dockerfile 裡的：

```dockerfile
COPY --chown=trivy:trivy ../security/vulner_db/db/ /home/trivy/.cache/trivy/db/
COPY --chown=trivy:trivy ../security/vulner_db/java-db/ /home/trivy/.cache/trivy/java-db/
```

也就是說，解壓後要把 `db/` 整個目錄放到 build context 的 `security/vulner_db/db/`，`java-db/` 放到 `security/vulner_db/java-db/`。

### 2.3 確認資料庫時效性

解壓後檢查 `metadata.json` 的更新時間，確保下載到的確實是最新版本，而不是快取住的舊版：

```bash
cat db/metadata.json
cat java-db/metadata.json
```

留意裡面的 `UpdatedAt` 欄位。

---

## 3. 簽章驗證（建議步驟）

### 3.1 背景

2026 年 3 月，Trivy 生態系發生過一次供應鏈攻擊事件（CVE-2026-33634）：攻擊者利用外洩憑證，對 Trivy 二進位本體（v0.69.4）、`trivy-action`、`setup-trivy` 這幾個發布管道植入竊憑證的惡意程式碼，波及範圍包含 GHCR、Docker Hub 上發布的映像檔。這起事件本身**不是**針對弱點資料庫（`trivy-db`/`trivy-java-db`）的內容遭竄改，但既然你們現行的映像檔管理已經導入 pinned version + cosign 簽章驗證的作法（因應同一起事件），建議下載資料庫時也一併驗證，把整條供應鏈的驗證原則統一。

### 3.2 驗證指令

Aqua Security 對外發布的 artifact（含容器映像檔）採 Sigstore 的 keyless 簽章機制，驗證方式：

```bash
cosign verify ghcr.io/aquasecurity/trivy-db:2 \
  --certificate-identity-regexp 'https://github\.com/aquasecurity/' \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"

cosign verify ghcr.io/aquasecurity/trivy-java-db:1 \
  --certificate-identity-regexp 'https://github\.com/aquasecurity/' \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

> 這裡的 `--certificate-identity-regexp` 用的是涵蓋整個 `aquasecurity` GitHub organization 的寬鬆比對，若要更嚴謹地只允許 `trivy-db` repo 自己的 release workflow 簽署，可以收斂成 `'https://github\.com/aquasecurity/trivy-db/\.github/workflows/.+'`，收斂後請先手動測試一次確認能通過驗證，避免收斂過頭導致合法版本也被擋下。

若 `cosign` 尚未安裝在下載用的機器上，需先另外安裝（不在本手冊範圍，可依你們既有的 cosign 安裝流程處理）。

---

## 4. 傳輸進氣隙環境

依你們現行透過 VM1 隔離資料交換區的標準流程，將下列內容傳入氣隙環境的 build context：

```
security/vulner_db/db/
├── metadata.json
└── trivy.db

security/vulner_db/java-db/
├── metadata.json
└── trivy-java.db
```

> 建議連同下載時的 `metadata.json`（已包含在上方目錄結構內）一併保留，方便日後追查「這批資料庫是哪個時間點下載的」，不要在傳輸過程中被覆蓋或遺失。

---

## 5. Build 新版 Image

### 5.1 目錄結構確認

Build 前確認 Dockerfile 與 `security/vulner_db/` 的相對路徑關係正確（Dockerfile 內用的是 `../security/vulner_db/`，代表 build context 需要包含 Dockerfile 所在目錄的上一層，執行 build 指令時要注意 context 路徑跟 `-f` 參數的相對位置是否對得上）。

### 5.2 Build 指令

```bash
docker build \
  --build-arg TRIVY_VERSION=v1.0 \
  -t dai/trivy:db-$(date +%Y%m%d) \
  -f Dockerfile.trivy-db \
  <build-context-path>
```

### 5.3 Tag 命名建議

因為 `dai/trivy:v1.0` 這個 base 版本號不會隨資料庫更新而改變（base 只有在 Trivy 本體版本升級時才會動），建議新產出的 image 用**日期作為 tag**，例如 `dai/trivy:db-20260806`，避免每次更新資料庫都覆蓋掉同一個 tag，方便追蹤歷史版本、也方便有問題時快速回退到前一版資料庫。

---

## 6. 驗證新 Image

Build 完成後，在氣隙環境內做基本的功能驗證，確認資料庫確實生效、且掃描功能正常：

```bash
# 確認 image 內的資料庫時間戳記與預期一致
docker run --rm dai/trivy:db-20260806 \
  cat /home/trivy/.cache/trivy/db/metadata.json

# 用一個已知的測試映像檔跑一次掃描，確認可以正常掃出結果（不需連網）
docker run --rm dai/trivy:db-20260806 \
  image --skip-db-update --skip-java-db-update --offline-scan \
  <內部測試用 image>
```

若掃描結果正常產出（不是因為找不到資料庫而報錯、也不是嘗試連外網被擋下），代表這次的資料庫更新成功。

---

## 7. 部署更新

1. 依你們現行的 GitLab CI 流程，透過 Skopeo 將新 build 出來的 `dai/trivy:db-20260806` retag/上傳至內部 air-gapped registry。
2. 更新 GitLab CI 裡實際引用 Trivy image 的 pipeline 設定，把版本號指向新的 tag。
3. 更新完成後，找一個已知有漏洞的測試對象跑一次正式 pipeline，確認掃描結果符合預期（能抓到已知漏洞），而不只是「沒報錯」。

---

## 8. 兩種更新週期的區別（重要）

| 更新對象 | 更新頻率建議 | 觸發方式 |
|---|---|---|
| 弱點資料庫（本手冊範圍） | 建議每週或每兩週一次，弱點資料每天都在增加 | 重新走一次本手冊流程，base image 不變 |
| Trivy 本體版本（`dai/trivy:v1.0` 這個 base 本身） | 依官方發布節奏跟你們的版本評估週期，不需要跟資料庫同頻率 | 需要重新建置 base image，超出本手冊範圍 |

> ⚠️ 如果 base image 內建的 Trivy 版本太舊，長期下來可能與最新的資料庫 schema 版本不相容（Trivy 官方會不定期調整資料庫 schema，過舊的 Trivy 二進位可能無法讀取太新的資料庫，出現 `local DB has an old schema version` 之類的錯誤）。若第 6 節驗證步驟出現此類錯誤，代表該考慮升級 base image 版本了，不是資料庫下載流程的問題。

---

## 9. 常見問題排解

| 現象 | 可能原因 | 處理方式 |
|---|---|---|
| 掃描時出現 `Permission denied` | `COPY` 時忘記加 `--chown=trivy:trivy`，或是 host 端解壓時的檔案權限跟容器內 `trivy` 使用者對不上 | 確認 Dockerfile 內 `COPY` 指令都有帶 `--chown`，且 host 端來源檔案至少要有 owner 可讀權限 |
| `local DB has an old schema version` | Base image 內的 Trivy 版本過舊，跟下載到的新資料庫 schema 不相容 | 評估升級 `dai/trivy` base image 版本，見第 8 節 |
| 掃描時仍嘗試連外網 | 執行掃描指令時漏加 `--skip-db-update --skip-java-db-update`（掃 Java 相關內容時還需要 `--offline-scan`） | 補上對應參數，確認 `TRIVY_CACHE_DIR` 環境變數有正確指向已包含資料庫的路徑 |
| `cosign verify` 失敗 | Regexp 收斂過頭、或該 artifact 實際上不是走這個簽署流程發布的 | 先用第 3.2 節較寬鬆的 org 層級 regexp 重試一次，若仍失敗，暫停使用該次下載的資料庫並回報 |

---

## 10. 待辦與後續事項

- [ ] 確認 build context 與 Dockerfile 的相對路徑，補上實際的 `docker build` 指令範例中 `<build-context-path>` 與 `-f` 檔名
- [ ] 確認內部測試用的 image 名稱，補進第 6 節驗證指令
- [ ] 建立排程提醒（每週/每兩週），避免資料庫更新流程因為沒有自動化而被遺忘
- [ ] 評估是否要把第 2～6 節寫成自動化腳本，減少手動操作的出錯機會
- [ ] 定期評估 `dai/trivy:v1.0` base image 版本是否需要升級（見第 8 節）
