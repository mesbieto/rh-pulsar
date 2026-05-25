#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Wazuh Manager Overlay
#  Version: 1.0.0
#  Red Horizon Security — redhorizon.ph
#  © 2026 Red Horizon Security. All rights reserved.
#
#  Purpose:
#    Layers RH Pulsar detection content on top of an existing
#    Wazuh Manager installation. Run AFTER Wazuh's official
#    installer (wazuh-install.sh -a) on the same VM.
#
#  Deploys:
#    1. Custom decoders   (parse Zeek notice.log JSON)
#    2. Custom rules      (110001-110006 with MITRE tags)
#    3. Active response   (auto-isolate on Rule 110003)
#    4. Email digest      (15-min batches, dedupe, Gmail SMTP)
#    5. Index template    (OpenSearch field mappings)
#    6. Manager config    (/etc/rh-pulsar/manager.conf)
#
#  Companion to: install.sh v3.2.2+ (sensor-side)
#
#  Usage:
#    sudo bash rh-pulsar-manager-overlay.sh             # Full install
#    sudo bash rh-pulsar-manager-overlay.sh --dry-run   # Check only
#
#  Environment overrides (Ansible-friendly):
#    MANAGER_IP, ALERT_EMAIL, GMAIL_USER, GMAIL_APP_PASS
# ═══════════════════════════════════════════════════════════

set -euo pipefail

# ── Args ────────────────────────────────────────────────────
DRY_RUN=false
case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
    "") : ;;
    *) echo "Unknown argument: $1 — try --help"; exit 1 ;;
esac

# ── Colors ──────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' C='\033[0;36m' N='\033[0m'

# ── Versions / paths ───────────────────────────────────────
OVERLAY_VER="1.0.0"
LOG="/var/log/rh-pulsar-manager-install.log"
STATE_FILE="/etc/rh-pulsar/manager.state"
CONF_FILE="/etc/rh-pulsar/manager.conf"
DECODER_FILE="/var/ossec/etc/decoders/rh-pulsar-decoders.xml"
RULES_FILE="/var/ossec/etc/rules/rh-pulsar-rules.xml"
AR_SCRIPT="/var/ossec/active-response/bin/rh-pulsar-block.sh"
DIGEST_SCRIPT="/usr/local/sbin/rh-pulsar-email-digest.sh"
OSSEC_CONF="/var/ossec/etc/ossec.conf"

# ── State ───────────────────────────────────────────────────
PASS=0; WARN=0; FAIL=0
MANAGER_IP="${MANAGER_IP:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
GMAIL_USER="${GMAIL_USER:-}"
GMAIL_APP_PASS="${GMAIL_APP_PASS:-}"
CURRENT_PHASE="init"
SPINNER_PID=""

# ── Logging ─────────────────────────────────────────────────
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
ok()   { echo -e "${G}  [✓]${N} $1"; echo "[$(ts)] OK   [${CURRENT_PHASE}] $1" >> "$LOG"; PASS=$((PASS+1)); }
warn() { echo -e "${Y}  [!]${N} $1"; echo "[$(ts)] WARN [${CURRENT_PHASE}] $1" >> "$LOG"; WARN=$((WARN+1)); }
fail() { echo -e "${R}  [✗]${N} $1"; echo "[$(ts)] FAIL [${CURRENT_PHASE}] $1" >> "$LOG"; FAIL=$((FAIL+1)); }
info() { echo -e "${D}  [→]${N} $1"; echo "[$(ts)] INFO [${CURRENT_PHASE}] $1" >> "$LOG"; }
die()  { spinner_stop; echo -e "\n${R}  ✗ FATAL: $1${N}\n  See log: ${LOG}\n"; exit 1; }

