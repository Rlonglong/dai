# 附錄 A · `gitlab_runner` 帳號與 SSH 金鑰

三台 VM 都要有 `gitlab_runner` 這個 OS 帳號，但角色不同。這份講怎麼建、怎麼驗、怎麼輪替。

---

## 1. 誰是誰

```
VM3 的 gitlab_runner  ← CD runner 的執行身分，持有兩把私鑰（發送端）
        │
        ├─ ~/.ssh/gitlab_to_vm4  ──rsync/ssh──▶  VM4 的 gitlab_runner（只收）
        └─ ~/.ssh/gitlab_to_vm1  ──rsync/ssh──▶  VM1 的 gitlab_runner（只收）
```

| 機器 | 角色 | 需要私鑰嗎 | 需要能登出去嗎 |
|---|---|---|---|
| **VM3** | 發送端 | ✅ 兩把 | ✅ |
| **VM4** | 接收端 | ❌ | ❌ |
| **VM1** | 接收端 | ❌ | ❌ |

> 📌 這跟 Dagster 用的 `dagster_user → bcp_runner` 是**兩條完全獨立的通道**。
> **不要共用金鑰。** 那條是「執行期指揮」，這條是「部署」，
> 用途、時機、風險都不同，出事時也要能分別停掉。

---

## 2. 建立帳號

### VM4（接收端）

```bash
# 在 VM4，以 root
useradd -m -s /bin/bash gitlab_runner
mkdir -p /home/gitlab_runner/.ssh
chmod 700 /home/gitlab_runner/.ssh
chown -R gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh

# 部署目標目錄要能寫
#   Dagster 容器是 UID 10001，gitlab_runner 是另一個 UID，
#   靠 ACL 讓兩者都能操作同一個目錄
mkdir -p /data/deploy/workspace/dagster_workspace
setfacl -R -m u:gitlab_runner:rwx /data/deploy/workspace/dagster_workspace
setfacl -d -m u:gitlab_runner:rwx /data/deploy/workspace/dagster_workspace
#          ↑ -d 是 default ACL：之後新建的檔案自動繼承，
#            不然 rsync 建的新目錄 gitlab_runner 會進不去

# post-deploy 腳本
install -o root -g root -m 755 dai-post-deploy-vm4.sh /usr/local/sbin/

cat > /etc/sudoers.d/dai-gitlab-runner <<'EOF'
gitlab_runner ALL=(root) NOPASSWD: /usr/local/sbin/dai-post-deploy-vm4.sh
Defaults!/usr/local/sbin/dai-post-deploy-vm4.sh !requiretty
EOF
chmod 440 /etc/sudoers.d/dai-gitlab-runner
visudo -c        # ★一定要驗★ sudoers 寫錯會讓整台機器的 sudo 失效
```

### VM1（接收端）

```bash
# 在 VM1，以 root
useradd -m -s /bin/bash gitlab_runner
mkdir -p /home/gitlab_runner/.ssh
chmod 700 /home/gitlab_runner/.ssh
chown -R gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh

setfacl -R -m u:gitlab_runner:rwx /home/bcp_runner/scripts
setfacl -d -m u:gitlab_runner:rwx /home/bcp_runner/scripts

install -o root -g root -m 755 dai-post-deploy-vm1.sh /usr/local/sbin/

cat > /etc/sudoers.d/dai-gitlab-runner <<'EOF'
gitlab_runner ALL=(root) NOPASSWD: /usr/local/sbin/dai-post-deploy-vm1.sh
Defaults!/usr/local/sbin/dai-post-deploy-vm1.sh !requiretty
EOF
chmod 440 /etc/sudoers.d/dai-gitlab-runner
visudo -c
```

> 🔒 **為什麼 sudoers 只放行一支參數寫死的腳本**
> 如果寫 `NOPASSWD: /bin/chown`，任何拿到部署金鑰的人都能 `chown` 任意檔案
> （包括 `/etc/shadow`、`/etc/sudoers`），等於直接拿到 root。
> 腳本本身也必須 `root:root 0755` —— `gitlab_runner` 改得動腳本 = 一樣拿到 root。

### VM3（發送端）

```bash
# 在 VM3，以 root
useradd -m -s /bin/bash gitlab_runner
mkdir -p /home/gitlab_runner/.ssh
chmod 700 /home/gitlab_runner/.ssh
chown -R gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh
```

---

## 3. 產生並派發金鑰

**正式與測試要用不同的金鑰對**——共用的話，拿到測試金鑰的人就能登入正式機。

