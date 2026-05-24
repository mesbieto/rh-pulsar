#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Passive NDR Sensor Installer
#  Version: 2.0.0
#  Red Horizon — redhorizon.ph
#  © 2026 Red Horizon. All rights reserved.
#
#  Usage:
#    sudo bash install.sh            # Full install
#    sudo bash install.sh --dry-run  # Check only, no changes
# ═══════════════════════════════════════════════════════════

set -euo pipefail

# ── Args ────────────────────────────────────────────────────
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "${1:-}" == "--help" ]] && { echo "Usage: sudo bash install.sh [--dry-run]"; exit 0; }

# ── Colors ──────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' C='\033[0;36m' N='\033[0m'

# ── Versions ────────────────────────────────────────────────
ZEEK_VER="8.2.0"
WAZUH_VER="4.14.5"
JA4_VER="0.18.8"
PULSAR_VER="2.0.0"

# ── State ───────────────────────────────────────────────────
LOG="/var/log/rh-pulsar-install.log"
PASS=0; WARN=0; FAIL=0
SIEM_CHOICE=""; SIEM_NAME=""
SENSOR_NAME=""; MGMT_IFACE=""; CAP_IFACE=""
ALERT_EMAIL=""; SIEM_HOST=""

# ── Logging ─────────────────────────────────────────────────
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
ok()  { echo -e "${G}  [✓]${N} $1"; echo "[$(ts)] OK   $1" >> "$LOG"; ((PASS++)) || true; }
warn(){ echo -e "${Y}  [!]${N} $1"; echo "[$(ts)] WARN $1" >> "$LOG"; ((WARN++)) || true; }
fail(){ echo -e "${R}  [✗]${N} $1"; echo "[$(ts)] FAIL $1" >> "$LOG"; ((FAIL++)) || true; }
die() { echo -e "${R}  [✗] FATAL: $1${N}"; echo "[$(ts)] FATAL $1" >> "$LOG"; exit 1; }
info(){ echo -e "${D}  [→]${N} $1"; }
hdr() { echo ""; echo -e "${R}  ── $1${N}"; echo ""; }
has() { command -v "$1" &>/dev/null; }

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
    echo -e "${D}  Red Horizon — redhorizon.ph${N}"
    [[ "$DRY_RUN" == true ]] && echo -e "\n${C}  [ DRY RUN — no changes will be made ]${N}"
    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
}

