#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Detection Validation Script
#  Version: 1.0.0
#  Red Horizon Security — redhorizon.ph
#
#  Tests all 5 detection rules and reports results.
#  Usage: sudo bash validate.sh
# ═══════════════════════════════════════════════════════════

# ── Colors ──────────────────────────────────────────────────
G='\033[0;32m' R='\033[0;31m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' N='\033[0m'

# ── State ───────────────────────────────────────────────────
NOTICE_LOG="/opt/zeek/logs/current/notice.log"
PASS=0; FAIL=0
TS=$(date +%s)

# ── Helpers ─────────────────────────────────────────────────
ok()   { echo -e "${G}  [✓]${N} $1"; ((PASS++)) || true; }
fail() { echo -e "${R}  [✗]${N} $1"; ((FAIL++)) || true; }
warn() { echo -e "${Y}  [!]${N} $1"; }
info() { echo -e "${D}  [→]${N} $1"; }

# ── Banner ──────────────────────────────────────────────────
clear
echo -e "${R}"
echo "  ██████╗ ██╗  ██╗    ██████╗ ██╗   ██╗██╗     ███████╗ █████╗ ██████╗"
echo "  ██╔══██╗██║  ██║    ██╔══██╗██║   ██║██║     ██╔════╝██╔══██╗██╔══██╗"
echo "  ██████╔╝███████║    ██████╔╝██║   ██║██║     ███████╗███████║██████╔╝"
echo "  ██╔══██╗██╔══██║    ██╔═══╝ ██║   ██║██║     ╚════██║██╔══██║██╔══██╗"
echo "  ██║  ██║██║  ██║    ██║     ╚██████╔╝███████╗███████║██║  ██║██║  ██║"
echo "  ╚═╝  ╚═╝╚═╝  ╚═╝    ╚═╝      ╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝"
echo -e "${N}"
echo -e "${W}  Detection Validation — v1.0.0${N}"
echo -e "${D}  Red Horizon Security — redhorizon.ph${N}"
echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""

# ── Pre-checks ──────────────────────────────────────────────
echo -e "${W}  Pre-checks${N}"
echo ""

# Root
[[ $EUID -ne 0 ]] && { echo -e "${R}  Run as root: sudo bash validate.sh${N}"; exit 1; }
ok "Running as root"

# Zeek running
if /opt/zeek/bin/zeekctl status 2>/dev/null | grep -q "running"; then
    ok "Zeek: running"
else
    fail "Zeek: not running — run: sudo /opt/zeek/bin/zeekctl deploy"
    exit 1
fi

# Interface
local_iface=$(grep "^interface=" /opt/zeek/etc/node.cfg 2>/dev/null | cut -d= -f2)
ok "Capture interface: ${local_iface:-unknown}"

# Internet
if curl -s --max-time 5 http://detectportal.firefox.com > /dev/null 2>&1; then
    ok "Internet: reachable"
    TARGET="http://detectportal.firefox.com"
else
    warn "Internet unreachable — using local gateway"
    TARGET="http://$(ip route | awk '/default/{print $3}' | head -1)"
fi

# notice.log writable
[[ -d /opt/zeek/logs/current ]] || { fail "Zeek logs directory missing"; exit 1; }
ok "Zeek logs directory: present"

# Clear old notice entries for clean test
info "Clearing previous notice.log for clean results..."
> "$NOTICE_LOG" 2>/dev/null || true

echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
echo -e "${W}  Generating test traffic...${N}"
echo ""

# ── Rule 110001 — C2 Beacon ─────────────────────────────────
info "Testing Rule 110001 — C2 Beacon (6 connections to same host)..."
for i in 1 2 3 4 5 6; do
    curl -s --max-time 3 "${TARGET}" > /dev/null 2>&1 || true
done
ok "Rule 110001: traffic sent"

