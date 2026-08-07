#!/usr/bin/env bash
# =============================================================================
# ci/dtrack_suppress_os.sh —— 自動放行 libc* 系列元件的弱點
# =============================================================================
# 在做什麼
#   容器映像檔的 SBOM 會把整個 base image 的套件也列進來，其中 libc 系列
#   （libc6 / libc-bin / libcrypt1 …）數量最多、也最不可能由我們處理：
#     1. 不是我們安裝的，是 base image 帶進來的
#     2. 不能單獨升級（要換整個 base image 版本）
#     3. 幾乎所有容器映像都會中，跟本專案的程式碼無關
#
#   所以這支腳本把 libc* 的弱點自動標記為 NOT_AFFECTED + suppressed，
#   並在 Details 欄留下一段固定的系統放行說明。
#
# ★★ 範圍嚴格限定：只有元件名稱以 libc 開頭的才自動放行 ★★
#
#   這是公司規定：**只有 libc 開頭的元件可以用「規則性放行」處理，
#   其他一律要人工評估、人工標註理由。**
#
#   所以這支腳本不碰 openssl、zlib、bash、coreutils，也不碰任何
#   pypi / maven / npm 套件 —— 那些出現弱點時就是要有人去看。
#
#   判斷條件（兩個都要成立）：
#     1. 元件名稱（小寫後）以 "libc" 開頭
#     2. purl 是作業系統套件：pkg:deb/ pkg:rpm/ pkg:apk/
#   第 2 條是保險，避免哪天有個 pypi 套件剛好叫 libcloud 之類的被誤放。
#
# 需要的變數（同 build_sbom.sh）：
#   DTRACK_URL、DTRACK_API_KEY
#   DTRACK_PROJECT_UUID   要處理的專案 UUID（build_sbom.sh 會帶進來）
#
# 選用：
#   DTRACK_OS_SUPPRESS=0       設 0 可以整個關掉這個行為（預設開啟）
#   DTRACK_SUPPRESS_DRY_RUN=1  只印出會標記哪些，不真的送出
#   DTRACK_SUPPRESS_PREFIX     元件名稱前綴，預設 libc。★改這個等於改公司規定，
#                              要先確認過再改★
#
# ★ API Key 需要 VULNERABILITY_ANALYSIS 權限 ★
#   這是一個「能讓紅燈變綠燈」的權限，見
#   docs/D-Track與Superset手冊/附錄/A_D-Track_Analysis狀態與權限對照.md
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${DTRACK_OS_SUPPRESS:-1}" == "1" ]] || { log_info "DTRACK_OS_SUPPRESS=0，略過 libc* 自動放行"; exit 0; }

need_cmd python3
require_vars DTRACK_URL DTRACK_API_KEY DTRACK_PROJECT_UUID

section "SCA · 自動放行 libc* 元件弱點"

DTRACK_URL="$DTRACK_URL" \
DTRACK_API_KEY="$DTRACK_API_KEY" \
DTRACK_PROJECT_UUID="$DTRACK_PROJECT_UUID" \
DTRACK_SUPPRESS_DRY_RUN="${DTRACK_SUPPRESS_DRY_RUN:-0}" \
DTRACK_SUPPRESS_PREFIX="${DTRACK_SUPPRESS_PREFIX:-libc}" \
CI_PIPELINE_URL="${CI_PIPELINE_URL:-}" \
CI_PROJECT_NAME="${CI_PROJECT_NAME:-}" \
CI_COMMIT_REF_NAME="${CI_COMMIT_REF_NAME:-}" \
python3 <<'PYEOF'
import json, os, sys, urllib.request, urllib.error
from datetime import date

BASE    = os.environ["DTRACK_URL"].rstrip("/")
KEY     = os.environ["DTRACK_API_KEY"]
PROJECT = os.environ["DTRACK_PROJECT_UUID"]
DRY     = os.environ.get("DTRACK_SUPPRESS_DRY_RUN") == "1"
PREFIX  = os.environ.get("DTRACK_SUPPRESS_PREFIX", "libc").lower()

# 保險條件：必須是作業系統套件管理員安裝的東西
OS_PURL_PREFIXES = ("pkg:deb/", "pkg:rpm/", "pkg:apk/")


