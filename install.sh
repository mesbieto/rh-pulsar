#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Passive NDR Sensor Installer
#  Version: 3.0.0
#  Red Horizon Security — redhorizon.ph
#  © 2026 Red Horizon Security. All rights reserved.
#
#  Usage:
#    sudo bash install.sh            # Full install
#    sudo bash install.sh --dry-run  # Check only
# ═══════════════════════════════════════════════════════════

set -euo pipefail

# ── Args ────────────────────────────────────────────────────
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "${1:-}" == "--help"    ]] && { echo "Usage: sudo bash install.sh [--dry-run]"; exit 0; }

# ── Colors ──────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' C='\033[0;36m' N='\033[0m'

# ── Versions ────────────────────────────────────────────────
ZEEK_VER="8.2.0"
WAZUH_VER="4.14.5"
JA4_VER="0.18.8"
PULSAR_VER="3.0.0"

# ── State ───────────────────────────────────────────────────
LOG="/var/log/rh-pulsar-install.log"
PASS=0; WARN=0; FAIL=0
SIEM_CHOICE=""; SIEM_NAME=""
SENSOR_NAME=""; MGMT_IFACE=""; CAP_IFACE=""
ALERT_EMAIL=""; SIEM_HOST=""
OS_ID=""; OS_VER=""; OS_PRETTY=""
PKG_MGR="apt"; ZEEK_REPO=""
CLOUD="bare-metal"; ARCH=""
SPINNER_PID=""

# ── Logging ─────────────────────────────────────────────────
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
ok()   { echo -e "${G}  [✓]${N} $1"; echo "[$(ts)] OK   $1" >> "$LOG"; ((PASS++)) || true; }
warn() { echo -e "${Y}  [!]${N} $1"; echo "[$(ts)] WARN $1" >> "$LOG"; ((WARN++)) || true; }
fail() { echo -e "${R}  [✗]${N} $1"; echo "[$(ts)] FAIL $1" >> "$LOG"; ((FAIL++)) || true; }
die()  { spinner_stop; echo -e "${R}  FATAL: $1${N}"; exit 1; }
info() { echo -e "${D}  [→]${N} $1"; }
has()  { command -v "$1" &>/dev/null; }

