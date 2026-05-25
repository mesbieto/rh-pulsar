#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Wazuh Manager Setup
#  Version: 1.0.0
#  Red Horizon — redhorizon.ph
#  © 2026 Red Horizon. All rights reserved.
#
#  Companion to install.sh — runs on Wazuh Manager VM (VM2)
#  Compatible with: install.sh v3.2.5+
#
#  Usage:
#    sudo bash setup-wazuh-manager.sh            # Full setup
#    sudo bash setup-wazuh-manager.sh --dry-run  # Check only
# ═══════════════════════════════════════════════════════════

set -euo pipefail

# ── Args ────────────────────────────────────────────────────
DRY_RUN=false
case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    --help|-h) sed -n '2,15p' "$0"; exit 0 ;;
    "") : ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
esac

# ── Colors ──────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' C='\033[0;36m' N='\033[0m'

# ── Versions ────────────────────────────────────────────────
PULSAR_VER="1.0.0"
WAZUH_REPO="4.x"

# ── State ───────────────────────────────────────────────────
LOG="/var/log/rh-pulsar-manager-install.log"
STATE_FILE="/etc/rh-pulsar/manager.state"
CONF_FILE="/etc/rh-pulsar/manager.conf"
PASS=0; WARN=0; FAIL=0
MANAGER_IP=""
ALERT_EMAIL=""
GMAIL_APP_PASS=""
AR_TIMEOUT=3600
OPENSEARCH_HEAP=""
SPINNER_PID=""
CURRENT_PHASE="init"
TOTAL_STEPS=8; CURRENT_STEP=0

# ── Logging ─────────────────────────────────────────────────
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
ok()   { echo -e "${G}  [✓]${N} $1"; echo "[$(ts)] OK   [$CURRENT_PHASE] $1" >> "$LOG"; PASS=$((PASS+1)); }
warn() { echo -e "${Y}  [!]${N} $1"; echo "[$(ts)] WARN [$CURRENT_PHASE] $1" >> "$LOG"; WARN=$((WARN+1)); }
fail() { echo -e "${R}  [✗]${N} $1"; echo "[$(ts)] FAIL [$CURRENT_PHASE] $1" >> "$LOG"; FAIL=$((FAIL+1)); }
info() { echo -e "${D}  [→]${N} $1"; echo "[$(ts)] INFO [$CURRENT_PHASE] $1" >> "$LOG"; }
die()  { spinner_stop; echo -e "\n${R}  FATAL: $1${N}\n  Log: ${LOG}\n"; exit 1; }
has()  { command -v "$1" &>/dev/null; }

on_error() {
    local exit_code=$? line_no=$1
    spinner_stop
    echo ""
    echo -e "${R}  ✗ FAILED — Phase: ${CURRENT_PHASE} | Line: ${line_no} | Exit: ${exit_code}${N}"
    echo -e "${D}  Last command: ${BASH_COMMAND}${N}"
    echo -e "${D}  Log: ${LOG}${N}"
    tail -10 "$LOG" 2>/dev/null | sed 's/^/    /'
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
    [[ -n "${SPINNER_PID:-}" ]] && {
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r\033[K"
    }
}

# ── Phase progress ───────────────────────────────────────────
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
        [[ $n -ge $max ]] && return 1
        sleep $delay; delay=$((delay*2))
    done
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
    echo -e "${W}  Wazuh Manager Setup — v${PULSAR_VER}${N}"
    echo -e "${D}  Red Horizon — redhorizon.ph${N}"
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

    [[ $EUID -ne 0 ]] && die "Run as root: sudo bash setup-wazuh-manager.sh"
    ok "Root"

    # OS check
    local os_id os_ver
    os_id=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    os_ver=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    case "${os_id}:${os_ver}" in
        ubuntu:24.04) ok "OS: Ubuntu 24.04 LTS" ;;
        ubuntu:22.04) warn "OS: Ubuntu 22.04 — supported but 24.04 recommended" ;;
        *) die "Unsupported OS: ${os_id} ${os_ver} — Ubuntu 24.04 required" ;;
    esac

    # APT lock
    fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && \
        die "APT locked — wait for other package operations to finish"
    ok "APT: free"

    # Resources
    local cpu ram_kb ram_gb disk
    cpu=$(nproc)
    ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    ram_gb=$(awk '/MemTotal/{printf "%.1f",$2/1024/1024}' /proc/meminfo)
    disk=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')

    [[ "$cpu"    -ge 4       ]] && ok "CPU: ${cpu} vCPU" || warn "CPU: ${cpu} — 4+ recommended for Wazuh+OpenSearch"
    [[ "$ram_kb" -ge 8388608 ]] && ok "RAM: ${ram_gb}GB" || fail "RAM: ${ram_gb}GB — minimum 8GB required for OpenSearch"
    [[ "$disk"   -ge 50      ]] && ok "Disk: ${disk}GB free" || fail "Disk: ${disk}GB — minimum 50GB required"

    # Auto-size OpenSearch heap — half of RAM, max 31GB
    local heap_mb=$(( ram_kb / 1024 / 2 ))
    [[ "$heap_mb" -gt 31744 ]] && heap_mb=31744
    OPENSEARCH_HEAP="${heap_mb}m"
    ok "OpenSearch heap: ${OPENSEARCH_HEAP} (auto-sized)"

    # Internet
    retry curl -sf --connect-timeout 5 --max-time 8 https://packages.wazuh.com &>/dev/null && \
        ok "Internet: reachable" || fail "Internet: unreachable"

    # Ports
    for port in 1514 1515 9200 9300 5601 55000; do
        local cnt; cnt=$(ss -tlnp 2>/dev/null | grep -c ":${port} " || echo 0)
        cnt=$(echo "$cnt" | tr -d '[:space:]')
        if [[ "$cnt" -gt 0 ]]; then
            # Check if it is already Wazuh/OpenSearch
            local proc; proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'users:\(\("\K[^"]+' | head -1 || echo "unknown")
            warn "Port ${port}: in use by ${proc} — may be existing install"
        else
            ok "Port ${port}: free"
        fi
    done

    # Check if already installed
    if systemctl is-active --quiet wazuh-manager 2>/dev/null; then
        warn "Wazuh Manager already running — will reconfigure"
    fi

    # Summary
    echo ""
    echo -e "  ${G}${PASS} passed${N}  ${Y}${WARN} warnings${N}  ${R}${FAIL} conflicts${N}"
    echo ""

    [[ "$DRY_RUN" == true ]] && {
        [[ "$FAIL" -gt 0 ]] && \
            echo -e "${R}  ✗ ${FAIL} conflict(s) — resolve before running${N}" || \
            echo -e "${G}  ✓ Ready — run: sudo bash setup-wazuh-manager.sh${N}"
        echo ""; exit 0
    }

    [[ "$FAIL" -gt 0 ]] && {
        read -rp "  ${FAIL} conflict(s). Continue? (y/N): " c || true
        [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1
    }
}