# ── Error trap ──────────────────────────────────────────────
on_error() {
    local exit_code=$?
    local line_no=$1
    spinner_stop
    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${R}  ✗ OVERLAY INSTALL FAILED${N}"
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "  ${W}Phase    :${N} ${CURRENT_PHASE}"
    echo -e "  ${W}Line     :${N} ${line_no}"
    echo -e "  ${W}Exit code:${N} ${exit_code}"
    echo -e "  ${W}Last cmd :${N} ${BASH_COMMAND}"
    echo -e "  ${W}Log file :${N} ${LOG}"
    echo ""
    echo -e "${D}  Last 15 log lines:${N}"
    tail -15 "$LOG" 2>/dev/null | sed 's/^/    /' || echo "    (log unavailable)"
    echo ""
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR
trap 'spinner_stop 2>/dev/null || true' EXIT INT TERM

# ── Spinner ─────────────────────────────────────────────────
spinner_start() {
    local msg="${1:-}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    ( local i=0
      while true; do
          printf "\r  ${C}%s${N} %s " "${frames[$((i % 10))]}" "$msg"
          i=$((i+1)); sleep 0.08
      done ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
}
spinner_stop() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r\033[K"
    fi
}

# ── Phase + progress bar ───────────────────────────────────
TOTAL_STEPS=5; CURRENT_STEP=0
phase() {
    spinner_stop
    CURRENT_STEP=$((CURRENT_STEP+1))
    CURRENT_PHASE="$1"
    local pct=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local bar="" f=$(( pct / 5 )) e=$(( 20 - pct / 5 ))
    for ((i=0;i<f;i++)); do bar+="█"; done
    for ((i=0;i<e;i++)); do bar+="░"; done
    echo ""
    echo -e "${R}  ── PHASE ${CURRENT_STEP}/${TOTAL_STEPS} — $1${N}"
    echo -e "  ${D}[${G}${bar}${D}]${N} ${W}${pct}%${N}"
    echo ""
}

# ── Retry helper ────────────────────────────────────────────
retry() {
    local n=0 max=3 delay=2
    until "$@"; do
        n=$((n+1))
        if [[ $n -ge $max ]]; then return 1; fi
        sleep $delay
        delay=$((delay*2))
    done
}

# ── Secret prompt ───────────────────────────────────────────
read_secret() {
    local varname="$1" prompt="$2"
    local current="${!varname:-}"
    if [[ -n "$current" ]]; then
        info "${varname}: loaded from environment"
        return 0
    fi
    echo -n "  ${prompt}: "
    read -rs value
    echo ""
    [[ -z "$value" ]] && die "$varname required"
    printf -v "$varname" '%s' "$value"
}

# ── Banner ──────────────────────────────────────────────────
banner() {
    clear
    echo -e "${R}"
    echo "  ██████╗ ██╗  ██╗    ██████╗ ██╗   ██╗██╗     ███████╗ █████╗ ██████╗"
    echo "  ██╔══██╗██║  ██║    ██╔══██╗██║   ██║██║     ██╔════╝██╔══██╗██╔══██╗"
    echo "  ██████╔╝███████║    ██████╔╝██║   ██║██║     ███████╗███████║██████╔╝"
    echo "  ██╔══██╗██╔══██║    ██╔═══╝ ██║   ██║██║     ╚════██║██╔══██║██╔══██╗"
    echo "  ██║  ██║██║  ██║    ██║     ╚██████╔╝███████╗███████║██║  ██║██║  ██║"
    echo "  ╚═╝  ╚═╝╚═╝  ╚═╝    ╚═╝      ╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝"
    echo -e "${N}"
    echo -e "${W}  Wazuh Manager Overlay — v${OVERLAY_VER}${N}"
    echo -e "${D}  Adds RH Pulsar detection content to an existing Wazuh manager${N}"
    [[ "$DRY_RUN" == true ]] && \
        echo -e "\n${C}  [ DRY RUN — no changes will be made ]${N}"
    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
}

# ═══════════════════════════════════════════════════════════
# PHASE 1 — PREFLIGHT
# ═══════════════════════════════════════════════════════════
preflight() {
    phase "PREFLIGHT"

    [[ $EUID -ne 0 ]] && die "Run as root: sudo bash $0"
    ok "Root privileges"

    # OS check
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-}" == "ubuntu" ]] && [[ "${VERSION_ID:-}" == "24.04" ]]; then
            ok "OS: ${PRETTY_NAME}"
        elif [[ "${ID:-}" == "ubuntu" ]] && [[ "${VERSION_ID:-}" == "22.04" ]]; then
            warn "OS: ${PRETTY_NAME} — tolerated, 24.04 recommended"
        else
            die "Unsupported OS: ${PRETTY_NAME:-unknown}"
        fi
    fi

    # Wazuh manager must already be installed
    if [[ ! -d /var/ossec ]] || [[ ! -f /var/ossec/bin/wazuh-control ]]; then
        die "Wazuh Manager not found at /var/ossec. Run Wazuh's official installer first:
        curl -sO https://packages.wazuh.com/4.12/wazuh-install.sh
        sudo bash ./wazuh-install.sh -a"
    fi
    ok "Wazuh Manager: detected at /var/ossec"

    # Check manager is running
    if /var/ossec/bin/wazuh-control status 2>/dev/null | grep -q "is running"; then
        ok "Wazuh Manager: running"
    else
        warn "Wazuh Manager: not running — will start after overlay"
    fi

    # Required commands
    for cmd in curl jq python3 systemctl; do
        if command -v "$cmd" &>/dev/null; then
            ok "Required: $cmd"
        else
            fail "Missing: $cmd"
        fi
    done

    # Internet (for postfix install if needed)
    if curl -sf --connect-timeout 5 --max-time 8 https://archive.ubuntu.com &>/dev/null; then
        ok "Internet: reachable"
    else
        warn "Internet: unreachable — postfix may already be installed"
    fi

    # Disk space — 5GB free is enough for overlay (Wazuh installed already)
    local disk; disk=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    [[ "$disk" -ge 5 ]] && ok "Disk: ${disk}GB free" || fail "Disk: ${disk}GB — need 5GB+ free"

    # Existing overlay?
    if [[ -f "$STATE_FILE" ]]; then
        warn "Previous overlay detected at $STATE_FILE — will reconfigure in place"
    else
        ok "Clean overlay install"
    fi

    echo ""
    echo -e "  ${G}${PASS} passed${N}  ${Y}${WARN} warnings${N}  ${R}${FAIL} failed${N}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        [[ "$FAIL" -gt 0 ]] && echo -e "${R}  ✗ Resolve ${FAIL} issue(s) first${N}" || echo -e "${G}  ✓ Ready — run: sudo bash $0${N}"
        echo ""; exit 0
    fi

    [[ "$FAIL" -gt 0 ]] && die "Preflight failed — fix above issues and retry"
}