# ── Spinner ─────────────────────────────────────────────────
spinner_start() {
    local msg="${1:-}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    ( local i=0
      while true; do
          printf "\r  ${C}%s${N} %s " "${frames[$((i % 10))]}" "$msg"
          ((i++)) || true; sleep 0.08
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

# ── Progress bar (animated) ──────────────────────────────────
TOTAL_STEPS=7; CURRENT_STEP=0
progress() {
    spinner_stop
    ((CURRENT_STEP++)) || true
    local target=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local prev=$(( (CURRENT_STEP - 1) * 100 / TOTAL_STEPS ))
    echo ""
    echo -e "${R}  ── PHASE ${CURRENT_STEP}/${TOTAL_STEPS} — $1${N}"
    local p=$prev
    while [[ "$p" -le "$target" ]]; do
        local f=$(( p / 5 )) e=$(( 20 - p / 5 )) bar=""
        for ((i=0;i<f;i++)); do bar+="█"; done
        for ((i=0;i<e;i++)); do bar+="░"; done
        printf "\r  ${D}[${G}%s${D}]${N} ${W}%d%%${N} " "$bar" "$p"
        ((p+=3)) || true; sleep 0.02
    done
    local f=$(( target / 5 )) e=$(( 20 - target / 5 )) bar=""
    for ((i=0;i<f;i++)); do bar+="█"; done
    for ((i=0;i<e;i++)); do bar+="░"; done
    printf "\r  ${D}[${G}%s${D}]${N} ${W}%d%%${N} ${G}✓${N}\n\n" "$bar" "$target"
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
# DETECT ENVIRONMENT (runs silently in background where possible)
# ═══════════════════════════════════════════════════════════
detect_env() {
    ARCH=$(uname -m)

    # OS
    if [[ -f /etc/os-release ]]; then
        OS_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_VER=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_PRETTY=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi

    case "${OS_ID}:${OS_VER}" in
        ubuntu:24.04) PKG_MGR="apt"; ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/" ;;
        ubuntu:22.04) PKG_MGR="apt"; ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_22.04/" ;;
        ubuntu:20.04) PKG_MGR="apt"; ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_20.04/" ;;
        debian:12)    PKG_MGR="apt"; ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/Debian_12/" ;;
        debian:11)    PKG_MGR="apt"; ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/Debian_11/" ;;
        rhel:*|centos:*|rocky:*|almalinux:*) PKG_MGR="yum"; ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/CentOS_8/" ;;
        fedora:*)     PKG_MGR="dnf"; ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/Fedora_37/" ;;
        *)            PKG_MGR="apt"; ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/" ;;
    esac

    # Auto-fix broken apt sources
    if [[ "$PKG_MGR" == "apt" ]]; then
        if apt-get update -qq 2>&1 | grep -q "Malformed\|sources could not"; then
            local cn; cn=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 || echo "noble")
            cat > /etc/apt/sources.list.d/ubuntu.sources << EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: ${cn} ${cn}-updates ${cn}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: ${cn}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        fi
    fi

    # Cloud detection (fast — 2s timeout each)
    if curl -s --max-time 2 http://169.254.169.254/latest/meta-data/ami-id &>/dev/null; then
        CLOUD="AWS"
    elif curl -s --max-time 2 -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" &>/dev/null; then
        CLOUD="Azure"
    elif curl -s --max-time 2 -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/ &>/dev/null; then
        CLOUD="GCP"
    elif curl -s --max-time 2 http://169.254.169.254/metadata/v1/id &>/dev/null; then
        CLOUD="DigitalOcean"
    elif curl -s --max-time 2 http://169.254.169.254/v1.json &>/dev/null; then
        CLOUD="Vultr"
    elif grep -qi "vmware" /sys/class/dmi/id/product_name 2>/dev/null; then
        CLOUD="VMware"
    elif grep -qi "virtualbox\|innotek" /sys/class/dmi/id/product_name 2>/dev/null; then
        CLOUD="VirtualBox"
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 1 — PREFLIGHT + BOOTSTRAP
# Merged into one phase for speed
# ═══════════════════════════════════════════════════════════
preflight() {
    progress "ENVIRONMENT CHECK"

    # Root
    [[ $EUID -ne 0 ]] && die "Run as root: sudo bash install.sh"
    ok "Root"

    # APT lock
    [[ "$PKG_MGR" == "apt" ]] && \
        fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && \
        die "APT locked — wait and retry"

    # OS
    ok "OS: ${OS_PRETTY:-unknown} | Arch: ${ARCH} | Platform: ${CLOUD}"

    # Resources
    local cpu ram_kb ram_gb disk swap
    cpu=$(nproc)
    ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    ram_gb=$(awk '/MemTotal/{printf "%.1f",$2/1024/1024}' /proc/meminfo)
    disk=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    swap=$(awk '/SwapTotal/{printf "%.0f",$2/1024}' /proc/meminfo)

    [[ "$cpu"    -ge 2          ]] && ok "CPU: ${cpu} vCPU"       || warn "CPU: ${cpu} — 2+ recommended"
    [[ "$ram_kb" -ge 4194304    ]] && ok "RAM: ${ram_gb}GB"       || fail "RAM: ${ram_gb}GB — min 4GB"
    [[ "$disk"   -ge 20         ]] && ok "Disk: ${disk}GB free"   || fail "Disk: ${disk}GB — min 20GB"
    [[ "$swap"   -gt 0          ]] && ok "Swap: ${swap}MB"        || warn "Swap: none — will create 4GB"

    # Internet
    curl -s --max-time 8 https://google.com &>/dev/null && ok "Internet: reachable" || fail "Internet: unreachable"

    # Interfaces
    local iface_count
    iface_count=$(ip -br link show | grep -vc "^lo")
    [[ "$iface_count" -ge 2 ]] && ok "Interfaces: ${iface_count}" || warn "Interfaces: ${iface_count} — NDR needs 2"

    # Conflicts
    pgrep -x "unattended-upgrade" &>/dev/null && fail "Unattended upgrades running" || ok "No conflicting upgrades"
    for t in suricata snort; do
        pgrep -x "$t" &>/dev/null && fail "${t}: running — capture conflict" || true
    done

    # Previous install
    [[ -f /etc/rh-pulsar/sensor_id ]] && warn "Previous install — will upgrade" || ok "Clean install"

    # Bootstrap tools
    local need=()
    for pkg in curl iproute2 ethtool; do
        dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || need+=("$pkg")
    done
    if [[ ${#need[@]} -gt 0 ]]; then
        [[ "$DRY_RUN" == true ]] && warn "Would install: ${need[*]}" || {
            apt-get update -qq >> "$LOG" 2>&1
            apt-get install -y "${need[@]}" -qq >> "$LOG" 2>&1
            ok "Bootstrap: ${need[*]}"
        }
    fi

    # Summary
    echo ""
    echo -e "  ${D}────────────────────────────────────────${N}"
    echo -e "  ${G}${PASS} passed${N}  ${Y}${WARN} warnings${N}  ${R}${FAIL} conflicts${N}"
    echo -e "  ${D}────────────────────────────────────────${N}"
    echo ""

    [[ "$DRY_RUN" == true ]] && {
        [[ "$FAIL" -gt 0 ]] && echo -e "${R}  ✗ Resolve ${FAIL} conflict(s) first${N}" || \
            echo -e "${G}  ✓ Ready — run: sudo bash install.sh${N}"
        echo ""; exit 0
    }

    if [[ "$FAIL" -gt 0 ]]; then
        read -p "  ${FAIL} conflict(s). Continue anyway? (y/N): " c || true
        [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1
    else
        read -p "  Continue with installation? (Y/n): " c || true
        c=${c:-Y}
        [[ "$c" != "y" && "$c" != "Y" ]] && exit 1
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 2 — SIEM + CONFIGURATION
# Merged: collect all user input before any installation begins
# This allows background pre-downloads during user input
# ═══════════════════════════════════════════════════════════
configure() {
    progress "CONFIGURATION"

    # SIEM selection
    echo -e "${W}  Select SIEM platform:${N}"
    echo ""
    echo -e "  ${C}1)${N} Wazuh + OpenSearch     ${D}(default)${N}"
    echo -e "  ${C}2)${N} Splunk                 ${D}(Universal Forwarder)${N}"
    echo -e "  ${C}3)${N} Elastic / ELK          ${D}(Filebeat)${N}"
    echo -e "  ${C}4)${N} Microsoft Sentinel     ${D}(Azure Monitor Agent)${N}"
    echo -e "  ${C}5)${N} IBM QRadar             ${D}(Syslog)${N}"
    echo -e "  ${C}6)${N} Syslog Generic         ${D}(any syslog SIEM)${N}"
    echo -e "  ${C}7)${N} Standalone             ${D}(Zeek only)${N}"
    echo ""
    case $CLOUD in
        AWS)   info "Detected AWS — Splunk or Elastic recommended" ;;
        Azure) info "Detected Azure — Sentinel recommended" ;;
        VMware|VirtualBox) info "Detected VM — Wazuh recommended" ;;
    esac
    echo ""
    read -p "  Choice (1-7): " SIEM_CHOICE || true
    case $SIEM_CHOICE in
        1) SIEM_NAME="Wazuh + OpenSearch" ;;
        2) SIEM_NAME="Splunk" ;;
        3) SIEM_NAME="Elastic / ELK" ;;
        4) SIEM_NAME="Microsoft Sentinel" ;;
        5) SIEM_NAME="IBM QRadar" ;;
        6) SIEM_NAME="Syslog Generic" ;;
        7) SIEM_NAME="Standalone" ;;
        *) die "Invalid choice" ;;
    esac

    echo ""
    # Sensor identity
    read -p "  Sensor Name (e.g. RHP-CLIENT01): " SENSOR_NAME || true
    [[ -z "$SENSOR_NAME" ]] && die "Sensor name required"

    echo ""
    info "Available interfaces:"
    ip -br link show | grep -v "^lo" | awk '{print "    "$1" "$2" "$3}'
    echo ""

    read -p "  Management Interface (e.g. ens33): " MGMT_IFACE || true
    ip link show "$MGMT_IFACE" &>/dev/null || die "Interface $MGMT_IFACE not found"

    read -p "  Capture Interface  (e.g. ens37): " CAP_IFACE || true
    ip link show "$CAP_IFACE" &>/dev/null || die "Interface $CAP_IFACE not found"
    [[ "$CAP_IFACE" == "$MGMT_IFACE" ]] && warn "Same interface — OK for testing"

    read -p "  SOC Alert Email: " ALERT_EMAIL || true
    [[ -z "$ALERT_EMAIL" ]] && die "Email required"

    echo ""
    echo -e "${W}  SIEM: $SIEM_NAME${N}"
    case $SIEM_CHOICE in
        1) read -p "  Wazuh Manager IP: " SIEM_HOST || true
           read -p "  SMTP Relay IP: " SMTP_IP || true ;;
        2) read -p "  Splunk HEC Host: " SIEM_HOST || true
           read -p "  HEC Port (8088): " SPLUNK_PORT || true; SPLUNK_PORT=${SPLUNK_PORT:-8088}
           read -p "  HEC Token: " SPLUNK_TOKEN || true ;;
        3) read -p "  Elasticsearch Host: " SIEM_HOST || true
           read -p "  Port (9200): " ELASTIC_PORT || true; ELASTIC_PORT=${ELASTIC_PORT:-9200}
           read -p "  Username (elastic): " ELASTIC_USER || true; ELASTIC_USER=${ELASTIC_USER:-elastic}
           read -p "  Password: " ELASTIC_PASS || true ;;
        4) read -p "  Workspace ID: " SENTINEL_WS || true
           read -p "  Primary Key: " SENTINEL_KEY || true; SIEM_HOST="sentinel" ;;
        5) read -p "  QRadar IP: " SIEM_HOST || true
           read -p "  Port (514): " QRADAR_PORT || true; QRADAR_PORT=${QRADAR_PORT:-514} ;;
        6) read -p "  Syslog IP: " SIEM_HOST || true
           read -p "  Port (514): " SYSLOG_PORT || true; SYSLOG_PORT=${SYSLOG_PORT:-514}
           read -p "  Protocol TCP/UDP (UDP): " SYSLOG_PROTO || true; SYSLOG_PROTO=${SYSLOG_PROTO:-UDP} ;;
        7) SIEM_HOST="localhost" ;;
    esac

    echo ""
    echo -e "${D}  ── Summary ───────────────────────────${N}"
    echo -e "  Sensor  : ${W}$SENSOR_NAME${N} | SIEM: ${W}$SIEM_NAME${N}"
    echo -e "  Mgmt    : ${W}$MGMT_IFACE${N} | Capture: ${W}$CAP_IFACE${N}"
    echo -e "  Email   : ${W}$ALERT_EMAIL${N} | Platform: ${W}$CLOUD${N}"
    [[ "$SIEM_CHOICE" != "7" ]] && echo -e "  SIEM IP : ${W}$SIEM_HOST${N}"
    echo -e "${D}  ─────────────────────────────────────${N}"
    echo ""
    read -p "  Confirm? (y/N): " c || true
    if [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]]; then exit 1; fi

    # ── START BACKGROUND PRE-DOWNLOADS ──────────────────────
    # While we proceed, start downloading Zeek repo key in background
    info "Pre-fetching Zeek repository key in background..."
    (
        curl -fsSL "${ZEEK_REPO}Release.key" \
            | gpg --dearmor \
            | tee /etc/apt/trusted.gpg.d/security_zeek.gpg > /dev/null 2>&1
        echo "deb ${ZEEK_REPO} /" \
            | tee /etc/apt/sources.list.d/security:zeek.list >> "$LOG" 2>&1
    ) &
    ZEEK_PREFETCH_PID=$!
    disown "$ZEEK_PREFETCH_PID" 2>/dev/null || true
    ok "Background pre-fetch started"
}