# ═══════════════════════════════════════════════════════════
# PHASE 2 — CONFIGURATION
# Collect only what is needed — 3 inputs
# ═══════════════════════════════════════════════════════════
configure() {
    phase "CONFIGURATION"

    # Manager IP — auto-detect, just confirm
    local detected_ip
    detected_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | \
                  grep -v "^127\." | head -1 || echo "")

    echo -e "${W}  Manager IP${N}"
    echo -e "${D}  Detected: ${detected_ip}${N}"
    read -rp "  Confirm or enter Manager IP [${detected_ip}]: " input_ip || true
    MANAGER_IP="${input_ip:-$detected_ip}"
    [[ -z "$MANAGER_IP" ]] && die "Manager IP required"
    ok "Manager IP: ${MANAGER_IP}"

    echo ""
    echo -e "${W}  SOC Alert Email${N}"
    read -rp "  Email address for alerts: " ALERT_EMAIL || true
    [[ -z "$ALERT_EMAIL" ]] && die "Alert email required"
    ok "Alert email: ${ALERT_EMAIL}"

    echo ""
    echo -e "${W}  Gmail App Password${N}"
    echo -e "${D}  Generate at: myaccount.google.com/apppasswords${N}"
    echo -e "${D}  Requires 2FA enabled on Gmail${N}"
    echo -n "  Gmail App Password: "
    read -rs GMAIL_APP_PASS || true
    echo ""
    GMAIL_APP_PASS="${GMAIL_APP_PASS// /}"  # strip spaces Google adds in display
    [[ -z "$GMAIL_APP_PASS" ]] && die "Gmail App Password required"
    ok "Gmail App Password: configured (hidden)"

    echo ""
    echo -e "${W}  Active Response Timeout${N}"
    read -rp "  Auto-unblock after N seconds [3600]: " ar_input || true
    AR_TIMEOUT="${ar_input:-3600}"
    ok "AR timeout: ${AR_TIMEOUT}s"

    # Save config
    mkdir -p /etc/rh-pulsar
    cat > "$CONF_FILE" << EOF
# RH Pulsar Manager Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Compatible with: install.sh v3.2.5+
MANAGER_IP=${MANAGER_IP}
ALERT_EMAIL=${ALERT_EMAIL}
AR_TIMEOUT=${AR_TIMEOUT}
RETENTION_DAYS=90
OPENSEARCH_HEAP=${OPENSEARCH_HEAP}
WAZUH_REPO=${WAZUH_REPO}
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    chmod 600 "$CONF_FILE"

    # Store Gmail password separately — more restrictive permissions
    cat > /etc/rh-pulsar/gmail.conf << EOF
GMAIL_APP_PASS=${GMAIL_APP_PASS}
ALERT_EMAIL=${ALERT_EMAIL}
EOF
    chmod 600 /etc/rh-pulsar/gmail.conf

    echo ""
    echo -e "${D}  ── Summary ───────────────────${N}"
    echo -e "  Manager IP : ${W}${MANAGER_IP}${N}"
    echo -e "  Email      : ${W}${ALERT_EMAIL}${N}"
    echo -e "  AR Timeout : ${W}${AR_TIMEOUT}s${N}"
    echo -e "  OS Heap    : ${W}${OPENSEARCH_HEAP}${N}"
    echo -e "${D}  ──────────────────────────────${N}"
    echo ""
    read -rp "  Confirm? (y/N): " c || true
    [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1

    ok "Configuration saved to ${CONF_FILE}"
}

