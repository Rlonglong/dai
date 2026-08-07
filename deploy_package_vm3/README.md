# deploy_package_vm3 —— GitLab + Registry + Dependency-Track（VM3）

**解開位置**：`/run/media/root/D/deploy`（VM3 的部署根目錄）

> VM3 是整套 CI/CD 的中樞：GitLab、Container Registry、Dependency-Track、
> 兩個 GitLab Runner 都在這台。完整步驟見[部署手冊](../README.md) Phase 3、Phase 4。

---

## 這個包裡有什麼

```
deploy_package_vm3/
├── README.md                       ← 你正在看的這份
├── docker-compose.yml              ← security-hardened 版本，直接就在部署根目錄
├── .env.example                    ← ★cp 成 .env 再填★（Phase 0-6）
│
├── certs/                          ← TLS 憑證（VM3 對外提供 HTTPS）
│   ├── GRCA3.crt / GCA3.crt            CA 根 / 中繼
│   ├── dai_202606.crt / .key           Domain 憑證與私鑰
│   ├── fullcert_202606.crt             憑證鏈（伺服器 → 中繼 → 根）
│   └── gitlab.dai.post.gov.tw.crt      給 GitLab Runner 用（內容同憑證鏈，Phase 3-5）
│
├── os_packages/
│   └── docker/                     ← Docker 的 RPM（Phase 0-1）
│
├── security/
│   └── seccomp-gitlab.json         ← compose 已引用
│
├── dockerfile/                     ← 各服務映像的 Dockerfile（重編映像時才用得到）
│
├── workspace/
│   ├── nginx/conf.d/               ← NGINX_VM3_CONFIG_DIR
│   ├── gitlab/                     ← GITLAB_HOME，Phase 3-1 在這底下建 config/logs/data
│   │                                  Phase 3-6 的 gitleaks 執行檔也放這裡
│   ├── gitlab-runner-ci/           ← runner 註冊後的 config.toml 掛載點
│   ├── rsyslog/                    ← Phase 6-2
│   │   ├── dai_client.conf             轉發端（VM3 → VM4）
│   │   └── vm3-gitlab-imfile.conf      GitLab 應用層 log 監聽
│   └── script/                     ← 維運用的輔助腳本
│
├── gitlab_workspace/               ← ★Phase 4 的建置素材★
│   ├── server_hooks/pre-receive        裝進 GitLab 容器（Phase 4D，最關鍵的一步）
│   └── post_deploy/
│       ├── dai-post-deploy-vm4.sh      ★scp 到 VM4★ /usr/local/sbin/
│       └── dai-post-deploy-vm1.sh      ★scp 到 VM1★ /usr/local/sbin/
│
└── cicd_template/                  ← 建兩個 GitLab repo 時複製過去的素材
    ├── install.sh                      ★用這支複製，不要手動 cp★
    ├── common/                         ci/ 腳本、.gitleaks.toml、.flake8、pyproject.toml
    ├── dagster-workspace/              .gitlab-ci.yml、.gitignore、deploy_exclude.txt
    └── bcp-scripts/                    同上 + requirements.txt
```

---

## 開始之前一定要做的兩件事

```bash
cd /run/media/root/D/deploy

# 1. 建 .env（GITLAB_HOME 等路徑都在這裡）
cp .env.example .env && vim .env && chmod 600 .env

# 2. 後面 Phase 3 / Phase 4 的指令都用得到 ${GITLAB_HOME}，先讀進 shell
set -a; . ./.env; set +a
```

## 這個包裡「不是給 VM3 自己用」的東西

| 東西 | 送到哪 | 在哪一步 |
|---|---|---|
| `gitlab_workspace/post_deploy/dai-post-deploy-vm4.sh` | **VM4** `/usr/local/sbin/` | Phase 4B |
| `gitlab_workspace/post_deploy/dai-post-deploy-vm1.sh` | **VM1** `/usr/local/sbin/` | Phase 4B |

> 這兩支腳本裝在 VM1／VM4，但**只放在 VM3 的包裡**，部署時由 VM3 `scp` 過去。
> 這樣「腳本的唯一來源」只有一份，不會出現三台機器各有一份舊版的情況。

## 不在這個包裡、但 VM3 要用到的

| 東西 | 從哪裡來 |
|---|---|
| `gitleaks_<版本>_linux_x64.tar.gz` | 在有網路的機器上從 gitleaks releases 下載後帶進內網（Phase 3-6） |
| GitLab Runner 的註冊 Token | GitLab UI → Admin Area → CI/CD → Runners（Phase 3-5） |