# ═══════════════════════════════════════════════════════════
# PHASE 3 — SYSTEM PREP + ZEEK + JA4
# Merged for speed — parallel where possible
# ═══════════════════════════════════════════════════════════
install_platform() {
    progress "INSTALLING PLATFORM"

    # ── System prep ─────────────────────────────────────────
    spinner_start "Preparing system..."

    # Swap
    local swap; swap=$(awk '/SwapTotal/{printf "%.0f",$2/1024}' /proc/meminfo)
    if [[ "$swap" -eq 0 && ! -f /swapfile ]]; then
        fallocate -l 4G /swapfile 2>/dev/null || \
            dd if=/dev/zero of=/swapfile bs=1M count=4096 >> "$LOG" 2>&1
        chmod 600 /swapfile
        mkswap /swapfile >> "$LOG" 2>&1
        swapon /swapfile
        grep -q swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # Kernel tuning
    cat > /etc/sysctl.d/99-rh-pulsar.conf << EOF
vm.max_map_count = 262144
net.core.rmem_max = 134217728
net.core.netdev_max_backlog = 250000
kernel.randomize_va_space = 2
EOF
    sysctl -p /etc/sysctl.d/99-rh-pulsar.conf >> "$LOG" 2>&1

    # FD limits
    cat > /etc/security/limits.d/rh-pulsar.conf << EOF
* soft nofile 65536
* hard nofile 65536
EOF
    ulimit -n 65536 2>/dev/null || true

    spinner_stop
    ok "System tuned"

    # ── Packages (parallel download + install) ───────────────
    spinner_start "Installing required packages..."

    # Force IPv4 for faster repo resolution in some environments
    local APT_OPTS="-o Acquire::ForceIPv4=true -o Acquire::http::Timeout=30"

    case $PKG_MGR in
        apt)
            apt-get update -qq $APT_OPTS >> "$LOG" 2>&1
            # Install all at once — apt handles parallelism internally
            DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_OPTS \
                curl wget gnupg2 apt-transport-https ca-certificates \
                python3 python3-pip git jq ethtool libpcap-dev \
                postfix mailutils rsyslog irqbalance \
                >> "$LOG" 2>&1
            ;;
        yum|dnf)
            $PKG_MGR install -y \
                curl wget gnupg2 python3 python3-pip git jq ethtool \
                libpcap-devel postfix mailx rsyslog irqbalance \
                >> "$LOG" 2>&1
            ;;
    esac
    spinner_stop
    ok "Packages installed"

    # ── NTP + services ──────────────────────────────────────
    timedatectl set-ntp true 2>/dev/null || true
    systemctl enable --now systemd-timesyncd >> "$LOG" 2>&1 || true
    systemctl enable --now irqbalance >> "$LOG" 2>&1 || true
    ok "NTP + IRQbalance enabled"

    # ── Zeek install ────────────────────────────────────────
    if [[ -f /opt/zeek/bin/zeek ]]; then
        local zv; zv=$(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
        if [[ "$zv" == "$ZEEK_VER" ]]; then
            ok "Zeek ${zv} already installed — skipping"
            export PATH=/opt/zeek/bin:$PATH
        else
            spinner_start "Upgrading Zeek ${zv} → ${ZEEK_VER}..."
            apt-get update -qq $APT_OPTS >> "$LOG" 2>&1
            apt-get install -y zeek >> "$LOG" 2>&1
            spinner_stop
            ok "Zeek ${ZEEK_VER} installed"
        fi
    else
        spinner_start "Installing Zeek ${ZEEK_VER} — takes 2-3 min..."
        # Wait for background prefetch to complete
        wait "${ZEEK_PREFETCH_PID:-}" 2>/dev/null || true
        apt-get update -qq $APT_OPTS >> "$LOG" 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y zeek >> "$LOG" 2>&1
        spinner_stop
        ok "Zeek ${ZEEK_VER} installed"
    fi

    echo 'export PATH=/opt/zeek/bin:$PATH' > /etc/profile.d/zeek.sh
    export PATH=/opt/zeek/bin:$PATH

    # ── JA4+ install ────────────────────────────────────────
    if /opt/zeek/bin/zkg list 2>/dev/null | grep -q "foxio/ja4"; then
        ok "JA4+ already installed — skipping"
    else
        spinner_start "Installing JA4+ v${JA4_VER}..."
        pip3 install zkg --break-system-packages \
            --ignore-installed GitPython -q >> "$LOG" 2>&1
        /opt/zeek/bin/zkg autoconfig >> "$LOG" 2>&1
        /opt/zeek/bin/zkg install --force foxio/ja4 >> "$LOG" 2>&1
        spinner_stop
        ok "JA4+ v${JA4_VER} installed"
    fi

    # Silence websockets warning
    pip3 install websockets --break-system-packages -q >> "$LOG" 2>&1 || true

    # Backup existing configs
    local bk="/etc/rh-pulsar/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk"
    for f in /etc/filebeat/filebeat.yml /var/ossec/etc/ossec.conf \
              /etc/postfix/main.cf /etc/rsyslog.conf; do
        [[ -f "$f" ]] && cp "$f" "$bk/" 2>/dev/null || true
    done
    [[ -d /opt/zeek/etc ]] && cp -r /opt/zeek/etc "$bk/zeek-etc" 2>/dev/null || true
    ok "Configs backed up"
}

