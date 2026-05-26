#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Wazuh Manager Setup
#  Version: 1.1.0
#  Red Horizon Security — redhorizon.ph
#  © 2026 Red Horizon Security. All rights reserved.
#
#  Fresh Ubuntu 24.04 — installs full Wazuh stack +
#  RH Pulsar decoders, rules, email, active response.
#
#  Compatible with: install.sh v3.2.5+
#
#  Usage:
#    sudo bash setup-wazuh-manager.sh
#    sudo bash setup-wazuh-manager.sh --dry-run
# ═══════════════════════════════════════════════════════════

set -uo pipefail

# ── Args ────────────────────────────────────────────────────
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "${1:-}" == "--help"    ]] && { sed -n '2,15p' "$0"; exit 0; }

# ── Colors ──────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' C='\033[0;36m' N='\033[0m'

# ── Versions ────────────────────────────────────────────────
PULSAR_MGR_VER="1.1.3"
WAZUH_REPO="4.x"

# ── State ───────────────────────────────────────────────────
LOG="/var/log/rh-pulsar-manager-install.log"
CONF_FILE="/etc/rh-pulsar/manager.conf"
PASS=0; WARN=0; FAIL=0
MANAGER_IP=""; ALERT_EMAIL=""; GMAIL_APP_PASS=""
AR_TIMEOUT=3600; OPENSEARCH_HEAP=""
SPINNER_PID=""; CURRENT_PHASE="init"
TOTAL_STEPS=8; CURRENT_STEP=0

# ── Logging ─────────────────────────────────────────────────
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
ok()   { echo -e "${G}  [✓]${N} $1"; echo "[$(ts)] OK   $1" >> "$LOG"; PASS=$(( PASS + 1 )) || true; }
warn() { echo -e "${Y}  [!]${N} $1"; echo "[$(ts)] WARN $1" >> "$LOG"; WARN=$(( WARN + 1 )) || true; }
fail() { echo -e "${R}  [✗]${N} $1"; echo "[$(ts)] FAIL $1" >> "$LOG"; FAIL=$(( FAIL + 1 )) || true; }
info() { echo -e "${D}  [→]${N} $1"; echo "[$(ts)] INFO $1" >> "$LOG"; }
die()  { spinner_stop; echo -e "\n${R}  FATAL: $1${N}\n"; echo "[$(ts)] FATAL $1" >> "$LOG"; exit 1; }
has()  { command -v "$1" &>/dev/null; }

# ── Spinner ─────────────────────────────────────────────────
spinner_start() {
    local msg="${1:-}" frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    ( local i=0
      while true; do
          printf "\r  ${C}%s${N} %s " "${frames[$(( i % 10 ))]}" "$msg"
          i=$(( i + 1 )); sleep 0.08
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
trap 'spinner_stop 2>/dev/null || true' EXIT INT TERM

# ── Progress bar ────────────────────────────────────────────
phase() {
    spinner_stop
    CURRENT_STEP=$(( CURRENT_STEP + 1 )) || true
    CURRENT_PHASE="$1"
    local pct f e bar i
    pct=$(( CURRENT_STEP * 100 / TOTAL_STEPS )) || true
    f=$(( pct / 5 ))  || true
    e=$(( 20 - f ))   || true
    bar=""; i=0
    while [[ $i -lt $f ]]; do bar+="█"; i=$(( i + 1 )); done
    i=0
    while [[ $i -lt $e ]]; do bar+="░"; i=$(( i + 1 )); done
    echo ""
    echo -e "${R}  ── PHASE ${CURRENT_STEP}/${TOTAL_STEPS} — $1${N}"
    echo -e "  ${D}[${G}${bar}${D}]${N} ${W}${pct}%${N}"
    echo ""
}

# ── Retry ───────────────────────────────────────────────────
retry() {
    local n=0 max=3 delay=3
    until "$@" >> "$LOG" 2>&1; do
        n=$(( n + 1 )) || true
        [[ $n -ge $max ]] && return 1
        sleep $delay
        delay=$(( delay * 2 )) || true
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
    echo -e "${W}  Wazuh Manager Setup — v${PULSAR_MGR_VER}${N}"
    echo -e "${D}  Red Horizon Security — redhorizon.ph${N}"
    [[ "$DRY_RUN" == true ]] && echo -e "\n${C}  [ DRY RUN ]${N}"
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

    local os_id os_ver
    os_id=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
    os_ver=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "0")
    case "${os_id}:${os_ver}" in
        ubuntu:24.04) ok "OS: Ubuntu 24.04 LTS" ;;
        ubuntu:22.04) warn "OS: Ubuntu 22.04 — supported" ;;
        *) warn "OS: ${os_id} ${os_ver} — untested, proceeding" ;;
    esac

    fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && die "APT locked"
    ok "APT: free"

    local cpu ram_kb ram_gb disk
    cpu=$(nproc)
    ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    ram_gb=$(awk '/MemTotal/{printf "%.1f",$2/1024/1024}' /proc/meminfo)
    disk=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')

    [[ $cpu    -ge 4       ]] && ok "CPU: ${cpu} vCPU"      || warn "CPU: ${cpu} — 4+ recommended"
    [[ $ram_kb -ge 8388608 ]] && ok "RAM: ${ram_gb}GB"      || warn "RAM: ${ram_gb}GB — 8GB recommended"
    [[ $disk   -ge 50      ]] && ok "Disk: ${disk}GB free"  || warn "Disk: ${disk}GB — 50GB recommended"

    # Auto-size heap — half RAM, max 31GB
    local heap_mb
    heap_mb=$(( ram_kb / 1024 / 2 )) || true
    [[ $heap_mb -gt 31744 ]] && heap_mb=31744 || true
    OPENSEARCH_HEAP="${heap_mb}m"
    ok "OpenSearch heap: ${OPENSEARCH_HEAP}"

    curl -sf --connect-timeout 5 --max-time 8 https://packages.wazuh.com > /dev/null 2>&1 && \
        ok "Internet: reachable" || warn "Internet: slow — install may take longer"

    echo ""
    echo -e "  ${G}${PASS} passed${N}  ${Y}${WARN} warnings${N}  ${R}${FAIL} failed${N}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${G}  ✓ Ready — run: sudo bash setup-wazuh-manager.sh${N}"
        echo ""; exit 0
    fi

    read -rp "  Continue? (Y/n): " c || true
    c="${c:-Y}"
    [[ "$c" != "y" && "$c" != "Y" ]] && exit 1
}