# ═══════════════════════════════════════════════════════════
# PHASE 2 — CONFIGURATION
# ═══════════════════════════════════════════════════════════
configure() {
    phase "CONFIGURATION"

    # Auto-detect manager IP
    if [[ -z "$MANAGER_IP" ]]; then
        local auto_ip
        auto_ip=$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}' || echo "")
        if [[ -n "$auto_ip" ]]; then
            echo -e "  ${D}Auto-detected manager IP: ${W}${auto_ip}${N}"
            read -rp "  Confirm or enter different IP: " input_ip
            MANAGER_IP="${input_ip:-$auto_ip}"
        else
            read -rp "  Wazuh Manager IP (this host): " MANAGER_IP
        fi
    fi
    [[ -z "$MANAGER_IP" ]] && die "Manager IP required"

    # SOC alert email
    if [[ -z "$ALERT_EMAIL" ]]; then
        read -rp "  SOC Alert Email (digest recipient): " ALERT_EMAIL
    fi
    [[ -z "$ALERT_EMAIL" ]] && die "Alert email required"

    # Gmail credentials for SMTP relay
    echo ""
    echo -e "${D}  ──────────────────────────────────────────────────────${N}"
    echo -e "${D}  Email digest will relay through Gmail SMTP.${N}"
    echo -e "${D}  Generate an App Password at:${N}"
    echo -e "${D}    https://myaccount.google.com/apppasswords${N}"
    echo -e "${D}  (Requires 2FA enabled on the Google account)${N}"
    echo -e "${D}  ──────────────────────────────────────────────────────${N}"
    echo ""

    if [[ -z "$GMAIL_USER" ]]; then
        read -rp "  Gmail Sender Address: " GMAIL_USER
    fi
    [[ -z "$GMAIL_USER" ]] && die "Gmail sender required"

    read_secret GMAIL_APP_PASS "Gmail App Password (16 chars, spaces auto-stripped)"
    # Strip spaces from app password (Google displays with spaces, accepts without)
    GMAIL_APP_PASS=$(echo "$GMAIL_APP_PASS" | tr -d ' ')

    # Resource sizing
    local ram_kb opensearch_heap
    ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    opensearch_heap=$(( ram_kb / 2 / 1024 ))    # half RAM in MB
    [[ "$opensearch_heap" -gt 30000 ]] && opensearch_heap=30000   # JVM 30GB cap

    # Summary
    echo ""
    echo -e "${D}  ── Summary ───────────────────────────${N}"
    echo -e "  Manager IP   : ${W}$MANAGER_IP${N}"
    echo -e "  Alert Email  : ${W}$ALERT_EMAIL${N}"
    echo -e "  Gmail Sender : ${W}$GMAIL_USER${N}"
    echo -e "  OS Heap (est): ${W}${opensearch_heap}m${N} (informational)"
    echo -e "${D}  ─────────────────────────────────────${N}"
    echo ""
    read -rp "  Confirm? (y/N): " c || true
    [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1

    # Write config file
    mkdir -p /etc/rh-pulsar
    cat > "$CONF_FILE" << EOF
# RH Pulsar Manager Configuration
# Generated: $(ts)
MANAGER_IP=$MANAGER_IP
ALERT_EMAIL=$ALERT_EMAIL
GMAIL_USER=$GMAIL_USER
AR_TIMEOUT=3600
RETENTION_DAYS=90
OPENSEARCH_HEAP=${opensearch_heap}m
WAZUH_REPO=4.x
INSTALL_DATE=$(ts)
EOF
    chmod 600 "$CONF_FILE"
    ok "Config written: $CONF_FILE"
}

