#!/usr/bin/env bash
# =============================================================================
# ci/build_sbom.sh —— 產生 SBOM、上傳 Dependency-Track、等分數、決定擋不擋門
# =============================================================================
# 需要的 CI/CD Variables：
#   DTRACK_URL       例：https://dtrack.dai.post.gov.tw
#   DTRACK_API_KEY   D-Track 的 API Key（★Masked★）
#
# 選用：
#   DTRACK_IMAGE     當 repo 沒有 requirements.txt 時，改從這個映像檔裡
#                    pip freeze 產生 SBOM（dagster_workspace 的套件是烘焙在
#                    dai/dagster 映像裡的，repo 本身沒有 requirements.txt）
#   DTRACK_FAIL_ON_HIGH=1     連 High 也擋（日常掃描用）
#   DTRACK_FAIL_ON_MEDIUM=1   連 Medium 也擋（每季複掃用）
#   DTRACK_POLL_MAX=12        等待分析的輪數，每輪 5 秒
#   DTRACK_OS_SUPPRESS=0      關掉 OS 層套件自動放行（預設開啟）
#
# 門檻（Critical 一律擋，不能關）：
#   日常（MR / push）：Critical + High
#   每季複掃         ：Critical + High + Medium
#   兩者都不含 OS 層套件（glibc / libc-bin ... 由 ci/dtrack_suppress_os.sh 自動放行）
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need_cmd curl
require_vars DTRACK_URL DTRACK_API_KEY

ROOT="$(repo_root)"
cd "$ROOT"

# jq 不是每台 runner 都有，沒有就用 python3 頂替（RHEL 一定有 python3）
if command -v jq >/dev/null 2>&1; then
    jqr() { jq -r "$1"; }
else
    log_warn "找不到 jq，改用 python3 解析 JSON"
    jqr() {
        local path="${1#.}"
        python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('null'); sys.exit(0)
for k in '''${path}'''.split('.'):
    if not k: continue
    d = d.get(k) if isinstance(d, dict) else None
    if d is None: break
print('null' if d is None else d)
"
    }
fi

# -----------------------------------------------------------------------------
# 1. 產生 SBOM
# -----------------------------------------------------------------------------
section "SCA · 1/4 產生 SBOM"

if [[ -f requirements.txt ]]; then
    log_info "來源：requirements.txt"
    need_cmd cyclonedx-py
    cyclonedx-py requirements requirements.txt -o bom.json
elif [[ -n "${DTRACK_IMAGE:-}" ]]; then
    log_info "repo 沒有 requirements.txt，改從映像檔取套件清單：${DTRACK_IMAGE}"
    need_cmd docker
    need_cmd cyclonedx-py
    docker run --rm --entrypoint python "${DTRACK_IMAGE}" -m pip freeze > requirements.lock.txt \
        || die "無法從映像檔取得套件清單，確認 runner 有 docker 權限、映像檔名稱正確"
    cyclonedx-py requirements requirements.lock.txt -o bom.json
else
    die "產不出 SBOM：repo 裡沒有 requirements.txt，也沒有設定 DTRACK_IMAGE。

     這個 repo（dagster_workspace）的 Python 套件是烘焙在 dai/dagster 映像檔裡的，
     所以要掃的是「映像檔的套件」而不是「repo 的套件」。
     請設定 CI/CD Variable：
         DTRACK_IMAGE = gitlab.dai.post.gov.tw:5050/<group>/<project>/dagster:v2.7

     ★ 這裡刻意讓 job 失敗而不是跳過 ★
       一個靜默跳過的資安掃描，比沒有掃描更危險 —— 大家會以為它有在跑。"
fi

[[ -s bom.json ]] || die "bom.json 是空的，SBOM 產生失敗"
log_ok "SBOM 已產生（$(wc -c < bom.json) bytes）"

# -----------------------------------------------------------------------------
# 2. 上傳
# -----------------------------------------------------------------------------
section "SCA · 2/4 上傳 Dependency-Track"