def call(method, path, payload=None):
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
        detail = e.read().decode(errors="replace")[:300]
        if e.code in (401, 403):
            print(f"[FAIL]  D-Track 回 {e.code}：API Key 缺少 VULNERABILITY_ANALYSIS 權限。", file=sys.stderr)
            print("        到 Administration → Access Management → Teams 補上該權限，", file=sys.stderr)
            print("        或設 DTRACK_OS_SUPPRESS=0 關掉這個步驟。", file=sys.stderr)
            sys.exit(1)
        print(f"[FAIL]  D-Track {method} {path} 回 {e.code}：{detail}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"[FAIL]  連不到 D-Track：{e}", file=sys.stderr)
        sys.exit(1)


def is_auto_suppressible(component):
    """公司規定：只有 libc 開頭的元件可以規則性放行，其他一律人工處理。"""
    name = (component.get("name") or "").lower()
    purl = (component.get("purl") or "").lower()
    return name.startswith(PREFIX) and purl.startswith(OS_PURL_PREFIXES)


DETAILS = (
    f"【系統自動放行 · {PREFIX}* 系列元件】\n"
    f"放行日期：{date.today().isoformat()}\n"
    f"放行來源：CI 自動化（{os.environ.get('CI_PROJECT_NAME', '?')}"
    f":{os.environ.get('CI_COMMIT_REF_NAME', '?')}）\n"
    f"Pipeline：{os.environ.get('CI_PIPELINE_URL') or '（本機執行）'}\n"
    "\n"
    "放行理由：\n"
    f"本元件為 {PREFIX}* 系列，屬於容器 base image 的作業系統套件\n"
    "（purl 為 pkg:deb / pkg:rpm / pkg:apk），\n"
    "不是本專案自行安裝或選用的相依套件，無法單獨升級；\n"
    "修補方式為改用已更新的 base image，屬於映像檔改版流程，\n"
    "不在本專案的相依套件管理範圍內。\n"
    "\n"
    "補償控制：\n"
    "base image 版本由映像檔建置流程控管，隨映像檔改版一併更新。\n"
    "\n"
    "規則出處：ci/dtrack_suppress_os.sh\n"
    f"適用範圍：依公司規定，僅 {PREFIX}* 系列元件適用規則性自動放行，\n"
    "          其餘元件一律人工評估並個別填寫理由。\n"
    "※ 本筆為規則性自動放行，非個案人工評估。\n"
    "  若此元件確實被本專案直接使用，請人工改回 Exploitable 並開票追蹤。"
)

findings = call("GET", f"/api/v1/finding/project/{PROJECT}") or []

todo, skipped = [], 0
for f in findings:
    comp = f.get("component") or {}
    vuln = f.get("vulnerability") or {}
    ana = f.get("analysis") or {}
    if not is_auto_suppressible(comp):
        continue
    if ana.get("isSuppressed"):
        skipped += 1
        continue
    todo.append((comp, vuln))

print(f"[INFO]  findings 總數 {len(findings)}，其中 {PREFIX}* 待放行 {len(todo)}、已放行 {skipped}")
print(f"[INFO]  規則：僅元件名稱以 '{PREFIX}' 開頭且為 OS 套件者自動放行，其餘一律人工處理")

if not todo:
    print(f"[ OK ]  沒有需要新放行的 {PREFIX}* 弱點")
    sys.exit(0)

if DRY:
    for comp, vuln in todo:
        print(f"        [DRY-RUN] {comp.get('name')} {comp.get('version')} ← {vuln.get('vulnId')} ({vuln.get('severity')})")
    sys.exit(0)

done = 0
for comp, vuln in todo:
    call("PUT", "/api/v1/analysis", {
        "project": PROJECT,
        "component": comp["uuid"],
        "vulnerability": vuln["uuid"],
        "analysisState": "NOT_AFFECTED",
        "analysisJustification": "COMPONENT_NOT_PRESENT",
        "analysisDetails": DETAILS,
        "suppressed": True,
    })
    done += 1
    print(f"        放行 {comp.get('name')} {comp.get('version')} ← {vuln.get('vulnId')} ({vuln.get('severity')})")

print(f"[ OK ]  已自動放行 {done} 筆 {PREFIX}* 弱點")
PYEOF