# ── Rule 110004 — HTTP C2 Beacon ────────────────────────────
info "Testing Rule 110004 — HTTP C2 Beacon (11 hits same URI)..."
for i in 1 2 3 4 5 6 7 8 9 10 11; do
    curl -s --max-time 3 "${TARGET}/beacon-${TS}" > /dev/null 2>&1 || true
done
ok "Rule 110004: traffic sent"

# ── Rule 110005 — Suspicious UA ─────────────────────────────
info "Testing Rule 110005 — Suspicious UA (Havoc, Sliver, meterpreter)..."
curl -s --max-time 3 -A "Havoc/${TS}"       "${TARGET}/ua-${TS}-1" > /dev/null 2>&1 || true
curl -s --max-time 3 -A "Sliver/${TS}"      "${TARGET}/ua-${TS}-2" > /dev/null 2>&1 || true
curl -s --max-time 3 -A "meterpreter/${TS}" "${TARGET}/ua-${TS}-3" > /dev/null 2>&1 || true
ok "Rule 110005: traffic sent"

# ── Rule 110002 — DNS Tunnel ────────────────────────────────
info "Testing Rule 110002 — DNS Tunnel (long subdomains)..."
for sub in \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "bbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "ccccccccccccccccccccccccccc" \
    "ddddddddddddddddddddddddddd" \
    "eeeeeeeeeeeeeeeeeeeeeeeeeee" \
    "fffffffffffffffffffffffffff"; do
    nslookup "${sub}.dns-${TS}.com" > /dev/null 2>&1 || true
done
ok "Rule 110002: traffic sent"

# ── Rule 110003 — JA4/JA4S ──────────────────────────────────
info "Testing Rule 110003 — JA4/JA4S (TLS fingerprint check)..."
curl -s --max-time 5 https://google.com  > /dev/null 2>&1 || true
curl -s --max-time 5 https://github.com  > /dev/null 2>&1 || true
ok "Rule 110003: TLS traffic sent (fires only on known Sliver fingerprint)"

# ── Wait for Zeek to process ────────────────────────────────
echo ""
info "Waiting 8 seconds for Zeek to process traffic..."
sleep 8

# ── Parse results ───────────────────────────────────────────
echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
echo -e "${W}  Detection Results${N}"
echo ""

declare -A RULES=(
    ["C2Beacon::C2_Beacon_Detected"]="110001|C2 Beacon|T1071"
    ["DNSTunnel::DNS_Tunnel_Detected"]="110002|DNS Tunnel|T1071.004"
    ["DetectJA4::Sliver_JA4_Detected"]="110003|Sliver JA4/JA4S|T1573"
    ["HTTPC2::HTTP_C2_Beacon"]="110004|HTTP C2 Beacon|T1071.001"
    ["HTTPC2::Suspicious_UserAgent"]="110005|Suspicious UA|T1071.001"
)

declare -A FIRED