# ═══════════════════════════════════════════════════════════
# PHASE 4 — DETECTION SCRIPTS + ZEEK CONFIG
# All scripts deployed + configured in one phase
# ═══════════════════════════════════════════════════════════
deploy_and_configure() {
    progress "DEPLOYING DETECTION ENGINE"

    local SITE="/opt/zeek/share/zeek/site"
    local ETC="/opt/zeek/etc"
    mkdir -p "$SITE"

    # ── c2beacon.zeek — Rule 110001 ─────────────────────────
    cat > "$SITE/c2beacon.zeek" << 'EOF'
# RH Pulsar — C2 Beacon Detection
# Rule 110001 — MITRE T1071
# Red Horizon Security — redhorizon.ph
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
# RH Pulsar — DNS Tunnel Detection v5
# Rule 110002 — MITRE T1071.004
# Red Horizon Security — redhorizon.ph
# Detects: TXT/MX/AAAA/NULL/ANY abuse + long subdomains (any type)
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
    # Classic tunnel record types
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
    # Long subdomain — catches DGA + tunneling regardless of record type
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
# RH Pulsar — JA4/JA4S TLS Fingerprint Detection
# Rule 110003 — MITRE T1573
# Red Horizon Security — redhorizon.ph
# Detects Sliver C2 via TLS fingerprint — works on encrypted traffic
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
    # Uses http_message_done at priority -5 to ensure UA is
    # fully parsed before detection fires. Confirmed working.
    cat > "$SITE/http-c2.zeek" << 'EOF'
# RH Pulsar — HTTP C2 & Suspicious UA Detection
# Rules 110004/110005 — MITRE T1071.001
# Red Horizon Security — redhorizon.ph
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
    if (/curl\//          in ua) return T;
    return F;
}
# http_message_done ensures full HTTP context is available
# before detection — fixes timing issue with http_request
event http_message_done(c: connection, is_orig: bool,
                        stat: http_message_stat) &priority=-5 {
    if (!is_orig) return;
    if (!c?$http) return;
    local src = c$id$orig_h;
    local dst = c$id$resp_h;
    local ua  = c$http?$user_agent ? c$http$user_agent : "";
    local uri = c$http?$uri ? c$http$uri : "";
    # Rule 110005 — Suspicious User-Agent
    if (ua != "" && is_sus_ua(ua)) {
        NOTICE([$note=Suspicious_UserAgent,
                $msg=fmt("Suspicious UA: %s -> %s UA=%s", src, dst, ua),
                $src=src, $dst=dst, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("ua-%s-%s", src, ua)]);
    }
    # Rule 110004 — HTTP C2 Beacon (URI repetition)
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

    ok "All 5 detection scripts deployed"

    # ── Zeek configuration ───────────────────────────────────
    cat > "$SITE/local.zeek" << LZEEK
# RH Pulsar local.zeek v${PULSAR_VER}
# Platform: ${CLOUD} | OS: ${OS_PRETTY}
# Generated: $(date)
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
    mgmt_ip=$(ip -4 addr show "$MGMT_IFACE" 2>/dev/null | \
              grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 || echo "10.0.0.0/8")
    echo "${mgmt_ip}    # ${SENSOR_NAME}" > "$ETC/networks.cfg"

    # Capture interface — up, promisc, no IP (only if dedicated)
    ip link set "$CAP_IFACE" up
    ip link set "$CAP_IFACE" promisc on
    ethtool -K "$CAP_IFACE" gro off lro off 2>/dev/null || true

    if [[ "$CAP_IFACE" != "$MGMT_IFACE" ]]; then
        ip addr flush dev "$CAP_IFACE" 2>/dev/null || true
        # Persist
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
        ok "$CAP_IFACE — up, promiscuous, no IP, offload off"
    else
        ok "$CAP_IFACE — promiscuous, offload off (IP preserved — testing mode)"
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 5 — SIEM FORWARDER
# ═══════════════════════════════════════════════════════════
install_forwarder() {
    progress "SIEM INTEGRATION: $SIEM_NAME"

    local ZL="/opt/zeek/logs/current"

    case $SIEM_CHOICE in
    1) # Wazuh
        spinner_start "Installing Wazuh Agent..."
        curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH \
            | gpg --no-default-keyring \
            --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
            --import >> "$LOG" 2>&1
        chmod 644 /usr/share/keyrings/wazuh.gpg
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
https://packages.wazuh.com/4.x/apt/ stable main" \
            | tee /etc/apt/sources.list.d/wazuh.list >> "$LOG" 2>&1
        apt-get update -qq >> "$LOG" 2>&1
        WAZUH_MANAGER="$SIEM_HOST" apt-get install -y wazuh-agent >> "$LOG" 2>&1
        spinner_stop
        for l in notice conn dns ssl http; do
            echo "  <localfile><log_format>json</log_format><location>${ZL}/${l}.log</location></localfile>" \
                >> /var/ossec/etc/ossec.conf
        done
        systemctl enable --now wazuh-agent >> "$LOG" 2>&1
        postconf -e "relayhost = [${SMTP_IP:-$SIEM_HOST}]:25" 2>/dev/null || true
        postconf -e "myhostname = $SENSOR_NAME" 2>/dev/null || true
        postconf -e "inet_interfaces = loopback-only" 2>/dev/null || true
        postconf -e "mydestination =" 2>/dev/null || true
        systemctl enable --now postfix >> "$LOG" 2>&1
        ok "Wazuh Agent + Postfix — Manager: $SIEM_HOST"
        ;;
    2) # Splunk
        spinner_start "Installing Splunk Universal Forwarder..."
        local DEB="splunkforwarder-9.2.0-linux-2.6-amd64.deb"
        wget -q "https://download.splunk.com/products/universalforwarder/releases/9.2.0/linux/${DEB}" \
            -O /tmp/${DEB} >> "$LOG" 2>&1
        dpkg -i /tmp/${DEB} >> "$LOG" 2>&1
        spinner_stop
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
        /opt/splunkforwarder/bin/splunk start \
            --accept-license --answer-yes --no-prompt >> "$LOG" 2>&1
        /opt/splunkforwarder/bin/splunk enable boot-start >> "$LOG" 2>&1
        ok "Splunk UF — $SIEM_HOST:$SPLUNK_PORT"
        ;;
    3) # Elastic
        spinner_start "Installing Filebeat..."
        wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
            | gpg --dearmor -o /usr/share/keyrings/elastic.gpg >> "$LOG" 2>&1
        echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
            | tee /etc/apt/sources.list.d/elastic.list >> "$LOG" 2>&1
        apt-get update -qq >> "$LOG" 2>&1
        apt-get install -y filebeat >> "$LOG" 2>&1
        spinner_stop
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
  hosts: ["$SIEM_HOST:$ELASTIC_PORT"]
  username: "$ELASTIC_USER"
  password: "$ELASTIC_PASS"
  index: "rh-pulsar-%{+yyyy.MM.dd}"
