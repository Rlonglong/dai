# deploy_package_vm4 —— PostgreSQL + Dagster（VM4）

**解開位置**：`/data/deploy`（VM4 的部署根目錄）

> VM4 的資料碟掛在 `/data`，跟 VM1／VM3／VM5 的 `/run/media/root/D` 不一樣。
> 完整步驟見[部署手冊](../README.md) Phase 1。

---

## 這個包裡有什麼

```
deploy_package_vm4/
├── README.md                       ← 你正在看的這份
├── docker-compose.yml              ← security-hardened 版本，直接就在部署根目錄
├── .env.example                    ← ★cp 成 .env 再填★（Phase 0-6）
│
├── certs/                          ← 只有 CA 信任鏈（VM4 不對外提供 TLS 服務）
│   ├── GRCA3.crt                       → /etc/pki/ca-trust/source/anchors/
│   └── GCA3.crt
│
├── os_packages/
│   └── docker/                     ← Docker 的 RPM（Phase 0-1）
│
├── security/
│   └── seccomp-dagster.json        ← 三個 dagster 容器共用（compose 已引用）
│
└── workspace/
    ├── init-infra-db.sql           ← infra-db 首次啟動時建立五個資料庫
    ├── dagster_workspace/          ← Dagster 程式與 dbt 專案（DAGSTER_WORKSPACE）
    │                                  之後由 CD 從 VM3 rsync 覆蓋，見 Phase 4
    ├── dagster_data/               ← 落地檔工作目錄（DAGSTER_DATA_DIR，容器內 /data）
    ├── rsyslog/                    ← Phase 6-2
    │   ├── vm4-server.conf             集中接收端 → /etc/rsyslog.d/10-dai-server.conf
    │   └── vm4-integrity-forward.conf  雜湊 manifest 轉發到 VM1
    │                                   → /etc/rsyslog.d/25-dai-integrity-fwd.conf
    ├── scripts/
    │   └── log_hash.sh             ← 每日雜湊存證 → /opt/dai/scripts/（Phase 6-3）
    └── logrotate/
        └── dai                     ← → /etc/logrotate.d/dai（Phase 6-4）
```

---

## 開始之前一定要做的三件事

```bash
cd /data/deploy

# 1. 建 .env
cp .env.example .env && vim .env && chmod 600 .env

# 2. init-infra-db.sql 裡的密碼要跟 VM3／VM5 的 .env 對得起來
vim workspace/init-infra-db.sql

# 3. Dagster 容器是 UID 10001，掛載目錄要先給它
chown -R 10001:10001 workspace/dagster_workspace workspace/dagster_data
```

> ⚠️ `workspace/init-infra-db.sql` **只在 PostgreSQL 資料目錄是空的時候會執行一次**。
> 改了之後要重跑，必須先 `docker compose down` 並刪掉 `infra-db-data` volume。

## 不在這個包裡、但 VM4 要用到的

| 東西 | 從哪裡來 |
|---|---|
| `dagster_code/.env`、`dbt_project/profiles.yml` | **人工建立**，不進版控、`deploy_exclude.txt` 保護它們不被 rsync 刪掉 |
| `dai-post-deploy-vm4.sh` | 從 **VM3** 的包 `gitlab_workspace/post_deploy/` scp 過來（Phase 4B） |