# ═══════════════════════════════════════════════════════════
# PHASE 3 — DEPLOY DECODERS + RULES
# ═══════════════════════════════════════════════════════════
deploy_detection_content() {
    phase "DEPLOYING DETECTION CONTENT"

    # Backup existing files
    local bk="/etc/rh-pulsar/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk"
    [[ -f "$DECODER_FILE" ]] && cp "$DECODER_FILE" "$bk/"
    [[ -f "$RULES_FILE"   ]] && cp "$RULES_FILE"   "$bk/"
    [[ -f "$OSSEC_CONF"   ]] && cp "$OSSEC_CONF"   "$bk/"
    ok "Backed up existing config to ${bk}"

    # ── Decoder ─────────────────────────────────────────────
    mkdir -p "$(dirname "$DECODER_FILE")"
    cat > "$DECODER_FILE" << 'EOF'
<!--
  RH Pulsar — Wazuh Decoders for Zeek notice.log
  Source: install.sh writes notice.log with label "rh-pulsar-zeek"
  Format: Zeek JSON notices with fields: ts, note, msg, src, dst, identifier
-->

<decoder name="rh-pulsar-zeek">
  <prematch>"rh-pulsar-zeek"</prematch>
</decoder>

<decoder name="rh-pulsar-zeek-fields">
  <parent>rh-pulsar-zeek</parent>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>
EOF
    chmod 640 "$DECODER_FILE"
    chown root:wazuh "$DECODER_FILE" 2>/dev/null || true
    ok "Decoder deployed: $DECODER_FILE"

    # ── Rules ───────────────────────────────────────────────
    mkdir -p "$(dirname "$RULES_FILE")"
    cat > "$RULES_FILE" << 'EOF'
<!--
  RH Pulsar — Wazuh Rules
  Maps Zeek notice types to Wazuh rule IDs (110001-110006)
  All rules require parent rule 110000 to match (group: rh-pulsar)
-->

<group name="rh-pulsar,ndr,">

  <!-- Base rule — fires on any RH Pulsar Zeek notice -->
  <rule id="110000" level="3">
    <decoded_as>rh-pulsar-zeek</decoded_as>
    <description>RH Pulsar: Zeek notice received</description>
    <group>rh-pulsar,zeek,</group>
  </rule>

  <!-- Rule 110001 — C2 Beacon (T1071) -->
  <rule id="110001" level="12">
    <if_sid>110000</if_sid>
    <field name="note">C2Beacon::C2_Beacon_Detected</field>
    <description>RH Pulsar 110001: C2 Beacon detected — repeated outbound connections</description>
    <mitre>
      <id>T1071</id>
    </mitre>
    <group>rh-pulsar,c2,beacon,attack.command_and_control,</group>
  </rule>

  <!-- Rule 110002 — DNS Tunnel (T1071.004) -->
  <rule id="110002" level="14">
    <if_sid>110000</if_sid>
    <field name="note">DNSTunnel::DNS_Tunnel_Detected</field>
    <description>RH Pulsar 110002: DNS Tunnel detected — possible data exfiltration via DNS</description>
    <mitre>
      <id>T1071.004</id>
    </mitre>
    <group>rh-pulsar,dns,tunnel,exfiltration,attack.command_and_control,</group>
  </rule>

  <!-- Rule 110003 — Sliver JA4 (T1573) — TRIGGERS ACTIVE RESPONSE -->
  <rule id="110003" level="15">
    <if_sid>110000</if_sid>
    <field name="note">DetectJA4::Sliver_JA4_Detected</field>
    <description>RH Pulsar 110003: Sliver C2 framework detected via JA4 fingerprint</description>
    <mitre>
      <id>T1573</id>
    </mitre>
    <group>rh-pulsar,ja4,sliver,c2,attack.command_and_control,</group>
  </rule>

  <!-- Rule 110003b — Malicious JA4 from DB (T1573) -->
  <rule id="110013" level="14">
    <if_sid>110000</if_sid>
    <field name="note">DetectJA4::Malicious_JA4_Detected</field>
    <description>RH Pulsar 110003: Malicious JA4 fingerprint detected from intel DB</description>
    <mitre>
      <id>T1573</id>
    </mitre>
    <group>rh-pulsar,ja4,c2,attack.command_and_control,</group>
  </rule>

  <!-- Rule 110004 — HTTP C2 Beacon (T1071.001) -->
  <rule id="110004" level="12">
    <if_sid>110000</if_sid>
    <field name="note">HTTPC2::HTTP_C2_Beacon</field>
    <description>RH Pulsar 110004: HTTP C2 Beacon detected — repeated hits to same URI</description>
    <mitre>
      <id>T1071.001</id>
    </mitre>
    <group>rh-pulsar,http,c2,beacon,attack.command_and_control,</group>
  </rule>

  <!-- Rule 110005 — Suspicious User-Agent (T1071.001) -->
  <rule id="110005" level="10">
    <if_sid>110000</if_sid>
    <field name="note">HTTPC2::Suspicious_UserAgent</field>
    <description>RH Pulsar 110005: Suspicious User-Agent — possible C2 client</description>
    <mitre>
      <id>T1071.001</id>
    </mitre>
    <group>rh-pulsar,http,suspicious_ua,attack.command_and_control,</group>
  </rule>

  <!-- Rule 110006 — Novel JA4 from baseline (T1573) -->
  <rule id="110006" level="10">
    <if_sid>110000</if_sid>
    <field name="note">JA4Baseline::Novel_JA4_Observed</field>
    <description>RH Pulsar 110006: Novel JA4 fingerprint — anomaly vs environment baseline</description>
    <mitre>
      <id>T1573</id>
    </mitre>
    <group>rh-pulsar,ja4,anomaly,baseline,</group>
  </rule>

</group>
EOF
    chmod 640 "$RULES_FILE"
    chown root:wazuh "$RULES_FILE" 2>/dev/null || true
    ok "Rules deployed: $RULES_FILE (rules 110000-110006, 110013)"

    # Validate XML
    if command -v xmllint &>/dev/null; then
        xmllint --noout "$DECODER_FILE" 2>>"$LOG" && ok "Decoder XML: valid"
        xmllint --noout "$RULES_FILE"   2>>"$LOG" && ok "Rules XML: valid"
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 4 — ACTIVE RESPONSE + OSSEC.CONF
# ═══════════════════════════════════════════════════════════
deploy_active_response() {
    phase "DEPLOYING ACTIVE RESPONSE"

    # ── Manager-side AR config in ossec.conf ────────────────
    # Only add if not already present (idempotency)
    if ! grep -q "rh-pulsar-block" "$OSSEC_CONF" 2>/dev/null; then
        # Insert before closing </ossec_config>
        local tmp_conf="${OSSEC_CONF}.tmp.$$"
        awk '
            /<\/ossec_config>/ && !done {
                print ""
                print "  <!-- ════ RH Pulsar Active Response ════ -->"
                print "  <command>"
                print "    <name>rh-pulsar-block</name>"
                print "    <executable>rh-pulsar-block.sh</executable>"
                print "    <timeout_allowed>yes</timeout_allowed>"
                print "  </command>"
                print ""
                print "  <active-response>"
                print "    <command>rh-pulsar-block</command>"
                print "    <location>local</location>"
                print "    <rules_id>110003</rules_id>"
                print "    <timeout>3600</timeout>"
                print "  </active-response>"
                print ""
                done=1
            }
            { print }
        ' "$OSSEC_CONF" > "$tmp_conf"
        mv "$tmp_conf" "$OSSEC_CONF"
        chown root:wazuh "$OSSEC_CONF" 2>/dev/null || true
        chmod 660 "$OSSEC_CONF"
        ok "Active response configured in ossec.conf (Rule 110003 only)"
    else
        ok "Active response: already in ossec.conf (skipped)"
    fi

    # ── AR script for sensor distribution ───────────────────
    # This script will be copied to sensors during sensor install.sh
    # We stage it here in a known location for documentation/manual copy
    mkdir -p /etc/rh-pulsar/sensor-deploy
    cat > /etc/rh-pulsar/sensor-deploy/rh-pulsar-block.sh << 'AREOF'
#!/bin/bash
# RH Pulsar — Active Response: Auto-isolate Source IP
# Runs on SENSOR (not manager) when triggered by Wazuh manager
# Triggered by: Rule 110003 (Sliver JA4 detection)
# Action: iptables DROP on source IP for AR_TIMEOUT seconds

# Wazuh AR API: action arg ($1) is 'add' or 'delete'
# Subsequent args contain the alert JSON

LOG="/var/log/rh-pulsar-ar.log"
ACTION="${1:-add}"
USER="${2:-}"
SRCIP="${3:-}"

# Source per-sensor config if exists
[[ -f /etc/rh-pulsar/manager.conf ]] && . /etc/rh-pulsar/manager.conf
AR_TIMEOUT="${AR_TIMEOUT:-3600}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# Sanity check IP
if [[ ! "$SRCIP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    log "ERROR: Invalid source IP: '$SRCIP'"
    exit 1
fi

# Don't block private/local ranges we shouldn't (safety net)
case "$SRCIP" in
    127.*|0.0.0.0|169.254.*)
        log "REFUSED: Will not block local/link-local IP: $SRCIP"
        exit 1 ;;
esac

case "$ACTION" in
    add)
        log "BLOCK: Adding iptables DROP for $SRCIP (timeout ${AR_TIMEOUT}s)"
        iptables -I INPUT   -s "$SRCIP" -j DROP -m comment --comment "rh-pulsar-block" 2>/dev/null
        iptables -I FORWARD -s "$SRCIP" -j DROP -m comment --comment "rh-pulsar-block" 2>/dev/null
        ;;
    delete)
        log "UNBLOCK: Removing iptables DROP for $SRCIP"
        iptables -D INPUT   -s "$SRCIP" -j DROP -m comment --comment "rh-pulsar-block" 2>/dev/null || true
        iptables -D FORWARD -s "$SRCIP" -j DROP -m comment --comment "rh-pulsar-block" 2>/dev/null || true
        ;;
    *)
        log "ERROR: Unknown action: $ACTION"
        exit 1 ;;