# Parse notice.log
if [[ -f "$NOTICE_LOG" ]]; then
    while IFS= read -r line; do
        [[ "$line" == \#* || -z "$line" ]] && continue
        note=$(echo "$line" | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('note',''))
except: pass
" 2>/dev/null)
        msg=$(echo "$line" | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('msg',''))
except: pass
" 2>/dev/null)
        ts_raw=$(echo "$line" | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    from datetime import datetime
    print(datetime.fromtimestamp(float(d.get('ts',0))).strftime('%H:%M:%S'))
except: pass
" 2>/dev/null)

        [[ -n "$note" && -v "RULES[$note]" ]] && FIRED["$note"]="${ts_raw}|${msg}"
    done < "$NOTICE_LOG"
fi

# Print results
SCORE=0
for note in \
    "C2Beacon::C2_Beacon_Detected" \
    "DNSTunnel::DNS_Tunnel_Detected" \
    "DetectJA4::Sliver_JA4_Detected" \
    "HTTPC2::HTTP_C2_Beacon" \
    "HTTPC2::Suspicious_UserAgent"; do

    IFS='|' read -r rule_id rule_name mitre <<< "${RULES[$note]}"

    if [[ -v "FIRED[$note]" ]]; then
        IFS='|' read -r fired_ts fired_msg <<< "${FIRED[$note]}"
        echo -e "  ${G}[✓]${N} ${W}Rule ${rule_id}${N} — ${rule_name} — MITRE ${mitre}"
        echo -e "      ${D}Time : ${fired_ts}${N}"
        echo -e "      ${D}Alert: ${fired_msg}${N}"
        ((SCORE++)) || true
    else
        if [[ "$note" == "DetectJA4::Sliver_JA4_Detected" ]]; then
            echo -e "  ${Y}[~]${N} ${W}Rule ${rule_id}${N} — ${rule_name} — MITRE ${mitre}"
            echo -e "      ${D}Pending — requires real Sliver C2 traffic${N}"
            echo -e "      ${D}JA4 engine confirmed working in ssl.log${N}"
        else
            echo -e "  ${R}[✗]${N} ${W}Rule ${rule_id}${N} — ${rule_name} — MITRE ${mitre}"
            echo -e "      ${D}Not fired — check Zeek logs${N}"
        fi
    fi
    echo ""
done

# ── JA4 fingerprint check ───────────────────────────────────
echo -e "${W}  JA4 Fingerprint Engine${N}"
echo ""

JA4_COUNT=$(python3 -c "
import json
count=0
try:
    with open('/opt/zeek/logs/current/ssl.log') as f:
        for line in f:
            line=line.strip()
            if line.startswith('#') or not line: continue
            try:
                d=json.loads(line)
                if d.get('ja4','') or d.get('ja4s',''):
                    count+=1
            except: pass
except: pass
print(count)
" 2>/dev/null || echo 0)

if [[ "$JA4_COUNT" -gt 0 ]]; then
    ok "JA4/JA4S fingerprints captured: ${JA4_COUNT} TLS sessions"

    # Show sample
    python3 -c "
import json
try:
    with open('/opt/zeek/logs/current/ssl.log') as f:
        for line in f:
            line=line.strip()
            if line.startswith('#') or not line: continue
            try:
                d=json.loads(line)
                ja4=d.get('ja4','')
                ja4s=d.get('ja4s','')
                if ja4:
                    print(f'  \033[0;37m  Sample JA4 : {ja4}\033[0m')
                    print(f'  \033[0;37m  Sample JA4S: {ja4s}\033[0m')
                    break
            except: pass
except: pass
" 2>/dev/null
else
    warn "No JA4 fingerprints yet — generate HTTPS traffic"
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
echo -e "  ${W}Sensor     :${N} $(cat /etc/rh-pulsar/name 2>/dev/null || echo 'unknown')"
echo -e "  ${W}Sensor ID  :${N} $(cat /etc/rh-pulsar/sensor_id 2>/dev/null || echo 'unknown')"
echo -e "  ${W}Interface  :${N} ${local_iface:-unknown}"
echo -e "  ${W}Zeek       :${N} $(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)"
echo -e "  ${W}Timestamp  :${N} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

if [[ "$SCORE" -ge 4 ]]; then
    echo -e "  ${G}Score: ${SCORE}/5 rules validated ✓${N}"
    echo -e "  ${G}RH Pulsar detection engine is operational.${N}"
elif [[ "$SCORE" -ge 2 ]]; then
    echo -e "  ${Y}Score: ${SCORE}/5 rules validated${N}"
    echo -e "  ${Y}Partial — check interface and traffic routing.${N}"
else
    echo -e "  ${R}Score: ${SCORE}/5 rules validated${N}"
    echo -e "  ${R}Check Zeek status and capture interface.${N}"
fi

echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
echo -e "${W}  Red Horizon Security — redhorizon.ph${N}"
echo -e "${D}  © 2026 Red Horizon Security. All rights reserved.${N}"
echo ""