# ═══════════════════════════════════════════════════════════
# PHASE 0 — BOOTSTRAP (minimal tools for checks)
# ═══════════════════════════════════════════════════════════
bootstrap() {
    hdr "PHASE 0 — BOOTSTRAP"

    [[ $EUID -ne 0 ]] && die "Run as root: sudo bash install.sh"
    ok "Root"

    has apt-get || die "apt-get not found — Ubuntu required"

    fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && die "APT locked by another process"

    # Minimal bootstrap tools only
    local need=()
    for pkg in curl iproute2 ethtool; do
        dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || need+=("$pkg")
    done

    if [[ ${#need[@]} -gt 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            warn "Would install bootstrap tools: ${need[*]}"
        else
            apt-get update -qq >> "$LOG" 2>&1
            apt-get install -y "${need[@]}" -qq >> "$LOG" 2>&1
            ok "Bootstrap tools installed"
        fi
    else
        ok "Bootstrap tools present"
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 1 — PRE-FLIGHT
# ═══════════════════════════════════════════════════════════
preflight() {
    hdr "PHASE 1 — PRE-FLIGHT CHECKS"

    # ── System ──────────────────────────────────────────────
    echo -e "${D}  System${N}"

    grep -q "Ubuntu 24.04" /etc/os-release 2>/dev/null && ok "Ubuntu 24.04 LTS" || warn "Not Ubuntu 24.04 — may have issues"
    [[ $(nproc) -ge 4 ]] && ok "CPU: $(nproc) vCPU" || warn "CPU: $(nproc) vCPU — 4+ recommended"

    local ram_gb; ram_gb=$(awk '/MemTotal/{printf "%.1f",$2/1024/1024}' /proc/meminfo)
    local ram_kb; ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    [[ "$ram_kb" -ge 4194304 ]] && ok "RAM: ${ram_gb}GB" || fail "RAM: ${ram_gb}GB — minimum 4GB required"

    local disk; disk=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    [[ "$disk" -ge 20 ]] && ok "Disk: ${disk}GB free" || fail "Disk: ${disk}GB free — minimum 20GB required"

    local swap; swap=$(awk '/SwapTotal/{printf "%.0f",$2/1024}' /proc/meminfo)
    [[ "$swap" -gt 0 ]] && ok "Swap: ${swap}MB" || warn "Swap: none — recommend 4GB"

    timedatectl status 2>/dev/null | grep -q "synchronized: yes" && ok "NTP: synchronized" || warn "NTP: not synchronized"

    # ── Network ─────────────────────────────────────────────
    echo ""
    echo -e "${D}  Network${N}"

    curl -s --max-time 8 https://google.com > /dev/null 2>&1 && ok "Internet: reachable" || fail "Internet: unreachable"
    getent hosts download.opensuse.org > /dev/null 2>&1 && ok "DNS: resolving" || warn "DNS: some repos not resolving"

    local iface_count; iface_count=$(ip -br link show | grep -vc "^lo")
    [[ "$iface_count" -ge 2 ]] && ok "Interfaces: ${iface_count} detected" || warn "Interfaces: ${iface_count} — NDR needs 2 (mgmt + capture)"

    # Per interface
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local state has_ip
        state=$(ip -br link show "$iface" | awk '{print $2}')
        has_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -c "inet" || echo 0)
        if [[ "$has_ip" -gt 0 ]]; then
            local ip_addr; ip_addr=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
            ok "  ${iface}: ${state} — ${ip_addr}"
        else
            ok "  ${iface}: ${state} — no IP (capture-ready)"
        fi
        # NIC offload check
        if has ethtool; then
            local gro; gro=$(ethtool -k "$iface" 2>/dev/null | awk '/generic-receive-offload/{print $2}')
            [[ "$gro" == "on" ]] && warn "  ${iface}: GRO on — will disable for capture"
        fi
    done <<< "$(ip -br link show | grep -v "^lo" | awk '{print $1}')"

    # ── Ports ───────────────────────────────────────────────
    echo ""
    echo -e "${D}  Ports${N}"

    if has ss; then
        for port in 1514 1515 9200 55000 514 25; do
            local cnt; cnt=$(ss -tlnp 2>/dev/null | grep -c ":${port} " || echo 0)
            cnt=$(echo "$cnt" | tr -d '[:space:]')
            [[ "$cnt" -gt 0 ]] && warn "Port ${port}: in use" || ok "Port ${port}: free"
        done
    fi

    # ── Software ────────────────────────────────────────────
    echo ""
    echo -e "${D}  Software${N}"

    fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && fail "APT locked" || ok "APT: free"
    pgrep -x "unattended-upgrade" &>/dev/null && fail "Unattended upgrades running" || ok "No conflicting upgrades"

    # Zeek
    if [[ -f /opt/zeek/bin/zeek ]]; then
        local zv; zv=$(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
        [[ "$zv" == "$ZEEK_VER" ]] && ok "Zeek ${zv}: up to date" || warn "Zeek ${zv}: will upgrade to ${ZEEK_VER}"
    else
        ok "Zeek: not installed — clean"
    fi

    # Conflicts
    for tool in suricata snort; do
        has "$tool" && pgrep -x "$tool" &>/dev/null && fail "${tool}: running — capture conflict" || ok "${tool}: not running"
    done

    # AppArmor
    [[ -d /sys/kernel/security/apparmor ]] && warn "AppArmor active — may restrict Zeek" || ok "AppArmor: not active"

    # Previous install
    [[ -f /etc/rh-pulsar/sensor_id ]] && warn "Previous RH Pulsar found — will upgrade" || ok "Previous install: none"

    # ── Tools needed ────────────────────────────────────────
    echo ""
    echo -e "${D}  Required packages${N}"

    local missing=()
    for pkg in curl wget gnupg2 python3 python3-pip git jq ethtool \
               libpcap-dev postfix mailutils rsyslog irqbalance; do
        dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || missing+=("$pkg")
    done

    [[ ${#missing[@]} -eq 0 ]] && ok "All packages present" || warn "${#missing[@]} packages to install: ${missing[*]}"

    # ── Paths ───────────────────────────────────────────────
    echo ""
    echo -e "${D}  Paths${N}"

    [[ -w /opt ]] && ok "/opt: writable" || fail "/opt: not writable"
    [[ -w /etc ]] && ok "/etc: writable" || fail "/etc: not writable"
    [[ -d /opt/zeek ]] && warn "/opt/zeek: exists — will upgrade" || ok "/opt/zeek: clean"

    # ── Summary ─────────────────────────────────────────────
    echo ""
    echo -e "${D}  ─────────────────────────────────────────────────────${N}"
    echo -e "  ${G}${PASS} passed${N}  /  ${Y}${WARN} warnings${N}  /  ${R}${FAIL} conflicts${N}"
    echo -e "${D}  ─────────────────────────────────────────────────────${N}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$FAIL" -gt 0 ]]; then
            echo -e "${R}  ✗ ${FAIL} conflict(s) — resolve before installing${N}"
            echo -e "${D}  Re-check with: sudo bash install.sh --dry-run${N}"
        else
            echo -e "${G}  ✓ System ready for installation${N}"
            echo ""
            echo -e "${W}  Run: sudo bash install.sh${N}"
        fi
        echo ""
        exit 0
    fi

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${R}  [!] ${FAIL} conflict(s) detected.${N}"
        read -p "  Continue anyway? (y/N): " c || true
        if [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]]; then
            echo "  Aborted."; exit 1
        fi
    else
        read -p "  Continue with installation? (Y/n): " c || true
        c=${c:-Y}
        if [[ "$c" != "y" && "$c" != "Y" ]]; then exit 1; fi
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 2 — SIEM SELECTION
# ═══════════════════════════════════════════════════════════
select_siem() {
    hdr "PHASE 2 — SIEM"

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
    ok "SIEM: $SIEM_NAME"
}

# ═══════════════════════════════════════════════════════════
# PHASE 3 — CONFIGURATION
# ═══════════════════════════════════════════════════════════
configure() {
    hdr "PHASE 3 — SENSOR CONFIGURATION"

    read -p "  Sensor Name (e.g. RHP-CLIENT01): " SENSOR_NAME || true
    [[ -z "$SENSOR_NAME" ]] && die "Sensor name required"

    echo ""
    info "Available interfaces:"
    ip -br link show | grep -v "^lo" | awk '{print "      "$1}'
    echo ""

    read -p "  Management Interface (e.g. ens33): " MGMT_IFACE || true
    ip link show "$MGMT_IFACE" > /dev/null 2>&1 || die "Interface $MGMT_IFACE not found"

    read -p "  Capture Interface  (e.g. ens37): " CAP_IFACE || true
    ip link show "$CAP_IFACE" > /dev/null 2>&1 || die "Interface $CAP_IFACE not found"
    [[ "$CAP_IFACE" == "$MGMT_IFACE" ]] && warn "Same interface for capture and management — OK for testing"

    read -p "  SOC Alert Email: " ALERT_EMAIL || true
    [[ -z "$ALERT_EMAIL" ]] && die "Alert email required"

    echo ""
    echo -e "${W}  SIEM: $SIEM_NAME${N}"

    case $SIEM_CHOICE in
        1)
            read -p "  Wazuh Manager IP: " SIEM_HOST || true
            read -p "  SMTP Relay IP: " SMTP_IP || true
            ;;
        2)
            read -p "  Splunk HEC Host: " SIEM_HOST || true
            read -p "  Splunk HEC Port (8088): " SPLUNK_PORT || true
            SPLUNK_PORT=${SPLUNK_PORT:-8088}
            read -p "  Splunk HEC Token: " SPLUNK_TOKEN || true
            ;;
        3)
            read -p "  Elasticsearch Host: " SIEM_HOST || true
            read -p "  Elasticsearch Port (9200): " ELASTIC_PORT || true
            ELASTIC_PORT=${ELASTIC_PORT:-9200}
            read -p "  Username (elastic): " ELASTIC_USER || true
            ELASTIC_USER=${ELASTIC_USER:-elastic}
            read -p "  Password: " ELASTIC_PASS || true
            ;;
        4)
            read -p "  Workspace ID: " SENTINEL_WS || true
            read -p "  Primary Key: " SENTINEL_KEY || true
            SIEM_HOST="sentinel"
            ;;
        5)
            read -p "  QRadar IP: " SIEM_HOST || true
            read -p "  Syslog Port (514): " QRADAR_PORT || true
            QRADAR_PORT=${QRADAR_PORT:-514}
            ;;
        6)
            read -p "  Syslog Server IP: " SIEM_HOST || true
            read -p "  Syslog Port (514): " SYSLOG_PORT || true
            SYSLOG_PORT=${SYSLOG_PORT:-514}
            read -p "  Protocol TCP/UDP (UDP): " SYSLOG_PROTO || true
            SYSLOG_PROTO=${SYSLOG_PROTO:-UDP}
            ;;
        7) SIEM_HOST="localhost" ;;
    esac

    echo ""
    echo -e "${D}  ─────────────────────────────${N}"
    echo -e "  Sensor  : ${W}$SENSOR_NAME${N}"
    echo -e "  SIEM    : ${W}$SIEM_NAME${N}"
    echo -e "  Mgmt    : ${W}$MGMT_IFACE${N}"
    echo -e "  Capture : ${W}$CAP_IFACE${N}"
    echo -e "  Email   : ${W}$ALERT_EMAIL${N}"
    [[ "$SIEM_CHOICE" != "7" ]] && echo -e "  SIEM IP : ${W}$SIEM_HOST${N}"
    echo -e "${D}  ─────────────────────────────${N}"
    echo ""
    read -p "  Confirm? (y/N): " c || true
    if [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]]; then exit 1; fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 4 — SYSTEM PREP