esac

exit 0
AREOF
    chmod 755 /etc/rh-pulsar/sensor-deploy/rh-pulsar-block.sh
    ok "AR script staged: /etc/rh-pulsar/sensor-deploy/rh-pulsar-block.sh"
    info "Copy to each sensor at: /var/ossec/active-response/bin/rh-pulsar-block.sh"
    info "Permissions on sensor: chown root:wazuh, chmod 750"
}

# ═══════════════════════════════════════════════════════════
# PHASE 5 — EMAIL DIGEST + RESTART
# ═══════════════════════════════════════════════════════════
deploy_email_digest() {
    phase "EMAIL DIGEST + FINALIZE"

    # ── Install postfix if missing ──────────────────────────
    if ! command -v postfix &>/dev/null; then
        spinner_start "Installing postfix..."
        DEBIAN_FRONTEND=noninteractive retry apt-get update -qq >> "$LOG" 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            postfix mailutils libsasl2-modules >> "$LOG" 2>&1
        spinner_stop
        ok "Postfix installed"
    else
        ok "Postfix: already installed"
    fi

    # ── Configure postfix for Gmail relay ───────────────────
    postconf -e "relayhost = [smtp.gmail.com]:587"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_tls_security_level = encrypt"
    postconf -e "smtp_sasl_tls_security_options = noanonymous"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "mydestination ="

    # SASL password file
    echo "[smtp.gmail.com]:587 ${GMAIL_USER}:${GMAIL_APP_PASS}" > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd
    ok "Postfix Gmail relay configured (port 587 TLS)"

    systemctl restart postfix
    systemctl enable postfix >> "$LOG" 2>&1
    ok "Postfix: restarted + enabled"

    # ── Email digest script ─────────────────────────────────
    cat > "$DIGEST_SCRIPT" << 'DIGESTEOF'
#!/bin/bash
# RH Pulsar — Email Digest
# Runs every 15 minutes via systemd timer
# Reads new alerts from /var/ossec/logs/alerts/alerts.json
# Dedupes by (src_ip + rule_id) within 1 hour
# Sends one digest email if there are any new alerts

set -uo pipefail

. /etc/rh-pulsar/manager.conf 2>/dev/null || { echo "no config"; exit 1; }

ALERTS_JSON="/var/ossec/logs/alerts/alerts.json"
STATE_DIR="/var/lib/rh-pulsar"
STATE_FILE="${STATE_DIR}/last_digest.ts"
DEDUPE_FILE="${STATE_DIR}/dedupe.cache"
LOG="/var/log/rh-pulsar-digest.log"

mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Determine since when to read alerts
LAST_TS=0
[[ -f "$STATE_FILE" ]] && LAST_TS=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
NOW_TS=$(date +%s)

# Read new alerts from alerts.json (newline-delimited JSON)
if [[ ! -f "$ALERTS_JSON" ]]; then
    log "No alerts.json found — skipping"
    echo "$NOW_TS" > "$STATE_FILE"
    exit 0
fi

# Build dedupe cache: remove entries older than 1 hour
DEDUPE_CUTOFF=$(( NOW_TS - 3600 ))
if [[ -f "$DEDUPE_FILE" ]]; then
    awk -v cutoff="$DEDUPE_CUTOFF" '$1 >= cutoff' "$DEDUPE_FILE" > "${DEDUPE_FILE}.tmp" || true
    mv "${DEDUPE_FILE}.tmp" "$DEDUPE_FILE"
else
    touch "$DEDUPE_FILE"
fi

# Filter alerts: rh-pulsar group, level >= 10, since LAST_TS, not duplicates
DIGEST_BODY=$(python3 - "$ALERTS_JSON" "$LAST_TS" "$DEDUPE_FILE" "$NOW_TS" << 'PYEOF'
import sys, json, os
from datetime import datetime

alerts_path, last_ts_s, dedupe_path, now_ts_s = sys.argv[1:5]
last_ts = int(last_ts_s)
now_ts = int(now_ts_s)

# Load existing dedupe cache (ts<TAB>key per line)
seen = set()
try:
    with open(dedupe_path) as f:
        for line in f:
            parts = line.strip().split('\t', 1)
            if len(parts) == 2:
                seen.add(parts[1])
except Exception:
    pass

new_alerts = []
new_dedupe = []

try:
    with open(alerts_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                a = json.loads(line)
            except Exception:
                continue

            ts_str = a.get('timestamp', '')
            try:
                ts = int(datetime.fromisoformat(ts_str.replace('Z','+00:00')).timestamp())
            except Exception:
                continue
            if ts <= last_ts:
                continue

            rule = a.get('rule', {})
            level = rule.get('level', 0)
            if level < 10:
                continue

            groups = rule.get('groups', [])
            if 'rh-pulsar' not in groups:
                continue

            rule_id = rule.get('id', 'unknown')
            agent = a.get('agent', {}).get('name', 'unknown')
            data = a.get('data', {})
            src = data.get('src', 'unknown')
            dst = data.get('dst', 'unknown')
            note = data.get('note', '')
            msg = data.get('msg', '')

            mitre = ''
            if rule.get('mitre'):
                mitre = ','.join(rule['mitre'].get('id', []))

            # Dedupe key: src + rule
            key = f"{src}|{rule_id}"
            if key in seen:
                continue
            seen.add(key)
            new_dedupe.append(f"{now_ts}\t{key}")

            new_alerts.append({
                'ts': ts_str,
                'rule_id': rule_id,
                'level': level,
                'agent': agent,
                'src': src,
                'dst': dst,
                'note': note,
                'msg': msg,
                'mitre': mitre,
            })
except Exception as e:
    print(f"ERROR reading alerts: {e}", file=sys.stderr)
    sys.exit(1)

# Append new entries to dedupe file
if new_dedupe:
    with open(dedupe_path, 'a') as f:
        for d in new_dedupe:
            f.write(d + '\n')

# Output digest body or "EMPTY"
if not new_alerts:
    print("EMPTY")
    sys.exit(0)

# Build digest body
print(f"COUNT={len(new_alerts)}")
print(f"AGENT={new_alerts[0]['agent']}")
print("---BODY---")
for a in new_alerts:
    print(f"[{a['ts']}] Rule {a['rule_id']} (lvl {a['level']}) — {a['note']}")
    print(f"  Sensor: {a['agent']}")
    print(f"  Source: {a['src']}  -> Destination: {a['dst']}")
    print(f"  MITRE : {a['mitre']}")
    print(f"  Detail: {a['msg']}")
    print(f"  Action: " + ("AUTO-ISOLATED (Rule 110003)" if a['rule_id']=='110003' else "alert-only"))
    print("")
PYEOF
)

if [[ "$DIGEST_BODY" == "EMPTY" ]]; then
    log "No new alerts to send"
    echo "$NOW_TS" > "$STATE_FILE"
    exit 0
fi

# Parse digest
COUNT=$(echo "$DIGEST_BODY" | head -1 | cut -d= -f2)
AGENT=$(echo "$DIGEST_BODY" | sed -n '2p' | cut -d= -f2)
BODY=$(echo "$DIGEST_BODY" | sed -n '/^---BODY---$/,$p' | tail -n +2)

SUBJECT="[RH PULSAR] ${COUNT} Alerts — ${AGENT} — $(date '+%Y-%m-%d %H:%M')"

# Send email
{
    echo "RH Pulsar Detection Summary"
    echo "==========================="
    echo "Time:     $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Sensor:   ${AGENT}"
    echo "Count:    ${COUNT} new alerts (deduped by src+rule, 1hr window)"
    echo ""
    echo "$BODY"
    echo ""
    echo "--"
    echo "RH Pulsar Manager: ${MANAGER_IP}"
    echo "Dashboard: https://${MANAGER_IP}"
} | mail -s "$SUBJECT" "$ALERT_EMAIL"

log "Sent digest: ${COUNT} alerts to ${ALERT_EMAIL}"
echo "$NOW_TS" > "$STATE_FILE"
DIGESTEOF
    chmod 755 "$DIGEST_SCRIPT"
    ok "Email digest script: $DIGEST_SCRIPT"

    # ── Systemd timer for digest (every 15 min) ─────────────
    cat > /etc/systemd/system/rh-pulsar-email-digest.service << EOF
[Unit]
Description=RH Pulsar — Email Digest Sender
Documentation=https://redhorizon.ph

[Service]
Type=oneshot
ExecStart=$DIGEST_SCRIPT
StandardOutput=journal
StandardError=journal
Nice=10
EOF

    cat > /etc/systemd/system/rh-pulsar-email-digest.timer << 'EOF'
[Unit]
Description=RH Pulsar — Email Digest Every 15 Minutes

[Timer]
OnCalendar=*:0/15
Persistent=true
Unit=rh-pulsar-email-digest.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now rh-pulsar-email-digest.timer >> "$LOG" 2>&1
    ok "Email digest timer: every 15 minutes"

    # ── Restart Wazuh manager to pick up new rules ──────────
    spinner_start "Restarting Wazuh manager to load new rules..."
    if /var/ossec/bin/wazuh-control restart >> "$LOG" 2>&1; then
        spinner_stop
        ok "Wazuh Manager restarted with RH Pulsar rules"
    else
        spinner_stop
        warn "wazuh-control restart returned non-zero — check $LOG"
        warn "Verify with: sudo /var/ossec/bin/wazuh-control status"
    fi

    # Save state
    cat > "$STATE_FILE" << EOF
OVERLAY_VER=$OVERLAY_VER
INSTALL_DATE=$(ts)
MANAGER_IP=$MANAGER_IP
ALERT_EMAIL=$ALERT_EMAIL
EOF
    chmod 600 "$STATE_FILE"
    ok "State saved: $STATE_FILE"
}

# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════
summary() {
    CURRENT_PHASE="summary"

    # Try to detect dashboard port (Wazuh defaults to 443)
    local dash_port=443
    if ss -tln 2>/dev/null | grep -q ":5601 "; then
        dash_port=5601
    fi

    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${G}  RH PULSAR MANAGER OVERLAY DEPLOYED${N}"
    echo ""
    echo -e "  ${W}Wazuh Manager  :${N} https://${MANAGER_IP}:55000  (API)"
    echo -e "  ${W}Wazuh Indexer  :${N} https://${MANAGER_IP}:9200"
    echo -e "  ${W}Dashboard      :${N} https://${MANAGER_IP}:${dash_port}"
    echo -e "  ${W}Email alerts   :${N} ${ALERT_EMAIL} (digest every 15 min, ≥ level 10)"
    echo -e "  ${W}Active response:${N} enabled for Rule 110003 (Sliver JA4)"
    echo -e "  ${W}Log file       :${N} ${LOG}"
    echo ""
    echo -e "  ${W}Rules deployed :${N}"
    echo -e "    ${G}[✓]${N} 110001 C2 Beacon            (lvl 12, T1071)"
    echo -e "    ${G}[✓]${N} 110002 DNS Tunnel            (lvl 14, T1071.004)"
    echo -e "    ${G}[✓]${N} 110003 Sliver JA4 + AR       (lvl 15, T1573)"
    echo -e "    ${G}[✓]${N} 110013 Malicious JA4 (DB)    (lvl 14, T1573)"
    echo -e "    ${G}[✓]${N} 110004 HTTP C2 Beacon        (lvl 12, T1071.001)"
    echo -e "    ${G}[✓]${N} 110005 Suspicious UA         (lvl 10, T1071.001)"
    echo -e "    ${G}[✓]${N} 110006 Novel JA4 (Tier 2)    (lvl 10, T1573)"
    echo ""
    echo -e "${Y}  ⚠  IMPORTANT — Active Response setup on each sensor:${N}"
    echo -e "    1. SCP the AR script to each sensor:"
    echo -e "       ${D}scp /etc/rh-pulsar/sensor-deploy/rh-pulsar-block.sh \\${N}"
    echo -e "       ${D}    sensor:/var/ossec/active-response/bin/rh-pulsar-block.sh${N}"
    echo -e "    2. Set permissions on sensor:"
    echo -e "       ${D}sudo chown root:wazuh /var/ossec/active-response/bin/rh-pulsar-block.sh${N}"
    echo -e "       ${D}sudo chmod 750         /var/ossec/active-response/bin/rh-pulsar-block.sh${N}"
    echo -e "    3. Restart wazuh-agent: ${D}sudo systemctl restart wazuh-agent${N}"
    echo ""
    echo -e "  ${W}To add a new client sensor:${N}"
    echo -e "    On sensor VM: ${D}SIEM_HOST=${MANAGER_IP} sudo bash install.sh${N}"
    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${W}  Red Horizon Security — redhorizon.ph${N}"
    echo -e "${D}  © 2026 Red Horizon Security. All rights reserved.${N}"
    echo ""
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════
main() {
    mkdir -p /var/log /etc/rh-pulsar
    : > "$LOG"
    chmod 600 "$LOG"
    echo "[$(ts)] RH Pulsar Manager Overlay v${OVERLAY_VER} — DRY_RUN=${DRY_RUN}" >> "$LOG"

    banner
    preflight                  # 1
    configure                  # 2
    deploy_detection_content   # 3
    deploy_active_response     # 4
    deploy_email_digest        # 5
    summary
}

main "$@"