PROJECT_NAME="${CI_PROJECT_NAME:-$(basename "$ROOT")}"
PROJECT_VERSION="${CI_COMMIT_REF_NAME:-local}"

UPLOAD_RESPONSE="$(curl -sS -X POST "${DTRACK_URL}/api/v1/bom" \
    -H "accept: application/json" \
    -H "X-API-Key: ${DTRACK_API_KEY}" \
    -F "autoCreate=true" \
    -F "projectName=${PROJECT_NAME}" \
    -F "projectVersion=${PROJECT_VERSION}" \
    -F "bom=@bom.json")" || die "上傳失敗，確認 ${DTRACK_URL} 連得到、API Key 正確"

TOKEN="$(printf '%s' "$UPLOAD_RESPONSE" | jqr '.token')"
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] \
    || die "上傳沒有拿到 token，D-Track 回應：${UPLOAD_RESPONSE}"
log_ok "已上傳（專案 ${PROJECT_NAME}:${PROJECT_VERSION}，token ${TOKEN:0:8}...）"

# -----------------------------------------------------------------------------
# 3. 等 D-Track 算完
# -----------------------------------------------------------------------------
section "SCA · 3/4 等待分析完成"

POLL_MAX="${DTRACK_POLL_MAX:-12}"
done_ok=0
for ((i = 1; i <= POLL_MAX; i++)); do
    STATUS="$(curl -sS -H "X-API-Key: ${DTRACK_API_KEY}" \
        "${DTRACK_URL}/api/v1/bom/token/${TOKEN}" | jqr '.processing')"
    log_info "檢查進度 (${i}/${POLL_MAX})：processing=${STATUS}"
    if [[ "$STATUS" == "false" ]]; then done_ok=1; break; fi
    sleep 5
done

# 等不到結果 = 擋門。「等逾時就當作通過」等於把品質閘門變成裝飾品。
[[ $done_ok -eq 1 ]] || die "等待 D-Track 分析逾時（${POLL_MAX} 輪 × 5 秒）。
     視為未通過。確認 dtrack-server 狀態後重跑，或調高 DTRACK_POLL_MAX。"
log_ok "分析完成"

# -----------------------------------------------------------------------------
# 4. 取分數、判斷
# -----------------------------------------------------------------------------
section "SCA · 4/4 弱點結果"

PROJECT_INFO="$(curl -sS -G -H "X-API-Key: ${DTRACK_API_KEY}" \
    --data-urlencode "name=${PROJECT_NAME}" \
    --data-urlencode "version=${PROJECT_VERSION}" \
    "${DTRACK_URL}/api/v1/project/lookup")"
UUID="$(printf '%s' "$PROJECT_INFO" | jqr '.uuid')"
[[ -n "$UUID" && "$UUID" != "null" ]] || die "查不到專案 UUID，D-Track 回應：${PROJECT_INFO}"

# -----------------------------------------------------------------------------
# 4-1. 自動放行 OS 層套件（glibc / libc-bin / openssl ... 這類 base image 帶進來的）
#      規則與理由見 ci/dtrack_suppress_os.sh
# -----------------------------------------------------------------------------
DTRACK_PROJECT_UUID="$UUID" "${ROOT}/ci/dtrack_suppress_os.sh"

# -----------------------------------------------------------------------------
# 4-2. 重算 metrics
#      擋門看的是 metrics 的數字，而 metrics 不是即時的。
#      剛剛放行完（或有人在網頁上標了例外）之後不重算，
#      這裡拿到的會是舊數字 —— 這是「明明標了還是紅的」最常見的原因。
# -----------------------------------------------------------------------------
curl -sS -o /dev/null -X POST -H "X-API-Key: ${DTRACK_API_KEY}" \
    "${DTRACK_URL}/api/v1/metrics/project/${UUID}/refresh" || true
log_info "已要求重算 metrics，等待 10 秒"
sleep 10