# ═══════════════════════════════════════════════════════════
# PHASE 2 — CONFIGURATION (3 inputs only)
# ═══════════════════════════════════════════════════════════
configure() {
    phase "CONFIGURATION"

    # Auto-detect Manager IP
    local detected_ip
    detected_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | \
                  grep -v "^127\." | head -1 || echo "")

    echo -e "${W}  1. Manager IP${N}"
    echo -e "${D}     Auto-detected: ${detected_ip}${N}"
    read -rp "     Confirm or enter IP [${detected_ip}]: " input_ip || true
    MANAGER_IP="${input_ip:-$detected_ip}"
    [[ -z "$MANAGER_IP" ]] && die "Manager IP required"
    ok "Manager IP: ${MANAGER_IP}"

    echo ""
    echo -e "${W}  2. SOC Alert Email${N}"
    read -rp "     Email: " ALERT_EMAIL || true
    [[ -z "$ALERT_EMAIL" ]] && die "Email required"
    ok "Email: ${ALERT_EMAIL}"

    echo ""
    echo -e "${W}  3. Gmail App Password${N}"
    echo -e "${D}     Get at: myaccount.google.com/apppasswords${N}"
    printf "     Password: "
    read -rs GMAIL_APP_PASS || true
    echo ""
    [[ -z "$GMAIL_APP_PASS" ]] && die "Gmail App Password required"
    ok "Gmail App Password: set"

    echo ""
    echo -e "${D}  ─────────────────────────${N}"
    echo -e "  Manager : ${W}${MANAGER_IP}${N}"
    echo -e "  Email   : ${W}${ALERT_EMAIL}${N}"
    echo -e "  Heap    : ${W}${OPENSEARCH_HEAP}${N}"
    echo -e "${D}  ─────────────────────────${N}"
    echo ""
    read -rp "  Confirm? (y/N): " c || true
    [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1

    mkdir -p /etc/rh-pulsar
    cat > "$CONF_FILE" << EOF
MANAGER_IP=${MANAGER_IP}
ALERT_EMAIL=${ALERT_EMAIL}
AR_TIMEOUT=${AR_TIMEOUT}
OPENSEARCH_HEAP=${OPENSEARCH_HEAP}
WAZUH_REPO=${WAZUH_REPO}
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
VERSION=${PULSAR_MGR_VER}
EOF
    chmod 600 "$CONF_FILE"

    cat > /etc/rh-pulsar/gmail.conf << EOF
GMAIL_USER=${ALERT_EMAIL}
GMAIL_PASS=${GMAIL_APP_PASS}
EOF
    chmod 600 /etc/rh-pulsar/gmail.conf

    ok "Config saved: ${CONF_FILE}"
}

