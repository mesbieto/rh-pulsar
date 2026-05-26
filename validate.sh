#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Stack Validator
#  Version: 1.0.0
#  Red Horizon Security — redhorizon.ph
#
#  Validates the full RH Pulsar stack after installation.
#  Safe to run at any time — read-only, no config changes.
#
#  On manager:  sudo bash validate.sh
#  On sensor:   sudo bash validate.sh --sensor
#  Inject test: sudo bash validate.sh --inject-alert
# ═══════════════════════════════════════════════════════════

set -uo pipefail

# ── Args ────────────────────────────────────────────────────
MODE="manager"
INJECT=false
case "${1:-}" in
    --sensor)       MODE="sensor"  ;;
    --inject-alert) INJECT=true    ;;
    --help|-h)      sed -n '2,10p' "$0"; exit 0 ;;
    "")             : ;;
    *)              echo "Unknown arg: $1 — try --help"; exit 1 ;;
esac

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash validate.sh"; exit 1; }

# ── Colors ──────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' C='\033[0;36m' N='\033[0m'

PASS=0; WARN=0; FAIL=0

ok()   { echo -e "${G}  [✓]${N} $1"; PASS=$(( PASS+1 )); }
warn() { echo -e "${Y}  [!]${N} $1"; WARN=$(( WARN+1 )); }
fail() { echo -e "${R}  [✗]${N} $1"; FAIL=$(( FAIL+1 )); }
info() { echo -e "${D}  [→]${N} $1"; }
hdr()  { echo ""; echo -e "${R}  ── $1 ──${N}"; echo ""; }

# ── Load config ─────────────────────────────────────────────
CONF="/etc/rh-pulsar/manager.conf"
MANAGER_IP=""
OPENSEARCH_PASS=""
AR_TIMEOUT=3600
[[ -f "$CONF" ]] && source "$CONF" 2>/dev/null || true

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
echo -e "${W}  Stack Validator — Mode: ${MODE}${N}"
echo -e "${D}  Red Horizon Security — redhorizon.ph${N}"
echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"


