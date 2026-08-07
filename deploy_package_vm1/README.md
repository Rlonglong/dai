# deploy_package_vm1 —— BCP Pipeline（VM1）

**解開位置**：`/run/media/root/D/deploy`（VM1 的部署根目錄）

> **VM1 不跑容器。** 這個包裡沒有 `docker-compose.yml`、沒有 `.env`、
> 也沒有 Docker 的 rpm。VM1 的腳本是由 VM4 的 Dagster 透過 SSH 叫起來、
> 直接跑在 host 的 Python 3.11 venv 上。
> 完整步驟見[部署手冊](../README.md) Phase 5。

---

## 這個包裡有什麼

```
deploy_package_vm1/
├── README.md                       ← 你正在看的這份
│
├── certs/                          ← 只有 CA 信任鏈（VM1 不對外提供 TLS 服務）
│   ├── GRCA3.crt                       CA 根憑證 → /etc/pki/ca-trust/source/anchors/
│   └── GCA3.crt                        中繼憑證
│
├── python_env/                     ← 離線安裝素材（Phase 0-3、Phase 5-2）
│   ├── README.md                       ★離線安裝的完整說明在這份★
│   ├── py/                             Python 3.11 的 RPM
│   ├── req/                            17 個 wheel + requirements.txt + install_requirements.sh
│   ├── bcp/                            msodbcsql18 / mssql-tools18 / unixODBC 的 RPM
│   └── build_tmp/                      產生上面這些檔案的下載腳本（部署時不需要）
│
├── scripts/                        ← BCP 腳本的初始內容 → /home/bcp_runner/scripts/
│                                      （之後由 CD 從 VM3 rsync 覆蓋，見 Phase 4）
│
├── workspace/
│   └── rsyslog/                    ← Phase 6-2
│       ├── dai_client.conf             轉發端（VM1 → VM4）→ /etc/rsyslog.d/20-dai-client.conf
│       └── vm1-integrity-server.conf   接收 VM4 的雜湊 manifest
│                                       → /etc/rsyslog.d/10-dai-integrity-server.conf
│
└── cicd_template/                  ← 建 `bcp-scripts` GitLab repo 時複製過去的素材
    ├── install.sh                      ★用這支複製，不要手動 cp★
    ├── common/                         ci/ 腳本、.gitleaks.toml、.flake8、pyproject.toml
    └── bcp-scripts/                    .gitlab-ci.yml、.gitignore、deploy_exclude.txt、requirements.txt
```

---

## 各項東西去哪裡

| 來源 | 目的地 | 在哪一步 |
|---|---|---|
| `certs/GRCA3.crt` | `/etc/pki/ca-trust/source/anchors/` | Phase 0-9 |
| `python_env/py/*.rpm` | `dnf localinstall` | Phase 0-3 |
| `python_env/bcp/*.rpm` | `dnf localinstall`（ODBC 驅動） | Phase 0-3 |
| `python_env/req/*.whl` | `/run/media/root/D/python_env/dai_venv` 的 venv | Phase 5-2 |
| `scripts/*` | `/home/bcp_runner/scripts/` | Phase 5 前置 |
| `workspace/rsyslog/*.conf` | `/etc/rsyslog.d/` | Phase 6-2 |
| `cicd_template/` | `~/bcp-scripts-init/`（建 repo 用的暫存目錄） | Phase 4C |

## 不在這個包裡、但 VM1 要用到的

| 東西 | 從哪裡來 |
|---|---|
| `/home/bcp_runner/.env` | **人工建立**，不進版控、不被 rsync 動到（Phase 5-4、5-5） |
| `dai-post-deploy-vm1.sh` | 從 **VM3** 的包 `gitlab_workspace/post_deploy/` scp 過來（Phase 4B） |
| `gitleaks` 執行檔 | 開發者本機用，另外取得（Phase 4H） |