# ═══════════════════════════════════════════════════════════
# PHASE 3 — INSTALL WAZUH STACK (fresh)
# ═══════════════════════════════════════════════════════════
install_wazuh_stack() {
    phase "INSTALLING WAZUH STACK"

    local APT="-o Acquire::ForceIPv4=true -o Acquire::http::Timeout=30 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

    # Base packages
    spinner_start "Installing base packages..."
    apt-get update -qq $APT >> "$LOG" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT \
        curl wget gnupg2 apt-transport-https ca-certificates \
        python3 python3-pip postfix libsasl2-modules \
        >> "$LOG" 2>&1
    spinner_stop
    ok "Base packages installed"

    # Wazuh GPG + repo
    if ! grep -q "packages.wazuh.com" /etc/apt/sources.list.d/wazuh.list 2>/dev/null; then
        spinner_start "Adding Wazuh repository..."
        curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
            | gpg --no-default-keyring \
            --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
            --import >> "$LOG" 2>&1
        chmod 644 /usr/share/keyrings/wazuh.gpg
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
https://packages.wazuh.com/${WAZUH_REPO}/apt/ stable main" \
            > /etc/apt/sources.list.d/wazuh.list
        apt-get update -qq $APT >> "$LOG" 2>&1 || true
        spinner_stop
        ok "Wazuh repository added"
    else
        ok "Wazuh repository already present"
    fi

    # Wazuh Manager
    if dpkg -l wazuh-manager 2>/dev/null | grep -q "^ii"; then
        ok "Wazuh Manager already installed — skipping"
    else
        spinner_start "Installing Wazuh Manager (2-3 min)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT \
            wazuh-manager >> "$LOG" 2>&1
        spinner_stop
        ok "Wazuh Manager installed"
    fi

    # Wazuh Indexer (OpenSearch)
    if dpkg -l wazuh-indexer 2>/dev/null | grep -q "^ii"; then
        ok "Wazuh Indexer already installed — skipping"
    else
        spinner_start "Installing Wazuh Indexer (OpenSearch)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT \
            wazuh-indexer >> "$LOG" 2>&1
        spinner_stop

        # JVM heap
        local jvm="/etc/wazuh-indexer/jvm.options"
        [[ -f "$jvm" ]] && {
            sed -i "s/-Xms[0-9]*[mg]/-Xms${OPENSEARCH_HEAP}/" "$jvm" 2>/dev/null || true
            sed -i "s/-Xmx[0-9]*[mg]/-Xmx${OPENSEARCH_HEAP}/" "$jvm" 2>/dev/null || true
        }
        sysctl -w vm.max_map_count=262144 >> "$LOG" 2>&1 || true
        grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null || \
            echo "vm.max_map_count=262144" >> /etc/sysctl.conf
        ok "Wazuh Indexer installed (heap: ${OPENSEARCH_HEAP})"
    fi

    # Wazuh Dashboard
    if dpkg -l wazuh-dashboard 2>/dev/null | grep -q "^ii"; then
        ok "Wazuh Dashboard already installed — skipping"
    else
        spinner_start "Installing Wazuh Dashboard..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT \
            wazuh-dashboard >> "$LOG" 2>&1
        spinner_stop
        ok "Wazuh Dashboard installed"
    fi

    # ── Ensure all components on same version ────────────────
    # Prevents API/Dashboard version mismatch on upgrade
    spinner_start "Checking component version consistency..."
    local mgr_ver idx_ver dsh_ver
    mgr_ver=$(dpkg -l wazuh-manager  2>/dev/null | awk '/^ii/{print $3}' | grep -oP '^\d+\.\d+\.\d+' | head -1 || echo "")
    idx_ver=$(dpkg -l wazuh-indexer  2>/dev/null | awk '/^ii/{print $3}' | grep -oP '^\d+\.\d+\.\d+' | head -1 || echo "")
    dsh_ver=$(dpkg -l wazuh-dashboard 2>/dev/null | awk '/^ii/{print $3}' | grep -oP '^\d+\.\d+\.\d+' | head -1 || echo "")
    spinner_stop

    if [[ -n "$mgr_ver" && ("$idx_ver" != "$mgr_ver" || "$dsh_ver" != "$mgr_ver") ]]; then
        warn "Version mismatch detected — upgrading all components to match Manager ${mgr_ver}"
        spinner_start "Upgrading all Wazuh components to ${mgr_ver}..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT \
            "wazuh-manager=${mgr_ver}-1" \
            "wazuh-indexer=${mgr_ver}-1" \
            "wazuh-dashboard=${mgr_ver}-1" \
            >> "$LOG" 2>&1 || {
            # Fallback — upgrade all to latest
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT \
                --only-upgrade wazuh-manager wazuh-indexer wazuh-dashboard \
                >> "$LOG" 2>&1 || true
        }
        spinner_stop
        ok "All Wazuh components upgraded to consistent version"
    else
        ok "Version consistency: Manager=${mgr_ver} Indexer=${idx_ver} Dashboard=${dsh_ver}"
    fi

    # Enable logall for full event archiving — needed for RH Pulsar
    if grep -q "<logall>no</logall>" /var/ossec/etc/ossec.conf 2>/dev/null; then
        sed -i 's/<logall>no<\/logall>/<logall>yes<\/logall>/' \
            /var/ossec/etc/ossec.conf 2>/dev/null || true
        sed -i 's/<logall_json>no<\/logall_json>/<logall_json>yes<\/logall_json>/' \
            /var/ossec/etc/ossec.conf 2>/dev/null || true
        ok "Archive logging enabled (logall + logall_json)"
    fi

    # Start services
    spinner_start "Starting Wazuh services..."
    for svc in wazuh-indexer wazuh-manager wazuh-dashboard; do
        systemctl enable "$svc" >> "$LOG" 2>&1 || true
        systemctl start  "$svc" >> "$LOG" 2>&1 || true
        sleep 2
    done
    spinner_stop
    ok "Wazuh services started"

    # Publish manager version so sensors can pin agent version
    # install.sh reads this file via HTTP to auto-match agent version
    local wazuh_ver
    wazuh_ver=$(dpkg -l wazuh-manager 2>/dev/null | awk '/^ii/{print $3}' | \
                grep -oP '^\d+\.\d+\.\d+' | head -1 || echo "")
    if [[ -n "$wazuh_ver" ]]; then
        mkdir -p /var/www/html 2>/dev/null || true
        echo "$wazuh_ver" > /var/ossec/etc/rh-pulsar-wazuh-version.txt
        chmod 644 /var/ossec/etc/rh-pulsar-wazuh-version.txt
        ok "Manager version published: ${wazuh_ver} → /var/ossec/etc/rh-pulsar-wazuh-version.txt"
        # Also save to manager.conf for reference
        echo "WAZUH_VERSION=${wazuh_ver}" >> "$CONF_FILE" 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 4 — RH PULSAR DECODERS + RULES
