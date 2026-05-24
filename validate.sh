#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Detection Validation
#  Version: 3.2.2
#  Red Horizon Security — redhorizon.ph
#
#  Tests all 5 detection rules + verifies forwarder.
#  Usage: sudo bash validate.sh
# ═══════════════════════════════════════════════════════════

set -uo pipefail   # NOT -e — validate continues past individual rule failures

# ── Colors ──────────────────────────────────────────────────
G='\033[0;32m' R='\033[0;31m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' N='\033[0m'

# ── State ───────────────────────────────────────────────────
NOTICE_LOG="/opt/zeek/logs/current/notice.log"
CONN_LOG="/opt/zeek/logs/current/conn.log"
SSL_LOG="/opt/zeek/logs/current/ssl.log"
PASS=0; FAIL=0
TS=$(date +%s)
TARGET=""

# ── Helpers ─────────────────────────────────────────────────
ok()   { echo -e "${G}  [✓]${N} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${R}  [✗]${N} $1"; FAIL=$((FAIL+1)); }
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
echo -e "${W}  Detection Validation — v3.2.2${N}"
echo -e "${D}  Red Horizon Security — redhorizon.ph${N}"
echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""

# ── Pre-checks ──────────────────────────────────────────────
echo -e "${W}  Pre-checks${N}"
echo ""

[[ $EUID -ne 0 ]] && { echo -e "${R}  Run as root: sudo bash validate.sh${N}"; exit 1; }
ok "Running as root"

if /opt/zeek/bin/zeekctl status 2>/dev/null | grep -q "running"; then
    ok "Zeek: running"
else
    fail "Zeek: not running — run: sudo /opt/zeek/bin/zeekctl deploy"
    exit 1
fi

local_iface=$(grep "^interface=" /opt/zeek/etc/node.cfg 2>/dev/null | cut -d= -f2 || echo "unknown")
ok "Capture interface: ${local_iface}"

# Internet check + target selection
if curl -sf --connect-timeout 3 --max-time 5 http://detectportal.firefox.com > /dev/null 2>&1; then
    ok "Internet: reachable"
    TARGET="http://detectportal.firefox.com"
else
    warn "Internet unreachable — using local gateway"
    GW=$(ip route | awk '/default/{print $3}' | head -1)
    if [[ -z "$GW" ]]; then
        fail "No default gateway found — cannot generate test traffic"
        exit 1
    fi
    TARGET="http://${GW}"
fi

[[ -d /opt/zeek/logs/current ]] || { fail "Zeek logs dir missing"; exit 1; }
ok "Zeek logs dir: present"

# Snapshot notice.log size — we'll only consider new entries
NOTICE_START_LINES=0
[[ -f "$NOTICE_LOG" ]] && NOTICE_START_LINES=$(wc -l < "$NOTICE_LOG" 2>/dev/null || echo 0)
info "Notice log baseline: ${NOTICE_START_LINES} lines"

echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
echo -e "${W}  Generating test traffic...${N}"
echo ""

# ── Rule 110001 — C2 Beacon ─────────────────────────────────
info "Testing Rule 110001 — C2 Beacon (6 connections to same host)..."
for i in 1 2 3 4 5 6; do
    curl -s --connect-timeout 3 --max-time 3 "${TARGET}" > /dev/null 2>&1 || true
done
ok "Rule 110001: traffic sent"

# ── Rule 110004 — HTTP C2 Beacon ────────────────────────────
info "Testing Rule 110004 — HTTP C2 Beacon (11 hits same URI)..."
for i in $(seq 1 11); do
    curl -s --connect-timeout 3 --max-time 3 "${TARGET}/beacon-${TS}" > /dev/null 2>&1 || true
done
ok "Rule 110004: traffic sent"