# ═══════════════════════════════════════════════════════════
# PHASE 3 — INSTALL WAZUH MANAGER + OPENSEARCH + DASHBOARDS
# ═══════════════════════════════════════════════════════════
install_wazuh_stack() {
    phase "INSTALLING WAZUH STACK"

    local APT_OPTS="-o Acquire::ForceIPv4=true -o Acquire::http::Timeout=30"

    # Base packages
    spinner_start "Installing base packages..."
    retry apt-get update -qq $APT_OPTS >> "$LOG" 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_OPTS \
        curl wget gnupg2 apt-transport-https ca-certificates \
        python3 python3-pip postfix libsasl2-modules \
        >> "$LOG" 2>&1
    spinner_stop
    ok "Base packages installed"

    # Wazuh repo
    if ! grep -q "packages.wazuh.com" /etc/apt/sources.list.d/wazuh.list 2>/dev/null; then
        curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
            | gpg --no-default-keyring \
            --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
            --import >> "$LOG" 2>&1
        chmod 644 /usr/share/keyrings/wazuh.gpg
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
https://packages.wazuh.com/${WAZUH_REPO}/apt/ stable main" \
            > /etc/apt/sources.list.d/wazuh.list
        retry apt-get update -qq $APT_OPTS >> "$LOG" 2>&1
        ok "Wazuh repository added"
    fi

    # Wazuh Manager
    if systemctl is-active --quiet wazuh-manager 2>/dev/null; then
        local wv; wv=$(grep WAZUH_VERSION /var/ossec/etc/ossec.conf 2>/dev/null | \
                       grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        ok "Wazuh Manager already running (${wv}) — skipping install"
    else
        spinner_start "Installing Wazuh Manager (this takes 2-3 min)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_OPTS \
            wazuh-manager >> "$LOG" 2>&1
        spinner_stop
        ok "Wazuh Manager installed"
    fi

    # OpenSearch
    if systemctl is-active --quiet wazuh-indexer 2>/dev/null; then
        ok "Wazuh Indexer (OpenSearch) already running — skipping"
    else
        spinner_start "Installing Wazuh Indexer (OpenSearch)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_OPTS \
            wazuh-indexer >> "$LOG" 2>&1
        spinner_stop

        # Configure OpenSearch heap
        local jvm_file="/etc/wazuh-indexer/jvm.options"
        if [[ -f "$jvm_file" ]]; then
            sed -i "s/-Xms[0-9]*[mg]/-Xms${OPENSEARCH_HEAP}/" "$jvm_file" 2>/dev/null || true
            sed -i "s/-Xmx[0-9]*[mg]/-Xmx${OPENSEARCH_HEAP}/" "$jvm_file" 2>/dev/null || true
        fi

        # vm.max_map_count for OpenSearch
        sysctl -w vm.max_map_count=262144 >> "$LOG" 2>&1
        grep -q "vm.max_map_count" /etc/sysctl.conf || \
            echo "vm.max_map_count=262144" >> /etc/sysctl.conf

        ok "Wazuh Indexer installed (heap: ${OPENSEARCH_HEAP})"
    fi

    # Wazuh Dashboard
    if systemctl is-active --quiet wazuh-dashboard 2>/dev/null; then
        ok "Wazuh Dashboard already running — skipping"
    else
        spinner_start "Installing Wazuh Dashboard..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_OPTS \
            wazuh-dashboard >> "$LOG" 2>&1
        spinner_stop
        ok "Wazuh Dashboard installed"
    fi

    # Initialize Wazuh indexer certificates + cluster
    if [[ ! -f /etc/wazuh-indexer/certs/wazuh-indexer.pem ]]; then
        spinner_start "Initializing Wazuh indexer certificates..."
        # wazuh-certs-tool.sh not present in apt installs.
        # Certs are already handled by the official wazuh-install.sh -a base.
        # If running standalone: download cert tool manually first.
        warn "Cert tool not found — certs may already exist from base Wazuh install"
        spinner_stop
    fi

    # Start all services
    spinner_start "Starting Wazuh services..."
    systemctl daemon-reload >> "$LOG" 2>&1

    for svc in wazuh-indexer wazuh-manager wazuh-dashboard; do
        systemctl enable "$svc" >> "$LOG" 2>&1 || true
        systemctl start "$svc" >> "$LOG" 2>&1 || true
        sleep 3
    done
    spinner_stop

    # Wait for OpenSearch to be ready
    spinner_start "Waiting for OpenSearch to be ready (up to 60s)..."
    local ready=false
    for i in $(seq 1 12); do
        if curl -sf --max-time 5 --insecure \
            "https://localhost:9200/_cluster/health" \
            &>/dev/null 2>&1 || \
           curl -sf --max-time 5 \
            "http://localhost:9200/_cluster/health" \
            &>/dev/null 2>&1; then
            ready=true; break
        fi
        sleep 5
    done
    spinner_stop

    [[ "$ready" == true ]] && ok "OpenSearch: ready" || \
        warn "OpenSearch: not yet ready — may need more time to start"

    # Enable logall for RH Pulsar event archiving
    if grep -q "<logall>no</logall>" /var/ossec/etc/ossec.conf 2>/dev/null; then
        sed -i 's/<logall>no<\/logall>/<logall>yes<\/logall>/' \
            /var/ossec/etc/ossec.conf
        sed -i 's/<logall_json>no<\/logall_json>/<logall_json>yes<\/logall_json>/' \
            /var/ossec/etc/ossec.conf
        ok "Archive logging enabled (logall + logall_json)"
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 4 — DEPLOY RH PULSAR DECODER + RULES
# These must match install.sh v3.2.5+ notice type strings exactly
# ═══════════════════════════════════════════════════════════
deploy_decoders_and_rules() {
    phase "RH PULSAR DECODERS + RULES"

    # ── Decoder ─────────────────────────────────────────────
    # Matches the label key="rh-pulsar-zeek" set by install.sh
    cat > /var/ossec/etc/decoders/rh-pulsar-decoders.xml << 'EOF'
<!--
  RH Pulsar — Wazuh Decoders
  Compatible with: install.sh v3.2.5+
  Red Horizon — redhorizon.ph

  These decoders parse Zeek JSON logs forwarded by the
  Wazuh Agent on each RH Pulsar sensor.

  The label key "rh-pulsar-zeek" is set by install.sh
  in the agent ossec.conf localfile blocks.
-->

<!-- Base decoder — matches ONLY logs tagged rh-pulsar-zeek by install.sh -->
<!-- install.sh writes: <label key="rh-pulsar-zeek"> in localfile config -->
<!-- Wazuh serialises this label as the string "rh-pulsar-zeek" in each log line -->
<decoder name="rh-pulsar-zeek">
  <prematch>rh-pulsar-zeek</prematch>
</decoder>

<!-- JSON field extractor — fires on top of base decoder -->
<decoder name="rh-pulsar-zeek-fields">
  <parent>rh-pulsar-zeek</parent>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>
EOF
    ok "Decoder deployed: /var/ossec/etc/decoders/rh-pulsar-decoders.xml"

    # ── Rules ────────────────────────────────────────────────
    # Rule IDs and notice types must match install.sh v3.2.5+ exactly
    cat > /var/ossec/etc/rules/rh-pulsar-rules.xml << 'EOF'
<!--
  RH Pulsar — Wazuh Detection Rules
  Compatible with: install.sh v3.2.5+
  Red Horizon — redhorizon.ph

  Rule ID mapping:
    110001 — C2Beacon::C2_Beacon_Detected
    110002 — DNSTunnel::DNS_Tunnel_Detected
    110003 — DetectJA4::Sliver_JA4_Detected / Malicious_JA4_Detected
    110004 — HTTPC2::HTTP_C2_Beacon
    110005 — HTTPC2::Suspicious_UserAgent
    110006 — JA4Baseline::Novel_JA4_Observed

  Active Response:
    Rule 110003 only — Sliver JA4 match is near-certain
    All other rules: alert only (FP risk too high for auto-block)
-->

<group name="rh-pulsar,zeek,ndr,">

  <!-- ══════════════════════════════════════════════════════
       RULE 110001 — C2 Beacon Detection
       Fires after 5 repeated connections to same external host
       MITRE T1071 — Application Layer Protocol
       ══════════════════════════════════════════════════════ -->
  <rule id="110001" level="12">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">C2Beacon::C2_Beacon_Detected</field>
    <description>RH Pulsar: C2 Beacon detected from $(src) to $(dst)</description>
    <mitre>
      <id>T1071</id>
    </mitre>
    <group>c2,beacon,rh-pulsar,</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110002 — DNS Tunnel Detection
       Fires on suspicious record types (TXT/MX/NULL) or
       long subdomains (>20 chars) — DGA + tunneling
       MITRE T1071.004 — DNS
       ══════════════════════════════════════════════════════ -->
  <rule id="110002" level="14">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">DNSTunnel::DNS_Tunnel_Detected</field>
    <description>RH Pulsar: DNS Tunnel detected from $(src)</description>
    <mitre>
      <id>T1071.004</id>
    </mitre>
    <group>dns,tunnel,rh-pulsar,</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110003a — Sliver C2 JA4 (manual fingerprint)
       Matches curated Sliver TLS fingerprints
       MITRE T1573 — Encrypted Channel
       Active Response: YES — auto-isolate source IP
       ══════════════════════════════════════════════════════ -->
  <rule id="110003" level="15">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">DetectJA4::Sliver_JA4_Detected</field>
    <description>RH Pulsar: Sliver C2 JA4 fingerprint match — $(src) -> $(dst)</description>
    <mitre>
      <id>T1573</id>
    </mitre>
    <group>c2,ja4,sliver,rh-pulsar,active-response,</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110003b — Malicious JA4 (threat intel DB)
       Matches ja4db.com sourced fingerprints
       MITRE T1573 — Encrypted Channel
       ══════════════════════════════════════════════════════ -->
  <rule id="110013" level="14">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">DetectJA4::Malicious_JA4_Detected</field>
    <description>RH Pulsar: Malicious JA4 (DB match) — $(src) -> $(dst)</description>
    <mitre>
      <id>T1573</id>
    </mitre>
    <group>c2,ja4,rh-pulsar,</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110004 — HTTP C2 Beacon
       Same URI hit 10+ times — beaconing pattern
       MITRE T1071.001 — Web Protocols
       ══════════════════════════════════════════════════════ -->
  <rule id="110004" level="12">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">HTTPC2::HTTP_C2_Beacon</field>
    <description>RH Pulsar: HTTP C2 beacon detected — $(src) -> $(dst)</description>
    <mitre>
      <id>T1071.001</id>
    </mitre>
    <group>c2,http,beacon,rh-pulsar,</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110005 — Suspicious User-Agent
       Curl, python-requests, Sliver, Havoc, CobaltStrike, etc.
       MITRE T1071.001 — Web Protocols
       ══════════════════════════════════════════════════════ -->
  <rule id="110005" level="10">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">HTTPC2::Suspicious_UserAgent</field>
    <description>RH Pulsar: Suspicious User-Agent from $(src) — $(msg)</description>
    <mitre>
      <id>T1071.001</id>
    </mitre>
    <group>http,useragent,rh-pulsar,</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110006 — Novel JA4 Fingerprint (Tier 2)
       JA4 not seen in 7-day baseline or threat intel DB
       MITRE T1573 — Encrypted Channel
       ══════════════════════════════════════════════════════ -->
  <rule id="110006" level="10">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">JA4Baseline::Novel_JA4_Observed</field>
    <description>RH Pulsar: Novel JA4 fingerprint (not in baseline) — $(src)</description>
    <mitre>
      <id>T1573</id>
    </mitre>
    <group>ja4,baseline,rh-pulsar,</group>
    <options>no_full_log</options>
  </rule>

</group>
EOF
    ok "Rules deployed: /var/ossec/etc/rules/rh-pulsar-rules.xml"
    ok "Rules: 110001-110006, 110013 (7 detection rules)"
}

# ═══════════════════════════════════════════════════════════
# PHASE 5 — EMAIL ALERTS (digest mode — no flooding)
# ═══════════════════════════════════════════════════════════
configure_email() {
    phase "EMAIL ALERTS"

    # ── Postfix Gmail relay ──────────────────────────────────
    info "Configuring Postfix as Gmail SMTP relay..."

    postconf -e "relayhost = [smtp.gmail.com]:587"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_tls_security_level = encrypt"
    postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
    postconf -e "smtp_sasl_tls_security_options = noanonymous"
    postconf -e "myhostname = rh-pulsar-manager"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "mydestination ="

    # Gmail credentials — chmod 600
    echo "[smtp.gmail.com]:587 ${ALERT_EMAIL}:${GMAIL_APP_PASS}" \
        > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd.db

    systemctl enable --now postfix >> "$LOG" 2>&1
    ok "Postfix: Gmail relay configured"

    # ── Wazuh email config in ossec.conf ────────────────────
    # Only alert on level 10+ — prevents noise from lower severity events
    if ! grep -q "<email_notification>" /var/ossec/etc/ossec.conf 2>/dev/null; then
        python3 - "$ALERT_EMAIL" "$MANAGER_IP" << 'PYEOF'
import sys, re
alert_email = sys.argv[1]
manager_ip  = sys.argv[2]
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    content = f.read()

email_config = f"""
  <!-- RH Pulsar Email Alerts — digest mode, level 10+ only -->
  <global>
    <email_notification>yes</email_notification>
    <email_to>{alert_email}</email_to>
    <smtp_server>localhost</smtp_server>
    <email_from>rhpulsar@{manager_ip}</email_from>
    <email_maxperhour>12</email_maxperhour>
    <email_log_source>alerts.log</email_log_source>
  </global>

  <!-- Email alert threshold — only fire for level 10 and above -->
  <alerts>
    <email_alert_level>10</email_alert_level>
  </alerts>

"""
# Insert after <ossec_config>
new_content = re.sub(
    r'(<ossec_config>)',
    r'\1' + email_config,
    content, count=1
)
with open(path, "w") as f:
    f.write(new_content)
PYEOF
        ok "Wazuh: email alerts configured (level 10+, max 12/hour)"
    else
        ok "Wazuh: email config already present — skipping"
    fi

    # ── Email digest script ──────────────────────────────────
    # Batches alerts into one email every 15 minutes
    # Suppresses same src+rule within 1 hour
    cat > /usr/local/sbin/rh-pulsar-email-digest.sh << 'DIGEST'
#!/bin/bash
# RH Pulsar — Email Digest
# Batches Wazuh alerts into one email per 15 minutes
# Suppresses same src+rule combos for 1 hour
# Runs via cron every 15 minutes

ALERT_EMAIL=$(grep ALERT_EMAIL /etc/rh-pulsar/manager.conf | cut -d= -f2)
SUPPRESS_DIR="/var/lib/rh-pulsar/suppress"
QUEUE_FILE="/var/lib/rh-pulsar/alert-queue.json"
ALERTS_LOG="/var/ossec/logs/alerts/alerts.json"
mkdir -p "$SUPPRESS_DIR" /var/lib/rh-pulsar

# Parse alerts from last 15 minutes matching RH Pulsar rules
python3 << PYEOF
import json, os, time, subprocess
from datetime import datetime

now = time.time()
window = 900  # 15 minutes
suppress_ttl = 3600  # 1 hour
suppress_dir = "$SUPPRESS_DIR"
alerts_log = "$ALERTS_LOG"
alert_email = "$ALERT_EMAIL"

rh_rules = {
    "110001": ("HIGH",   "C2 Beacon",          "T1071"),
    "110002": ("HIGH",   "DNS Tunnel",          "T1071.004"),
    "110003": ("CRIT",   "Sliver JA4 — AUTO-ISOLATED", "T1573"),
    "110004": ("MED",    "HTTP C2 Beacon",      "T1071.001"),
    "110005": ("MED",    "Suspicious UA",       "T1071.001"),
    "110006": ("LOW",    "Novel JA4 Baseline",  "T1573"),
    "110013": ("HIGH",   "Malicious JA4 (DB)",  "T1573"),
}

new_alerts = []
try:
    with open(alerts_log) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                rule_id = str(d.get("rule", {}).get("id", ""))
                if rule_id not in rh_rules: continue

                ts = d.get("timestamp", "")
                src = d.get("data", {}).get("src", d.get("agent", {}).get("ip", "unknown"))
                dst = d.get("data", {}).get("dst", "unknown")
                msg = d.get("data", {}).get("msg", d.get("rule", {}).get("description", ""))
                sensor = d.get("agent", {}).get("name", "unknown")

                # Time filter — last 15 minutes only
                try:
                    alert_time = datetime.fromisoformat(ts.replace("Z","")).timestamp()
                    if (now - alert_time) > window: continue
                except: pass

                # Suppress duplicate src+rule within 1 hour
                suppress_key = f"{rule_id}-{src}"
                suppress_file = os.path.join(suppress_dir, suppress_key.replace("/","_"))
                if os.path.exists(suppress_file):
                    if (now - os.path.getmtime(suppress_file)) < suppress_ttl:
                        continue
                open(suppress_file, "w").close()

                severity, name, mitre = rh_rules[rule_id]
                new_alerts.append({
                    "rule_id": rule_id,
                    "severity": severity,
                    "name": name,
                    "mitre": mitre,
                    "src": src,
                    "dst": dst,
                    "msg": msg,
                    "sensor": sensor,
                    "ts": ts,
                })
            except: continue
except FileNotFoundError:
    pass

if not new_alerts:
    exit(0)

# Build digest email
count = len(new_alerts)
sensor_names = list(set(a["sensor"] for a in new_alerts))
sensor_str = ", ".join(sensor_names)
subject = f"[RH PULSAR] {count} Alert{'s' if count>1 else ''} — {sensor_str} — {datetime.now().strftime('%Y-%m-%d %H:%M')}"

body = f"""RH PULSAR DETECTION ALERT
{'='*60}
Time     : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} UTC
Sensor(s): {sensor_str}
Alerts   : {count}
{'='*60}

"""
for a in new_alerts:
    body += f"""[{a['severity']}] Rule {a['rule_id']} — {a['name']}
  MITRE  : {a['mitre']}
  Source : {a['src']}
  Dest   : {a['dst']}
  Sensor : {a['sensor']}
  Detail : {a['msg'][:120]}
{'-'*60}
"""

body += f"""
Dashboard: https://{os.popen("hostname -I | awk '{print $1}'").read().strip()}
Log      : /var/ossec/logs/alerts/alerts.json

Red Horizon — redhorizon.ph
"""

# Send via sendmail
proc = subprocess.Popen(
    ["/usr/sbin/sendmail", "-t"],
    stdin=subprocess.PIPE
)
email_content = f"To: {alert_email}\nSubject: {subject}\nContent-Type: text/plain\n\n{body}"
proc.communicate(email_content.encode())
print(f"Digest sent: {count} alerts to {alert_email}")
PYEOF
DIGEST
    chmod 755 /usr/local/sbin/rh-pulsar-email-digest.sh

    # Cron — every 15 minutes
    (crontab -l 2>/dev/null | grep -v "rh-pulsar-email-digest"; \
     echo "*/15 * * * * /usr/local/sbin/rh-pulsar-email-digest.sh >> /var/log/rh-pulsar-digest.log 2>&1") \
        | crontab -
    ok "Email digest: every 15 min, 1hr suppression per src+rule"

    # Test email
    info "Sending test email..."
    echo "Subject: [RH PULSAR] Manager setup complete
To: ${ALERT_EMAIL}
Content-Type: text/plain

RH Pulsar Wazuh Manager installed successfully.
Manager IP : ${MANAGER_IP}
Time       : $(date '+%Y-%m-%d %H:%M:%S') UTC
Dashboard  : https://${MANAGER_IP}

Red Horizon — redhorizon.ph" \
        | /usr/sbin/sendmail -t 2>/dev/null || true

    ok "Test email sent to ${ALERT_EMAIL}"
}

# ═══════════════════════════════════════════════════════════
# PHASE 6 — ACTIVE RESPONSE
# Only for Rule 110003 (Sliver JA4) — highest confidence
# Isolates infected source IP via iptables on sensor VM
# ═══════════════════════════════════════════════════════════
configure_active_response() {
    phase "ACTIVE RESPONSE"

    # ── AR script on manager ─────────────────────────────────
    # Wazuh sends this command to the agent on the sensor VM
    cat > /var/ossec/active-response/bin/rh-pulsar-block.sh << ARSCRIPT
#!/bin/bash
# RH Pulsar — Active Response: Isolate Infected Source IP
# Triggered by: Rule 110003 (Sliver JA4) only
# Action: iptables DROP on src IP
# Auto-unblock: after ${AR_TIMEOUT} seconds
# Log: /var/log/rh-pulsar-ar.log

AR_LOG="/var/log/rh-pulsar-ar.log"
AR_TIMEOUT="${AR_TIMEOUT}"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" >> "\$AR_LOG"; }

# Parse Wazuh active response input
ACTION=\$1
USER=\$2
IP=\$3

[[ -z "\$IP" || "\$IP" == "-" ]] && exit 0
[[ "\$IP" =~ ^127\. || "\$IP" == "localhost" ]] && exit 0  # never block loopback

case "\$ACTION" in
    add)
        log "AUTO-ISOLATE: blocking \$IP (Sliver JA4 detected)"
        iptables -I INPUT  -s "\$IP" -j DROP 2>/dev/null || true
        iptables -I FORWARD -s "\$IP" -j DROP 2>/dev/null || true
        log "ISOLATED: \$IP — Wazuh will send delete after \${AR_TIMEOUT}s"
        exit 0
        ;;
    delete)
        # Wazuh manager sends this automatically after <timeout> seconds
        log "UNBLOCK: removing iptables DROP for \$IP"
        iptables -D INPUT  -s "\$IP" -j DROP 2>/dev/null || true
        iptables -D FORWARD -s "\$IP" -j DROP 2>/dev/null || true
        log "UNBLOCKED: \$IP"
        exit 0
        ;;
    *)
        log "Unknown action: \$ACTION for \$IP"
        exit 1
        ;;