METRICS="$(curl -sS -H "X-API-Key: ${DTRACK_API_KEY}" \
    "${DTRACK_URL}/api/v1/metrics/project/${UUID}/current")"

CRITICAL="$(printf '%s' "$METRICS" | jqr '.critical')"
HIGH="$(printf '%s'     "$METRICS" | jqr '.high')"
MEDIUM="$(printf '%s'   "$METRICS" | jqr '.medium')"
LOW="$(printf '%s'      "$METRICS" | jqr '.low')"

# 拿不到數字（null / 空）就當作沒過，不要因為解析失敗而放行
num() { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo "-1"; }
c="$(num "$CRITICAL")"; h="$(num "$HIGH")"; m="$(num "$MEDIUM")"

# 擋門後統一印這一段：告訴人「怎麼樣才能過」，而不是只丟一個紅燈
how_to_pass() {
    cat >&2 <<'HOWTO'

  怎麼讓它過（三條路，擇一）：
    1. 升級套件版本  ← 正解。到 D-Track 看 Fixed in 有沒有可用版本，
                        改 requirements.txt（或映像檔）後開 MR 重掃。
    2. 標記為不受影響  ← 沒有修補版本、或我們沒用到那個弱點路徑時走這條。
         D-Track → 該專案 → Audit Vulnerabilities → 展開該筆 →
         Analysis 選 NOT_AFFECTED → Details 寫清楚理由 → 勾 Suppress →
         回到這個 job 按 Retry（metrics 由本腳本自動重算，不用手動點）。
         ★ Details 沒寫理由的例外，稽核時等於沒有做過評估 ★
    3. 排期處理  ← 有影響但一時修不掉：Redmine 開票，
         D-Track 標 Exploitable 並在 Details 寫票號，走緊急放行流程。

  完整步驟：docs/D-Track與Superset手冊/日常維運/04_弱掃紅燈與MR被卡住的解除流程.md
HOWTO
}

cat >&2 <<EOF
=======================================
🛡️  資安掃描結果（${PROJECT_NAME}:${PROJECT_VERSION}）
🔥 Critical : ${CRITICAL}
🚨 High     : ${HIGH}
⚠️  Medium   : ${MEDIUM}
ℹ️  Low      : ${LOW}
   D-Track  : ${DTRACK_URL}/projects/${UUID}
=======================================
EOF

if [[ "$c" -lt 0 || "$h" -lt 0 || "$m" -lt 0 ]]; then
    die "無法解析 D-Track 回傳的弱點數（回應：${METRICS}），視為未通過。"
fi

# 上面的數字**不含**已 suppressed 的項目，
# 所以 OS 層套件（見 4-1）與人工標過 Not Affected 的都已經不在裡面了。

if [[ "$c" -gt 0 ]]; then
    log_error "偵測到 ${c} 個 Critical 弱點 → 阻擋 Pipeline"
    how_to_pass
    exit 1
fi

if [[ "${DTRACK_FAIL_ON_HIGH:-0}" == "1" && "$h" -gt 0 ]]; then
    log_error "偵測到 ${h} 個 High 弱點（門檻：High 以上擋）→ 阻擋 Pipeline"
    how_to_pass
    exit 1
fi

if [[ "${DTRACK_FAIL_ON_MEDIUM:-0}" == "1" && "$m" -gt 0 ]]; then
    log_error "偵測到 ${m} 個 Medium 弱點（門檻：Medium 以上擋）→ 阻擋 Pipeline"
    how_to_pass
    exit 1
fi

[[ "${DTRACK_FAIL_ON_HIGH:-0}" != "1" && "$h" -gt 0 ]] && \
    log_warn "有 ${h} 個 High 弱點，這一關不擋，但請排入處理"
[[ "${DTRACK_FAIL_ON_MEDIUM:-0}" != "1" && "$m" -gt 0 ]] && \
    log_warn "有 ${m} 個 Medium 弱點，這一關不擋，每季複掃時會擋"
log_ok "SCA 檢查通過"