# ═══════════════════════════════════════════════════════════
# MANAGER CHECKS
# ═══════════════════════════════════════════════════════════
if [[ "$MODE" == "manager" ]]; then

    # ── 1. Core services ────────────────────────────────────
    hdr "CORE SERVICES"
    for svc in wazuh-indexer wazuh-manager wazuh-dashboard filebeat postfix nginx; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            ver=$(dpkg -l "$svc" 2>/dev/null | awk '/^ii/{print $3}' | head -1 || echo "")
            ok "$svc: running${ver:+ (v${ver})}"
        else
            status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
            fail "$svc: $status"
        fi
    done

    # ── 2. Ports ────────────────────────────────────────────
    hdr "PORTS"
    declare -A PORTS=(
        [443]="Wazuh Dashboard"
        [1514]="Wazuh Agent comms"
        [1515]="Wazuh Enrollment"
        [9200]="Wazuh Indexer"
        [55000]="Wazuh API"
        [80]="Version file (nginx)"
        [25]="Postfix SMTP"
    )
    for port in 443 1514 1515 9200 55000 80 25; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            ok "Port ${port}: listening  (${PORTS[$port]})"
        else
            fail "Port ${port}: NOT listening  (${PORTS[$port]})"
        fi
    done

    # ── 3. TLS certificates ─────────────────────────────────
    hdr "TLS CERTIFICATES"
    for cert_dir in /etc/wazuh-indexer/certs /etc/filebeat/certs /etc/wazuh-dashboard/certs; do
        if [[ -d "$cert_dir" ]] && ls "$cert_dir"/*.pem &>/dev/null 2>&1; then
            count=$(ls "$cert_dir"/*.pem 2>/dev/null | wc -l)
            ok "$cert_dir: ${count} cert files"
        else
            fail "$cert_dir: missing or empty"
        fi
    done

    # ── 4. OpenSearch health ─────────────────────────────────
    hdr "OPENSEARCH (WAZUH INDEXER)"
    if [[ -n "$OPENSEARCH_PASS" ]]; then
        CACERT="/etc/wazuh-indexer/certs/root-ca.pem"
        OS_URL="https://localhost:9200"

        # Cluster health
        health=$(curl -sk -u "admin:${OPENSEARCH_PASS}" \
            --cacert "$CACERT" \
            "${OS_URL}/_cluster/health" 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" \
            2>/dev/null || echo "unreachable")
        case "$health" in
            green)  ok  "Cluster health: GREEN" ;;
            yellow) warn "Cluster health: YELLOW (single-node, expected)" ;;
            red)    fail "Cluster health: RED — check indexer logs" ;;
            *)      fail "Cluster health: $health" ;;
        esac

        # Alert index exists
        alert_count=$(curl -sk -u "admin:${OPENSEARCH_PASS}" \
            --cacert "$CACERT" \
            "${OS_URL}/wazuh-alerts-*/_count" 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count','?'))" \
            2>/dev/null || echo "?")
        if [[ "$alert_count" != "?" && "$alert_count" != "0" ]]; then
            ok "Alert index: ${alert_count} documents"
        elif [[ "$alert_count" == "0" ]]; then
            warn "Alert index: 0 documents (no alerts yet — run --inject-alert)"
        else
            warn "Alert index: not found yet (normal if just installed)"
        fi

        # Filebeat index
        fb_count=$(curl -sk -u "admin:${OPENSEARCH_PASS}" \
            --cacert "$CACERT" \
            "${OS_URL}/_cat/indices/wazuh-alerts-*?h=index,docs.count" 2>/dev/null | \
            head -3 || echo "none")
        [[ -n "$fb_count" ]] && info "Indices: $fb_count" || true

    else
        warn "OPENSEARCH_PASS not found in ${CONF} — skipping OpenSearch checks"
        info "Run: source /etc/rh-pulsar/manager.conf && echo \$OPENSEARCH_PASS"
    fi

    # ── 5. Wazuh Manager config ──────────────────────────────
    hdr "WAZUH MANAGER CONFIG"
    [[ -f /var/ossec/etc/decoders/rh-pulsar-decoders.xml ]] && \
        ok "Decoder: rh-pulsar-decoders.xml present" || \
        fail "Decoder: rh-pulsar-decoders.xml MISSING"

    [[ -f /var/ossec/etc/rules/rh-pulsar-rules.xml ]] && \
        ok "Rules: rh-pulsar-rules.xml present (110001-110007)" || \
        fail "Rules: rh-pulsar-rules.xml MISSING"

    # Decoder has no plugin_decoder (the old bug)
    if grep -q "plugin_decoder" /var/ossec/etc/decoders/rh-pulsar-decoders.xml 2>/dev/null; then
        fail "Decoder: invalid <plugin_decoder> still present — re-run setup"
    else
        ok "Decoder: no invalid plugin_decoder directives"
    fi

    # Rule uses >= threshold pattern is not applicable to XML rules — check AR location
    if grep -q "<location>all</location>" /var/ossec/etc/ossec.conf 2>/dev/null; then
        ok "AR location: all (runs on sensors)"
    elif grep -q "<location>local</location>" /var/ossec/etc/ossec.conf 2>/dev/null; then
        fail "AR location: local (runs on manager — ineffective, re-run setup)"
    else
        warn "AR location: not configured yet"
    fi

    # XML validity
    python3 -c "