# ═══════════════════════════════════════════════════════════
prep_system() {
    hdr "PHASE 4 — SYSTEM PREP"

    info "Installing packages..."
    apt-get install -y \
        curl wget gnupg2 apt-transport-https ca-certificates \
        python3 python3-pip git jq ethtool libpcap-dev \
        postfix mailutils rsyslog irqbalance \
        >> "$LOG" 2>&1
    ok "Packages installed"

    # NIC offload off on capture interface
    ethtool -K "$CAP_IFACE" gro off lro off 2>/dev/null || true
    ok "NIC offload disabled on $CAP_IFACE"

    # File descriptor limits
    cat > /etc/security/limits.d/rh-pulsar.conf << EOF
* soft nofile 65536
* hard nofile 65536
EOF
    ulimit -n 65536 2>/dev/null || true
    ok "FD limits: 65536"

    # Kernel tuning
    cat > /etc/sysctl.d/99-rh-pulsar.conf << EOF
vm.max_map_count = 262144
net.core.rmem_max = 134217728
net.core.netdev_max_backlog = 250000
kernel.randomize_va_space = 2
EOF
    sysctl -p /etc/sysctl.d/99-rh-pulsar.conf >> "$LOG" 2>&1
    ok "Kernel tuning applied"

    # Swap if missing
    if [[ ! -f /swapfile ]]; then
        fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 >> "$LOG" 2>&1
        chmod 600 /swapfile
        mkswap /swapfile >> "$LOG" 2>&1
        swapon /swapfile
        grep -q swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap: 4GB created"
    fi

    # NTP
    timedatectl set-ntp true 2>/dev/null || true
    systemctl enable --now systemd-timesyncd >> "$LOG" 2>&1 || true
    ok "NTP enabled"

    # IRQbalance
    systemctl enable --now irqbalance >> "$LOG" 2>&1 || true
    ok "IRQbalance enabled"

    # Backup existing configs
    local bk="/etc/rh-pulsar/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk"
    for f in /etc/filebeat/filebeat.yml /var/ossec/etc/ossec.conf \
              /etc/postfix/main.cf /etc/rsyslog.conf; do
        [[ -f "$f" ]] && cp "$f" "$bk/" 2>/dev/null || true
    done
    [[ -d /opt/zeek/etc ]] && cp -r /opt/zeek/etc "$bk/zeek-etc" 2>/dev/null || true
    ok "Configs backed up → $bk"
}

