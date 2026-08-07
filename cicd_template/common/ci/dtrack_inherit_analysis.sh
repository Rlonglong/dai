#!/usr/bin/env bash
# =============================================================================
# ci/dtrack_inherit_analysis.sh —— 把已經評估過的例外帶到目前這個分支
# =============================================================================
# 在解決什麼問題
#
#   D-Track 的 Analysis（標記例外）是綁在「專案 : 版本」上的，
#   而我們的版本 = 分支名稱：
#
#       bcp-scripts : main                ← 有人在這裡寫過理由、標了 Not Affected
#       bcp-scripts : feat/add-report     ← 新開的分支，**又是一張白紙**
#
#   結果是同一個弱點在每一條新分支都會再擋一次，每個人都要重新寫一次理由。
#   幾次之後大家就不寫理由了，隨便標一標讓它過 —— 那整個機制就廢了。
#
#   這支腳本在評估擋門之前，把 main 上「已經評估過並放行」的結論
#   複製到目前這個版本：
#
#       ★ 同一個元件、同一個 CVE，理由只要寫一次 ★
#
# 複製什麼、不複製什麼
#
#   複製：analysisState 是 NOT_AFFECTED / FALSE_POSITIVE / RESOLVED 且已 suppressed 的
#   不複製：EXPLOITABLE、IN_TRIAGE、沒有標記的
#           —— 那些本來就該擋，帶過來反而會讓人以為處理完了
#
#   目前版本上已經有標記的，一律不覆蓋（人工判斷優先於繼承）。
#
# 需要的變數：
#   DTRACK_URL、DTRACK_API_KEY
#   DTRACK_PROJECT_NAME    專案名稱（= CI_PROJECT_NAME）
#   DTRACK_PROJECT_UUID    目前這個版本的 UUID
#
# 選用：
#   DTRACK_BASELINE_VERSION   來源版本，預設 main
#   DTRACK_INHERIT=0          關掉繼承（預設開啟）
#   DTRACK_INHERIT_DRY_RUN=1  只印出會帶哪些，不真的送出
#
# ★ API Key 需要 VULNERABILITY_ANALYSIS 權限 ★
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${DTRACK_INHERIT:-1}" == "1" ]] || { log_info "DTRACK_INHERIT=0，略過例外繼承"; exit 0; }

need_cmd python3
require_vars DTRACK_URL DTRACK_API_KEY DTRACK_PROJECT_NAME DTRACK_PROJECT_UUID

BASELINE="${DTRACK_BASELINE_VERSION:-main}"

# 自己就是 baseline 的話沒什麼好繼承的
if [[ "${CI_COMMIT_REF_NAME:-}" == "$BASELINE" ]]; then
    log_info "目前就是 ${BASELINE}，不需要繼承"
    exit 0
fi

section "SCA · 繼承 ${BASELINE} 上已評估過的例外"

DTRACK_URL="$DTRACK_URL" \
DTRACK_API_KEY="$DTRACK_API_KEY" \
DTRACK_PROJECT_NAME="$DTRACK_PROJECT_NAME" \
DTRACK_PROJECT_UUID="$DTRACK_PROJECT_UUID" \
DTRACK_BASELINE_VERSION="$BASELINE" \
DTRACK_INHERIT_DRY_RUN="${DTRACK_INHERIT_DRY_RUN:-0}" \
CI_COMMIT_REF_NAME="${CI_COMMIT_REF_NAME:-local}" \
python3 <<'PYEOF'
import json, os, sys, urllib.parse, urllib.request, urllib.error
from datetime import date

BASE     = os.environ["DTRACK_URL"].rstrip("/")
KEY      = os.environ["DTRACK_API_KEY"]
NAME     = os.environ["DTRACK_PROJECT_NAME"]
TARGET   = os.environ["DTRACK_PROJECT_UUID"]
BASELINE = os.environ["DTRACK_BASELINE_VERSION"]
DRY      = os.environ.get("DTRACK_INHERIT_DRY_RUN") == "1"

# 只有這三種是「已經評估過、確定可以放行」的結論
INHERITABLE = {"NOT_AFFECTED", "FALSE_POSITIVE", "RESOLVED"}


