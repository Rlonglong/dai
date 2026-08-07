# deploy_package_vm5 —— Keycloak + Nginx + Superset（VM5）

**解開位置**：`/run/media/root/D/deploy`（VM5 的部署根目錄）

> VM5 是整套系統的 SSO 入口，也是 `dagster.dai.post.gov.tw` /
> `superset.dai.post.gov.tw` 的對外 nginx。
> 完整步驟見[部署手冊](../README.md) Phase 2。

---

## 這個包裡有什麼

```
deploy_package_vm5/
├── README.md                       ← 你正在看的這份
├── docker-compose.yml              ← security-hardened 版本，直接就在部署根目錄
├── .env.example                    ← ★cp 成 .env 再填★（Phase 0-6）
│
├── certs/                          ← TLS 憑證（VM5 對外提供 HTTPS）
│   ├── GRCA3.crt / GCA3.crt            CA 根 / 中繼
│   ├── dai_202606.crt / .key           Domain 憑證與私鑰
│   └── fullcert_202606.crt             憑證鏈（伺服器 → 中繼 → 根）
│
├── os_packages/
│   └── docker/                     ← Docker 的 RPM（Phase 0-1）
│
├── security/
│   ├── seccomp-keycloak.json       ← compose 已引用
│   └── seccomp-superset.json
│
└── workspace/
    ├── nginx/conf.d/               ← NGINX_CONFIG_DIR
    ├── superset_config.py          ← 掛進 superset 容器（Phase 0-12 要 chmod 644）
    ├── custom_sso_security_manager.py  ← 同上
    └── rsyslog/
        └── dai_client.conf         ← 轉發端（VM5 → VM4）→ /etc/rsyslog.d/20-dai-client.conf
```

---

## 開始之前一定要做的兩件事

```bash
cd /run/media/root/D/deploy

# 1. 建 .env
cp .env.example .env && vim .env && chmod 600 .env

# 2. Superset 以非 root 讀這兩個設定檔，權限不足會啟動失敗
chmod 644 workspace/superset_config.py workspace/custom_sso_security_manager.py
```

> ⚠️ `.env` 裡的 `KEYCLOAK_DB_*` / `SUPERSET_DB_*` 必須跟
> **VM4** `workspace/init-infra-db.sql` 建立的資料庫與帳號完全一致，
> 否則 Keycloak / Superset 會連不上資料庫。

## 需要留意的設定

| 項目 | 說明 |
|---|---|
| Keycloak / Superset 的 `dns:` | compose 裡釘的是公司 DNS（`10.10.43.1` / `10.10.43.2`）。IP 不同的話**部署前**要改 compose |
| Keycloak Realm 與 Clients | 不在這個包裡，Phase 2-2 用 API 或 Admin Console 建立 |
| LDAP User Federation | 不在這個包裡，Phase 2-3 需要公司提供實際連線資訊 |