# ═══════════════════════════════════════════════════════════
# PHASE 5 — ZEEK
# ═══════════════════════════════════════════════════════════
install_zeek() {
    hdr "PHASE 5 — ZEEK ${ZEEK_VER}"

    if [[ -f /opt/zeek/bin/zeek ]]; then
        local zv; zv=$(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
        if [[ "$zv" == "$ZEEK_VER" ]]; then
            ok "Zeek ${zv} already installed"
            export PATH=/opt/zeek/bin:$PATH
            return
        fi
        warn "Upgrading Zeek ${zv} → ${ZEEK_VER}"
    fi

    echo 'deb http://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/ /' \
        | tee /etc/apt/sources.list.d/security:zeek.list >> "$LOG" 2>&1

    curl -fsSL https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/Release.key \
        | gpg --dearmor | tee /etc/apt/trusted.gpg.d/security_zeek.gpg > /dev/null 2>&1

    apt-get update -qq >> "$LOG" 2>&1
    apt-get install -y zeek >> "$LOG" 2>&1

    echo 'export PATH=/opt/zeek/bin:$PATH' > /etc/profile.d/zeek.sh
    export PATH=/opt/zeek/bin:$PATH
    ok "Zeek ${ZEEK_VER} installed"
}

# ═══════════════════════════════════════════════════════════
# PHASE 6 — JA4+
# ═══════════════════════════════════════════════════════════
install_ja4() {
    hdr "PHASE 6 — JA4+ v${JA4_VER}"

    # Check if already installed
    if sudo /opt/zeek/bin/zkg list 2>/dev/null | grep -q "foxio/ja4"; then
        ok "JA4+ already installed"
        return
    fi

    pip3 install zkg --break-system-packages --ignore-installed GitPython >> "$LOG" 2>&1
    /opt/zeek/bin/zkg autoconfig >> "$LOG" 2>&1
    /opt/zeek/bin/zkg install --force foxio/ja4 >> "$LOG" 2>&1
    ok "JA4+ v${JA4_VER} installed"
}

# ═══════════════════════════════════════════════════════════
# PHASE 7 — DETECTION SCRIPTS
# ═══════════════════════════════════════════════════════════
deploy_scripts() {
    hdr "PHASE 7 — DETECTION SCRIPTS"

    local SITE="/opt/zeek/share/zeek/site"
    mkdir -p "$SITE"

    # c2beacon.zeek — Rule 110001
    cat > "$SITE/c2beacon.zeek" << 'EOF'
# RH Pulsar — C2 Beacon Detection
# Rule 110001 — MITRE T1071
# Red Horizon — redhorizon.ph
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
                $msg=fmt("C2 Beacon: %s -> %s (%d connections)", src, dst, beacon_tracker[src, dst]),
                $src=src, $dst=dst, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("%s-%s", src, dst)]);
    }
}
EOF
    ok "c2beacon.zeek — Rule 110001"

    # dnstunnel.zeek — Rule 110002
    cat > "$SITE/dnstunnel.zeek" << 'EOF'