import xml.etree.ElementTree as ET
ET.parse('/var/ossec/etc/ossec.conf')
" 2>/dev/null && ok "ossec.conf: XML valid" || fail "ossec.conf: XML invalid"

    # ── 6. Active response ───────────────────────────────────
    hdr "ACTIVE RESPONSE"
    [[ -f /var/ossec/active-response/bin/rh-pulsar-block.sh ]] && \
        ok "AR script: present on manager" || \
        warn "AR script: not on manager (lives on sensors — OK)"

    systemctl is-enabled --quiet rh-pulsar-ar-restore.service 2>/dev/null && \
        ok "AR restore service: enabled" || \
        warn "AR restore service: not enabled (run systemctl enable rh-pulsar-ar-restore)"

    block_count=$(ls /var/lib/rh-pulsar/ar-blocks/*.block 2>/dev/null | wc -l)
    [[ "$block_count" -gt 0 ]] && \
        info "Active blocks: ${block_count} IP(s) currently isolated" || \
        ok "Active blocks: none"

    # ── 7. Email ────────────────────────────────────────────
    hdr "EMAIL"
    crontab -l 2>/dev/null | grep -q "rh-pulsar-digest" && \
        ok "Digest cron: active (every 15 min)" || \
        fail "Digest cron: missing — re-run setup"

    [[ -f /usr/local/sbin/rh-pulsar-digest.sh ]] && \
        ok "Digest script: present" || \
        fail "Digest script: missing"

    [[ -f /etc/rh-pulsar/gmail.conf ]] && \
        ok "Gmail config: present (chmod 600)" || \
        warn "Gmail config: missing"

    # ── 8. Enrolled agents ──────────────────────────────────
    hdr "ENROLLED AGENTS"
    if command -v /var/ossec/bin/agent_control &>/dev/null; then
        agent_list=$(/var/ossec/bin/agent_control -l 2>/dev/null | grep "ID:" | head -10 || echo "")
        if [[ -n "$agent_list" ]]; then
            ok "Enrolled agents:"
            echo "$agent_list" | while read -r line; do
                info "  $line"
            done
        else
            warn "No agents enrolled yet — run install.sh on a sensor first"
        fi
    else
        info "agent_control not found — check Wazuh Manager install"
    fi

    # ── 9. Version file served ──────────────────────────────
    hdr "VERSION FILE"
    vf=$(cat /var/www/html/rh-pulsar-wazuh-version.txt 2>/dev/null || echo "missing")
    if [[ "$vf" != "missing" ]]; then
        ok "Version file: ${vf}"
        # Test if nginx serves it
        served=$(curl -sf --connect-timeout 3 "http://localhost/rh-pulsar-wazuh-version.txt" 2>/dev/null || echo "")
        [[ "$served" == "$vf" ]] && ok "nginx serving version file: OK" || \
            warn "nginx not serving version file — check nginx config"
    else
        fail "Version file missing at /var/www/html/rh-pulsar-wazuh-version.txt"
    fi

fi


# ═══════════════════════════════════════════════════════════
# SENSOR CHECKS
# ═══════════════════════════════════════════════════════════
if [[ "$MODE" == "sensor" ]]; then
    SENSOR_CONF="/etc/rh-pulsar/manager.conf"  # reuse variable name

    # ── 1. Core services ────────────────────────────────────
    hdr "CORE SERVICES"
    for svc in wazuh-agent zeek; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            ok "$svc: running"
        elif [[ "$svc" == "zeek" ]]; then
            # Zeek is managed by zeekctl, not systemd
            if /opt/zeek/bin/zeekctl status 2>/dev/null | grep -q "running"; then
                ok "zeek: running (zeekctl)"
            else
                fail "zeek: not running — run: /opt/zeek/bin/zeekctl deploy"
            fi
        else
            fail "$svc: not running"
        fi
    done

    # ── 2. Zeek detection scripts ───────────────────────────
    hdr "ZEEK DETECTION SCRIPTS"
    for script in c2beacon dnstunnel detect-ja4 malicious_ja4_db ja4-baseline http-c2; do
        if [[ -f "/opt/zeek/share/zeek/site/${script}.zeek" ]]; then
            ok "${script}.zeek: present"
        else
            fail "${script}.zeek: MISSING"
        fi
    done

    # Threshold check — must use >= not ==
    for script in c2beacon http-c2 dnstunnel; do
        file="/opt/zeek/share/zeek/site/${script}.zeek"
        [[ -f "$file" ]] || continue
        if grep -q ">= beacon_threshold\|>= suspicious_threshold\|>= long_sub_threshold" "$file" 2>/dev/null; then
            ok "${script}.zeek: threshold uses >= (correct)"
        elif grep -q "== beacon_threshold\|== suspicious_threshold" "$file" 2>/dev/null; then
            fail "${script}.zeek: threshold uses == — one-shot bug, re-run install.sh"
        fi
    done

    # ── 3. Capture interface ────────────────────────────────
    hdr "CAPTURE INTERFACE"
    CAP_IFACE=$(grep "interface=" /opt/zeek/etc/node.cfg 2>/dev/null | cut -d= -f2 || echo "")
    if [[ -n "$CAP_IFACE" ]]; then
        ok "Capture interface: $CAP_IFACE"
        if ip link show "$CAP_IFACE" 2>/dev/null | grep -q "PROMISC"; then
            ok "$CAP_IFACE: promiscuous mode ON"
        else
            fail "$CAP_IFACE: NOT in promiscuous mode"
        fi
    else
        warn "Could not determine capture interface from node.cfg"
    fi

    # ── 4. Zeek logs ────────────────────────────────────────
    hdr "ZEEK LOGS"
    ZL="/opt/zeek/logs/current"
    for log in conn.log dns.log notice.log ssl.log http.log; do
        if [[ -f "$ZL/$log" ]]; then
            lines=$(grep -vc "^#" "$ZL/$log" 2>/dev/null || echo 0)
            ok "$log: ${lines} data lines"
        else
            warn "$log: not yet created (normal if no traffic seen)"
        fi
    done

    # ── 5. Wazuh Agent connection ────────────────────────────
    hdr "WAZUH AGENT"
    if grep -q "Connected to the server" /var/ossec/logs/ossec.log 2>/dev/null; then
        ok "Agent: connected to manager"
        manager=$(grep "Connected to" /var/ossec/logs/ossec.log 2>/dev/null | tail -1)
        info "$manager"
    else
        fail "Agent: NOT connected — check manager IP and ports 1514/1515"
        info "Last log: $(tail -5 /var/ossec/logs/ossec.log 2>/dev/null | head -1)"
    fi

    # ossec.conf has localfile blocks for Zeek logs
    if grep -q "rh-pulsar-zeek" /var/ossec/etc/ossec.conf 2>/dev/null; then
        count=$(grep -c "rh-pulsar-zeek" /var/ossec/etc/ossec.conf || echo 0)
        ok "Agent config: ${count} Zeek localfile entries"
    else
        fail "Agent config: no Zeek localfile entries — re-run install.sh"
    fi

    # ── 6. AR script ────────────────────────────────────────
    hdr "ACTIVE RESPONSE"
    [[ -f /var/ossec/active-response/bin/rh-pulsar-block.sh ]] && \
        ok "AR script: present" || \
        fail "AR script: MISSING — re-run install.sh"

    systemctl is-enabled --quiet rh-pulsar-ar-restore.service 2>/dev/null && \
        ok "AR restore service: enabled" || \
        warn "AR restore service: not enabled"

    # ── 7. JA4 DB ───────────────────────────────────────────
    hdr "JA4 THREAT INTEL DB"
    DB="/opt/zeek/share/zeek/site/malicious_ja4_db.zeek"
    if [[ -f "$DB" ]]; then
        fp_count=$(grep -c '^    "t' "$DB" 2>/dev/null || echo 0)
        if [[ "$fp_count" -gt 0 ]]; then
            ok "JA4 DB: ${fp_count} fingerprints loaded"
            generated=$(grep "Generated:" "$DB" 2>/dev/null | head -1 | cut -d: -f2- || echo "")
            [[ -n "$generated" ]] && info "Last update:$generated"
        else
            warn "JA4 DB: placeholder only (first update pending)"
            info "Force update: sudo /usr/local/sbin/rh-pulsar-ja4-update.sh"
        fi
    else
        fail "JA4 DB: file missing"
    fi

    if [[ -f /var/lib/rh-pulsar/ja4-update.state ]]; then
        state=$(grep "last_status=" /var/lib/rh-pulsar/ja4-update.state | cut -d= -f2)
        info "JA4 updater last status: $state"
    fi
fi


# ═══════════════════════════════════════════════════════════
# INJECT ALERT TEST (manager only)
# Tests the full pipeline: agent → manager → OpenSearch
# ═══════════════════════════════════════════════════════════
if [[ "$INJECT" == true ]]; then
    hdr "PIPELINE INJECT TEST"

    if [[ "$MODE" == "sensor" ]]; then
        echo -e "${Y}  Run --inject-alert on the MANAGER, not the sensor.${N}"
    elif [[ -z "$OPENSEARCH_PASS" ]]; then
        warn "OPENSEARCH_PASS not found — cannot verify OpenSearch injection"
    else
        CACERT="/etc/wazuh-indexer/certs/root-ca.pem"
        OS_URL="https://localhost:9200"

        # Count alerts before injection
        before=$(curl -sk -u "admin:${OPENSEARCH_PASS}" --cacert "$CACERT" \
            "${OS_URL}/wazuh-alerts-*/_count" 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" \
            2>/dev/null || echo "0")
        info "Alert count before injection: ${before}"

        # Write a fake C2 Beacon notice directly to alerts.json
        # (simulates what happens when rule 110001 fires)
        TS=$(date -u +"%Y-%m-%dT%H:%M:%S.000+0000")
        cat >> /var/ossec/logs/alerts/alerts.json << ALERT
{"timestamp":"${TS}","rule":{"id":"110001","description":"RH Pulsar INJECT TEST: C2 Beacon","level":12,"groups":["c2","beacon","rh-pulsar"]},"agent":{"id":"000","name":"rh-pulsar-validate"},"data":{"src":"10.99.99.1","dst":"1.2.3.4","note":"C2Beacon::C2_Beacon_Detected","msg":"VALIDATE: inject test from validate.sh"}}
ALERT
        ok "Injected fake Rule 110001 alert into alerts.json"
        info "Waiting up to 30s for Filebeat to ship to OpenSearch..."

        # Poll OpenSearch for 30 seconds
        for i in $(seq 1 10); do
            sleep 3
            after=$(curl -sk -u "admin:${OPENSEARCH_PASS}" --cacert "$CACERT" \
                "${OS_URL}/wazuh-alerts-*/_count" 2>/dev/null | \
                python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" \
                2>/dev/null || echo "0")
            if [[ "$after" -gt "$before" ]]; then
                ok "OpenSearch received alert (count: ${before} → ${after})"
                break
            fi
            [[ $i -eq 10 ]] && warn "Alert not yet in OpenSearch after 30s — check Filebeat logs"
        done

        # Verify it appears in alerts.json on manager
        if grep -q "rh-pulsar-validate" /var/ossec/logs/alerts/alerts.json 2>/dev/null; then
            ok "alerts.json: test alert written"
        else
            fail "alerts.json: test alert not found"
        fi

        # Manually trigger digest to verify email
        info "Triggering digest manually..."
        bash /usr/local/sbin/rh-pulsar-digest.sh >> /var/log/rh-pulsar-digest.log 2>&1 || true
        ok "Digest triggered — check inbox at ${ALERT_EMAIL:-your email}"
    fi
fi


# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${R}${FAIL} failed${N}  ${Y}${WARN} warnings${N}  ${G}${PASS} passed${N}"
    echo ""
    echo -e "  ${Y}Run setup again for failed items, or check the log at /var/log/rh-pulsar-manager-install.log${N}"
elif [[ $WARN -gt 0 ]]; then
    echo -e "  ${G}${PASS} passed${N}  ${Y}${WARN} warnings${N}  ${R}0 failed${N}"
    echo ""
    echo -e "  ${G}Stack is functional. Review warnings above.${N}"
else
    echo -e "  ${G}${PASS} passed${N}  ${Y}0 warnings${N}  ${R}0 failed${N}"
    echo ""
    echo -e "  ${G}All checks passed — stack is fully operational.${N}"
fi
echo ""
echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo ""