# Must match install.sh v3.2.5+ notice types exactly
# ═══════════════════════════════════════════════════════════
deploy_detections() {
    phase "RH PULSAR DECODERS + RULES"

    # ── Decoder ─────────────────────────────────────────────
    cat > /var/ossec/etc/decoders/rh-pulsar-decoders.xml << 'EOF'
<!--
  RH Pulsar Wazuh Decoders — Compatible with install.sh v3.2.5+
  Red Horizon Security — redhorizon.ph

  Matches label key="rh-pulsar-zeek" set by install.sh agent ossec.conf
-->

<!-- Base: any Zeek JSON tagged rh-pulsar-zeek -->
<decoder name="rh-pulsar-zeek">
  <prematch>{"ts":</prematch>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>

<!-- Notice log: all RH Pulsar detections -->
<decoder name="rh-pulsar-notice">
  <parent>rh-pulsar-zeek</parent>
  <prematch>"note":"</prematch>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>

<!-- Conn log -->
<decoder name="rh-pulsar-conn">
  <parent>rh-pulsar-zeek</parent>
  <prematch>"proto":"</prematch>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>

<!-- DNS log -->
<decoder name="rh-pulsar-dns">
  <parent>rh-pulsar-zeek</parent>
  <prematch>"query":"</prematch>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>

<!-- SSL log — JA4/JA4S fields -->
<decoder name="rh-pulsar-ssl">
  <parent>rh-pulsar-zeek</parent>
  <prematch>"ja4":</prematch>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>

<!-- HTTP log -->
<decoder name="rh-pulsar-http">
  <parent>rh-pulsar-zeek</parent>
  <prematch>"user_agent":</prematch>
  <plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>
EOF
    ok "Decoder deployed"

    # ── Rules ────────────────────────────────────────────────
    # Notice types match install.sh v3.2.5+ exactly
    cat > /var/ossec/etc/rules/rh-pulsar-rules.xml << 'EOF'
<!--
  RH Pulsar Wazuh Rules — Compatible with install.sh v3.2.5+
  Red Horizon Security — redhorizon.ph

  Active Response: Rule 110003 ONLY (Sliver JA4 — near-certain detection)
  All others: alert only
-->
<group name="rh-pulsar,zeek,ndr,">

  <!-- 110001 — C2 Beacon — 5 connections to same external host -->
  <rule id="110001" level="12">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">C2Beacon::C2_Beacon_Detected</field>
    <description>RH Pulsar: C2 Beacon — $(src) -> $(dst)</description>
    <mitre><id>T1071</id></mitre>
    <group>c2,beacon,rh-pulsar,</group>
  </rule>

  <!-- 110002 — DNS Tunnel — suspicious record types or long subdomains -->
  <rule id="110002" level="14">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">DNSTunnel::DNS_Tunnel_Detected</field>
    <description>RH Pulsar: DNS Tunnel — $(src)</description>
    <mitre><id>T1071.004</id></mitre>
    <group>dns,tunnel,rh-pulsar,</group>
  </rule>

  <!-- 110003 — Sliver JA4 manual fingerprint — ACTIVE RESPONSE -->
  <rule id="110003" level="15">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">DetectJA4::Sliver_JA4_Detected</field>
    <description>RH Pulsar: Sliver C2 JA4 match — $(src) AUTO-ISOLATED</description>
    <mitre><id>T1573</id></mitre>
    <group>c2,ja4,sliver,rh-pulsar,active-response,</group>
  </rule>

  <!-- 110004 — HTTP C2 Beacon — same URI 10+ times -->
  <rule id="110004" level="12">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">HTTPC2::HTTP_C2_Beacon</field>
    <description>RH Pulsar: HTTP C2 Beacon — $(src) -> $(dst)</description>
    <mitre><id>T1071.001</id></mitre>
    <group>c2,http,beacon,rh-pulsar,</group>
  </rule>

  <!-- 110005 — Suspicious User-Agent -->
  <rule id="110005" level="10">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">HTTPC2::Suspicious_UserAgent</field>
    <description>RH Pulsar: Suspicious UA — $(src): $(msg)</description>
    <mitre><id>T1071.001</id></mitre>
    <group>http,useragent,rh-pulsar,</group>
  </rule>

  <!-- 110006 — Novel JA4 baseline alert -->
  <rule id="110006" level="10">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">JA4Baseline::Novel_JA4_Observed</field>
    <description>RH Pulsar: Novel JA4 fingerprint — $(src)</description>
    <mitre><id>T1573</id></mitre>
    <group>ja4,baseline,rh-pulsar,</group>
  </rule>

  <!-- 110007 — Malicious JA4 from threat intel DB -->
  <rule id="110007" level="14">
    <decoded_as>rh-pulsar-notice</decoded_as>
    <field name="note">DetectJA4::Malicious_JA4_Detected</field>
    <description>RH Pulsar: Malicious JA4 DB match — $(src) -> $(dst)</description>
    <mitre><id>T1573</id></mitre>
    <group>c2,ja4,rh-pulsar,</group>
  </rule>

</group>
EOF
    ok "Rules deployed (110001-110007)"
}

# ═══════════════════════════════════════════════════════════
# PHASE 5 — EMAIL (Postfix Gmail relay + digest)
# ═══════════════════════════════════════════════════════════
configure_email() {
    phase "EMAIL ALERTS"

    # Postfix Gmail relay
    postconf -e "relayhost = [smtp.gmail.com]:587"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_tls_security_level = encrypt"
    postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
    postconf -e "myhostname = rh-pulsar-manager"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "mydestination ="

    echo "[smtp.gmail.com]:587 ${ALERT_EMAIL}:${GMAIL_APP_PASS}" \
        > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd >> "$LOG" 2>&1
    chmod 600 /etc/postfix/sasl_passwd.db 2>/dev/null || true

    systemctl enable --now postfix >> "$LOG" 2>&1 || true
    ok "Postfix: Gmail SMTP relay configured"

    # Wazuh email config — level 10+ only, no flooding
    if ! grep -q "email_notification" /var/ossec/etc/ossec.conf 2>/dev/null; then
        python3 - "$ALERT_EMAIL" "$MANAGER_IP" << 'PYEOF'
import sys, re
email = sys.argv[1]
mgr   = sys.argv[2]
path  = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    c = f.read()
block = f"""
  <global>
    <email_notification>yes</email_notification>
    <email_to>{email}</email_to>
    <smtp_server>localhost</smtp_server>
    <email_from>rhpulsar@{mgr}</email_from>
    <email_maxperhour>12</email_maxperhour>
    <email_log_source>alerts.log</email_log_source>
  </global>
  <alerts>
    <email_alert_level>10</email_alert_level>
  </alerts>
"""
# Merge multiple ossec_config blocks first
parts = c.split("</ossec_config>")
if len(parts) > 2:
    merged = parts[0]
    for part in parts[1:-1]:
        part = re.sub(r'\s*<ossec_config>\s*', '\n', part)
        merged += part
    c = merged.rstrip() + "\n\n</ossec_config>\n"
c = re.sub(r'(<ossec_config>)', r'\1' + block, c, count=1)
with open(path, "w") as f:
    f.write(c)
PYEOF
        ok "Wazuh email: level 10+ alerts, max 12/hr"
    else
        ok "Wazuh email: already configured"
    fi

    # Email digest script — 15min batching, 1hr suppression per src+rule
    cat > /usr/local/sbin/rh-pulsar-digest.sh << 'DIGEST'
#!/bin/bash
# RH Pulsar Email Digest — runs every 15 min via cron
# Batches alerts, suppresses same src+rule for 1 hour

CONF="/etc/rh-pulsar/manager.conf"
GMAIL="/etc/rh-pulsar/gmail.conf"
[[ -f "$CONF"  ]] && source "$CONF"
[[ -f "$GMAIL" ]] && source "$GMAIL"

SUPPRESS_DIR="/var/lib/rh-pulsar/suppress"
ALERTS_JSON="/var/ossec/logs/alerts/alerts.json"
mkdir -p "$SUPPRESS_DIR"

python3 << PYEOF
import json, os, time, subprocess
from datetime import datetime

now        = time.time()
window     = 900
suppress   = 3600
sup_dir    = "$SUPPRESS_DIR"
alerts_log = "$ALERTS_JSON"
email      = "$ALERT_EMAIL"
mgr_ip     = "$MANAGER_IP"

rules = {
    "110001": ("HIGH", "C2 Beacon",           "T1071"),
    "110002": ("HIGH", "DNS Tunnel",           "T1071.004"),
    "110003": ("CRIT", "Sliver JA4 ISOLATED",  "T1573"),
    "110004": ("MED",  "HTTP C2 Beacon",       "T1071.001"),
    "110005": ("MED",  "Suspicious UA",        "T1071.001"),
    "110006": ("LOW",  "Novel JA4 Baseline",   "T1573"),
    "110007": ("HIGH", "Malicious JA4 DB",     "T1573"),
}

alerts = []
try:
    with open(alerts_log) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d    = json.loads(line)
                rid  = str(d.get("rule", {}).get("id", ""))
                if rid not in rules: continue
                src    = d.get("data", {}).get("src", "unknown")
                dst    = d.get("data", {}).get("dst", "unknown")
                msg    = d.get("data", {}).get("msg", d.get("rule", {}).get("description", ""))
                sensor = d.get("agent", {}).get("name", "unknown")
                ts     = d.get("timestamp", "")
                try:
                    t = datetime.fromisoformat(ts.replace("Z","")).timestamp()
                    if (now - t) > window: continue
                except: pass
                key  = f"{rid}-{src}".replace("/","_")
                sup  = os.path.join(sup_dir, key)
                if os.path.exists(sup) and (now - os.path.getmtime(sup)) < suppress:
                    continue
                open(sup, "w").close()
                sev, name, mitre = rules[rid]
                alerts.append({"rid":rid,"sev":sev,"name":name,
                                "mitre":mitre,"src":src,"dst":dst,
                                "msg":msg,"sensor":sensor})
            except: continue
except FileNotFoundError:
    pass

if not alerts:
    exit(0)

n       = len(alerts)
sensors = list(set(a["sensor"] for a in alerts))
subj    = f"[RH PULSAR] {n} Alert{'s' if n>1 else ''} — {', '.join(sensors)} — {datetime.now().strftime('%Y-%m-%d %H:%M')}"

body  = f"RH PULSAR DETECTION ALERT\n{'='*55}\n"
body += f"Time     : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} UTC\n"
body += f"Sensors  : {', '.join(sensors)}\n"
body += f"Alerts   : {n}\n{'='*55}\n\n"
for a in alerts:
    body += f"[{a['sev']}] Rule {a['rid']} — {a['name']}\n"
    body += f"  MITRE  : {a['mitre']}\n"
    body += f"  Source : {a['src']}\n"
    body += f"  Dest   : {a['dst']}\n"
    body += f"  Sensor : {a['sensor']}\n"
    body += f"  Detail : {a['msg'][:100]}\n"
    body += f"{'-'*55}\n"
body += f"\nDashboard: http://{mgr_ip}:5601\n"
body += f"Red Horizon Security — redhorizon.ph\n"

p = subprocess.Popen(["/usr/sbin/sendmail", "-t"], stdin=subprocess.PIPE)
p.communicate(f"To: {email}\nSubject: {subj}\nContent-Type: text/plain\n\n{body}".encode())
print(f"Digest: {n} alerts sent to {email}")
PYEOF
DIGEST
    chmod 755 /usr/local/sbin/rh-pulsar-digest.sh

    # Cron every 15 min
    ( crontab -l 2>/dev/null | grep -v "rh-pulsar-digest"
      echo "*/15 * * * * /usr/local/sbin/rh-pulsar-digest.sh >> /var/log/rh-pulsar-digest.log 2>&1"
    ) | crontab -
    ok "Email digest: cron every 15 min (1hr suppress per src+rule)"

    # Test email
    info "Sending test email to ${ALERT_EMAIL}..."
    printf "To: %s\nSubject: [RH PULSAR] Manager setup complete\nContent-Type: text/plain\n\nRH Pulsar Wazuh Manager v%s installed.\nManager: %s\nTime: %s UTC\n\nRed Horizon Security\n" \
        "$ALERT_EMAIL" "$PULSAR_MGR_VER" "$MANAGER_IP" "$(date -u '+%Y-%m-%d %H:%M:%S')" \
        | /usr/sbin/sendmail -t 2>/dev/null || true
    ok "Test email queued → ${ALERT_EMAIL}"
}

# ═══════════════════════════════════════════════════════════
# PHASE 6 — ACTIVE RESPONSE (Rule 110003 only)
# ═══════════════════════════════════════════════════════════
configure_ar() {
    phase "ACTIVE RESPONSE"

    cat > /var/ossec/active-response/bin/rh-pulsar-block.sh << AREOF
#!/bin/bash
# RH Pulsar Active Response — isolate infected source IP
# Triggered: Rule 110003 (Sliver JA4) only
# Action: iptables DROP src IP on sensor VM
# Unblock: after ${AR_TIMEOUT}s automatically
AR_LOG="/var/log/rh-pulsar-ar.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" >> "\$AR_LOG"; }
ACTION=\$1; USER=\$2; IP=\$3
[[ -z "\$IP" || "\$IP" == "-" ]] && exit 0
[[ "\$IP" =~ ^127\. ]] && exit 0
case "\$ACTION" in
    add)
        iptables -I INPUT   -s "\$IP" -j DROP 2>/dev/null || true
        iptables -I FORWARD -s "\$IP" -j DROP 2>/dev/null || true
        log "ISOLATED: \$IP (Sliver JA4 — auto-unblock in ${AR_TIMEOUT}s)"
        ( sleep ${AR_TIMEOUT}
          iptables -D INPUT   -s "\$IP" -j DROP 2>/dev/null || true
          iptables -D FORWARD -s "\$IP" -j DROP 2>/dev/null || true
          log "UNBLOCKED: \$IP"
        ) &
        disown ;;
    delete)
        iptables -D INPUT   -s "\$IP" -j DROP 2>/dev/null || true
        iptables -D FORWARD -s "\$IP" -j DROP 2>/dev/null || true
        log "MANUAL UNBLOCK: \$IP" ;;