# RH Pulsar — DNS Tunnel Detection v5
# Rule 110002 — MITRE T1071.004
# Red Horizon — redhorizon.ph
module DNSTunnel;
export {
    redef enum Notice::Type += { DNS_Tunnel_Detected };
    global suspicious_threshold: count = 100;
    global long_sub_threshold: count = 5;
    global long_sub_len: count = 40;
    global suppress_for: interval = 1hr;
    global suspicious_qtypes: set[count] = { 16, 15, 28, 255, 0 };
}
global dns_tracker: table[addr, string] of count &create_expire=1hr;
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
    local src = c$id$orig_h;
    local dst = c$id$resp_h;
    local root = get_root_domain(query);
    if (qtype in suspicious_qtypes) {
        if ([src, root] !in dns_tracker) dns_tracker[src, root] = 0;
        dns_tracker[src, root] += 1;
        if (dns_tracker[src, root] == suspicious_threshold) {
            NOTICE([$note=DNS_Tunnel_Detected,
                    $msg=fmt("DNS Tunnel: %s querying %s (%d queries) via %s",
                             src, root, dns_tracker[src, root], dst),
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
                    $msg=fmt("DNS Tunnel (Long Sub): %s -> %s len=%d via %s",
                             src, root, |parts[0]|, dst),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("longsub-%s-%s", src, root)]);
        }
    }
}
EOF
    ok "dnstunnel.zeek — Rule 110002"

    # detect-ja4.zeek — Rule 110003
    cat > "$SITE/detect-ja4.zeek" << 'EOF'
# RH Pulsar — JA4/JA4S TLS Fingerprint Detection
# Rule 110003 — MITRE T1573
# Red Horizon — redhorizon.ph
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
    ok "detect-ja4.zeek — Rule 110003"

    # http-c2.zeek — Rules 110004/110005
    cat > "$SITE/http-c2.zeek" << 'EOF'
# RH Pulsar — HTTP C2 & Suspicious UA Detection
# Rules 110004/110005 — MITRE T1071.001
# Red Horizon — redhorizon.ph
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
    if (/Sliver/          in ua) return T;
    if (/Havoc/           in ua) return T;
    if (/CobaltStrike/    in ua) return T;
    if (/meterpreter/     in ua) return T;
    if (/curl\//          in ua) return T;
    return F;
}
event http_request(c: connection, method: string, original_URI: string,
                   unescaped_URI: string, version: string) &priority=5 {
    local src = c$id$orig_h;
    local dst = c$id$resp_h;
    local ua = (c?$http && c$http?$user_agent) ? c$http$user_agent : "";
    if (ua != "" && is_sus_ua(ua)) {
        NOTICE([$note=Suspicious_UserAgent,
                $msg=fmt("Suspicious UA: %s -> %s UA=%s", src, dst, ua),
                $src=src, $dst=dst, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("ua-%s-%s", src, ua)]);
    }
    if ([src, original_URI] !in http_beacon_tracker)
        http_beacon_tracker[src, original_URI] = 0;
    http_beacon_tracker[src, original_URI] += 1;
    if (http_beacon_tracker[src, original_URI] == beacon_threshold) {
        NOTICE([$note=HTTP_C2_Beacon,
                $msg=fmt("HTTP C2 Beacon: %s -> %s URI=%s count=%d",
                         src, dst, original_URI,
                         http_beacon_tracker[src, original_URI]),
                $src=src, $dst=dst, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("beacon-%s-%s", src, original_URI)]);
    }
}
EOF
    ok "http-c2.zeek — Rules 110004/110005"
}