EOF
        systemctl enable --now filebeat >> "$LOG" 2>&1
        ok "Filebeat — $SIEM_HOST:$ELASTIC_PORT"
        ;;
    4) # Sentinel
        spinner_start "Installing Azure Monitor Agent..."
        wget -q \
            https://raw.githubusercontent.com/Microsoft/OMS-Agent-for-Linux/master/installer/scripts/onboard_agent.sh \
            -O /tmp/oms.sh >> "$LOG" 2>&1
        chmod +x /tmp/oms.sh
        /tmp/oms.sh -w "$SENTINEL_WS" -s "$SENTINEL_KEY" >> "$LOG" 2>&1
        spinner_stop
        ok "Azure Monitor Agent — Workspace: $SENTINEL_WS"
        ;;
    5|6) # QRadar / Syslog
        local tgt_host tgt_port tgt_proto
        [[ "$SIEM_CHOICE" == "5" ]] && {
            tgt_host="$SIEM_HOST"; tgt_port="${QRADAR_PORT:-514}"; tgt_proto="tcp"; }
        [[ "$SIEM_CHOICE" == "6" ]] && {
            tgt_host="$SIEM_HOST"; tgt_port="${SYSLOG_PORT:-514}"
            tgt_proto=$(echo "${SYSLOG_PROTO:-UDP}" | tr '[:upper:]' '[:lower:]'); }
        cat > /etc/rsyslog.d/rh-pulsar.conf << EOF
