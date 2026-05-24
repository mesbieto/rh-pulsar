#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Passive NDR Sensor Installer
#  Version: 3.1.0 (Ubuntu 24.04 LTS — production)
#  Red Horizon Security — redhorizon.ph
#  © 2026 Red Horizon Security. All rights reserved.
#
#  Targets:
#    Primary  : Ubuntu 24.04 LTS  (recommended — most stable)
#    Tolerated: Ubuntu 22.04 LTS  (warning shown)
#
#  Usage:
#    sudo bash install.sh             # Full install
#    sudo bash install.sh --dry-run   # Check only
#    sudo bash install.sh --help
#
#  Environment overrides (avoid prompts — useful for Ansible):
#    SENSOR_NAME, MGMT_IFACE, CAP_IFACE, ALERT_EMAIL
#    SIEM_CHOICE, SIEM_HOST, SPLUNK_TOKEN, ELASTIC_PASS,
#    SENTINEL_KEY, SMTP_IP
# ═══════════════════════════════════════════════════════════

set -euo pipefail

# ── Args ────────────────────────────────────────────────────
DRY_RUN=false
case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
    "") : ;;
    *) echo "Unknown argument: $1 — try --help"; exit 1 ;;
esac

# ── Colors ──────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' C='\033[0;36m' N='\033[0m'

# ── Versions (Zeek tracks upstream stable; agents pinned for SIEM compatibility) ──
PULSAR_VER="3.1.0"
WAZUH_REPO="4.x"                              # Wazuh recommends tracking 4.x for agents
FILEBEAT_MAJOR="8"                            # Filebeat 8.x for Elastic 8.x stack
SPLUNK_UF_VER="9.2.3"                         # Splunk UF — stable LTS line
SPLUNK_UF_BUILD="282c9a5ba636"                # Required for download URL
ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/"

# ── State ───────────────────────────────────────────────────
LOG="/var/log/rh-pulsar-install.log"
STATE_FILE="/etc/rh-pulsar/install.state"
PASS=0; WARN=0; FAIL=0
SIEM_CHOICE="${SIEM_CHOICE:-}"; SIEM_NAME=""
SENSOR_NAME="${SENSOR_NAME:-}"; MGMT_IFACE="${MGMT_IFACE:-}"; CAP_IFACE="${CAP_IFACE:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"; SIEM_HOST="${SIEM_HOST:-}"
OS_ID=""; OS_VER=""; OS_PRETTY=""; OS_CODENAME=""
CLOUD="bare-metal"; ARCH=""
SPINNER_PID=""; ZEEK_PREFETCH_PID=""
CURRENT_PHASE="init"
INSTALLED_COMPONENTS=()    # for failure reporting

# ── Logging ─────────────────────────────────────────────────
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
ok()   { echo -e "${G}  [✓]${N} $1"; echo "[$(ts)] OK   [${CURRENT_PHASE}] $1" >> "$LOG"; PASS=$((PASS+1)); }
warn() { echo -e "${Y}  [!]${N} $1"; echo "[$(ts)] WARN [${CURRENT_PHASE}] $1" >> "$LOG"; WARN=$((WARN+1)); }
fail() { echo -e "${R}  [✗]${N} $1"; echo "[$(ts)] FAIL [${CURRENT_PHASE}] $1" >> "$LOG"; FAIL=$((FAIL+1)); }
info() { echo -e "${D}  [→]${N} $1"; echo "[$(ts)] INFO [${CURRENT_PHASE}] $1" >> "$LOG"; }
die()  { spinner_stop; echo -e "\n${R}  ✗ FATAL: $1${N}\n  See log: ${LOG}\n"; exit 1; }
has()  { command -v "$1" &>/dev/null; }
note() { INSTALLED_COMPONENTS+=("$1"); }