```bash
# 在 VM3，切換成 gitlab_runner
su - gitlab_runner

# 正式環境用的兩把（ed25519 比 RSA 短、快、安全性相當）
ssh-keygen -t ed25519 -N "" -C "gitlab-cd-to-vm4-prod" -f ~/.ssh/gitlab_to_vm4
ssh-keygen -t ed25519 -N "" -C "gitlab-cd-to-vm1-prod" -f ~/.ssh/gitlab_to_vm1

# 測試環境另外兩把
ssh-keygen -t ed25519 -N "" -C "gitlab-cd-to-vm4-stg" -f ~/.ssh/gitlab_to_vm4_stg
ssh-keygen -t ed25519 -N "" -C "gitlab-cd-to-vm1-stg" -f ~/.ssh/gitlab_to_vm1_stg

chmod 600 ~/.ssh/gitlab_to_*
chmod 644 ~/.ssh/gitlab_to_*.pub
```

> `-N ""` 是空 passphrase。CI 沒有人可以互動輸入密碼，所以只能這樣。
> 補償措施是下一節的 `from=` 限制 + `restrict` + 定期輪替。

### 派發公鑰到目標機

```bash
# 把公鑰內容印出來
cat ~/.ssh/gitlab_to_vm4.pub
```

到 **VM4**，以 root：

```bash
# ★不要用 ssh-copy-id★ 那會用預設選項寫入，少了下面的限制條件
cat >> /home/gitlab_runner/.ssh/authorized_keys <<'EOF'
from="<VM3_IP>",restrict,pty ssh-ed25519 AAAAC3Nz...（貼上公鑰全文） gitlab-cd-to-vm4-prod
EOF

chmod 600 /home/gitlab_runner/.ssh/authorized_keys
chown gitlab_runner:gitlab_runner /home/gitlab_runner/.ssh/authorized_keys
```

**限制條件的意思**：

| 選項 | 作用 |
|---|---|
| `from="<VM3_IP>"` | **只有從 VM3 這個 IP 來的連線才接受**。金鑰外流到別台機器也用不了 |
| `restrict` | 關掉 port forwarding、agent forwarding、X11 forwarding。這條通道只需要執行指令，不需要當跳板 |
| `pty` | `restrict` 會連 pty 一起關掉，但 `sudo` 需要它，所以加回來 |

VM1 同樣做一次（用 `gitlab_to_vm1.pub`）。

---

## 4. 取得 known_hosts

CD 用 `StrictHostKeyChecking=yes`，所以要先把目標機的 host key 記下來。

```bash
# 在 VM3，以 gitlab_runner
ssh-keyscan -t ed25519,rsa <VM4_IP> >  ~/.ssh/known_hosts_vm4
ssh-keyscan -t ed25519,rsa <VM1_IP> >  ~/.ssh/known_hosts_vm1
chmod 644 ~/.ssh/known_hosts_vm*
```

> ⚠️ `ssh-keyscan` 本身不驗證真偽（它就是「相信第一次看到的」）。
> 嚴謹的做法是**直接到目標機上讀 host key 的指紋**再核對：
> ```bash
> # 在 VM4 上
> ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
> # 在 VM3 上比對
> ssh-keygen -lf ~/.ssh/known_hosts_vm4
> ```
> 兩邊的指紋一樣才算數。第一次建置時務必做這一步。

---

## 5. 驗證

```bash
# 在 VM3，以 gitlab_runner
ssh -i ~/.ssh/gitlab_to_vm4 \
    -o UserKnownHostsFile=~/.ssh/known_hosts_vm4 \
    -o StrictHostKeyChecking=yes \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    gitlab_runner@<VM4_IP> \
    'echo "登入成功"; id; ls -ld /data/deploy/workspace/dagster_workspace'
```

沒有跳密碼提示、直接印出結果就成功了。

```bash
# 再驗 sudo 的部分
ssh -i ~/.ssh/gitlab_to_vm4 ... gitlab_runner@<VM4_IP> \
    'sudo -n /usr/local/sbin/dai-post-deploy-vm4.sh'
# -n 是「不要問密碼，要問就直接失敗」
```

### 反向驗證：限制真的有效嗎

```bash
# 從「不是 VM3」的機器試同一把金鑰 → 應該被拒
ssh -i gitlab_to_vm4 gitlab_runner@<VM4_IP>
# 預期：Permission denied (publickey)

# 試 port forwarding → 應該被拒（restrict 生效）
ssh -i ~/.ssh/gitlab_to_vm4 -L 9999:localhost:22 gitlab_runner@<VM4_IP>
```

---

## 6. 把金鑰放進 GitLab

Settings → CI/CD → Variables → Add variable

| 欄位 | 值 |
|---|---|
| Key | `DEPLOY_SSH_KEY` |
| **Type** | **File** ← 私鑰是多行的，Variable 型別會壞掉 |
| Value | `cat ~/.ssh/gitlab_to_vm4` 的**完整內容**（含 BEGIN/END 兩行） |
| Protect variable | ✅ |
| Environment scope | `production` |

同樣方式加 `DEPLOY_KNOWN_HOSTS`（值是 `known_hosts_vm4` 的內容）。

