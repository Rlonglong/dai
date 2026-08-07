#!/usr/bin/env bash
# =============================================================================
# 限制 GitLab repository mirroring 僅 admin 可設定
# 對應 secure_report/gitlab_secure_report.md「四、Go 二進位依賴弱點」
# 風險情境分析第 4 點（golang.org/x/crypto SSH 系列 8 筆 HIGH CVE）
#
# 為何需要這支腳本（而不是寫進 docker-compose/gitlab.rb）：
#   GitLab 的 mirror_available 是存在資料庫裡的 ApplicationSetting，
#   已查證沒有對應的 omnibus gitlab.rb 設定項可以在容器啟動時套用
#   （與 secure_report 第三章 devise 段落的 password_authentication
#   設定屬於同一類限制）。唯一能設定它的方式是 GitLab 啟動後透過
#   Admin UI / Application Settings API / gitlab-rails console。
#   本腳本走 gitlab-rails console（透過 docker exec），可重複執行
#   （idempotent），方便日後排程或在每次部署後手動執行一次以確保設定
#   沒有被意外改回預設值。
#
# 設定效果：mirror_available = false
#   GitLab 官方文件原文："Allow repository mirroring to configured by
#   project Maintainers. If disabled, only Administrators can configure
#   repository mirroring."
#   即一般 Maintainer 角色將無法在專案設定中開啟 pull/push mirror，僅
#   instance admin 能操作——這同時收斂了 golang.org/x/crypto/ssh 系列
#   CVE 的觸發面（GitLab 反過來以 SSH client 連線到使用者指定的外部
#   git remote，是該系列 CVE 的真實觸發路徑）。
#
# 執行前提：gitlab 容器必須已完成 gitlab-ctl reconfigure 並進入
#   healthy 狀態（puma/Rails 可回應），否則 gitlab-rails console 會啟動
#   失敗或逾時。
#
# 用法：
#   ./enforce_gitlab_mirror_admin_only.sh [container_name]
#   container_name 預設為 "gitlab"（對應 docker-compose_vm3_secure.yml
#   的 container_name）。
#
# 建議排程（與 log_hash.sh 同一類用法，cron 範例）：
#   # 每次部署/重啟容器後，等 healthcheck 過了再手動或排程跑一次：
#   0 6 * * * /opt/nexflow/scripts/enforce_gitlab_mirror_admin_only.sh >> /var/log/nexflow/mirror_enforce.log 2>&1
#   （排程僅為「防止設定被意外改回預設值」的保險，非必要的每日重複設定）
# =============================================================================
set -euo pipefail

CONTAINER_NAME="${1:-gitlab}"

echo "[$(date -Iseconds)] enforce_gitlab_mirror_admin_only.sh started (container: ${CONTAINER_NAME})"

if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "[$(date -Iseconds)] ERROR: container '${CONTAINER_NAME}' is not running, abort." >&2
  exit 1
fi

# gitlab-rails runner 比 console 更適合非互動腳本：單一指令、無 REPL 提示，
# 失敗時的 exit code 可以被腳本判斷。
RUBY_SNIPPET=$(cat <<'RUBY'
setting = ApplicationSetting.current
before = setting.mirror_available
setting.update!(mirror_available: false)
puts "mirror_available: #{before} -> #{setting.reload.mirror_available}"
RUBY
)

if docker exec "${CONTAINER_NAME}" gitlab-rails runner "${RUBY_SNIPPET}"; then
  echo "[$(date -Iseconds)] mirror_available enforced to false (admin-only mirroring)"
else
  echo "[$(date -Iseconds)] ERROR: gitlab-rails runner failed — GitLab 可能尚未完成啟動，請確認 healthcheck 狀態後重試" >&2
  exit 1
fi

echo "[$(date -Iseconds)] enforce_gitlab_mirror_admin_only.sh completed"