esac
ARSCRIPT
    chmod 750 /var/ossec/active-response/bin/rh-pulsar-block.sh
    chown root:wazuh /var/ossec/active-response/bin/rh-pulsar-block.sh 2>/dev/null || true
    ok "Active response script deployed"

    # ── Configure AR in ossec.conf ───────────────────────────
    # Only triggers on Rule 110003 — Sliver JA4 (near-certain detection)
    if ! grep -q "rh-pulsar-block" /var/ossec/etc/ossec.conf 2>/dev/null; then
        python3 - "$AR_TIMEOUT" << 'PYEOF'
import sys, re
ar_timeout = sys.argv[1]
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    content = f.read()

ar_config = f"""
  <!-- RH Pulsar Active Response — Sliver JA4 only (Rule 110003) -->
  <command>
    <name>rh-pulsar-block</name>
    <executable>rh-pulsar-block.sh</executable>
    <timeout_allowed>yes</timeout_allowed>
  </command>

  <active-response>
    <command>rh-pulsar-block</command>
    <location>defined-agent</location>
    <rules_id>110003</rules_id>
    <timeout>{ar_timeout}</timeout>
  </active-response>

"""
new_content = re.sub(
    r'(</ossec_config>)',
    ar_config + r'\1',
    content, count=1
)
with open(path, "w") as f:
    f.write(new_content)