module(load="imfile" PollingInterval="1")
input(type="imfile" File="${ZL}/notice.log" Tag="rh-pulsar-notice" Severity="warning" Facility="local0")
input(type="imfile" File="${ZL}/conn.log"   Tag="rh-pulsar-conn"   Severity="info"    Facility="local0")
input(type="imfile" File="${ZL}/dns.log"    Tag="rh-pulsar-dns"    Severity="info"    Facility="local0")
input(type="imfile" File="${ZL}/ssl.log"    Tag="rh-pulsar-ssl"    Severity="info"    Facility="local0")
input(type="imfile" File="${ZL}/http.log"   Tag="rh-pulsar-http"   Severity="info"    Facility="local0")
if \$syslogtag startswith "rh-pulsar" then {
    action(type="omfwd" Target="$tgt_host" Port="$tgt_port" Protocol="$tgt_proto")
}
EOF
        systemctl restart rsyslog >> "$LOG" 2>&1
        ok "Rsyslog → $tgt_host:$tgt_port ($tgt_proto)"
        ;;
    7)
        ok "Standalone — logs at $ZL"
        ;;
    esac
}

# ═══════════════════════════════════════════════════════════
# PHASE 6 — DEPLOY + VALIDATE
# ═══════════════════════════════════════════════════════════
deploy_and_validate() {
    progress "DEPLOYING & VALIDATING"

    # Deploy Zeek
    spinner_start "Deploying Zeek sensor..."
    /opt/zeek/bin/zeekctl deploy >> "$LOG" 2>&1
    spinner_stop
    ok "Zeek deployed"

    # Watchdog cron
    (crontab -l 2>/dev/null | grep -v "zeekctl cron"; \
     echo "*/5 * * * * /opt/zeek/bin/zeekctl cron") | crontab -
    ok "Watchdog cron enabled"

    # Wait briefly then validate
    sleep 5

    local p=0 f=0

    /opt/zeek/bin/zeekctl status 2>/dev/null | grep -q "running" && \
        { ok "Zeek: RUNNING"; ((p++)); } || { warn "Zeek: not running"; ((f++)); }

    for s in c2beacon dnstunnel detect-ja4 http-c2; do
        [[ -f "/opt/zeek/share/zeek/site/${s}.zeek" ]] && \
            { ok "Script ${s}.zeek: present"; ((p++)); } || \
            { warn "${s}.zeek: missing"; ((f++)); }
    done

    ip link show "$CAP_IFACE" | grep -q "PROMISC" && \
        { ok "$CAP_IFACE: promiscuous"; ((p++)); } || \
        { warn "$CAP_IFACE: not promiscuous"; ((f++)); }

    case $SIEM_CHOICE in
        1) systemctl is-active --quiet wazuh-agent && \
               { ok "Wazuh Agent: running"; ((p++)); } || \
               { warn "Wazuh Agent: not running"; ((f++)); } ;;
        2) /opt/splunkforwarder/bin/splunk status 2>/dev/null | grep -q "running" && \
               { ok "Splunk UF: running"; ((p++)); } || \
               { warn "Splunk UF: not running"; ((f++)); } ;;
        3) systemctl is-active --quiet filebeat && \
               { ok "Filebeat: running"; ((p++)); } || \
               { warn "Filebeat: not running"; ((f++)); } ;;
        4) ok "Sentinel: verify in Azure portal"; ((p++)) ;;
        5|6) systemctl is-active --quiet rsyslog && \
               { ok "Rsyslog: running"; ((p++)); } || \
               { warn "Rsyslog: not running"; ((f++)); } ;;
        7) ok "Standalone: no forwarder"; ((p++)) ;;
    esac

    echo ""
    echo -e "  Validation: ${G}${p} passed${N} / ${R}${f} failed${N}"
}