def call(method, path, payload=None, quiet404=False):
    req = urllib.request.Request(
        BASE + path, method=method,
        headers={"X-API-Key": KEY, "Accept": "application/json",
                 "Content-Type": "application/json"},
        data=json.dumps(payload).encode() if payload is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read().decode()
            return json.loads(body) if body.strip() else None
    except urllib.error.HTTPError as e:
        if e.code == 404 and quiet404:
            return None
        if e.code in (401, 403):
            print(f"[FAIL]  D-Track 回 {e.code}：API Key 缺少 VULNERABILITY_ANALYSIS 權限。", file=sys.stderr)
            print("        補權限，或設 DTRACK_INHERIT=0 關掉這個步驟。", file=sys.stderr)
            sys.exit(1)
        print(f"[FAIL]  D-Track {method} {path} 回 {e.code}："
              f"{e.read().decode(errors='replace')[:300]}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"[FAIL]  連不到 D-Track：{e}", file=sys.stderr)
        sys.exit(1)


def key_of(finding):
    """用 purl（沒有就退回 name@version）+ CVE 當比對鍵"""
    c = finding.get("component") or {}
    v = finding.get("vulnerability") or {}
    ident = c.get("purl") or f"{c.get('name')}@{c.get('version')}"
    return (ident, v.get("vulnId"))


# -----------------------------------------------------------------------------
# 1. 找 baseline 版本
# -----------------------------------------------------------------------------
q = urllib.parse.urlencode({"name": NAME, "version": BASELINE})
base_proj = call("GET", f"/api/v1/project/lookup?{q}", quiet404=True)
if not base_proj or not base_proj.get("uuid"):
    print(f"[INFO]  D-Track 上還沒有 {NAME}:{BASELINE}，沒有東西可以繼承（第一次跑很正常）")
    sys.exit(0)

base_uuid = base_proj["uuid"]

# -----------------------------------------------------------------------------
# 2. 取兩邊的 findings
# -----------------------------------------------------------------------------
base_findings   = call("GET", f"/api/v1/finding/project/{base_uuid}") or []
target_findings = call("GET", f"/api/v1/finding/project/{TARGET}") or []

# baseline 上「已評估過且放行」的
approved = {}
for f in base_findings:
    a = f.get("analysis") or {}
    state = (a.get("state") or a.get("analysisState") or "").upper()
    if state in INHERITABLE and a.get("isSuppressed"):
        approved[key_of(f)] = (state, a)

# 目前版本上已經有人標過的，不要覆蓋
already = {key_of(f) for f in target_findings
           if (f.get("analysis") or {}).get("state")
           or (f.get("analysis") or {}).get("isSuppressed")}

todo = [f for f in target_findings
        if key_of(f) in approved and key_of(f) not in already]

print(f"[INFO]  {NAME}:{BASELINE} 上已評估放行 {len(approved)} 筆；"
      f"目前版本可繼承 {len(todo)} 筆")

if not todo:
    print("[ OK ]  沒有需要繼承的例外")
    sys.exit(0)

if DRY:
    for f in todo:
        c, v = f.get("component") or {}, f.get("vulnerability") or {}
        print(f"        [DRY-RUN] {c.get('name')} {c.get('version')} ← {v.get('vulnId')}")
    sys.exit(0)

# -----------------------------------------------------------------------------
# 3. 套用
# -----------------------------------------------------------------------------
done = 0
for f in todo:
    c, v = f["component"], f["vulnerability"]
    state, a = approved[key_of(f)]
    original = (a.get("analysisDetails") or a.get("details") or "").strip()

    details = (
        f"【繼承自 {NAME}:{BASELINE} 的評估結論】\n"
        f"繼承日期：{date.today().isoformat()}\n"
        f"繼承到：{NAME}:{os.environ.get('CI_COMMIT_REF_NAME')}\n"
        f"原始結論：{state}\n"
        "\n"
        "── 以下為原始評估內容 ──\n"
        f"{original or '（原始紀錄沒有填寫 Details）'}\n"
        "\n"
        "※ 本筆由 ci/dtrack_inherit_analysis.sh 自動帶入，理由沿用 "
        f"{BASELINE} 上的評估。\n"
        "  若這個分支的使用方式與當初評估時不同，請人工改回 Exploitable。"
    )

    call("PUT", "/api/v1/analysis", {
        "project": TARGET,
        "component": c["uuid"],
        "vulnerability": v["uuid"],
        "analysisState": state,
        "analysisDetails": details,
        "suppressed": True,
    })
    done += 1
    print(f"        繼承 {c.get('name')} {c.get('version')} ← {v.get('vulnId')} ({state})")

print(f"[ OK ]  已繼承 {done} 筆評估結論，這些不會在本次掃描重複擋門")
PYEOF