`staging` scope 用測試機的那組。

> 💡 貼上之後**把 VM3 上的私鑰檔案留著**（CD runner 不一定用得到，
> 但輪替與除錯時需要）。權限保持 600、只有 `gitlab_runner` 讀得到。

---

## 7. 金鑰輪替

**建議每半年一次**，以及以下情況**立即**：

- 有 Maintainer 權限的人離職／轉調
- 懷疑金鑰外流
- 目標機重灌

### 步驟（可以不中斷服務）

```bash
# 1. 產新金鑰（不要覆蓋舊的）
su - gitlab_runner
ssh-keygen -t ed25519 -N "" -C "gitlab-cd-to-vm4-prod-$(date +%Y%m)" \
           -f ~/.ssh/gitlab_to_vm4_new

# 2. 新公鑰「加到」目標機（舊的先留著，這時候兩把都能用）
cat ~/.ssh/gitlab_to_vm4_new.pub
#    到 VM4 append 進 authorized_keys，一樣要加 from= 和 restrict

# 3. 驗證新金鑰能用
ssh -i ~/.ssh/gitlab_to_vm4_new ... gitlab_runner@<VM4_IP> 'echo OK'

# 4. 更新 GitLab 的 DEPLOY_SSH_KEY 變數為新私鑰內容

# 5. 跑一次 deploy job（或手動 verify_sync）確認 CD 正常

# 6. 確認沒問題之後，才從目標機的 authorized_keys 刪掉舊的那一行

# 7. VM3 上刪掉舊私鑰
shred -u ~/.ssh/gitlab_to_vm4
mv ~/.ssh/gitlab_to_vm4_new ~/.ssh/gitlab_to_vm4
mv ~/.ssh/gitlab_to_vm4_new.pub ~/.ssh/gitlab_to_vm4.pub
```

> ★ 順序不能顛倒 ★
> 先刪舊的再驗新的話，中間只要有一步出錯，CD 就完全斷了，
> 而且你連不上去修（因為金鑰已經刪了）。

輪替完在
[13_Variables與環境隔離 · 變數盤點表](../進階調整/13_Variables與環境隔離.md#7-變數盤點表建議印出來貼在交接本)
上記錄日期。

---

## 8. 防火牆

CD 需要新開兩條規則：

| 來源 | 目的 | Port | 用途 |
|---|---|---|---|
| VM3 | VM4 | TCP 22 | rsync + post-deploy + 雜湊對帳 |
| VM3 | VM1 | TCP 22 | 同上 |

> 完整的跨 VM 防火牆表見 Redmine `DAI 跨 VM 防火牆開通及 DNS 申請`，
> 這兩條要記得補進去。

---

## 9. 首次接管既有目錄

VM1 / VM4 上已經有正在跑的檔案，第一次讓 CD 接管時：

```bash
# 1. ★先備份★ 萬一排除清單有漏，這是唯一的救命索
tar czf /root/backup_before_cd_$(date +%F).tar.gz /home/bcp_runner/scripts
tar czf /root/backup_before_cd_$(date +%F).tar.gz /data/deploy/workspace/dagster_workspace

# 2. 確認 .env / profiles.yml 都在，並記下內容（等下要核對它們有沒有活下來）
sha256sum /data/deploy/workspace/dagster_workspace/dagster_code/.env

# 3. ★一定要先 dry-run★
ci/deploy_rsync.sh --dry-run

# 4. 逐行檢查輸出，特別是 deleting 開頭的行
#    看到 deleting .env 或 deleting profiles.yml 就停下來，
#    表示排除清單有問題

# 5. 確認無誤才真的跑
ci/deploy_rsync.sh

# 6. 核對機密檔案還在、內容沒變
sha256sum /data/deploy/workspace/dagster_workspace/dagster_code/.env
```

備份至少保留一個月再刪。

---

## 10. 檢查清單

```
[ ] VM1 / VM3 / VM4 都建好 gitlab_runner 帳號
[ ] VM1 / VM4 的目標目錄設好 ACL（含 -d default ACL）
[ ] VM1 / VM4 的 post_deploy 腳本安裝好，root:root 0755
[ ] VM1 / VM4 的 sudoers 設好，visudo -c 通過
[ ] VM3 產好四把金鑰（正式 2 + 測試 2）
[ ] 公鑰加進目標機，且有 from= 與 restrict 限制
[ ] host key 指紋人工核對過
[ ] 免密碼登入驗證通過
[ ] sudo -n post_deploy 驗證通過
[ ] 反向驗證：從別台機器用同一把金鑰 → 被拒
[ ] GitLab Variables 設好（File 型別、Protected、environment scope）
[ ] 防火牆 VM3→VM4:22、VM3→VM1:22 已開通
[ ] 首次部署前已備份，且 dry-run 檢查過
[ ] 首次部署後 .env / profiles.yml 的 sha256 沒變
```