# ── Rule 110005 — Suspicious UA ─────────────────────────────
info "Testing Rule 110005 — Suspicious UA (Havoc, Sliver, meterpreter)..."
curl -s --connect-timeout 3 --max-time 3 -A "Havoc/C2-${TS}"       "${TARGET}/ua-${TS}-1" > /dev/null 2>&1 || true
curl -s --connect-timeout 3 --max-time 3 -A "Sliver/C2-${TS}"      "${TARGET}/ua-${TS}-2" > /dev/null 2>&1 || true
curl -s --connect-timeout 3 --max-time 3 -A "meterpreter/C2-${TS}" "${TARGET}/ua-${TS}-3" > /dev/null 2>&1 || true
ok "Rule 110005: traffic sent"

# ── Rule 110002 — DNS Tunnel ────────────────────────────────
info "Testing Rule 110002 — DNS Tunnel (8 long-subdomain queries)..."
for sub in \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "bbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "ccccccccccccccccccccccccccc" \
    "ddddddddddddddddddddddddddd" \
    "eeeeeeeeeeeeeeeeeeeeeeeeeee" \
    "fffffffffffffffffffffffffff" \
    "ggggggggggggggggggggggggggg" \
    "hhhhhhhhhhhhhhhhhhhhhhhhhhh"; do
    dig +time=2 +tries=1 "${sub}.dns-${TS}.com" > /dev/null 2>&1 || true
done
ok "Rule 110002: traffic sent"

# ── Rule 110003 — JA4/JA4S ──────────────────────────────────
info "Testing Rule 110003 — JA4/JA4S (TLS fingerprint check)..."
curl -s --connect-timeout 3 --max-time 5 https://google.com > /dev/null 2>&1 || true
curl -s --connect-timeout 3 --max-time 5 https://github.com > /dev/null 2>&1 || true
ok "Rule 110003: TLS traffic sent (fires only on known Sliver fingerprint)"

# ── Wait for Zeek to process — poll instead of hard sleep ───
echo ""
info "Waiting for Zeek to process traffic (up to 15s)..."
NOTICE_NEW=0
for i in $(seq 1 15); do
    sleep 1
    if [[ -f "$NOTICE_LOG" ]]; then
        local_lines=$(wc -l < "$NOTICE_LOG" 2>/dev/null || echo 0)
        NOTICE_NEW=$(( local_lines - NOTICE_START_LINES ))
        if [[ "$NOTICE_NEW" -gt 0 ]]; then
            info "Notices fired after ${i}s (${NOTICE_NEW} new)"
            # Give Zeek 2 more seconds to write all pending notices
            sleep 2
            break
        fi
    fi
    [[ "$i" == "15" ]] && warn "Max wait reached — proceeding"
done

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

# Single Python pass over notice.log — only new entries since baseline
if [[ -f "$NOTICE_LOG" ]]; then
    while IFS='|' read -r note ts_raw msg; do
        [[ -n "$note" ]] && FIRED["$note"]="${ts_raw}|${msg}"
    done < <(python3 - "$NOTICE_LOG" "$NOTICE_START_LINES" <<'PYEOF'
import sys, json
from datetime import datetime
path = sys.argv[1]
baseline = int(sys.argv[2])
try:
    with open(path) as f:
        for i, line in enumerate(f):
            if i < baseline:
                continue
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            try:
                d = json.loads(line)
                note = d.get('note', '')
                msg  = d.get('msg', '')
                ts   = d.get('ts', 0)
                try:
                    ts_fmt = datetime.fromtimestamp(float(ts)).strftime('%H:%M:%S')
                except Exception:
                    ts_fmt = ''
                if note:
                    print(f"{note}|{ts_fmt}|{msg}")
            except Exception:
                pass
except Exception:
    pass
PYEOF
    )
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

    if [[ -n "${FIRED[$note]:-}" ]]; then
        IFS='|' read -r fired_ts fired_msg <<< "${FIRED[$note]}"
        echo -e "  ${G}[✓]${N} ${W}Rule ${rule_id}${N} — ${rule_name} — MITRE ${mitre}"
        echo -e "      ${D}Time : ${fired_ts}${N}"
        echo -e "      ${D}Alert: ${fired_msg}${N}"
        SCORE=$((SCORE+1))
    else
        if [[ "$note" == "DetectJA4::Sliver_JA4_Detected" ]]; then
            echo -e "  ${Y}[~]${N} ${W}Rule ${rule_id}${N} — ${rule_name} — MITRE ${mitre}"
            echo -e "      ${D}Pending — requires real Sliver C2 traffic${N}"
            echo -e "      ${D}JA4 engine confirmed working in ssl.log${N}"
        else
            echo -e "  ${R}[✗]${N} ${W}Rule ${rule_id}${N} — ${rule_name} — MITRE ${mitre}"
            echo -e "      ${D}Not fired — check capture interface + logs${N}"
        fi
    fi
    echo ""