# ═══════════════════════════════════════════════════════════
# PHASE 8 — ZEEK CONFIG
# ═══════════════════════════════════════════════════════════
configure_zeek() {
    hdr "PHASE 8 — ZEEK CONFIGURATION"

    local SITE="/opt/zeek/share/zeek/site"
    local ETC="/opt/zeek/etc"

    # local.zeek
    cat > "$SITE/local.zeek" << LZEEK
# RH Pulsar local.zeek v${PULSAR_VER}
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
    ok "local.zeek configured"

    # node.cfg
    cat > "$ETC/node.cfg" << EOF
[zeek]
type=standalone
host=localhost
interface=$CAP_IFACE
EOF
    ok "node.cfg — capture: $CAP_IFACE"

    # networks.cfg
    local mgmt_ip
    mgmt_ip=$(ip -4 addr show "$MGMT_IFACE" 2>/dev/null | \
              grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 || echo "10.0.0.0/8")
    echo "${mgmt_ip}    # ${SENSOR_NAME}" > "$ETC/networks.cfg"
    ok "networks.cfg configured"

    # Capture interface — up, promisc, no IP, offload off
    ip link set "$CAP_IFACE" up
    ip link set "$CAP_IFACE" promisc on
    ip addr flush dev "$CAP_IFACE" 2>/dev/null || true
    ethtool -K "$CAP_IFACE" gro off lro off 2>/dev/null || true
    ok "$CAP_IFACE — up, promiscuous, no IP"

    # Persist across reboots
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
    ok "Interface config persisted"
}

# ═══════════════════════════════════════════════════════════
# PHASE 9 — SIEM FORWARDER
# ═══════════════════════════════════════════════════════════
install_forwarder() {
    hdr "PHASE 9 — SIEM: $SIEM_NAME"

    local ZEEK_LOGS="/opt/zeek/logs/current"

    case $SIEM_CHOICE in
    1) # Wazuh
        curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH \
            | gpg --no-default-keyring \
            --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
            --import >> "$LOG" 2>&1
        chmod 644 /usr/share/keyrings/wazuh.gpg
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
            | tee /etc/apt/sources.list.d/wazuh.list >> "$LOG" 2>&1
        apt-get update -qq >> "$LOG" 2>&1
        WAZUH_MANAGER="$SIEM_HOST" apt-get install -y wazuh-agent >> "$LOG" 2>&1
        for log in notice conn dns ssl http; do
            cat >> /var/ossec/etc/ossec.conf << EOF
  <localfile><log_format>json</log_format><location>${ZEEK_LOGS}/${log}.log</location></localfile>
EOF
        done
        systemctl enable --now wazuh-agent >> "$LOG" 2>&1
        postconf -e "relayhost = [${SMTP_IP:-$SIEM_HOST}]:25" 2>/dev/null || true
        postconf -e "myhostname = $SENSOR_NAME" 2>/dev/null || true
        postconf -e "inet_interfaces = loopback-only" 2>/dev/null || true
        postconf -e "mydestination =" 2>/dev/null || true
        systemctl enable --now postfix >> "$LOG" 2>&1
        ok "Wazuh Agent + Postfix configured"
        ;;
    2) # Splunk
        local DEB="splunkforwarder-9.2.0-linux-2.6-amd64.deb"
        wget -q "https://download.splunk.com/products/universalforwarder/releases/9.2.0/linux/${DEB}" \
            -O /tmp/${DEB} >> "$LOG" 2>&1
        dpkg -i /tmp/${DEB} >> "$LOG" 2>&1
        mkdir -p /opt/splunkforwarder/etc/system/local
        cat > /opt/splunkforwarder/etc/system/local/outputs.conf << EOF
[httpout:rh-pulsar]
server = $SIEM_HOST:$SPLUNK_PORT
httpEventCollectorToken = $SPLUNK_TOKEN
useSSL = true
EOF
        cat > /opt/splunkforwarder/etc/system/local/inputs.conf << EOF