esac
AREOF
    chmod 750 /var/ossec/active-response/bin/rh-pulsar-block.sh
    chown root:wazuh /var/ossec/active-response/bin/rh-pulsar-block.sh 2>/dev/null || true
    ok "AR script deployed"

    # AR config in ossec.conf
    if ! grep -q "rh-pulsar-block" /var/ossec/etc/ossec.conf 2>/dev/null; then
        python3 - "$AR_TIMEOUT" << 'PYEOF'
import sys, re
timeout = sys.argv[1]
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    c = f.read()
ar = f"""
  <command>
    <name>rh-pulsar-block</name>
    <executable>rh-pulsar-block.sh</executable>
    <timeout_allowed>yes</timeout_allowed>
  </command>
  <active-response>
    <command>rh-pulsar-block</command>
    <location>local</location>
    <rules_id>110003</rules_id>
    <timeout>{timeout}</timeout>
  </active-response>
"""
# Merge multiple ossec_config blocks into one before inserting
parts = c.split("</ossec_config>")
if len(parts) > 2:
    import re as re2
    merged = parts[0]
    for part in parts[1:-1]:
        part = re2.sub(r'\s*<ossec_config>\s*', '\n', part)
        merged += part
    c = merged.rstrip() + "\n\n</ossec_config>\n"