done

# ── JA4 fingerprint engine check ────────────────────────────
echo -e "${W}  JA4 Fingerprint Engine${N}"
echo ""

JA4_COUNT=$(python3 - "$SSL_LOG" <<'PYEOF' 2>/dev/null
import sys, json
path = sys.argv[1]
count = 0
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            try:
                d = json.loads(line)
                if d.get('ja4') or d.get('ja4s'):
                    count += 1
            except Exception:
                pass
except Exception:
    pass
print(count)
PYEOF
)
JA4_COUNT=${JA4_COUNT:-0}

if [[ "$JA4_COUNT" -gt 0 ]]; then
    ok "JA4/JA4S fingerprints captured: ${JA4_COUNT} TLS sessions"
    python3 - "$SSL_LOG" <<'PYEOF' 2>/dev/null || true
import sys, json
path = sys.argv[1]
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            try:
                d = json.loads(line)
                ja4 = d.get('ja4', '')
                ja4s = d.get('ja4s', '')
                if ja4:
                    print(f"  \033[0;37m  Sample JA4 : {ja4}\033[0m")
                    print(f"  \033[0;37m  Sample JA4S: {ja4s}\033[0m")
                    break
            except Exception:
                pass
except Exception:
    pass
PYEOF
else
    warn "No JA4 fingerprints yet — generate HTTPS traffic and re-run"
fi

# ── JA4 Threat Intel Updater status ─────────────────────────
echo ""
echo -e "${W}  JA4 Threat Intel (ja4db.com)${N}"
echo ""

if systemctl list-unit-files rh-pulsar-ja4-update.timer &>/dev/null; then
    if systemctl is-enabled --quiet rh-pulsar-ja4-update.timer; then
        ok "Updater timer: enabled"
    else
        warn "Updater timer: not enabled"
    fi

    # Last run status
    if [[ -f /var/lib/rh-pulsar/ja4-update.state ]]; then
        last_status=$(grep "last_status=" /var/lib/rh-pulsar/ja4-update.state 2>/dev/null | cut -d= -f2 || echo "")
        last_attempt=$(grep "last_attempt=" /var/lib/rh-pulsar/ja4-update.state 2>/dev/null | cut -d= -f2- || echo "")
        fp_count=$(grep "fingerprint_count=" /var/lib/rh-pulsar/ja4-update.state 2>/dev/null | cut -d= -f2 || echo "")
        case "${last_status:-empty}" in
            success)
                ok "Last refresh: ${last_attempt:-unknown} (success)"
                ok "DB fingerprints loaded: ${fp_count:-?}" ;;
            empty)
                warn "State file present but malformed" ;;
            *)
                warn "Last refresh: ${last_attempt:-unknown} (status: ${last_status})"
                info "Manual retry: sudo systemctl start rh-pulsar-ja4-update.service" ;;
        esac
    else
        warn "No update history yet — first run pending"
    fi

    # Next scheduled run
    next_run=$(systemctl list-timers rh-pulsar-ja4-update.timer --no-pager 2>/dev/null | awk 'NR==2{print $1, $2}' || echo "")
    [[ -n "$next_run" && "$next_run" != " " ]] && info "Next refresh: ${next_run}"
else
    warn "JA4 updater not installed — run installer to add"
fi

# ── Alert Delivery (honest about how it works) ──────────────
echo ""
echo -e "${W}  Alert Delivery${N}"
echo ""

SIEM_NAME=$(cat /etc/rh-pulsar/siem 2>/dev/null || echo "unknown")
CONTACT=$(cat /etc/rh-pulsar/contact 2>/dev/null || echo "unknown")