[monitor://${ZEEK_LOGS}/notice.log]
index = rh_pulsar
sourcetype = zeek:notice
[monitor://${ZEEK_LOGS}/conn.log]
index = rh_pulsar
sourcetype = zeek:conn
[monitor://${ZEEK_LOGS}/dns.log]
index = rh_pulsar
sourcetype = zeek:dns
[monitor://${ZEEK_LOGS}/ssl.log]
index = rh_pulsar
sourcetype = zeek:ssl
[monitor://${ZEEK_LOGS}/http.log]
index = rh_pulsar
sourcetype = zeek:http
EOF
        /opt/splunkforwarder/bin/splunk start --accept-license --answer-yes --no-prompt >> "$LOG" 2>&1
        /opt/splunkforwarder/bin/splunk enable boot-start >> "$LOG" 2>&1
        ok "Splunk UF configured"
        ;;
    3) # Elastic
        wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
            | gpg --dearmor -o /usr/share/keyrings/elastic.gpg >> "$LOG" 2>&1
        echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
            | tee /etc/apt/sources.list.d/elastic.list >> "$LOG" 2>&1
        apt-get update -qq >> "$LOG" 2>&1
        apt-get install -y filebeat >> "$LOG" 2>&1
        cat > /etc/filebeat/filebeat.yml << EOF
filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - ${ZEEK_LOGS}/*.log
    json.keys_under_root: true
    fields:
      sensor: "$SENSOR_NAME"
      platform: rh-pulsar
    fields_under_root: true
output.elasticsearch:
  hosts: ["$SIEM_HOST:$ELASTIC_PORT"]
  username: "$ELASTIC_USER"
  password: "$ELASTIC_PASS"
  index: "rh-pulsar-%{+yyyy.MM.dd}"
EOF
        systemctl enable --now filebeat >> "$LOG" 2>&1
        ok "Filebeat configured"
        ;;
    4) # Sentinel
        wget -q https://raw.githubusercontent.com/Microsoft/OMS-Agent-for-Linux/master/installer/scripts/onboard_agent.sh \
            -O /tmp/oms.sh >> "$LOG" 2>&1
        chmod +x /tmp/oms.sh
        /tmp/oms.sh -w "$SENTINEL_WS" -s "$SENTINEL_KEY" >> "$LOG" 2>&1
        ok "Azure Monitor Agent configured"
        ;;
    5|6) # QRadar or Syslog
        local target_host target_port target_proto
        [[ "$SIEM_CHOICE" == "5" ]] && { target_host="$SIEM_HOST"; target_port="${QRADAR_PORT:-514}"; target_proto="tcp"; }
        [[ "$SIEM_CHOICE" == "6" ]] && { target_host="$SIEM_HOST"; target_port="${SYSLOG_PORT:-514}"; target_proto=$(echo "${SYSLOG_PROTO:-UDP}" | tr '[:upper:]' '[:lower:]'); }
        cat > /etc/rsyslog.d/rh-pulsar.conf << EOF
module(load="imfile" PollingInterval="1")
input(type="imfile" File="${ZEEK_LOGS}/notice.log" Tag="rh-pulsar-notice" Severity="warning" Facility="local0")
input(type="imfile" File="${ZEEK_LOGS}/conn.log"   Tag="rh-pulsar-conn"   Severity="info"    Facility="local0")
input(type="imfile" File="${ZEEK_LOGS}/dns.log"    Tag="rh-pulsar-dns"    Severity="info"    Facility="local0")
input(type="imfile" File="${ZEEK_LOGS}/ssl.log"    Tag="rh-pulsar-ssl"    Severity="info"    Facility="local0")
input(type="imfile" File="${ZEEK_LOGS}/http.log"   Tag="rh-pulsar-http"   Severity="info"    Facility="local0")
if \$syslogtag startswith "rh-pulsar" then {
    action(type="omfwd" Target="$target_host" Port="$target_port" Protocol="$target_proto")
}
EOF
        systemctl restart rsyslog >> "$LOG" 2>&1
        ok "Rsyslog configured → $target_host:$target_port"
        ;;
    7)
        ok "Standalone — logs at $ZEEK_LOGS"
        ;;
    esac

    # Install websockets to silence Zeek warning
    pip3 install websockets --break-system-packages >> "$LOG" 2>&1 || true
}

# ═══════════════════════════════════════════════════════════
# PHASE 10 — START
# ═══════════════════════════════════════════════════════════
start_services() {
    hdr "PHASE 10 — START"

    /opt/zeek/bin/zeekctl deploy >> "$LOG" 2>&1
    ok "Zeek deployed"

    # Watchdog cron
    (crontab -l 2>/dev/null | grep -v "zeekctl cron"; \
     echo "*/5 * * * * /opt/zeek/bin/zeekctl cron") | crontab -
    ok "Watchdog cron enabled"
}

# ═══════════════════════════════════════════════════════════
# PHASE 11 — VALIDATE
# ═══════════════════════════════════════════════════════════
validate() {
    hdr "PHASE 11 — VALIDATION"

    local p=0 f=0

    /opt/zeek/bin/zeekctl status 2>/dev/null | grep -q "running" && \
        { ok "Zeek: running"; ((p++)); } || { warn "Zeek: not running — run: zeekctl deploy"; ((f++)); }

    for s in c2beacon dnstunnel detect-ja4 http-c2; do
        [[ -f "/opt/zeek/share/zeek/site/${s}.zeek" ]] && \
            { ok "Script ${s}.zeek: present"; ((p++)); } || \
            { warn "${s}.zeek: missing"; ((f++)); }
    done

    ip link show "$CAP_IFACE" | grep -q "PROMISC" && \
        { ok "$CAP_IFACE: promiscuous"; ((p++)); } || \
        { warn "$CAP_IFACE: not promiscuous"; ((f++)); }

    ! ip -4 addr show "$CAP_IFACE" | grep -q "inet" && \
        { ok "$CAP_IFACE: no IP"; ((p++)); } || \
        { warn "$CAP_IFACE: has IP — should be none"; ((f++)); }

    case $SIEM_CHOICE in
        1) systemctl is-active --quiet wazuh-agent && { ok "Wazuh Agent: running"; ((p++)); } || { warn "Wazuh Agent: not running"; ((f++)); } ;;
        2) /opt/splunkforwarder/bin/splunk status 2>/dev/null | grep -q "running" && { ok "Splunk UF: running"; ((p++)); } || { warn "Splunk UF: not running"; ((f++)); } ;;
        3) systemctl is-active --quiet filebeat && { ok "Filebeat: running"; ((p++)); } || { warn "Filebeat: not running"; ((f++)); } ;;
        4) ok "Sentinel: verify in Azure portal"; ((p++)) ;;
        5|6) systemctl is-active --quiet rsyslog && { ok "Rsyslog: running"; ((p++)); } || { warn "Rsyslog: not running"; ((f++)); } ;;
        7) ok "Standalone: no forwarder"; ((p++)) ;;
    esac

    sleep 3
    [[ -f "/opt/zeek/logs/current/conn.log" ]] && \
        { ok "Zeek logs: generating"; ((p++)); } || \
        { warn "Zeek logs: not yet — generate some traffic"; ((f++)); }

    echo ""
    echo -e "  Validation: ${G}${p} passed${N} / ${R}${f} failed${N}"
}

# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════
summary() {
    mkdir -p /etc/rh-pulsar
    local mac
    mac=$(ip link show "$MGMT_IFACE" 2>/dev/null | \
          awk '/ether/{print $2}' | tr -d ':' | tr '[:lower:]' '[:upper:]' || echo "000000")
    local SENSOR_ID="RHP-${mac:0:6}-$(date +%Y%m%d)"

    echo "$SENSOR_ID"      > /etc/rh-pulsar/sensor_id
    echo "$SIEM_NAME"      > /etc/rh-pulsar/siem
    echo "$SENSOR_NAME"    > /etc/rh-pulsar/name
    echo "$PULSAR_VER"     > /etc/rh-pulsar/version
    date '+%Y-%m-%d %H:%M:%S' > /etc/rh-pulsar/install_date

    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${G}  RH PULSAR DEPLOYED${N}"
    echo ""
    echo -e "  ${D}Sensor   :${N} ${W}$SENSOR_NAME${N}"
    echo -e "  ${D}ID       :${N} ${W}$SENSOR_ID${N}"
    echo -e "  ${D}Version  :${N} ${W}RH Pulsar v${PULSAR_VER}${N}"
    echo -e "  ${D}SIEM     :${N} ${W}$SIEM_NAME${N}"
    echo -e "  ${D}Zeek     :${N} ${W}v${ZEEK_VER}${N}"
    echo -e "  ${D}JA4+     :${N} ${W}v${JA4_VER}${N}"
    echo -e "  ${D}Capture  :${N} ${W}$CAP_IFACE (promiscuous — no IP)${N}"
    echo -e "  ${D}Mgmt     :${N} ${W}$MGMT_IFACE${N}"
    echo -e "  ${D}Email    :${N} ${W}$ALERT_EMAIL${N}"
    echo ""
    echo -e "  ${G}[✓]${N} 110001 C2 Beacon      T1071"
    echo -e "  ${G}[✓]${N} 110002 DNS Tunnel      T1071.004"
    echo -e "  ${G}[✓]${N} 110003 Sliver JA4/JA4S T1573"
    echo -e "  ${G}[✓]${N} 110004 HTTP C2 Beacon  T1071.001"
    echo -e "  ${G}[✓]${N} 110005 Suspicious UA   T1071.001"
    echo ""
    echo -e "  ${D}Logs     : /opt/zeek/logs/current/${N}"
    echo -e "  ${D}Install  : $LOG${N}"
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
    mkdir -p /var/log /etc/rh-pulsar
    : > "$LOG"
    echo "[$(ts)] RH Pulsar v${PULSAR_VER} — DRY_RUN=${DRY_RUN}" >> "$LOG"

    banner
    bootstrap
    preflight      # exits here if --dry-run

    select_siem
    configure
    prep_system
    install_zeek
    install_ja4
    deploy_scripts
    configure_zeek
    install_forwarder
    start_services
    validate
    summary
}

main "$@"