# ── Error trap — report which phase + line + last command ───
on_error() {
    local exit_code=$?
    local line_no=$1
    spinner_stop
    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${R}  ✗ INSTALLATION FAILED${N}"
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "  ${W}Phase    :${N} ${CURRENT_PHASE}"
    echo -e "  ${W}Line     :${N} ${line_no}"
    echo -e "  ${W}Exit code:${N} ${exit_code}"
    echo -e "  ${W}Last cmd :${N} ${BASH_COMMAND}"
    echo -e "  ${W}Log file :${N} ${LOG}"
    echo ""
    if [[ ${#INSTALLED_COMPONENTS[@]} -gt 0 ]]; then
        echo -e "  ${W}Partially installed:${N}"
        for c in "${INSTALLED_COMPONENTS[@]}"; do
            echo -e "    ${D}• ${c}${N}"
        done
        echo ""
        echo -e "  ${D}To clean up manually, see: ${LOG}${N}"
    fi
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

# ── Phase tracking + progress ───────────────────────────────
TOTAL_STEPS=6; CURRENT_STEP=0
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

# ── Retry helper (network calls) ────────────────────────────
retry() {
    local n=0 max=3 delay=2
    until "$@"; do
        n=$((n+1))
        if [[ $n -ge $max ]]; then
            return 1
        fi
        sleep $delay
        delay=$((delay*2))
    done
}

# ── Secret prompt (silent, with env var fallback) ───────────
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
    echo -e "${W}  Passive NDR Platform — v${PULSAR_VER}${N}"
    echo -e "${D}  Red Horizon Security — redhorizon.ph${N}"
    [[ "$DRY_RUN" == true ]] && \
        echo -e "\n${C}  [ DRY RUN — no changes will be made ]${N}"
    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
}

# ═══════════════════════════════════════════════════════════
# DETECT — OS, cloud, arch
# ═══════════════════════════════════════════════════════════
detect_env() {
    ARCH=$(uname -m)
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VER="${VERSION_ID:-unknown}"
        OS_PRETTY="${PRETTY_NAME:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-noble}"
    fi
    # Cloud probe — fast, 2s timeouts
    if curl -sf --connect-timeout 2 --max-time 2 http://169.254.169.254/latest/meta-data/ami-id &>/dev/null; then
        CLOUD="AWS"
    elif curl -sf --connect-timeout 2 --max-time 2 -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" &>/dev/null; then
        CLOUD="Azure"
    elif curl -sf --connect-timeout 2 --max-time 2 -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/ &>/dev/null; then
        CLOUD="GCP"
    elif curl -sf --connect-timeout 2 --max-time 2 http://169.254.169.254/metadata/v1/id &>/dev/null; then
        CLOUD="DigitalOcean"
    elif grep -qi "vmware" /sys/class/dmi/id/product_name 2>/dev/null; then
        CLOUD="VMware"
    elif grep -qi "virtualbox\|innotek" /sys/class/dmi/id/product_name 2>/dev/null; then
        CLOUD="VirtualBox"
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 1 — PREFLIGHT
# ═══════════════════════════════════════════════════════════
preflight() {
    phase "PREFLIGHT"

    [[ $EUID -ne 0 ]] && die "Run as root: sudo bash install.sh"
    ok "Root privileges"

    # OS check — Ubuntu 24.04 preferred, 22.04 warn, others fail
    case "${OS_ID}:${OS_VER}" in
        ubuntu:24.04)
            ok "OS: ${OS_PRETTY} (recommended target)"
            ;;
        ubuntu:22.04)
            warn "OS: ${OS_PRETTY} — tolerated, but Ubuntu 24.04 LTS is the most stable target"
            warn "Detection rules tested only on 24.04; behavior on 22.04 may vary"
            ;;
        *)
            die "Unsupported OS: ${OS_PRETTY:-unknown}. RH Pulsar v${PULSAR_VER} supports Ubuntu 24.04 LTS (recommended) and 22.04 LTS only."
            ;;
    esac
    ok "Arch: ${ARCH} | Platform: ${CLOUD}"

    # APT lock
    if fuser /var/lib/dpkg/lock-frontend &>/dev/null; then
        die "APT is locked by another process — wait for it to finish and retry"
    fi
    ok "APT: available"

    # Resources
    local cpu ram_kb ram_gb disk
    cpu=$(nproc)
    ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    ram_gb=$(awk '/MemTotal/{printf "%.1f",$2/1024/1024}' /proc/meminfo)
    disk=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    [[ "$cpu"    -ge 2       ]] && ok "CPU: ${cpu} vCPU"     || warn "CPU: ${cpu} — 2+ recommended"
    [[ "$ram_kb" -ge 4194304 ]] && ok "RAM: ${ram_gb}GB"     || fail "RAM: ${ram_gb}GB — min 4GB"
    [[ "$disk"   -ge 20      ]] && ok "Disk: ${disk}GB free" || fail "Disk: ${disk}GB — min 20GB"

    # Internet
    if retry curl -sf --connect-timeout 5 --max-time 8 https://archive.ubuntu.com &>/dev/null; then
        ok "Internet: reachable"
    else
        fail "Internet: unreachable — installer requires apt repo access"
    fi

    # Interfaces
    local iface_count
    iface_count=$(ip -br link show | grep -vc "^lo")
    [[ "$iface_count" -ge 2 ]] && ok "Interfaces: ${iface_count}" || warn "Interfaces: ${iface_count} — NDR ideally uses 2"

    # Conflicts
    pgrep -x unattended-upgrade &>/dev/null && fail "Unattended-upgrade running — wait or stop it" || ok "No conflicting upgrades"
    for t in suricata snort; do
        pgrep -x "$t" &>/dev/null && fail "${t}: running — capture conflict" || true
    done

    # Previous install
    [[ -f /etc/rh-pulsar/sensor_id ]] && warn "Previous install detected — will upgrade in place" || ok "Clean install"

    # Bootstrap tools
    local need=()
    for pkg in curl iproute2 ethtool dnsutils; do
        dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || need+=("$pkg")
    done
    if [[ ${#need[@]} -gt 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            warn "Would install: ${need[*]}"
        else
            spinner_start "Installing bootstrap tools..."
            retry apt-get update -qq >> "$LOG" 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >> "$LOG" 2>&1
            spinner_stop
            ok "Bootstrap: ${need[*]}"
        fi
    fi

    # Summary
    echo ""
    echo -e "  ${G}${PASS} passed${N}  ${Y}${WARN} warnings${N}  ${R}${FAIL} conflicts${N}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        [[ "$FAIL" -gt 0 ]] && echo -e "${R}  ✗ Resolve ${FAIL} conflict(s) first${N}" || echo -e "${G}  ✓ Ready — run: sudo bash install.sh${N}"
        echo ""; exit 0
    fi

    if [[ "$FAIL" -gt 0 ]]; then
        read -rp "  ${FAIL} conflict(s) detected. Continue anyway? (y/N): " c || true
        [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 2 — CONFIGURATION (collect everything before installing)
# ═══════════════════════════════════════════════════════════
configure() {
    phase "CONFIGURATION"

    # SIEM selection — skip if env var set
    if [[ -z "$SIEM_CHOICE" ]]; then
        echo -e "${W}  Select SIEM platform:${N}"
        echo ""
        echo -e "  ${C}1)${N} Wazuh + OpenSearch     ${D}(default)${N}"
        echo -e "  ${C}2)${N} Splunk                 ${D}(Universal Forwarder)${N}"
        echo -e "  ${C}3)${N} Elastic / ELK          ${D}(Filebeat)${N}"
        echo -e "  ${C}4)${N} Microsoft Sentinel     ${D}(Azure Monitor Agent)${N}"
        echo -e "  ${C}5)${N} IBM QRadar             ${D}(Syslog LEEF)${N}"
        echo -e "  ${C}6)${N} Syslog Generic         ${D}(RFC 5424)${N}"
        echo -e "  ${C}7)${N} Standalone             ${D}(Zeek only)${N}"
        echo ""
        case $CLOUD in
            AWS)   info "AWS detected — Splunk or Elastic recommended" ;;
            Azure) info "Azure detected — Sentinel recommended" ;;
        esac
        echo ""
        read -rp "  Choice (1-7): " SIEM_CHOICE
    else
        info "SIEM_CHOICE: ${SIEM_CHOICE} (from env)"
    fi

    case $SIEM_CHOICE in
        1) SIEM_NAME="Wazuh + OpenSearch" ;;
        2) SIEM_NAME="Splunk" ;;
        3) SIEM_NAME="Elastic / ELK" ;;
        4) SIEM_NAME="Microsoft Sentinel" ;;
        5) SIEM_NAME="IBM QRadar" ;;
        6) SIEM_NAME="Syslog Generic" ;;
        7) SIEM_NAME="Standalone" ;;
        *) die "Invalid SIEM choice: $SIEM_CHOICE" ;;
    esac

    echo ""
    # Sensor identity
    if [[ -z "$SENSOR_NAME" ]]; then
        read -rp "  Sensor Name (e.g. RHP-CLIENT01): " SENSOR_NAME
    fi
    [[ -z "$SENSOR_NAME" ]] && die "Sensor name required"

    echo ""
    info "Available interfaces:"
    ip -br link show | grep -v "^lo" | awk '{print "    "$1" ("$2")"}'
    echo ""

    if [[ -z "$MGMT_IFACE" ]]; then
        read -rp "  Management Interface (e.g. ens33): " MGMT_IFACE
    fi
    ip link show "$MGMT_IFACE" &>/dev/null || die "Interface $MGMT_IFACE not found"

    if [[ -z "$CAP_IFACE" ]]; then
        read -rp "  Capture Interface  (e.g. ens37): " CAP_IFACE
    fi
    ip link show "$CAP_IFACE" &>/dev/null || die "Interface $CAP_IFACE not found"
    [[ "$CAP_IFACE" == "$MGMT_IFACE" ]] && warn "Mgmt and capture interfaces are the same — OK for testing only"

    if [[ -z "$ALERT_EMAIL" ]]; then
        read -rp "  SOC Alert Email: " ALERT_EMAIL
    fi
    [[ -z "$ALERT_EMAIL" ]] && die "Email required"

    echo ""
    echo -e "${W}  SIEM: $SIEM_NAME${N}"
    case $SIEM_CHOICE in
        1)  [[ -z "$SIEM_HOST" ]] && read -rp "  Wazuh Manager IP: " SIEM_HOST
            [[ -z "${SMTP_IP:-}" ]] && read -rp "  SMTP Relay IP (blank to skip): " SMTP_IP || true
            ;;
        2)  [[ -z "$SIEM_HOST" ]] && read -rp "  Splunk HEC Host: " SIEM_HOST
            [[ -z "${SPLUNK_PORT:-}" ]] && { read -rp "  HEC Port (8088): " SPLUNK_PORT || true; SPLUNK_PORT=${SPLUNK_PORT:-8088}; }
            read_secret SPLUNK_TOKEN "Splunk HEC Token"
            ;;
        3)  [[ -z "$SIEM_HOST" ]] && read -rp "  Elasticsearch Host: " SIEM_HOST
            [[ -z "${ELASTIC_PORT:-}" ]] && { read -rp "  Port (9200): " ELASTIC_PORT || true; ELASTIC_PORT=${ELASTIC_PORT:-9200}; }
            [[ -z "${ELASTIC_USER:-}" ]] && { read -rp "  Username (elastic): " ELASTIC_USER || true; ELASTIC_USER=${ELASTIC_USER:-elastic}; }
            read_secret ELASTIC_PASS "Elastic Password"
            ;;
        4)  [[ -z "${SENTINEL_WS:-}" ]] && read -rp "  Workspace ID: " SENTINEL_WS
            read_secret SENTINEL_KEY "Sentinel Primary Key"
            SIEM_HOST="sentinel.azure.com"
            ;;
        5)  [[ -z "$SIEM_HOST" ]] && read -rp "  QRadar IP: " SIEM_HOST
            [[ -z "${QRADAR_PORT:-}" ]] && { read -rp "  Port (514): " QRADAR_PORT || true; QRADAR_PORT=${QRADAR_PORT:-514}; }
            ;;
        6)  [[ -z "$SIEM_HOST" ]] && read -rp "  Syslog IP: " SIEM_HOST
            [[ -z "${SYSLOG_PORT:-}" ]] && { read -rp "  Port (514): " SYSLOG_PORT || true; SYSLOG_PORT=${SYSLOG_PORT:-514}; }
            [[ -z "${SYSLOG_PROTO:-}" ]] && { read -rp "  Protocol TCP/UDP (UDP): " SYSLOG_PROTO || true; SYSLOG_PROTO=${SYSLOG_PROTO:-UDP}; }
            ;;
        7)  SIEM_HOST="localhost" ;;
    esac

    # Summary + confirm
    echo ""
    echo -e "${D}  ── Summary ───────────────────────────${N}"
    echo -e "  Sensor   : ${W}$SENSOR_NAME${N}"
    echo -e "  SIEM     : ${W}$SIEM_NAME${N}"
    echo -e "  Mgmt     : ${W}$MGMT_IFACE${N} | Capture: ${W}$CAP_IFACE${N}"
    echo -e "  Email    : ${W}$ALERT_EMAIL${N}"
    echo -e "  Platform : ${W}$CLOUD${N} | OS: ${W}$OS_PRETTY${N}"
    [[ "$SIEM_CHOICE" != "7" ]] && echo -e "  SIEM Host: ${W}$SIEM_HOST${N}"
    echo -e "${D}  ─────────────────────────────────────${N}"
    echo ""
    read -rp "  Confirm? (y/N): " c || true
    [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1

    # Save state for resume/cleanup
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" << EOF
SIEM_CHOICE=$SIEM_CHOICE
SIEM_NAME="$SIEM_NAME"
SENSOR_NAME="$SENSOR_NAME"
MGMT_IFACE=$MGMT_IFACE
CAP_IFACE=$CAP_IFACE
ALERT_EMAIL="$ALERT_EMAIL"
SIEM_HOST="$SIEM_HOST"
EOF
    chmod 600 "$STATE_FILE"

    # Pre-fetch Zeek repo key in background
    info "Pre-fetching Zeek repo key in background..."
    (
        curl -fsSL --retry 3 --retry-delay 2 "${ZEEK_REPO}Release.key" 2>/dev/null \
            | gpg --dearmor 2>/dev/null \
            | tee /etc/apt/trusted.gpg.d/security-zeek.gpg > /dev/null 2>&1 || true
        echo "deb ${ZEEK_REPO} /" > /etc/apt/sources.list.d/security-zeek.list 2>/dev/null || true
    ) &
    ZEEK_PREFETCH_PID=$!
    disown "$ZEEK_PREFETCH_PID" 2>/dev/null || true
    ok "Configuration captured"
}