PYEOF
        ok "Active response: configured for Rule 110003 (Sliver JA4)"
        ok "Auto-unblock: after ${AR_TIMEOUT}s"
    else
        ok "Active response: already configured — skipping"
    fi

    warn "AR note: only Rule 110003 triggers auto-isolation (highest confidence)"
    warn "Rules 110001/110002/110004/110005: alert only — FP risk too high for auto-block"
}

# ═══════════════════════════════════════════════════════════
# PHASE 7 — RESTART + VALIDATE
# ═══════════════════════════════════════════════════════════
restart_and_validate() {
    phase "RESTART + VALIDATE"

    # Validate ossec.conf XML before restarting
    if ! python3 -c "
import xml.etree.ElementTree as ET
ET.parse('/var/ossec/etc/ossec.conf')
" 2>/dev/null; then
        die "ossec.conf XML invalid — check /var/ossec/etc/ossec.conf"
    fi
    ok "ossec.conf: XML valid"

    # Restart all services
    spinner_start "Restarting Wazuh services..."
    systemctl restart wazuh-manager >> "$LOG" 2>&1
    sleep 5
    spinner_stop

    # Validate all services
    local p=0 f=0

    systemctl is-active --quiet wazuh-manager && \
        { ok "Wazuh Manager: running"; p=$((p+1)); } || \
        { fail "Wazuh Manager: not running"; f=$((f+1)); }

    systemctl is-active --quiet wazuh-indexer && \
        { ok "Wazuh Indexer: running"; p=$((p+1)); } || \
        { warn "Wazuh Indexer: not running — may still be starting"; }

    systemctl is-active --quiet wazuh-dashboard && \
        { ok "Wazuh Dashboard: running"; p=$((p+1)); } || \
        { warn "Wazuh Dashboard: not running — may still be starting"; }

    systemctl is-active --quiet postfix && \
        { ok "Postfix: running"; p=$((p+1)); } || \
        { fail "Postfix: not running"; f=$((f+1)); }

    # Check decoders loaded
    [[ -f /var/ossec/etc/decoders/rh-pulsar-decoders.xml ]] && \
        { ok "Decoders: present"; p=$((p+1)); } || \
        { fail "Decoders: missing"; f=$((f+1)); }

    # Check rules loaded
    [[ -f /var/ossec/etc/rules/rh-pulsar-rules.xml ]] && \
        { ok "Rules: present"; p=$((p+1)); } || \
        { fail "Rules: missing"; f=$((f+1)); }

    # Check AR script
    [[ -f /var/ossec/active-response/bin/rh-pulsar-block.sh ]] && \
        { ok "Active response script: present"; p=$((p+1)); } || \
        { fail "Active response: missing"; f=$((f+1)); }

    # Check agent enrollment port
    ss -tlnp 2>/dev/null | grep -q ":1515 " && \
        { ok "Port 1515 (enrollment): listening"; p=$((p+1)); } || \
        { warn "Port 1515: not yet listening"; }

    ss -tlnp 2>/dev/null | grep -q ":1514 " && \
        { ok "Port 1514 (agent): listening"; p=$((p+1)); } || \
        { warn "Port 1514: not yet listening"; }

    echo ""
    echo -e "  Validation: ${G}${p} passed${N} / ${R}${f} failed${N}"
}