# Insert AR config before closing tag
c = re.sub(r'\s*</ossec_config>\s*$', '\n' + ar + '\n</ossec_config>\n', c, count=1, flags=re.MULTILINE)
with open(path, "w") as f:
    f.write(c)
PYEOF
        ok "AR configured: Rule 110003 → auto-isolate → unblock after ${AR_TIMEOUT}s"
    else
        ok "AR already configured"
    fi

    warn "AR active only for Rule 110003 (Sliver JA4 — cryptographic match)"
    warn "Rules 110001/110002/110004/110005 = alert only (FP risk)"
}

# ═══════════════════════════════════════════════════════════
# PHASE 7 — RESTART + VALIDATE
# ═══════════════════════════════════════════════════════════
validate() {
    phase "RESTART + VALIDATE"

    # Merge multiple ossec_config blocks — common in Wazuh Manager default config
    python3 << 'PYEOF'
import re
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    c = f.read()
parts = c.split("</ossec_config>")
if len(parts) > 2:
    merged = parts[0]
    for part in parts[1:-1]:
        part = re.sub(r'\s*<ossec_config>\s*', '\n', part)
        merged += part
    c = merged.rstrip() + "\n\n</ossec_config>\n"
    with open(path, "w") as f:
        f.write(c)
    print("Merged multiple ossec_config blocks")
PYEOF

    # Merge multiple ossec_config blocks — common in Wazuh Manager default config
    python3 << 'PYEOF'
import re
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    c = f.read()
parts = c.split("</ossec_config>")
if len(parts) > 2:
    merged = parts[0]
    for part in parts[1:-1]:
        part = re.sub(r'\s*<ossec_config>\s*', '\n', part)
        merged += part
    c = merged.rstrip() + "\n\n</ossec_config>\n"
    with open(path, "w") as f:
        f.write(c)
    print("ossec_config blocks merged")
PYEOF

    # Validate ossec.conf XML
    python3 -c "
import xml.etree.ElementTree as ET
ET.parse('/var/ossec/etc/ossec.conf')
print('XML valid')
" >> "$LOG" 2>&1 && ok "ossec.conf: XML valid" || {
        fail "ossec.conf: XML invalid — check /var/ossec/etc/ossec.conf"
    }

    spinner_start "Restarting Wazuh Manager..."
    systemctl restart wazuh-manager >> "$LOG" 2>&1 || true
    sleep 5
    spinner_stop

    local p=0 f=0

    systemctl is-active --quiet wazuh-manager && \
        { ok "Wazuh Manager: running"; p=$(( p + 1 )) || true; } || \
        { fail "Wazuh Manager: not running"; f=$(( f + 1 )) || true; }

    systemctl is-active --quiet wazuh-indexer && \
        { ok "Wazuh Indexer: running"; p=$(( p + 1 )) || true; } || \
        { warn "Wazuh Indexer: starting (may need 60s)"; }

    systemctl is-active --quiet wazuh-dashboard && \
        { ok "Wazuh Dashboard: running"; p=$(( p + 1 )) || true; } || \
        { warn "Wazuh Dashboard: starting"; }

    systemctl is-active --quiet postfix && \
        { ok "Postfix: running"; p=$(( p + 1 )) || true; } || \
        { fail "Postfix: not running"; f=$(( f + 1 )) || true; }

    [[ -f /var/ossec/etc/decoders/rh-pulsar-decoders.xml ]] && \
        { ok "Decoder: present"; p=$(( p + 1 )) || true; } || \
        { fail "Decoder: missing"; f=$(( f + 1 )) || true; }

    [[ -f /var/ossec/etc/rules/rh-pulsar-rules.xml ]] && \
        { ok "Rules: present (110001-110007)"; p=$(( p + 1 )) || true; } || \
        { fail "Rules: missing"; f=$(( f + 1 )) || true; }

    [[ -f /var/ossec/active-response/bin/rh-pulsar-block.sh ]] && \
        { ok "AR script: present"; p=$(( p + 1 )) || true; } || \
        { fail "AR script: missing"; f=$(( f + 1 )) || true; }

    # Port checks
    sleep 3
    ss -tlnp 2>/dev/null | grep -q ":1514 " && \
        ok "Port 1514: listening" || warn "Port 1514: not yet listening"
    ss -tlnp 2>/dev/null | grep -q ":1515 " && \
        ok "Port 1515: listening" || warn "Port 1515: not yet listening"
    ss -tlnp 2>/dev/null | grep -q ":55000 " && \
        ok "Port 55000 (API): listening" || warn "Port 55000: not yet listening"

    echo ""
    echo -e "  Validation: ${G}${p} passed${N} / ${R}${f} failed${N}"
}