# ═══════════════════════════════════════════════════════════
# PHASE 3 — INSTALL PLATFORM (system tune + Zeek + JA4)
# ═══════════════════════════════════════════════════════════
install_platform() {
    phase "INSTALLING PLATFORM"

    # ── System tune ─────────────────────────────────────────
    spinner_start "Tuning system..."
    local swap; swap=$(awk '/SwapTotal/{printf "%.0f",$2/1024}' /proc/meminfo)
    if [[ "$swap" -eq 0 && ! -f /swapfile ]]; then
        fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 >> "$LOG" 2>&1
        chmod 600 /swapfile
        mkswap /swapfile >> "$LOG" 2>&1
        swapon /swapfile
        grep -q swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        note "swap-4GB"
    fi
    cat > /etc/sysctl.d/99-rh-pulsar.conf << EOF
vm.max_map_count = 262144
net.core.rmem_max = 134217728
net.core.netdev_max_backlog = 250000
EOF
    sysctl -p /etc/sysctl.d/99-rh-pulsar.conf >> "$LOG" 2>&1
    cat > /etc/security/limits.d/rh-pulsar.conf << EOF
* soft nofile 65536
* hard nofile 65536
EOF
    spinner_stop
    ok "System tuned"
    note "sysctl-tuning"

    # ── Packages ────────────────────────────────────────────
    spinner_start "Installing required packages..."
    local APT_OPTS="-o Acquire::ForceIPv4=true -o Acquire::http::Timeout=30"
    retry apt-get update -qq $APT_OPTS >> "$LOG" 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_OPTS \
        curl wget gnupg2 apt-transport-https ca-certificates \
        python3 python3-pip git jq ethtool libpcap-dev \
        postfix mailutils rsyslog irqbalance dnsutils \
        >> "$LOG" 2>&1
    spinner_stop
    ok "Packages installed"
    note "base-packages"

    timedatectl set-ntp true 2>/dev/null || true
    systemctl enable --now systemd-timesyncd >> "$LOG" 2>&1 || true
    systemctl enable --now irqbalance >> "$LOG" 2>&1 || true
    ok "NTP + IRQ balancing enabled"

    # ── Zeek install (agnostic — track upstream stable) ─────
    if [[ -f /opt/zeek/bin/zeek ]]; then
        local zv; zv=$(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        ok "Zeek ${zv} already installed — skipping reinstall"
    else
        spinner_start "Installing Zeek from openSUSE Build Service (xUbuntu_24.04)..."
        wait "${ZEEK_PREFETCH_PID:-}" 2>/dev/null || true
        retry apt-get update -qq $APT_OPTS >> "$LOG" 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zeek >> "$LOG" 2>&1
        spinner_stop
        local zv; zv=$(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        ok "Zeek ${zv} installed"
        note "zeek-${zv}"
    fi
    echo 'export PATH=/opt/zeek/bin:$PATH' > /etc/profile.d/zeek.sh
    export PATH=/opt/zeek/bin:$PATH

    # ── JA4+ ────────────────────────────────────────────────
    if /opt/zeek/bin/zkg list 2>/dev/null | grep -q "foxio/ja4"; then
        ok "JA4+ already installed — skipping"
    else
        spinner_start "Installing JA4+ via zkg..."
        pip3 install zkg --break-system-packages --ignore-installed GitPython -q >> "$LOG" 2>&1
        /opt/zeek/bin/zkg autoconfig >> "$LOG" 2>&1
        /opt/zeek/bin/zkg install --force foxio/ja4 >> "$LOG" 2>&1
        spinner_stop
        ok "JA4+ installed"
        note "ja4-plugin"
    fi
    pip3 install websockets --break-system-packages -q >> "$LOG" 2>&1 || true

    # ── Backup configs ──────────────────────────────────────
    local bk="/etc/rh-pulsar/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk"
    for f in /etc/filebeat/filebeat.yml /var/ossec/etc/ossec.conf \
             /etc/postfix/main.cf /etc/rsyslog.conf; do
        [[ -f "$f" ]] && cp "$f" "$bk/" 2>/dev/null || true
    done
    [[ -d /opt/zeek/etc ]] && cp -r /opt/zeek/etc "$bk/zeek-etc" 2>/dev/null || true
    ok "Configs backed up to ${bk}"
}

# ═══════════════════════════════════════════════════════════
# PHASE 4 — DEPLOY DETECTION SCRIPTS
# ═══════════════════════════════════════════════════════════
deploy_scripts() {
    phase "DEPLOYING DETECTION ENGINE"

    local SITE="/opt/zeek/share/zeek/site"
    local ETC="/opt/zeek/etc"
    mkdir -p "$SITE"

    # ── c2beacon.zeek — Rule 110001 ─────────────────────────
    cat > "$SITE/c2beacon.zeek" << 'EOF'
# RH Pulsar — C2 Beacon Detection — Rule 110001 — MITRE T1071
module C2Beacon;
export {
    redef enum Notice::Type += { C2_Beacon_Detected };
    global beacon_threshold: count = 5;
    global suppress_for: interval = 1hr;
    global skip_ports: set[port] = {
        1514/tcp, 1515/tcp, 9200/tcp, 9300/tcp, 55000/tcp, 25/tcp
    };
}
global beacon_tracker: table[addr, addr] of count &create_expire=1hr;
event connection_established(c: connection) {
    local src = c$id$orig_h;
    local dst = c$id$resp_h;
    if (c$id$resp_p in skip_ports) return;
    if (Site::is_local_addr(dst)) return;
    if ([src, dst] !in beacon_tracker) beacon_tracker[src, dst] = 0;
    beacon_tracker[src, dst] += 1;
    if (beacon_tracker[src, dst] == beacon_threshold) {
        NOTICE([$note=C2_Beacon_Detected,
                $msg=fmt("C2 Beacon: %s -> %s (%d connections)",
                         src, dst, beacon_tracker[src, dst]),
                $src=src, $dst=dst, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("%s-%s", src, dst)]);
    }
}
EOF

    # ── dnstunnel.zeek — Rule 110002 ────────────────────────
    cat > "$SITE/dnstunnel.zeek" << 'EOF'
# RH Pulsar — DNS Tunnel Detection — Rule 110002 — MITRE T1071.004
module DNSTunnel;
export {
    redef enum Notice::Type += { DNS_Tunnel_Detected };
    global suspicious_threshold: count = 100;
    global long_sub_threshold:   count = 5;
    global long_sub_len:         count = 20;
    global suppress_for:         interval = 1hr;
    global suspicious_qtypes: set[count] = { 16, 15, 28, 255, 0 };
}
global dns_tracker:      table[addr, string] of count &create_expire=1hr;
global long_sub_tracker: table[addr, string] of count &create_expire=1hr;
function get_root_domain(q: string): string {
    local parts = split_string(q, /\./);
    local n = |parts|;
    return (n >= 2) ? fmt("%s.%s", parts[n-2], parts[n-1]) : q;
}
event dns_request(c: connection, msg: dns_msg, query: string,
                  qtype: count, qclass: count) &priority=5 {
    if (qtype == 12) return;
    if (query == "") return;
    if (/\.arpa$/ in query) return;
    local src  = c$id$orig_h;
    local dst  = c$id$resp_h;
    local root = get_root_domain(query);
    if (qtype in suspicious_qtypes) {
        if ([src, root] !in dns_tracker) dns_tracker[src, root] = 0;
        dns_tracker[src, root] += 1;
        if (dns_tracker[src, root] == suspicious_threshold) {
            NOTICE([$note=DNS_Tunnel_Detected,
                    $msg=fmt("DNS Tunnel: %s -> %s (%d queries type=%d) via %s",
                             src, root, dns_tracker[src, root], qtype, dst),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("%s-%s", src, root)]);
        }
    }
    local parts = split_string(query, /\./);
    if (|parts| > 2 && |parts[0]| > long_sub_len) {
        if ([src, root] !in long_sub_tracker) long_sub_tracker[src, root] = 0;
        long_sub_tracker[src, root] += 1;
        if (long_sub_tracker[src, root] == long_sub_threshold) {
            NOTICE([$note=DNS_Tunnel_Detected,
                    $msg=fmt("DNS Tunnel (Long Sub): %s -> %s len=%d type=%d via %s",
                             src, root, |parts[0]|, qtype, dst),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("longsub-%s-%s", src, root)]);
        }
    }
}
EOF

    # ── detect-ja4.zeek — Rule 110003 ───────────────────────
    cat > "$SITE/detect-ja4.zeek" << 'EOF'
# RH Pulsar — JA4/JA4S TLS Fingerprint Detection — Rule 110003 — MITRE T1573
module DetectJA4;
export {
    redef enum Notice::Type += { Sliver_JA4_Detected };
    global suppress_for: interval = 4hr;
    global malicious_ja4: set[string] = {
        "t13d190900_9dc949149365_97f8aa674fd9",
        "t13i190900_9dc949149365_97f8aa674fd9",
        "t13i3111h2_e8f1e7e78f70_b26ce05bbdd6",
        "t13i131000_f57a46bbacb6_e5728521abd4"
    };
    global malicious_ja4s: set[string] = { "t130200_1301_a56c5b993250" };
}
event ssl_established(c: connection) &priority=5 {
    if (!c?$ssl) return;
    if (c$ssl?$ja4 && c$ssl$ja4 != "" && c$ssl$ja4 in malicious_ja4) {
        NOTICE([$note=Sliver_JA4_Detected,
                $msg=fmt("Sliver JA4: %s -> %s JA4=%s",
                         c$id$orig_h, c$id$resp_h, c$ssl$ja4),
                $src=c$id$orig_h, $dst=c$id$resp_h, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("%s-%s", c$id$orig_h, c$ssl$ja4)]);
    }
    if (c$ssl?$ja4s && c$ssl$ja4s != "" && c$ssl$ja4s in malicious_ja4s) {
        NOTICE([$note=Sliver_JA4_Detected,
                $msg=fmt("Sliver JA4S: %s -> %s JA4S=%s",
                         c$id$orig_h, c$id$resp_h, c$ssl$ja4s),
                $src=c$id$orig_h, $dst=c$id$resp_h, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("%s-%s", c$id$resp_h, c$ssl$ja4s)]);
    }
}
EOF

    # ── http-c2.zeek — Rules 110004/110005 ──────────────────
    cat > "$SITE/http-c2.zeek" << 'EOF'
# RH Pulsar — HTTP C2 & Suspicious UA Detection — Rules 110004/110005 — MITRE T1071.001
module HTTPC2;
export {
    redef enum Notice::Type += { HTTP_C2_Beacon, Suspicious_UserAgent };
    global beacon_threshold: count = 10;
    global suppress_for: interval = 1hr;
}
global http_beacon_tracker: table[addr, string] of count &create_expire=1hr;
function is_sus_ua(ua: string): bool {
    if (/python-requests/ in ua) return T;
    if (/Go-http-client/  in ua) return T;
    if (/libwww-perl/     in ua) return T;
    if (/[Ss]liver/       in ua) return T;
    if (/[Hh]avoc/        in ua) return T;
    if (/CobaltStrike/    in ua) return T;
    if (/meterpreter/     in ua) return T;
    return F;
}
event http_message_done(c: connection, is_orig: bool,
                        stat: http_message_stat) &priority=-5 {
    if (!is_orig) return;
    if (!c?$http) return;
    local src = c$id$orig_h;
    local dst = c$id$resp_h;
    local ua  = c$http?$user_agent ? c$http$user_agent : "";
    local uri = c$http?$uri ? c$http$uri : "";
    if (ua != "" && is_sus_ua(ua)) {
        NOTICE([$note=Suspicious_UserAgent,
                $msg=fmt("Suspicious UA: %s -> %s UA=%s", src, dst, ua),
                $src=src, $dst=dst, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("ua-%s-%s", src, ua)]);
    }
    if (uri != "") {
        if ([src, uri] !in http_beacon_tracker)
            http_beacon_tracker[src, uri] = 0;
        http_beacon_tracker[src, uri] += 1;
        if (http_beacon_tracker[src, uri] == beacon_threshold) {
            NOTICE([$note=HTTP_C2_Beacon,
                    $msg=fmt("HTTP C2 Beacon: %s -> %s URI=%s count=%d",
                             src, dst, uri, http_beacon_tracker[src, uri]),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("beacon-%s-%s", src, uri)]);
        }
    }
}
EOF
    ok "5 detection scripts deployed (Rules 110001–110005)"
    note "detection-scripts"

    # ── local.zeek ──────────────────────────────────────────
    cat > "$SITE/local.zeek" << LZEEK
# RH Pulsar local.zeek v${PULSAR_VER}
# Platform: ${CLOUD} | OS: ${OS_PRETTY}
@load base/protocols/conn
@load base/protocols/dns
@load base/protocols/http
@load base/protocols/ssl
@load base/protocols/ftp
@load base/protocols/smtp
@load base/frameworks/notice
@load packages
@load ./c2beacon
@load ./dnstunnel
@load ./detect-ja4
@load ./http-c2
@load tuning/json-logs
redef LogAscii::use_json = T;
redef Notice::mail_dest  = "$ALERT_EMAIL";
redef Notice::sendmail   = "/usr/sbin/sendmail";
redef ignore_checksums   = T;
redef Log::default_rotation_interval = 86400secs;
LZEEK

    cat > "$ETC/node.cfg" << EOF
[zeek]
type=standalone
host=localhost
interface=$CAP_IFACE
EOF

    local mgmt_ip
    mgmt_ip=$(ip -4 addr show "$MGMT_IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 || echo "10.0.0.0/8")
    echo "${mgmt_ip}    # ${SENSOR_NAME}" > "$ETC/networks.cfg"

    # ── Interface prep ──────────────────────────────────────
    ip link set "$CAP_IFACE" up
    ip link set "$CAP_IFACE" promisc on
    ethtool -K "$CAP_IFACE" gro off lro off 2>/dev/null || true
    if [[ "$CAP_IFACE" != "$MGMT_IFACE" ]]; then
        ip addr flush dev "$CAP_IFACE" 2>/dev/null || true
        cat > /etc/systemd/system/rh-pulsar-iface.service << EOF
[Unit]
Description=RH Pulsar capture interface
After=network.target
[Service]
Type=oneshot
ExecStart=/sbin/ip link set $CAP_IFACE up
ExecStart=/sbin/ip link set $CAP_IFACE promisc on
ExecStart=/sbin/ip addr flush dev $CAP_IFACE
ExecStart=/sbin/ethtool -K $CAP_IFACE gro off lro off
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        systemctl enable rh-pulsar-iface.service >> "$LOG" 2>&1
        ok "$CAP_IFACE: up, promiscuous, no IP, offload off (persistent)"
    else
        ok "$CAP_IFACE: promiscuous, offload off (IP preserved — testing mode)"
    fi
    note "zeek-config"
}

# ═══════════════════════════════════════════════════════════
# PHASE 5 — SIEM FORWARDER (SIEM agnostic — all 7 supported)
# ═══════════════════════════════════════════════════════════
install_forwarder() {
    phase "SIEM: $SIEM_NAME"

    local ZL="/opt/zeek/logs/current"

    case $SIEM_CHOICE in
    1)  # Wazuh agent
        if dpkg -l wazuh-agent 2>/dev/null | grep -q "^ii"; then
            ok "Wazuh Agent already installed — reconfiguring"
        else
            spinner_start "Installing Wazuh Agent (repo: ${WAZUH_REPO})..."
            curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
                | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import >> "$LOG" 2>&1
            chmod 644 /usr/share/keyrings/wazuh.gpg
            echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/${WAZUH_REPO}/apt/ stable main" \
                > /etc/apt/sources.list.d/wazuh.list
            retry apt-get update -qq >> "$LOG" 2>&1
            WAZUH_MANAGER="$SIEM_HOST" DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wazuh-agent >> "$LOG" 2>&1
            spinner_stop
            note "wazuh-agent"
        fi

        # ossec.conf — idempotent (only add localfile blocks if missing)
        if ! grep -q "rh-pulsar-zeek" /var/ossec/etc/ossec.conf 2>/dev/null; then
            for l in notice conn dns ssl http; do
                cat >> /var/ossec/etc/ossec.conf << EOF
  <localfile>
    <log_format>json</log_format>
    <location>${ZL}/${l}.log</location>
    <label key="rh-pulsar-zeek">${l}</label>
  </localfile>
EOF
            done
        fi
        chmod 640 /var/ossec/etc/ossec.conf
        systemctl enable --now wazuh-agent >> "$LOG" 2>&1

        # Postfix SMTP relay (optional)
        if [[ -n "${SMTP_IP:-}" ]]; then
            postconf -e "relayhost = [${SMTP_IP}]:25"
            postconf -e "myhostname = $SENSOR_NAME"
            postconf -e "inet_interfaces = loopback-only"
            postconf -e "mydestination ="
            systemctl enable --now postfix >> "$LOG" 2>&1
            ok "Postfix relay: ${SMTP_IP}"
        fi
        ok "Wazuh Agent → Manager: $SIEM_HOST"
        ;;

    2)  # Splunk UF
        if [[ -f /opt/splunkforwarder/bin/splunk ]]; then
            ok "Splunk UF already installed — reconfiguring"
        else
            spinner_start "Installing Splunk UF v${SPLUNK_UF_VER}..."
            local DEB="splunkforwarder-${SPLUNK_UF_VER}-${SPLUNK_UF_BUILD}-linux-amd64.deb"
            retry curl -fsSL "https://download.splunk.com/products/universalforwarder/releases/${SPLUNK_UF_VER}/linux/${DEB}" \
                -o "/tmp/${DEB}" >> "$LOG" 2>&1
            DEBIAN_FRONTEND=noninteractive dpkg -i "/tmp/${DEB}" >> "$LOG" 2>&1
            rm -f "/tmp/${DEB}"
            spinner_stop
            note "splunk-uf-${SPLUNK_UF_VER}"
        fi
        mkdir -p /opt/splunkforwarder/etc/system/local
        cat > /opt/splunkforwarder/etc/system/local/outputs.conf << EOF
[httpout:rh-pulsar]
server = $SIEM_HOST:$SPLUNK_PORT
httpEventCollectorToken = $SPLUNK_TOKEN
useSSL = true
EOF
        cat > /opt/splunkforwarder/etc/system/local/inputs.conf << EOF
[monitor://${ZL}/notice.log]
index = rh_pulsar
sourcetype = zeek:notice
[monitor://${ZL}/conn.log]
index = rh_pulsar
sourcetype = zeek:conn
[monitor://${ZL}/dns.log]
index = rh_pulsar
sourcetype = zeek:dns
[monitor://${ZL}/ssl.log]
index = rh_pulsar
sourcetype = zeek:ssl
[monitor://${ZL}/http.log]
index = rh_pulsar
sourcetype = zeek:http
EOF
        chmod 600 /opt/splunkforwarder/etc/system/local/outputs.conf
        /opt/splunkforwarder/bin/splunk start --accept-license --answer-yes --no-prompt >> "$LOG" 2>&1
        /opt/splunkforwarder/bin/splunk enable boot-start >> "$LOG" 2>&1
        ok "Splunk UF → $SIEM_HOST:$SPLUNK_PORT (token secured)"
        ;;

    3)  # Filebeat
        if dpkg -l filebeat 2>/dev/null | grep -q "^ii"; then
            ok "Filebeat already installed — reconfiguring"
        else
            spinner_start "Installing Filebeat ${FILEBEAT_MAJOR}.x..."
            curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
                | gpg --dearmor -o /usr/share/keyrings/elastic.gpg >> "$LOG" 2>&1
            echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/${FILEBEAT_MAJOR}.x/apt stable main" \
                > /etc/apt/sources.list.d/elastic.list
            retry apt-get update -qq >> "$LOG" 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq filebeat >> "$LOG" 2>&1
            spinner_stop
            note "filebeat-${FILEBEAT_MAJOR}.x"
        fi
        cat > /etc/filebeat/filebeat.yml << EOF
filebeat.inputs:
  - type: log
    enabled: true
    paths: [ ${ZL}/*.log ]
    json.keys_under_root: true
    fields:
      sensor: "$SENSOR_NAME"
      platform: rh-pulsar
      cloud: "$CLOUD"
    fields_under_root: true
output.elasticsearch:
  hosts: ["${SIEM_HOST}:${ELASTIC_PORT}"]
  username: "$ELASTIC_USER"
  password: "$ELASTIC_PASS"
  index: "rh-pulsar-%{+yyyy.MM.dd}"
EOF
        chmod 600 /etc/filebeat/filebeat.yml
        systemctl enable --now filebeat >> "$LOG" 2>&1
        ok "Filebeat → ${SIEM_HOST}:${ELASTIC_PORT} (password secured)"
        ;;

    4)  # Sentinel via Azure Monitor Agent (AMA) — MMA is deprecated
        spinner_start "Installing Azure Monitor Agent..."
        # AMA is installed via the Azure VM extension; on bare-metal/non-Azure VM,
        # we fall back to the Log Analytics agent install script which now
        # forwards to AMA where supported.
        if [[ "$CLOUD" == "Azure" ]]; then
            warn "AMA on Azure VMs should be deployed via Azure Policy / Portal — installer cannot do this in-VM"
            warn "Sentinel forwarding will fall back to syslog via rsyslog → AMA on the Azure side"
        fi
        # As a robust fallback, ship logs to a local syslog tag that AMA/MMA can pick up
        cat > /etc/rsyslog.d/30-rh-pulsar-sentinel.conf << EOF
module(load="imfile" PollingInterval="1")
input(type="imfile" File="${ZL}/notice.log" Tag="rh-pulsar-notice" Severity="warning" Facility="local0")
input(type="imfile" File="${ZL}/conn.log"   Tag="rh-pulsar-conn"   Severity="info"    Facility="local0")
input(type="imfile" File="${ZL}/dns.log"    Tag="rh-pulsar-dns"    Severity="info"    Facility="local0")
input(type="imfile" File="${ZL}/ssl.log"    Tag="rh-pulsar-ssl"    Severity="info"    Facility="local0")
input(type="imfile" File="${ZL}/http.log"   Tag="rh-pulsar-http"   Severity="info"    Facility="local0")
EOF
        # Store the workspace creds for the Azure-side AMA DCR
        cat > /etc/rh-pulsar/sentinel.env << EOF
SENTINEL_WS=$SENTINEL_WS
SENTINEL_KEY=$SENTINEL_KEY
EOF
        chmod 600 /etc/rh-pulsar/sentinel.env
        systemctl restart rsyslog >> "$LOG" 2>&1
        spinner_stop
        ok "Sentinel: rsyslog tags set | Configure AMA DCR on Azure side to ingest"
        note "sentinel-rsyslog-tagged"
        ;;

    5)  # QRadar — syslog LEEF
        cat > /etc/rsyslog.d/30-rh-pulsar-qradar.conf << EOF
module(load="imfile" PollingInterval="1")

# Read each Zeek log file
input(type="imfile" File="${ZL}/notice.log" Tag="rh-pulsar-notice")
input(type="imfile" File="${ZL}/conn.log"   Tag="rh-pulsar-conn")
input(type="imfile" File="${ZL}/dns.log"    Tag="rh-pulsar-dns")
input(type="imfile" File="${ZL}/ssl.log"    Tag="rh-pulsar-ssl")
input(type="imfile" File="${ZL}/http.log"   Tag="rh-pulsar-http")

# LEEF 2.0 format wrapper for QRadar
template(name="LEEFFormat" type="string"
    string="<134>%timegenerated% %\$myhostname% LEEF:2.0|RedHorizon|Pulsar|${PULSAR_VER}|%syslogtag%|sev=5\tcat=NDR\tsensor=${SENSOR_NAME}\tmsg=%msg%\n")

if \$syslogtag startswith "rh-pulsar" then {
    action(type="omfwd" Target="$SIEM_HOST" Port="$QRADAR_PORT" Protocol="tcp" Template="LEEFFormat")
}
EOF
        systemctl restart rsyslog >> "$LOG" 2>&1
        ok "Rsyslog (LEEF 2.0) → $SIEM_HOST:$QRADAR_PORT (TCP)"
        note "rsyslog-qradar"
        ;;

    6)  # Syslog Generic — RFC 5424
        local proto; proto=$(echo "${SYSLOG_PROTO:-UDP}" | tr '[:upper:]' '[:lower:]')
        cat > /etc/rsyslog.d/30-rh-pulsar-syslog.conf << EOF
module(load="imfile" PollingInterval="1")
input(type="imfile" File="${ZL}/notice.log" Tag="rh-pulsar-notice" Severity="warning" Facility="local0")
input(type="imfile" File="${ZL}/conn.log"   Tag="rh-pulsar-conn"   Severity="info"    Facility="local0")
input(type="imfile" File="${ZL}/dns.log"    Tag="rh-pulsar-dns"    Severity="info"    Facility="local0")
input(type="imfile" File="${ZL}/ssl.log"    Tag="rh-pulsar-ssl"    Severity="info"    Facility="local0")
input(type="imfile" File="${ZL}/http.log"   Tag="rh-pulsar-http"   Severity="info"    Facility="local0")

if \$syslogtag startswith "rh-pulsar" then {
    action(type="omfwd" Target="$SIEM_HOST" Port="$SYSLOG_PORT" Protocol="$proto"
           Template="RSYSLOG_SyslogProtocol23Format")
}
EOF
        systemctl restart rsyslog >> "$LOG" 2>&1
        ok "Rsyslog (RFC 5424) → $SIEM_HOST:$SYSLOG_PORT ($proto)"
        note "rsyslog-generic"
        ;;

    7)  ok "Standalone — logs stay at $ZL"
        ;;
    esac
}

# ═══════════════════════════════════════════════════════════
# PHASE 6 — DEPLOY + VALIDATE
# ═══════════════════════════════════════════════════════════
deploy_and_validate() {
    phase "DEPLOY & VALIDATE"

    # Deploy Zeek
    spinner_start "Deploying Zeek..."
    /opt/zeek/bin/zeekctl deploy >> "$LOG" 2>&1
    spinner_stop
    ok "Zeek deployed"
    note "zeek-deployed"

    # Watchdog cron — idempotent (replace any existing zeekctl cron line)
    (crontab -l 2>/dev/null | grep -v "zeekctl cron" ; \
     echo "*/5 * * * * /opt/zeek/bin/zeekctl cron") | crontab -
    ok "Watchdog cron enabled (zeekctl runs every 5 min)"

    sleep 5
    local p=0 f=0

    # Zeek running
    if /opt/zeek/bin/zeekctl status 2>/dev/null | grep -q "running"; then
        ok "Zeek: RUNNING"; p=$((p+1))
    else
        fail "Zeek: not running"; f=$((f+1))
    fi

    # Scripts present
    for s in c2beacon dnstunnel detect-ja4 http-c2; do
        if [[ -f "/opt/zeek/share/zeek/site/${s}.zeek" ]]; then
            ok "Script ${s}.zeek: present"; p=$((p+1))
        else
            fail "${s}.zeek: missing"; f=$((f+1))
        fi
    done

    # Promisc check
    if ip link show "$CAP_IFACE" | grep -q "PROMISC"; then
        ok "$CAP_IFACE: promiscuous"; p=$((p+1))
    else
        fail "$CAP_IFACE: not promiscuous"; f=$((f+1))
    fi

    # Real packet capture verification — wait up to 20s for conn.log entries
    spinner_start "Verifying packet capture (waiting for traffic)..."
    local captured=false
    for i in $(seq 1 20); do
        if [[ -s /opt/zeek/logs/current/conn.log ]] && \
           grep -qv "^#" /opt/zeek/logs/current/conn.log 2>/dev/null; then
            captured=true; break
        fi
        sleep 1
    done
    spinner_stop
    if [[ "$captured" == true ]]; then
        ok "Packet capture: WORKING (conn.log has entries)"; p=$((p+1))
    else
        warn "Packet capture: no entries yet — verify with: tail -f ${ZL:-/opt/zeek/logs/current}/conn.log"
        f=$((f+1))
    fi

    # SIEM forwarder validation — real end-to-end check, not just "service running"
    case $SIEM_CHOICE in
        1) systemctl is-active --quiet wazuh-agent && \
               { ok "Wazuh Agent: active"; p=$((p+1)); } || \
               { fail "Wazuh Agent: not active"; f=$((f+1)); }
           # Check connection to manager
           if ss -tn state established "( dport = :1514 )" 2>/dev/null | grep -q "$SIEM_HOST"; then
               ok "Wazuh: connected to manager $SIEM_HOST:1514"; p=$((p+1))
           else
               warn "Wazuh: no active connection to ${SIEM_HOST}:1514 — check firewall + manager enrollment"
           fi ;;
        2) /opt/splunkforwarder/bin/splunk status 2>/dev/null | grep -q "running" && \
               { ok "Splunk UF: running"; p=$((p+1)); } || \
               { fail "Splunk UF: not running"; f=$((f+1)); } ;;
        3) systemctl is-active --quiet filebeat && \
               { ok "Filebeat: active"; p=$((p+1)); } || \
               { fail "Filebeat: not active"; f=$((f+1)); }
           # Test ES reachability
           if curl -sf --connect-timeout 3 -u "${ELASTIC_USER}:${ELASTIC_PASS}" \
              "http://${SIEM_HOST}:${ELASTIC_PORT}" &>/dev/null; then
               ok "Elasticsearch: reachable from sensor"; p=$((p+1))
           else
               warn "Elasticsearch: not reachable — Filebeat will queue logs locally"
           fi ;;
        4) systemctl is-active --quiet rsyslog && \
               { ok "Rsyslog (for AMA): active"; p=$((p+1)); } || \
               { fail "Rsyslog: not active"; f=$((f+1)); } ;;
        5|6) systemctl is-active --quiet rsyslog && \
               { ok "Rsyslog: active"; p=$((p+1)); } || \
               { fail "Rsyslog: not active"; f=$((f+1)); }
           # Test target reachability for TCP
           if [[ "$SIEM_CHOICE" == "5" ]] || [[ "${SYSLOG_PROTO:-UDP}" =~ ^[Tt][Cc][Pp]$ ]]; then
               local port="${QRADAR_PORT:-${SYSLOG_PORT:-514}}"
               if timeout 3 bash -c "</dev/tcp/${SIEM_HOST}/${port}" 2>/dev/null; then
                   ok "SIEM target ${SIEM_HOST}:${port}: reachable (TCP)"; p=$((p+1))
               else
                   warn "SIEM target ${SIEM_HOST}:${port}: unreachable — check firewall"
               fi
           fi ;;
        7) ok "Standalone: no forwarder"; p=$((p+1)) ;;
    esac

    echo ""
    echo -e "  Validation: ${G}${p} passed${N} / ${R}${f} failed${N}"
}

# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════
summary() {
    CURRENT_PHASE="summary"
    mkdir -p /etc/rh-pulsar
    local mac
    mac=$(ip link show "$MGMT_IFACE" 2>/dev/null | awk '/ether/{print $2}' | tr -d ':' | tr '[:lower:]' '[:upper:]' || echo "000000")
    local SENSOR_ID="RHP-${mac:0:6}-$(date +%Y%m%d)"

    echo "$SENSOR_ID"   > /etc/rh-pulsar/sensor_id
    echo "$SIEM_NAME"   > /etc/rh-pulsar/siem
    echo "$SENSOR_NAME" > /etc/rh-pulsar/name
    echo "$PULSAR_VER"  > /etc/rh-pulsar/version
    echo "$CLOUD"       > /etc/rh-pulsar/cloud
    date '+%Y-%m-%d %H:%M:%S' > /etc/rh-pulsar/install_date
    chmod 600 /etc/rh-pulsar/sensor_id 2>/dev/null || true

    local zv; zv=$(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")

    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${G}  RH PULSAR DEPLOYED${N}"
    echo ""
    echo -e "  ${D}Sensor   :${N} ${W}$SENSOR_NAME${N} (${SENSOR_ID})"
    echo -e "  ${D}Version  :${N} ${W}RH Pulsar v${PULSAR_VER}${N}"
    echo -e "  ${D}Platform :${N} ${W}$CLOUD | $OS_PRETTY${N}"
    echo -e "  ${D}SIEM     :${N} ${W}$SIEM_NAME${N}"
    echo -e "  ${D}Zeek     :${N} ${W}v${zv}${N}"
    echo -e "  ${D}Capture  :${N} ${W}$CAP_IFACE${N} | Mgmt: ${W}$MGMT_IFACE${N}"
    echo -e "  ${D}Email    :${N} ${W}$ALERT_EMAIL${N}"
    echo ""
    echo -e "  ${G}[✓]${N} 110001 C2 Beacon       T1071"
    echo -e "  ${G}[✓]${N} 110002 DNS Tunnel       T1071.004"
    echo -e "  ${G}[✓]${N} 110003 Sliver JA4/JA4S  T1573"
    echo -e "  ${G}[✓]${N} 110004 HTTP C2 Beacon   T1071.001"
    echo -e "  ${G}[✓]${N} 110005 Suspicious UA    T1071.001"
    echo ""
    echo -e "  ${D}Logs    : /opt/zeek/logs/current/${N}"
    echo -e "  ${D}Install : $LOG${N}"
    echo -e "  ${D}Validate: sudo bash validate.sh${N}"
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
    echo "[$(ts)] RH Pulsar v${PULSAR_VER} install — DRY_RUN=${DRY_RUN}" >> "$LOG"

    banner
    detect_env
    preflight              # 1
    configure              # 2
    install_platform       # 3
    deploy_scripts         # 4
    install_forwarder      # 5
    deploy_and_validate    # 6
    summary
}

main "$@"