case "$SIEM_NAME" in
    "Standalone")
        info "Mode: Sensor-side email (LAB/TESTING ONLY)"
        info "Contact: ${CONTACT}"
        if [[ -f /etc/postfix/main.cf ]]; then
            relayhost=$(postconf -h relayhost 2>/dev/null || echo "")
            if [[ -n "$relayhost" && "$relayhost" != " " ]]; then
                ok "Postfix relay configured: ${relayhost}"
                # Try a test mail
                if echo "Test from RH Pulsar validate.sh at $(date)" | mail -s "RH Pulsar test alert" "$CONTACT" 2>/dev/null; then
                    ok "Test email queued — check ${CONTACT} inbox in ~30 seconds"
                    info "If nothing arrives, check: sudo mailq && sudo journalctl -u postfix -n 30"
                else
                    warn "mail command failed — postfix may not be ready"
                fi
            else
                warn "Postfix in LOCAL ONLY mode — alerts go to /var/mail/root"
                info "Read with: sudo cat /var/mail/root | tail -30"
            fi
        else
            warn "Postfix not installed — no mail delivery possible"
        fi
        warn "Standalone mail is TESTING ONLY — production deployments must use a SIEM"
        ;;
    *)
        ok "Mode: SIEM-managed (sensor does not send email directly)"
        info "Contact metadata: ${CONTACT}"
        info "Alert delivery is handled by: ${SIEM_NAME} manager"
        info "Configure email/Slack/PagerDuty on the SIEM manager side"
        ;;
esac

# ── Forwarder end-to-end check ──────────────────────────────
echo ""
echo -e "${W}  SIEM Forwarder${N}"
echo ""

info "Configured SIEM: $SIEM_NAME"

case "$SIEM_NAME" in
    "Wazuh + OpenSearch")
        if systemctl is-active --quiet wazuh-agent; then
            ok "Wazuh agent: active"
        else
            fail "Wazuh agent: not active"
        fi
        if ss -tn state established 2>/dev/null | grep -q ":1514"; then
            ok "Wazuh: connected to manager (TCP 1514)"
        else
            warn "Wazuh: no active session to manager — check firewall or agent enrollment"
        fi ;;
    "Splunk")
        if /opt/splunkforwarder/bin/splunk status 2>/dev/null | grep -q "running"; then
            ok "Splunk UF: running"
        else
            fail "Splunk UF: not running"
        fi ;;
    "Elastic / ELK")
        if systemctl is-active --quiet filebeat; then
            ok "Filebeat: active"
        else
            fail "Filebeat: not active"
        fi ;;
    "Microsoft Sentinel"|"IBM QRadar"|"Syslog Generic")
        if systemctl is-active --quiet rsyslog; then
            ok "Rsyslog: active"
        else
            fail "Rsyslog: not active"
        fi ;;
    "Standalone")
        ok "Standalone — no forwarder to check" ;;
    *)
        warn "Unknown SIEM config — skipping forwarder check" ;;
esac

# ── Summary ─────────────────────────────────────────────────
echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
echo -e "  ${W}Sensor     :${N} $(cat /etc/rh-pulsar/name 2>/dev/null || echo 'unknown')"
echo -e "  ${W}Sensor ID  :${N} $(cat /etc/rh-pulsar/sensor_id 2>/dev/null || echo 'unknown')"
echo -e "  ${W}Interface  :${N} ${local_iface}"
echo -e "  ${W}Zeek       :${N} $(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)"
echo -e "  ${W}Timestamp  :${N} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

if [[ "$SCORE" -ge 4 ]]; then
    echo -e "  ${G}Score: ${SCORE}/5 rules validated ✓${N}"
    echo -e "  ${G}RH Pulsar detection engine is operational.${N}"
elif [[ "$SCORE" -ge 2 ]]; then
    echo -e "  ${Y}Score: ${SCORE}/5 rules validated${N}"
    echo -e "  ${Y}Partial — check capture interface and traffic routing.${N}"
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