# ═══════════════════════════════════════════════════════════
# PHASE 8 — SUMMARY
# ═══════════════════════════════════════════════════════════
summary() {
    phase "COMPLETE"

    local wv
    wv=$( /var/ossec/bin/wazuh-control info 2>/dev/null | \
          grep WAZUH_VERSION | cut -d= -f2 | tr -d '"' || echo "unknown" )

    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${G}  RH PULSAR WAZUH MANAGER READY${N}"
    echo ""
    echo -e "  ${D}Version  :${N} ${W}v${PULSAR_MGR_VER}${N}"
    echo -e "  ${D}Wazuh    :${N} ${W}${wv}${N}"
    echo -e "  ${D}Manager  :${N} ${W}${MANAGER_IP}${N}"
    echo -e "  ${D}Email    :${N} ${W}${ALERT_EMAIL}${N}"
    echo -e "  ${D}AR       :${N} ${W}Rule 110003 only — auto-unblock ${AR_TIMEOUT}s${N}"
    echo ""
    echo -e "  ${G}[✓]${N} 110001 C2 Beacon          L12  T1071       Alert"
    echo -e "  ${G}[✓]${N} 110002 DNS Tunnel          L14  T1071.004   Alert"
    echo -e "  ${G}[✓]${N} 110003 Sliver JA4          L15  T1573       AUTO-ISOLATE"
    echo -e "  ${G}[✓]${N} 110004 HTTP C2 Beacon      L12  T1071.001   Alert"
    echo -e "  ${G}[✓]${N} 110005 Suspicious UA       L10  T1071.001   Alert"
    echo -e "  ${G}[✓]${N} 110006 Novel JA4 Baseline  L10  T1573       Alert"
    echo -e "  ${G}[✓]${N} 110007 Malicious JA4 DB    L14  T1573       Alert"
    echo ""
    echo -e "${D}  ─────────────────────────────────────────────────${N}"
    echo -e "  ${C}Dashboard :${N} http://${MANAGER_IP}:5601"
    echo -e "  ${C}API       :${N} https://${MANAGER_IP}:55000"
    echo -e "  ${C}OpenSearch:${N} https://${MANAGER_IP}:9200"
    echo ""
    echo -e "  ${W}Add a new sensor:${N}"
    echo -e "  ${D}  SIEM_HOST=${MANAGER_IP} sudo bash install.sh${N}"
    echo ""
    echo -e "  ${D}Logs:${N}"
    echo -e "  ${D}  Install : ${LOG}${N}"
    echo -e "  ${D}  Alerts  : /var/ossec/logs/alerts/alerts.json${N}"
    echo -e "  ${D}  Archives: /var/ossec/logs/archives/archives.log${N}"
    echo -e "  ${D}  AR      : /var/log/rh-pulsar-ar.log${N}"
    echo -e "  ${D}  Digest  : /var/log/rh-pulsar-digest.log${N}"
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
    mkdir -p /var/log /etc/rh-pulsar /var/lib/rh-pulsar
    touch "$LOG" 2>/dev/null || true
    chmod 600 "$LOG" 2>/dev/null || true
    echo "[$(ts)] RH Pulsar Manager Setup v${PULSAR_MGR_VER}" >> "$LOG"

    banner
    preflight       # 1
    configure       # 2
    install_wazuh_stack  # 3
    deploy_detections    # 4
    configure_email      # 5
    configure_ar         # 6
    validate             # 7
    summary              # 8
}

main "$@"
