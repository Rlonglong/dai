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
#   DTRACK_FAIL_ON_HIGH=1   連 High 也擋（預設只擋 Critical）
#   DTRACK_POLL_MAX=12      等待分析的輪數，每輪 5 秒
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

METRICS="$(curl -sS -H "X-API-Key: ${DTRACK_API_KEY}" \
    "${DTRACK_URL}/api/v1/metrics/project/${UUID}/current")"

CRITICAL="$(printf '%s' "$METRICS" | jqr '.critical')"
HIGH="$(printf '%s'     "$METRICS" | jqr '.high')"
MEDIUM="$(printf '%s'   "$METRICS" | jqr '.medium')"
LOW="$(printf '%s'      "$METRICS" | jqr '.low')"

# 拿不到數字（null / 空）就當作沒過，不要因為解析失敗而放行
num() { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo "-1"; }
c="$(num "$CRITICAL")"; h="$(num "$HIGH")"

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

if [[ "$c" -lt 0 || "$h" -lt 0 ]]; then
    die "無法解析 D-Track 回傳的弱點數（回應：${METRICS}），視為未通過。"
fi

if [[ "$c" -gt 0 ]]; then
    log_error "偵測到 ${c} 個 Critical 弱點 → 阻擋 Pipeline"
    echo "  修法：到上面的 D-Track 連結看是哪個套件，升級到有修補的版本。" >&2
    exit 1
fi

if [[ "${DTRACK_FAIL_ON_HIGH:-0}" == "1" && "$h" -gt 0 ]]; then
    log_error "偵測到 ${h} 個 High 弱點，且 DTRACK_FAIL_ON_HIGH=1 → 阻擋 Pipeline"
    exit 1
fi

[[ "$h" -gt 0 ]] && log_warn "有 ${h} 個 High 弱點，目前不擋門，但請排入處理（要擋請設 DTRACK_FAIL_ON_HIGH=1）"
log_ok "SCA 檢查通過"
