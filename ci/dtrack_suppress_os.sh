#!/usr/bin/env bash
# =============================================================================
# ci/dtrack_suppress_os.sh —— 自動放行「作業系統層套件」的弱點
# =============================================================================
# 在做什麼
#   容器映像檔的 SBOM 會把整個 base image 的 OS 套件也列進來
#   （glibc / libc-bin / openssl / zlib / bash / coreutils …）。
#   這些弱點對我們來說是「無法處理」的：
#     1. 不是我們安裝的，是 base image 帶進來的
#     2. 我們不能單獨升級它們（要換 base image 版本）
#     3. 絕大多數是 Debian/RHEL 已標記 will_not_fix 或不影響容器內使用情境
#
#   如果不處理，每次掃描都會被這幾百個 OS 弱點淹沒，
#   真正該看的「我們自己裝的套件」反而看不到 —— 這是最危險的狀態。
#
#   所以這支腳本把 OS 層套件的弱點自動標記為 NOT_AFFECTED + suppressed，
#   並在 Details 欄留下一段固定的系統放行說明（誰放的、為什麼、哪裡有規則）。
#   標記之後 D-Track 的 metrics 就不會再把它們算進 Critical/High/Medium。
#
# ★ 範圍嚴格限定 ★
#   只處理 purl 開頭是 pkg:deb/ pkg:rpm/ pkg:apk/ 的元件，
#   也就是「由作業系統套件管理員安裝的東西」。
#   pkg:pypi/ pkg:maven/ pkg:npm/ 這些「我們自己選的套件」一律不碰。
#
# 需要的變數（同 build_sbom.sh）：
#   DTRACK_URL、DTRACK_API_KEY
#   DTRACK_PROJECT_UUID   要處理的專案 UUID（build_sbom.sh 會帶進來）
#
# 選用：
#   DTRACK_OS_SUPPRESS=0  設 0 可以整個關掉這個行為（預設開啟）
#   DTRACK_SUPPRESS_DRY_RUN=1  只印出會標記哪些，不真的送出
#
# ★ API Key 需要 VULNERABILITY_ANALYSIS 權限 ★
#   這是一個「能讓紅燈變綠燈」的權限，見
#   docs/D-Track與Superset手冊/附錄/A_D-Track_Analysis狀態與權限對照.md
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${DTRACK_OS_SUPPRESS:-1}" == "1" ]] || { log_info "DTRACK_OS_SUPPRESS=0，略過 OS 套件自動放行"; exit 0; }

need_cmd python3
require_vars DTRACK_URL DTRACK_API_KEY DTRACK_PROJECT_UUID

section "SCA · 自動放行 OS 層套件弱點"

DTRACK_URL="$DTRACK_URL" \
DTRACK_API_KEY="$DTRACK_API_KEY" \
DTRACK_PROJECT_UUID="$DTRACK_PROJECT_UUID" \
DTRACK_SUPPRESS_DRY_RUN="${DTRACK_SUPPRESS_DRY_RUN:-0}" \
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

# 只認這三種：由作業系統套件管理員安裝的東西
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


def is_os_package(component):
    purl = (component.get("purl") or "").lower()
    return purl.startswith(OS_PURL_PREFIXES)


DETAILS = (
    "【系統自動放行 · 作業系統層套件】\n"
    f"放行日期：{date.today().isoformat()}\n"
    f"放行來源：CI 自動化（{os.environ.get('CI_PROJECT_NAME', '?')}"
    f":{os.environ.get('CI_COMMIT_REF_NAME', '?')}）\n"
    f"Pipeline：{os.environ.get('CI_PIPELINE_URL') or '（本機執行）'}\n"
    "\n"
    "放行理由：\n"
    "本元件屬於容器 base image 的作業系統套件（purl 為 pkg:deb / pkg:rpm / pkg:apk），\n"
    "不是本專案自行安裝或選用的相依套件，無法單獨升級；\n"
    "修補方式為改用已更新的 base image，屬於映像檔改版流程，\n"
    "不在本專案的相依套件管理範圍內。\n"
    "\n"
    "補償控制：\n"
    "base image 版本由映像檔建置流程控管，隨映像檔改版一併更新。\n"
    "\n"
    "規則出處：ci/dtrack_suppress_os.sh\n"
    "※ 本筆為規則性自動放行，非個案人工評估。\n"
    "  若此元件確實被本專案直接使用，請人工改回 Exploitable 並開票追蹤。"
)

findings = call("GET", f"/api/v1/finding/project/{PROJECT}") or []

todo, skipped = [], 0
for f in findings:
    comp = f.get("component") or {}
    vuln = f.get("vulnerability") or {}
    ana = f.get("analysis") or {}
    if not is_os_package(comp):
        continue
    if ana.get("isSuppressed"):
        skipped += 1
        continue
    todo.append((comp, vuln))

print(f"[INFO]  findings 總數 {len(findings)}，其中 OS 層待放行 {len(todo)}、已放行 {skipped}")

if not todo:
    print("[ OK ]  沒有需要新放行的 OS 層弱點")
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

print(f"[ OK ]  已自動放行 {done} 筆 OS 層弱點")
PYEOF