# ═══════════════════════════════════════════════════════════
# PHASE 7 — SUMMARY
# ═══════════════════════════════════════════════════════════
summary() {
    progress "COMPLETE"

    mkdir -p /etc/rh-pulsar
    local mac
    mac=$(ip link show "$MGMT_IFACE" 2>/dev/null | \
          awk '/ether/{print $2}' | tr -d ':' | tr '[:lower:]' '[:upper:]' || echo "000000")
    local SENSOR_ID="RHP-${mac:0:6}-$(date +%Y%m%d)"

    echo "$SENSOR_ID"   > /etc/rh-pulsar/sensor_id
    echo "$SIEM_NAME"   > /etc/rh-pulsar/siem
    echo "$SENSOR_NAME" > /etc/rh-pulsar/name
    echo "$PULSAR_VER"  > /etc/rh-pulsar/version
    echo "$CLOUD"       > /etc/rh-pulsar/cloud
    date '+%Y-%m-%d %H:%M:%S' > /etc/rh-pulsar/install_date

    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${G}  RH PULSAR DEPLOYED${N}"
    echo ""
    echo -e "  ${D}Sensor   :${N} ${W}$SENSOR_NAME${N} (${SENSOR_ID})"
    echo -e "  ${D}Version  :${N} ${W}RH Pulsar v${PULSAR_VER}${N}"
    echo -e "  ${D}Platform :${N} ${W}$CLOUD | $OS_PRETTY${N}"
    echo -e "  ${D}SIEM     :${N} ${W}$SIEM_NAME${N}"
    echo -e "  ${D}Zeek     :${N} ${W}v${ZEEK_VER}${N} | JA4+: ${W}v${JA4_VER}${N}"
    echo -e "  ${D}Capture  :${N} ${W}$CAP_IFACE${N} | Mgmt: ${W}$MGMT_IFACE${N}"
    echo -e "  ${D}Email    :${N} ${W}$ALERT_EMAIL${N}"
    echo ""
    echo -e "  ${G}[✓]${N} 110001 C2 Beacon       T1071"
    echo -e "  ${G}[✓]${N} 110002 DNS Tunnel       T1071.004"
    echo -e "  ${G}[✓]${N} 110003 Sliver JA4/JA4S  T1573"
    echo -e "  ${G}[✓]${N} 110004 HTTP C2 Beacon   T1071.001"
    echo -e "  ${G}[✓]${N} 110005 Suspicious UA    T1071.001"
    echo ""
    echo -e "  ${D}Logs   : /opt/zeek/logs/current/${N}"
    echo -e "  ${D}Log    : $LOG${N}"
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
    echo "[$(ts)] RH Pulsar v${PULSAR_VER} — DRY_RUN=${DRY_RUN}" >> "$LOG"

    banner

    # Detect environment silently while banner shows
    detect_env

    preflight          # Phase 1 — check + bootstrap
    configure          # Phase 2 — all user input + background prefetch
    install_platform   # Phase 3 — packages + Zeek + JA4
    deploy_and_configure  # Phase 4 — scripts + Zeek config
    install_forwarder  # Phase 5 — SIEM
    deploy_and_validate   # Phase 6 — deploy + validate
    summary            # Phase 7 — done
}

main "$@"