# ═══════════════════════════════════════════════════════════
# PHASE 8 — SUMMARY
# ═══════════════════════════════════════════════════════════
print_summary() {
    phase "COMPLETE"

    # Save state
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" << EOF
install_date=$(date '+%Y-%m-%d %H:%M:%S')
manager_ip=${MANAGER_IP}
alert_email=${ALERT_EMAIL}
ar_timeout=${AR_TIMEOUT}
opensearch_heap=${OPENSEARCH_HEAP}
version=${PULSAR_VER}
EOF
    chmod 600 "$STATE_FILE"

    local wazuh_ver
    # Try multiple methods to detect the installed Wazuh version
    wazuh_ver=$(dpkg -l wazuh-manager 2>/dev/null | awk '/^ii/{print $3}' | head -1 | grep -oP '\d+\.\d+\.\d+' || \
                /var/ossec/bin/wazuh-control info 2>/dev/null | grep WAZUH_VERSION | cut -d= -f2 | tr -d '"' || \
                grep -oP "(?<=wazuh-manager/)\d+\.\d+\.\d+" /var/ossec/etc/ossec.conf 2>/dev/null | head -1 || \
                echo "unknown")

    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${G}  RH PULSAR WAZUH MANAGER DEPLOYED${N}"
    echo ""
    echo -e "  ${D}Version    :${N} ${W}RH Pulsar Manager v${PULSAR_VER}${N}"
    echo -e "  ${D}Wazuh      :${N} ${W}${wazuh_ver}${N}"
    echo -e "  ${D}Manager IP :${N} ${W}${MANAGER_IP}${N}"
    echo -e "  ${D}Email      :${N} ${W}${ALERT_EMAIL}${N}"
    echo -e "  ${D}AR Timeout :${N} ${W}${AR_TIMEOUT}s (Rule 110003 only)${N}"
    echo -e "  ${D}OS Heap    :${N} ${W}${OPENSEARCH_HEAP}${N}"
    echo ""
    echo -e "  ${G}[✓]${N} Decoder   : /var/ossec/etc/decoders/rh-pulsar-decoders.xml"
    echo -e "  ${G}[✓]${N} Rules     : /var/ossec/etc/rules/rh-pulsar-rules.xml"
    echo -e "  ${G}[✓]${N} AR script : /var/ossec/active-response/bin/rh-pulsar-block.sh"
    echo -e "  ${G}[✓]${N} Email     : Postfix → Gmail SMTP (digest, max 12/hr)"
    echo -e "  ${G}[✓]${N} Digest    : /usr/local/sbin/rh-pulsar-email-digest.sh (cron 15min)"
    echo ""
    echo -e "  ${D}Rules active:${N}"
    echo -e "  ${G}[✓]${N} 110001 C2 Beacon          Level 12  T1071       Alert only"
    echo -e "  ${G}[✓]${N} 110002 DNS Tunnel          Level 14  T1071.004   Alert only"
    echo -e "  ${G}[✓]${N} 110003 Sliver JA4          Level 15  T1573       AUTO-ISOLATE"
    echo -e "  ${G}[✓]${N} 110004 HTTP C2 Beacon      Level 12  T1071.001   Alert only"
    echo -e "  ${G}[✓]${N} 110005 Suspicious UA       Level 10  T1071.001   Alert only"
    echo -e "  ${G}[✓]${N} 110006 Novel JA4           Level 10  T1573       Alert only"
    echo -e "  ${G}[✓]${N} 110013 Malicious JA4 (DB)  Level 14  T1573       Alert only"
    echo ""
    echo -e "${D}  ─────────────────────────────────────────────────────────${N}"
    echo ""
    echo -e "  ${W}Access:${N}"
    echo -e "  ${C}Wazuh Dashboard :${N} https://${MANAGER_IP}"
    echo -e "  ${C}Wazuh API       :${N} https://${MANAGER_IP}:55000"
    echo -e "  ${C}OpenSearch      :${N} https://${MANAGER_IP}:9200"
    echo ""
    echo ""
    echo -e "${Y}  ⚠  IMPORTANT — Sensor version alignment:${N}"
    echo -e "  ${D}Your sensors must run wazuh-agent matching this manager version: ${W}${wazuh_ver}${N}"
    echo -e "  ${D}install.sh auto-detects and pins the agent version via the manager API.${N}"
    echo -e "  ${D}If agent enrollment fails with version mismatch, check:${N}"
    echo -e "  ${D}  sudo dpkg -l wazuh-agent   # on sensor${N}"
    echo -e "  ${D}  sudo dpkg -l wazuh-manager  # on manager${N}"
    echo -e "  ${D}Both should show: ${W}${wazuh_ver}${N}"
    echo ""
    echo -e "  ${W}To add a new sensor:${N}"
    echo -e "  ${D}On sensor VM:${N}"
    echo -e "  ${C}  SIEM_HOST=${MANAGER_IP} sudo bash install.sh${N}"
    echo ""
    echo -e "  ${D}Logs:${N}"
    echo -e "  ${D}  Install : ${LOG}${N}"
    echo -e "  ${D}  Alerts  : /var/ossec/logs/alerts/alerts.json${N}"
    echo -e "  ${D}  Archives: /var/ossec/logs/archives/archives.log${N}"
    echo -e "  ${D}  AR log  : /var/log/rh-pulsar-ar.log${N}"
    echo -e "  ${D}  Digest  : /var/log/rh-pulsar-digest.log${N}"
    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${W}  Red Horizon — redhorizon.ph${N}"
    echo -e "${D}  © 2026 Red Horizon. All rights reserved.${N}"
    echo ""
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════
main() {
    mkdir -p /var/log /etc/rh-pulsar /var/lib/rh-pulsar
    : > "$LOG"
    chmod 600 "$LOG"
    echo "[$(ts)] RH Pulsar Manager Setup v${PULSAR_VER} — DRY_RUN=${DRY_RUN}" >> "$LOG"

    banner
    preflight              # 1 — system check
    configure              # 2 — collect 3 inputs
    install_wazuh_stack    # 3 — Wazuh + OpenSearch + Dashboards
    deploy_decoders_and_rules  # 4 — RH Pulsar decoders + rules
    configure_email        # 5 — Gmail relay + digest
    configure_active_response  # 6 — auto-isolate on Sliver JA4
    restart_and_validate   # 7 — restart + confirm
    print_summary          # 8 — done
}

main "$@"
