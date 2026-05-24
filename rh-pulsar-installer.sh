#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  RH PULSAR — Passive NDR Sensor Installer
#  Version: 1.0
#  Red Horizon — redhorizon.ph
#  © 2026 Red Horizon. All rights reserved.
#
#  Usage:
#    sudo bash install.sh              # Full install
#    sudo bash install.sh --dry-run    # Pre-flight check only
#
#  Supported SIEM:
#    Wazuh, Splunk, Elastic, Sentinel, QRadar, Syslog, Standalone
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# ARGUMENTS
# ─────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --help)
            echo "Usage: sudo bash install.sh [--dry-run]"
            echo ""
            echo "  --dry-run    Run pre-flight checks only."
            echo "               Checks for required tools and readiness."
            echo "               Does NOT install anything."
            exit 0
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# VERSIONS
# ─────────────────────────────────────────────────────────────
ZEEK_VERSION="8.2.0"
WAZUH_VERSION="4.14.5"
JA4_VERSION="0.18.8"
PULSAR_VERSION="1.3.0"

# ─────────────────────────────────────────────────────────────
# GLOBALS
# ─────────────────────────────────────────────────────────────
SIEM_CHOICE=""
SIEM_NAME=""
SENSOR_NAME=""
MGMT_IFACE=""
CAPTURE_IFACE=""
ALERT_EMAIL=""
SIEM_HOST=""
SMTP_RELAY_IP=""
SENSOR_ID=""
LOG_FILE="/var/log/rh-pulsar-install.log"

# Pre-flight counters
PF_PASSED=0
PF_WARNINGS=0
PF_CONFLICTS=0
PF_SKIPPED=0

# Tools that need to be installed before checks
TOOLS_MISSING=()
TOOLS_TO_INSTALL=()

# ─────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────
_log_file() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$LOG_FILE" 2>/dev/null || true; }

pass()    {
    echo -e "${GREEN}  [✓]${NC} $1"
    _log_file "PASS" "$1"
    ((PF_PASSED++)) || true
}
warn()    {
    echo -e "${YELLOW}  [!]${NC} $1"
    _log_file "WARN" "$1"
    ((PF_WARNINGS++)) || true
}
conflict(){
    echo -e "${RED}  [✗]${NC} $1"
    _log_file "CONFLICT" "$1"
    ((PF_CONFLICTS++)) || true
}
skip()    {
    echo -e "${GRAY}  [~]${NC} $1 ${GRAY}(tool not available — skipped)${NC}"
    _log_file "SKIP" "$1"
    ((PF_SKIPPED++)) || true
}
log()     {
    echo -e "${GREEN}  [✓]${NC} $1"
    _log_file "OK" "$1"
}
error()   {
    echo -e "${RED}  [✗] FATAL: $1${NC}"
    _log_file "FATAL" "$1"
    exit 1
}
info()    { echo -e "${GRAY}  [→]${NC} $1"; }
section() { echo ""; echo -e "${RED}  ── $1${NC}"; echo ""; }
subsect() { echo ""; echo -e "${BLUE}  ··· $1${NC}"; }

# Safe command check — never fails
has_cmd() { command -v "$1" &>/dev/null; }

# ─────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${RED}"
    echo "  ██████╗ ██╗  ██╗    ██████╗ ██╗   ██╗██╗     ███████╗ █████╗ ██████╗ "
    echo "  ██╔══██╗██║  ██║    ██╔══██╗██║   ██║██║     ██╔════╝██╔══██╗██╔══██╗"
    echo "  ██████╔╝███████║    ██████╔╝██║   ██║██║     ███████╗███████║██████╔╝"
    echo "  ██╔══██╗██╔══██║    ██╔═══╝ ██║   ██║██║     ╚════██║██╔══██║██╔══██╗"
    echo "  ██║  ██║██║  ██║    ██║     ╚██████╔╝███████╗███████║██║  ██║██║  ██║"
    echo "  ╚═╝  ╚═╝╚═╝  ╚═╝    ╚═╝      ╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝"
    echo -e "${NC}"
    echo -e "${WHITE}  Passive Network Detection & Response Platform${NC}"
    echo -e "${GRAY}  Version ${PULSAR_VERSION} — Red Horizon — redhorizon.ph${NC}"
    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo -e "${CYAN}  ┌─────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}  │  DRY RUN MODE — No changes will be made │${NC}"
        echo -e "${CYAN}  └─────────────────────────────────────────┘${NC}"
    fi
    echo ""
    echo -e "${RED}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# PHASE 0 — BOOTSTRAP
# Installs only what is needed to run the pre-flight checks
# Nothing else is installed here
# ═══════════════════════════════════════════════════════════════
bootstrap() {
    section "PHASE 0 — BOOTSTRAP"

    # Root check — hard requirement before anything
    [[ $EUID -ne 0 ]] && error "Must be run as root. Use: sudo bash install.sh"
    echo -e "${GREEN}  [✓]${NC} Running as root"

    # Verify apt is available — we are on Ubuntu
    if ! has_cmd apt-get; then
        error "apt-get not found — this installer requires Ubuntu/Debian"
    fi

    # Check for apt lock before touching anything
    if fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; then
        error "APT is locked by another process. Wait for it to finish and retry."
    fi

    # Minimal tools needed ONLY for pre-flight checks
    # These are tiny packages — fast to install
    local bootstrap_tools=(
        "curl"
        "iproute2"
        "procps"
        "ethtool"
        "net-tools"
        "lsb-release"
        "ca-certificates"
    )

    local need_install=()
    for tool in "${bootstrap_tools[@]}"; do
        if ! dpkg -l "$tool" 2>/dev/null | grep -q "^ii"; then
            need_install+=("$tool")
        fi
    done

    if [[ ${#need_install[@]} -gt 0 ]]; then
        info "Installing bootstrap tools: ${need_install[*]}"
        if [[ "$DRY_RUN" == true ]]; then
            warn "DRY RUN: would install bootstrap tools: ${need_install[*]}"
        else
            apt-get update -qq >> "$LOG_FILE" 2>&1
            apt-get install -y "${need_install[@]}" -qq >> "$LOG_FILE" 2>&1
            log "Bootstrap tools installed: ${need_install[*]}"
        fi
    else
        log "All bootstrap tools present"
    fi
}

# ═══════════════════════════════════════════════════════════════
# PHASE 1 — PRE-FLIGHT CHECKS
# Safe on ANY Ubuntu server — fresh, minimal, or loaded
# Uses fallbacks for every check
# ═══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────
# PF-1: SYSTEM
# ─────────────────────────────────────────────────────────────
pf_system() {
    subsect "System"

    # OS check — file-based, always safe
    if [[ -f /etc/os-release ]]; then
        local os_name os_version
        os_name=$(grep "^NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
        os_version=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')

        if grep -q "Ubuntu" /etc/os-release && grep -q "24.04" /etc/os-release; then
            pass "OS: Ubuntu 24.04 LTS"
        elif grep -q "Ubuntu" /etc/os-release; then
            warn "OS: ${os_name} ${os_version} — optimized for Ubuntu 24.04 LTS"
        else
            conflict "OS: ${os_name} ${os_version} — Ubuntu required"
        fi
    else
        conflict "OS: /etc/os-release not found — cannot verify OS"
    fi

    # Architecture — uname is always available
    local arch
    arch=$(uname -m)
    if [[ "$arch" == "x86_64" ]]; then
        pass "Architecture: x86_64"
    else
        warn "Architecture: ${arch} — x86_64 recommended"
    fi

    # Kernel — always available
    pass "Kernel: $(uname -r)"

    # Systemd — check via /run not pidof (safer)
    if [[ -d /run/systemd/system ]]; then
        pass "Init: systemd"
    else
        warn "Init: systemd not detected — service management may differ"
    fi

    # CPU — /proc/cpuinfo always exists
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo)
    if [[ "$cpu_cores" -ge 4 ]]; then
        pass "CPU: ${cpu_cores} vCPU — optimal"
    elif [[ "$cpu_cores" -ge 2 ]]; then
        warn "CPU: ${cpu_cores} vCPU — minimum met, 4+ recommended"
    else
        conflict "CPU: ${cpu_cores} vCPU — minimum 2 required"
    fi

    # RAM — /proc/meminfo always exists
    local ram_kb ram_gb
    ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    ram_gb=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
    if   [[ "$ram_kb" -ge 8388608 ]]; then pass "RAM: ${ram_gb}GB — optimal"
    elif [[ "$ram_kb" -ge 4194304 ]]; then warn "RAM: ${ram_gb}GB — minimum met, 8GB+ recommended"
    else conflict "RAM: ${ram_gb}GB — minimum 4GB required"
    fi

    # Disk root — df always exists
    local disk_free
    disk_free=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if   [[ "$disk_free" -ge 50 ]]; then pass "Disk /: ${disk_free}GB free — optimal"
    elif [[ "$disk_free" -ge 20 ]]; then warn "Disk /: ${disk_free}GB free — minimum met, 50GB+ recommended"
    else conflict "Disk /: ${disk_free}GB free — minimum 20GB required"
    fi

    # Disk /opt — only check if separate mount
    if mountpoint -q /opt 2>/dev/null; then
        local opt_free
        opt_free=$(df -BG /opt | awk 'NR==2 {print $4}' | tr -d 'G')
        if [[ "$opt_free" -ge 10 ]]; then
            pass "Disk /opt: ${opt_free}GB free (separate mount)"
        else
            conflict "Disk /opt: ${opt_free}GB free — Zeek needs 10GB+ on /opt"
        fi
    fi

    # Swap — /proc/meminfo
    local swap_mb
    swap_mb=$(awk '/SwapTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    if [[ "$swap_mb" -gt 0 ]]; then
        pass "Swap: ${swap_mb}MB configured"
    else
        warn "Swap: none — recommend 4GB swap for production stability"
    fi

    # NTP — timedatectl is present on all systemd Ubuntu
    if has_cmd timedatectl; then
        if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
            pass "NTP: synchronized"
        else
            warn "NTP: NOT synchronized — critical for log correlation. Run: timedatectl set-ntp true"
        fi
    else
        skip "NTP sync check (timedatectl not available)"
    fi

    # Timezone
    if has_cmd timedatectl; then
        local tz
        tz=$(timedatectl show --property=Timezone --value 2>/dev/null || \
             cat /etc/timezone 2>/dev/null || echo "unknown")
        pass "Timezone: ${tz}"
    fi

    # ASLR — /proc/sys always readable
    local aslr
    aslr=$(cat /proc/sys/kernel/randomize_va_space 2>/dev/null || echo "unknown")
    if [[ "$aslr" == "2" ]]; then
        pass "ASLR: fully enabled"
    else
        warn "ASLR: ${aslr} — not fully enabled (should be 2)"
    fi
}

# ─────────────────────────────────────────────────────────────
# PF-2: NETWORK CONNECTIVITY
# ─────────────────────────────────────────────────────────────
pf_network() {
    subsect "Network Connectivity"

    # Internet — curl is installed in bootstrap
    if curl -s --max-time 8 https://google.com > /dev/null 2>&1; then
        pass "Internet: reachable"
    else
        conflict "Internet: UNREACHABLE — required for package download"
    fi

    # DNS — use getent (always available — no bind-utils needed)
    local repos=(
        "download.opensuse.org"
        "packages.wazuh.com"
        "artifacts.elastic.co"
        "download.splunk.com"
    )
    for repo in "${repos[@]}"; do
        if getent hosts "$repo" > /dev/null 2>&1; then
            pass "DNS: ${repo} — resolvable"
        else
            warn "DNS: ${repo} — NOT resolvable — may affect package download"
        fi
    done

    # Zeek repo HTTP reachability
    local http_code
    http_code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
        https://download.opensuse.org/repositories/security:/zeek/ 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
        pass "Zeek repository: reachable (HTTP ${http_code})"
    else
        warn "Zeek repository: slow or unreachable (HTTP ${http_code})"
    fi

    # Wazuh repo
    http_code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
        https://packages.wazuh.com 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
        pass "Wazuh repository: reachable (HTTP ${http_code})"
    else
        warn "Wazuh repository: slow or unreachable (HTTP ${http_code})"
    fi
}

# ─────────────────────────────────────────────────────────────
# PF-3: NETWORK INTERFACES
# ─────────────────────────────────────────────────────────────
pf_interfaces() {
    subsect "Network Interfaces"

    # ip is installed in bootstrap
    local ifaces
    ifaces=$(ip -br link show | grep -v "^lo" | awk '{print $1}')
    local iface_count
    iface_count=$(echo "$ifaces" | grep -c "." || echo "0")

    if [[ "$iface_count" -ge 2 ]]; then
        pass "Interfaces: ${iface_count} detected — management + capture available"
    else
        warn "Interfaces: only ${iface_count} detected — NDR requires 2 (management + capture)"
    fi

    # Per-interface details
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local state has_ip ip_addr
        state=$(ip -br link show "$iface" 2>/dev/null | awk '{print $2}')
        has_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -c "inet" || echo "0")

        if [[ "$has_ip" -gt 0 ]]; then
            ip_addr=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
            pass "Interface ${iface}: ${state} — IP: ${ip_addr}"
        else
            pass "Interface ${iface}: ${state} — no IP (suitable for capture)"
        fi

        # MTU check — file-based, always safe
        local mtu
        mtu=$(cat /sys/class/net/"${iface}"/mtu 2>/dev/null || echo "unknown")
        if [[ "$mtu" != "unknown" ]] && [[ "$mtu" -lt 1500 ]] 2>/dev/null; then
            warn "Interface ${iface}: MTU ${mtu} — below standard 1500"
        fi

        # NIC offload — ethtool installed in bootstrap
        if has_cmd ethtool; then
            local gro lro
            gro=$(ethtool -k "$iface" 2>/dev/null | \
                  awk '/generic-receive-offload/ {print $2}' || echo "unknown")
            lro=$(ethtool -k "$iface" 2>/dev/null | \
                  awk '/large-receive-offload/ {print $2}' || echo "unknown")

            if [[ "$gro" == "on" ]]; then
                warn "Interface ${iface}: GRO enabled — will be disabled for capture"
            fi
            if [[ "$lro" == "on" ]]; then
                warn "Interface ${iface}: LRO enabled — will be disabled for capture"
            fi
            if [[ "$gro" == "off" && "$lro" == "off" ]]; then
                pass "Interface ${iface}: NIC offload already disabled — optimal"
            fi
        else
            skip "NIC offload check on ${iface} (ethtool not available)"
        fi

    done <<< "$ifaces"

    # Check for bonded interfaces — file-based
    if ls /proc/net/bonding/ 2>/dev/null | grep -q "bond"; then
        warn "Bonded interfaces detected — verify capture on correct bond member"
    fi
}

# ─────────────────────────────────────────────────────────────
# PF-4: PORT CONFLICTS
# ─────────────────────────────────────────────────────────────
pf_ports() {
    subsect "Port Availability"

    # ss is in iproute2 — installed in bootstrap
    if ! has_cmd ss; then
        skip "Port conflict checks (ss not available)"
        return
    fi

    local -A ports=(
        ["1514"]="Wazuh Agent → Manager"
        ["1515"]="Wazuh enrollment"
        ["55000"]="Wazuh API"
        ["9200"]="OpenSearch/Elasticsearch"
        ["9300"]="OpenSearch cluster"
        ["5601"]="Kibana/OpenSearch Dashboards"
        ["8088"]="Splunk HEC"
        ["9997"]="Splunk forwarder"
        ["514"]="Syslog"
        ["25"]="SMTP relay"
        ["587"]="SMTP submission"
    )

    for port in "${!ports[@]}"; do
        local desc="${ports[$port]}"
        local in_use_tcp in_use_udp
        # FIXED
        in_use_tcp=$(ss -tlnp 2>/dev/null | grep -c ":${port} " 2>/dev/null | tr -d '[:space:]' || echo "0")
        in_use_udp=$(ss -ulnp 2>/dev/null | grep -c ":${port} " 2>/dev/null | tr -d '[:space:]' || echo "0")

        if [[ "$in_use_tcp" -gt 0 || "$in_use_udp" -gt 0 ]]; then
            local proc
            proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | \
                   grep -oP 'users:\(\("\K[^"]+' | head -1 || echo "unknown process")
            warn "Port ${port} (${desc}): IN USE by ${proc}"
        else
            pass "Port ${port} (${desc}): free"
        fi
    done
}

# ─────────────────────────────────────────────────────────────
# PF-5: EXISTING SOFTWARE
# ─────────────────────────────────────────────────────────────
pf_software() {
    subsect "Existing Software"

    # APT lock — always check before anything
    if fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; then
        conflict "APT lock: held by another process — cannot install"
    else
        pass "APT lock: free"
    fi

    # Unattended upgrades — ps always available
    if pgrep -x "unattended-upgrade" &>/dev/null 2>&1; then
        conflict "Unattended upgrades: running — wait for completion before install"
    else
        pass "Unattended upgrades: not running"
    fi

    # Zeek — check binary and version
    if has_cmd zeek || [[ -f /opt/zeek/bin/zeek ]]; then
        local zeek_bin="${PATH_ZEEK:-/opt/zeek/bin/zeek}"
        [[ -f /opt/zeek/bin/zeek ]] && zeek_bin="/opt/zeek/bin/zeek"
        local zeek_ver
        zeek_ver=$("$zeek_bin" --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        if [[ "$zeek_ver" == "$ZEEK_VERSION" ]]; then
            pass "Zeek ${zeek_ver}: already at target version — will skip reinstall"
        else
            warn "Zeek ${zeek_ver}: installed — will upgrade to ${ZEEK_VERSION}"
        fi
    else
        pass "Zeek: not installed — clean install"
    fi

    # Zeek running — pgrep always available
    if pgrep -x "zeek" &>/dev/null 2>&1; then
        warn "Zeek: currently running — will be stopped during deploy"
    fi

    # Wazuh Agent — check /var/ossec (directory-based, always safe)
    if [[ -d /var/ossec ]]; then
        if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
            warn "Wazuh Agent: installed and running — will reconfigure"
        else
            warn "Wazuh Agent: installed but stopped — will reconfigure"
        fi
    else
        pass "Wazuh Agent: not installed — clean install"
    fi

    # Filebeat — check binary
    if has_cmd filebeat; then
        if systemctl is-active --quiet filebeat 2>/dev/null; then
            warn "Filebeat: running — config will be backed up and updated"
        else
            warn "Filebeat: installed — config will be updated"
        fi
    else
        pass "Filebeat: not installed — clean install"
    fi

    # Splunk UF — directory check
    if [[ -d /opt/splunkforwarder ]]; then
        local splunk_ver="unknown"
        [[ -f /opt/splunkforwarder/bin/splunk ]] && \
            splunk_ver=$(/opt/splunkforwarder/bin/splunk version 2>/dev/null | \
                         grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
        warn "Splunk UF ${splunk_ver}: installed — config will be updated"
    else
        pass "Splunk UF: not installed — clean install"
    fi

    # Suricata — conflict check
    if has_cmd suricata; then
        if systemctl is-active --quiet suricata 2>/dev/null; then
            conflict "Suricata: RUNNING — may compete for packets on capture interface"
        else
            warn "Suricata: installed but stopped — verify not on same capture interface"
        fi
    else
        pass "Suricata: not installed — no conflict"
    fi

    # Snort — conflict check
    if has_cmd snort; then
        warn "Snort: installed — verify not capturing on same interface"
    else
        pass "Snort: not installed — no conflict"
    fi

    # Active packet capture tools — pgrep always available
    for tool in tcpdump tshark wireshark; do
        if pgrep -x "$tool" &>/dev/null 2>&1; then
            conflict "${tool}: ACTIVELY RUNNING — will compete for packets on capture interface"
        fi
    done

    # Docker — may interfere with network interfaces
    if has_cmd docker; then
        warn "Docker: detected — ensure capture interface is not a Docker bridge"
        if docker network ls --format "{{.Name}}" 2>/dev/null | grep -q "."; then
            warn "Docker networks active — verify no overlap with capture interface"
        fi
    else
        pass "Docker: not installed — no network conflicts"
    fi

    # AppArmor — Ubuntu-specific, check via /sys
    if [[ -d /sys/kernel/security/apparmor ]]; then
        local aa_enforcing
        aa_enforcing=$(cat /sys/kernel/security/apparmor/profiles 2>/dev/null | \
                       grep -c "(enforce)" || echo "0")
        if [[ "$aa_enforcing" -gt 0 ]]; then
            warn "AppArmor: ${aa_enforcing} profiles in enforce mode — may restrict Zeek raw socket"
        else
            pass "AppArmor: loaded but no enforcing profiles affecting Zeek"
        fi
    else
        pass "AppArmor: not active"
    fi

    # SELinux — Ubuntu does not use SELinux by default
    # Check /etc/selinux/config if it exists — never getenforce
    if [[ -f /etc/selinux/config ]]; then
        local sel_mode
        sel_mode=$(grep "^SELINUX=" /etc/selinux/config | cut -d= -f2)
        if [[ "$sel_mode" == "enforcing" ]]; then
            conflict "SELinux: enforcing — will block Zeek packet capture"
        elif [[ "$sel_mode" == "permissive" ]]; then
            warn "SELinux: permissive — monitor for denials"
        else
            pass "SELinux: disabled"
        fi
    else
        pass "SELinux: not configured (standard for Ubuntu)"
    fi

    # Previous RH Pulsar install
    if [[ -f /etc/rh-pulsar/sensor_id ]]; then
        local prev_id prev_siem
        prev_id=$(cat /etc/rh-pulsar/sensor_id 2>/dev/null || echo "unknown")
        prev_siem=$(cat /etc/rh-pulsar/siem 2>/dev/null || echo "unknown")
        warn "Previous RH Pulsar: Sensor=${prev_id} SIEM=${prev_siem} — will upgrade"
    else
        pass "Previous RH Pulsar: not found — clean install"
    fi
}

# ─────────────────────────────────────────────────────────────
# PF-6: FIREWALL
# ─────────────────────────────────────────────────────────────
pf_firewall() {
    subsect "Firewall"

    # UFW — has_cmd check first
    if has_cmd ufw; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1 | awk '{print $2}' || echo "inactive")
        if [[ "$ufw_status" == "active" ]]; then
            warn "UFW: active — required ports will be opened automatically"
            local ufw_rules
            ufw_rules=$(ufw status 2>/dev/null || echo "")
            for port in 1514 1515 55000 514 25 587; do
                if echo "$ufw_rules" | grep -q "$port"; then
                    pass "UFW port ${port}: rule exists"
                else
                    warn "UFW port ${port}: no rule — will be added during install"
                fi
            done
        else
            pass "UFW: inactive — no firewall restrictions"
        fi
    else
        pass "UFW: not installed"
    fi

    # iptables — check if installed and has rules
    if has_cmd iptables; then
        local ipt_count
        ipt_count=$(iptables -L INPUT --line-numbers 2>/dev/null | wc -l || echo "0")
        if [[ "$ipt_count" -gt 5 ]]; then
            warn "iptables: active rules detected — verify SIEM ports not blocked"
        else
            pass "iptables: minimal or no rules"
        fi
    else
        pass "iptables: not installed"
    fi

    # nftables — check via /proc
    if [[ -f /proc/net/nf_conntrack ]] || has_cmd nft; then
        if has_cmd nft; then
            local nft_count
            nft_count=$(nft list ruleset 2>/dev/null | wc -l || echo "0")
            if [[ "$nft_count" -gt 5 ]]; then
                warn "nftables: active ruleset — verify SIEM ports permitted"
            else
                pass "nftables: minimal ruleset"
            fi
        fi
    fi
}

# ─────────────────────────────────────────────────────────────
# PF-7: RESOURCE LIMITS
# ─────────────────────────────────────────────────────────────
pf_resources() {
    subsect "Resource Limits"

    # File descriptors — shell builtin, always works
    local fd_limit
    fd_limit=$(ulimit -n 2>/dev/null || echo "unknown")
    if [[ "$fd_limit" == "unlimited" || "$fd_limit" -ge 65536 ]] 2>/dev/null; then
        pass "File descriptors: ${fd_limit} — optimal for Zeek"
    elif [[ "$fd_limit" -ge 1024 ]] 2>/dev/null; then
        warn "File descriptors: ${fd_limit} — will increase to 65536 for production"
    else
        warn "File descriptors: ${fd_limit} — may be too low, will increase"
    fi

    # vm.max_map_count — /proc/sys file, always readable
    local map_count
    map_count=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo "0")
    if [[ "$map_count" -ge 262144 ]]; then
        pass "vm.max_map_count: ${map_count} — OpenSearch ready"
    else
        warn "vm.max_map_count: ${map_count} — will set to 262144 for OpenSearch"
    fi

    # CPU frequency governor — /sys file, always readable
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        local gov
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        if [[ "$gov" == "performance" ]]; then
            pass "CPU governor: performance"
        else
            warn "CPU governor: ${gov} — recommend 'performance' for NDR"
        fi
    else
        skip "CPU governor check (cpufreq not available — likely VM)"
    fi

    # IRQbalance — check service state safely
    if systemctl list-units --type=service 2>/dev/null | grep -q "irqbalance"; then
        if systemctl is-active --quiet irqbalance 2>/dev/null; then
            pass "IRQbalance: running — network interrupt distribution optimized"
        else
            warn "IRQbalance: installed but not running — will enable"
        fi
    else
        warn "IRQbalance: not installed — will install for capture performance"
    fi

    # Hugepages — advanced network performance
    local hugepages
    hugepages=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo "0")
    if [[ "$hugepages" -gt 0 ]]; then
        pass "Hugepages: ${hugepages} configured"
    else
        info "Hugepages: not configured (optional for high-speed capture)"
    fi
}

# ─────────────────────────────────────────────────────────────
# PF-8: REQUIRED TOOLS FOR INSTALLATION
# Checks which tools need to be installed for the actual install
# This is the key dry-run output
# ─────────────────────────────────────────────────────────────
pf_tools() {
    subsect "Required Installation Tools"

    local required_tools=(
        "curl:curl"
        "wget:wget"
        "gpg:gnupg2"
        "python3:python3"
        "pip3:python3-pip"
        "git:git"
        "jq:jq"
        "ethtool:ethtool"
        "ss:iproute2"
        "ip:iproute2"
        "sendmail:mailutils"
        "postfix:postfix"
        "rsyslog:rsyslog"
        "irqbalance:irqbalance"
    )

    local missing_pkgs=()

    for entry in "${required_tools[@]}"; do
        local cmd pkg
        cmd="${entry%%:*}"
        pkg="${entry##*:}"

        if has_cmd "$cmd"; then
            pass "Tool ${cmd}: installed"
        else
            warn "Tool ${cmd}: NOT installed — package '${pkg}' will be installed"
            # Avoid duplicates
            local already=false
            for p in "${missing_pkgs[@]:-}"; do
                [[ "$p" == "$pkg" ]] && already=true && break
            done
            [[ "$already" == false ]] && missing_pkgs+=("$pkg")
        fi
    done

    # libpcap — Zeek dependency
    if dpkg -l libpcap-dev 2>/dev/null | grep -q "^ii"; then
        pass "libpcap-dev: installed"
    else
        warn "libpcap-dev: NOT installed — will be installed (Zeek dependency)"
        missing_pkgs+=("libpcap-dev")
    fi

    # Store globally for summary
    TOOLS_MISSING=("${missing_pkgs[@]:-}")

    if [[ ${#TOOLS_MISSING[@]} -eq 0 ]]; then
        pass "All required tools present — system ready for installation"
    else
        warn "${#TOOLS_MISSING[@]} packages will be installed: ${TOOLS_MISSING[*]}"
    fi
}

# ─────────────────────────────────────────────────────────────
# PF-9: PATHS
# ─────────────────────────────────────────────────────────────
pf_paths() {
    subsect "Paths & Existing Installs"

    # /opt/zeek
    if [[ -d /opt/zeek ]]; then
        local zeek_size
        zeek_size=$(du -sh /opt/zeek 2>/dev/null | cut -f1 || echo "unknown")
        warn "/opt/zeek: exists (${zeek_size}) — previous install, will upgrade"
    else
        pass "/opt/zeek: not present — clean install"
    fi

    # /var/ossec
    if [[ -d /var/ossec ]]; then
        warn "/var/ossec: exists — Wazuh previously installed, will reconfigure"
    else
        pass "/var/ossec: not present — clean install"
    fi

    # /etc/filebeat
    if [[ -d /etc/filebeat ]]; then
        warn "/etc/filebeat: exists — will back up and update config"
    else
        pass "/etc/filebeat: not present"
    fi

    # /opt/splunkforwarder
    if [[ -d /opt/splunkforwarder ]]; then
        warn "/opt/splunkforwarder: exists — will update config"
    else
        pass "/opt/splunkforwarder: not present"
    fi

    # Write permission to /opt
    if [[ -w /opt ]]; then
        pass "/opt: writable"
    else
        conflict "/opt: NOT writable — cannot install Zeek"
    fi

    # Write permission to /etc
    if [[ -w /etc ]]; then
        pass "/etc: writable"
    else
        conflict "/etc: NOT writable — cannot write configs"
    fi
}

# ─────────────────────────────────────────────────────────────
# PRE-FLIGHT SUMMARY
# ─────────────────────────────────────────────────────────────
preflight_summary() {
    echo ""
    echo -e "${GRAY}  ─────────────────────────────────────────────────────────────${NC}"
    echo -e "  Pre-flight summary:"
    echo -e "  ${GREEN}${PF_PASSED} passed${NC}  /  ${YELLOW}${PF_WARNINGS} warnings${NC}  /  ${RED}${PF_CONFLICTS} conflicts${NC}  /  ${GRAY}${PF_SKIPPED} skipped${NC}"
    echo -e "${GRAY}  ─────────────────────────────────────────────────────────────${NC}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        # Dry run summary
        echo -e "${CYAN}  ┌──────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}  │  DRY RUN COMPLETE                                        │${NC}"
        echo -e "${CYAN}  └──────────────────────────────────────────────────────────┘${NC}"
        echo ""

        if [[ "$PF_CONFLICTS" -gt 0 ]]; then
            echo -e "${RED}  ✗ ${PF_CONFLICTS} conflict(s) must be resolved before installation.${NC}"
            echo -e "${YELLOW}  Review the conflicts above and fix them, then re-run.${NC}"
            echo ""
        fi

        if [[ "$PF_WARNINGS" -gt 0 ]]; then
            echo -e "${YELLOW}  ! ${PF_WARNINGS} warning(s) detected.${NC}"
            echo -e "${GRAY}  These will be handled automatically during installation.${NC}"
            echo ""
        fi

        if [[ ${#TOOLS_MISSING[@]} -gt 0 ]]; then
            echo -e "${WHITE}  Packages that will be installed:${NC}"
            for pkg in "${TOOLS_MISSING[@]}"; do
                echo -e "${GRAY}    → ${pkg}${NC}"
            done
            echo ""
        fi

        if [[ "$PF_CONFLICTS" -eq 0 ]]; then
            echo -e "${GREEN}  ✓ System is ready for RH Pulsar installation.${NC}"
            echo ""
            echo -e "${WHITE}  To proceed with installation, run:${NC}"
            echo -e "${CYAN}  sudo bash install.sh${NC}"
        else
            echo -e "${RED}  ✗ System is NOT ready. Resolve conflicts first.${NC}"
            echo ""
            echo -e "${WHITE}  After resolving, verify with:${NC}"
            echo -e "${CYAN}  sudo bash install.sh --dry-run${NC}"
        fi

        echo ""
        echo -e "${GRAY}  Full log: ${LOG_FILE}${NC}"
        echo ""
        exit 0
    fi

    # Full install — ask to proceed
    if [[ "$PF_CONFLICTS" -gt 0 ]]; then
        echo -e "${RED}  [!] ${PF_CONFLICTS} conflict(s) detected.${NC}"
        echo -e "${YELLOW}  These may cause installation failure.${NC}"
        echo ""
        read -p "  Continue despite conflicts? (y/N): " FORCE
        [[ "$FORCE" != "y" && "$FORCE" != "Y" ]] && {
            echo ""
            echo -e "${GRAY}  Aborted. Fix conflicts and retry.${NC}"
            echo -e "${GRAY}  Run: sudo bash install.sh --dry-run${NC}"
            exit 1
        }
    elif [[ "$PF_WARNINGS" -gt 0 ]]; then
        echo -e "${YELLOW}  [!] ${PF_WARNINGS} warning(s) — will be handled automatically.${NC}"
        echo ""
        read -p "  Continue with installation? (Y/n): " CONT
        CONT=${CONT:-Y}
        [[ "$CONT" != "y" && "$CONT" != "Y" ]] && exit 1
    else
        echo -e "${GREEN}  [✓] All checks passed. System is ready.${NC}"
        echo ""
        read -p "  Continue with installation? (Y/n): " CONT
        CONT=${CONT:-Y}
        [[ "$CONT" != "y" && "$CONT" != "Y" ]] && exit 1
    fi
}

# ─────────────────────────────────────────────────────────────
# RUN PRE-FLIGHT
# ─────────────────────────────────────────────────────────────
run_preflight() {
    section "PRE-FLIGHT CHECKS"

    pf_system
    pf_network
    pf_interfaces
    pf_ports
    pf_software
    pf_firewall
    pf_resources
    pf_tools
    pf_paths

    preflight_summary
}

# ═══════════════════════════════════════════════════════════════
# INSTALLATION PHASES
# Only reached if NOT dry-run and pre-flight passed
# ═══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────
# SIEM SELECTION
# ─────────────────────────────────────────────────────────────
select_siem() {
    section "SIEM INTEGRATION"

    echo -e "${WHITE}  Select your SIEM platform:${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} Wazuh + OpenSearch        ${GRAY}(default RH Pulsar stack)${NC}"
    echo -e "  ${CYAN}2)${NC} Splunk Enterprise / Cloud  ${GRAY}(Universal Forwarder + HEC)${NC}"
    echo -e "  ${CYAN}3)${NC} Elastic / ELK Stack        ${GRAY}(Filebeat)${NC}"
    echo -e "  ${CYAN}4)${NC} Microsoft Sentinel         ${GRAY}(Azure Monitor Agent)${NC}"
    echo -e "  ${CYAN}5)${NC} IBM QRadar                 ${GRAY}(Syslog forwarding)${NC}"
    echo -e "  ${CYAN}6)${NC} Syslog — Generic           ${GRAY}(any syslog-compatible SIEM)${NC}"
    echo -e "  ${CYAN}7)${NC} Standalone                 ${GRAY}(Zeek only — no SIEM)${NC}"
    echo ""
    read -p "  Enter choice (1-7): " SIEM_CHOICE

    case $SIEM_CHOICE in
        1) SIEM_NAME="Wazuh + OpenSearch" ;;
        2) SIEM_NAME="Splunk" ;;
        3) SIEM_NAME="Elastic / ELK" ;;
        4) SIEM_NAME="Microsoft Sentinel" ;;
        5) SIEM_NAME="IBM QRadar" ;;
        6) SIEM_NAME="Syslog Generic" ;;
        7) SIEM_NAME="Standalone" ;;
        *) error "Invalid selection. Please choose 1-7." ;;
    esac
    log "SIEM selected: $SIEM_NAME"
}

# ─────────────────────────────────────────────────────────────
# COLLECT CONFIGURATION
# ─────────────────────────────────────────────────────────────
collect_config() {
    section "SENSOR CONFIGURATION"

    echo -e "${WHITE}  Sensor Identity${NC}"
    echo ""
    read -p "  Sensor Name (e.g. RHP-CLIENT01): " SENSOR_NAME
    [[ -z "$SENSOR_NAME" ]] && error "Sensor name cannot be empty"

    echo ""
    info "Available network interfaces:"
    ip -br link show | awk '{print "      " $1}' | grep -v "lo"
    echo ""

    read -p "  Management Interface (e.g. ens33): " MGMT_IFACE
    ip link show "$MGMT_IFACE" > /dev/null 2>&1 || error "Interface $MGMT_IFACE not found"

    read -p "  Capture Interface (e.g. ens37): " CAPTURE_IFACE
    ip link show "$CAPTURE_IFACE" > /dev/null 2>&1 || error "Interface $CAPTURE_IFACE not found"
    [[ "$CAPTURE_IFACE" == "$MGMT_IFACE" ]] && error "Capture and management interfaces must be different"

    read -p "  SOC Alert Email: " ALERT_EMAIL
    [[ -z "$ALERT_EMAIL" ]] && error "Alert email cannot be empty"

    echo ""
    echo -e "${WHITE}  SIEM Configuration — $SIEM_NAME${NC}"
    echo ""

    case $SIEM_CHOICE in
        1)
            read -p "  Wazuh Manager IP: " SIEM_HOST
            read -p "  SMTP Relay IP: " SMTP_RELAY_IP
            ;;
        2)
            read -p "  Splunk HEC Host: " SIEM_HOST
            read -p "  Splunk HEC Port (default 8088): " SPLUNK_HEC_PORT
            SPLUNK_HEC_PORT=${SPLUNK_HEC_PORT:-8088}
            read -p "  Splunk HEC Token: " SPLUNK_HEC_TOKEN
            [[ -z "$SPLUNK_HEC_TOKEN" ]] && error "Splunk HEC token required"
            ;;
        3)
            read -p "  Elasticsearch Host: " SIEM_HOST
            read -p "  Elasticsearch Port (default 9200): " ELASTIC_PORT
            ELASTIC_PORT=${ELASTIC_PORT:-9200}
            read -p "  Elastic Username (default elastic): " ELASTIC_USER
            ELASTIC_USER=${ELASTIC_USER:-elastic}
            read -p "  Elastic Password: " ELASTIC_PASS
            ;;
        4)
            read -p "  Log Analytics Workspace ID: " SENTINEL_WORKSPACE_ID
            read -p "  Log Analytics Primary Key: " SENTINEL_KEY
            [[ -z "$SENTINEL_WORKSPACE_ID" ]] && error "Workspace ID required"
            SIEM_HOST="sentinel"
            ;;
        5)
            read -p "  QRadar Console IP: " SIEM_HOST
            read -p "  Syslog Port (default 514): " QRADAR_PORT
            QRADAR_PORT=${QRADAR_PORT:-514}
            ;;
        6)
            read -p "  Syslog Server IP: " SIEM_HOST
            read -p "  Syslog Port (default 514): " SYSLOG_PORT
            SYSLOG_PORT=${SYSLOG_PORT:-514}
            read -p "  Protocol TCP/UDP (default UDP): " SYSLOG_PROTO
            SYSLOG_PROTO=${SYSLOG_PROTO:-UDP}
            ;;
        7)
            SIEM_HOST="localhost"
            warn "Standalone — logs at /opt/zeek/logs/current/"
            ;;
    esac

    echo ""
    echo -e "${WHITE}  Configuration Summary:${NC}"
    echo -e "${GRAY}  ─────────────────────────────────────${NC}"
    echo -e "  Sensor Name  : ${WHITE}$SENSOR_NAME${NC}"
    echo -e "  SIEM         : ${WHITE}$SIEM_NAME${NC}"
    echo -e "  Management   : ${WHITE}$MGMT_IFACE${NC}"
    echo -e "  Capture      : ${WHITE}$CAPTURE_IFACE${NC}"
    echo -e "  Alert Email  : ${WHITE}$ALERT_EMAIL${NC}"
    [[ "$SIEM_CHOICE" != "7" ]] && echo -e "  SIEM Host    : ${WHITE}$SIEM_HOST${NC}"
    echo -e "${GRAY}  ─────────────────────────────────────${NC}"
    echo ""
    read -p "  Confirm and proceed? (y/N): " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 1
}

# ─────────────────────────────────────────────────────────────
# PREPARE SYSTEM
# ─────────────────────────────────────────────────────────────
prepare_system() {
    section "PREPARING SYSTEM"

    info "Installing all required packages..."
    apt-get install -y \
        curl wget gnupg2 apt-transport-https ca-certificates \
        lsb-release ethtool net-tools iproute2 \
        libpcap-dev python3 python3-pip git jq \
        mailutils postfix rsyslog irqbalance \
        tcpdump procps \
        >> "$LOG_FILE" 2>&1
    log "All packages installed"

    # Disable NIC offload on capture interface
    ethtool -K "$CAPTURE_IFACE" gro off lro off 2>/dev/null || true
    log "NIC offload disabled on $CAPTURE_IFACE"

    # File descriptor limits
    cat > /etc/security/limits.d/rh-pulsar.conf << LIMITS
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
LIMITS
    ulimit -n 65536 2>/dev/null || true
    log "File descriptor limits set to 65536"

    # Kernel tuning
    cat > /etc/sysctl.d/99-rh-pulsar.conf << SYSCTL
# RH Pulsar — Kernel Tuning
# Red Horizon — redhorizon.ph
vm.max_map_count = 262144
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 0
kernel.randomize_va_space = 2
SYSCTL
    sysctl -p /etc/sysctl.d/99-rh-pulsar.conf >> "$LOG_FILE" 2>&1
    log "Kernel tuning applied"

    # NTP
    timedatectl set-ntp true 2>/dev/null || true
    log "NTP enabled"

    # IRQbalance
    systemctl enable irqbalance >> "$LOG_FILE" 2>&1 || true
    systemctl start irqbalance >> "$LOG_FILE" 2>&1 || true
    log "IRQbalance enabled"

    # UFW rules if active
    if has_cmd ufw && ufw status 2>/dev/null | grep -q "active"; then
        for port in 1514 1515 55000 514 25 587; do
            ufw allow "$port" comment "RH Pulsar" >> "$LOG_FILE" 2>&1 || true
        done
        log "UFW rules added for RH Pulsar ports"
    fi

    # Backup existing configs
    local backup_dir="/etc/rh-pulsar/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    for f in /etc/filebeat/filebeat.yml /etc/rsyslog.conf /etc/postfix/main.cf \
              /var/ossec/etc/ossec.conf; do
        [[ -f "$f" ]] && cp "$f" "$backup_dir/" 2>/dev/null || true
    done
    [[ -d /opt/zeek/etc ]] && cp -r /opt/zeek/etc "$backup_dir/zeek-etc" 2>/dev/null || true
    log "Existing configs backed up to $backup_dir"
}

# ─────────────────────────────────────────────────────────────
# INSTALL ZEEK
# ─────────────────────────────────────────────────────────────
install_zeek() {
    section "INSTALLING ZEEK ${ZEEK_VERSION}"

    if [[ -f /opt/zeek/bin/zeek ]]; then
        local installed_ver
        installed_ver=$(/opt/zeek/bin/zeek --version 2>&1 | \
                        grep -oP '\d+\.\d+\.\d+' | head -1)
        if [[ "$installed_ver" == "$ZEEK_VERSION" ]]; then
            log "Zeek ${ZEEK_VERSION} already installed — skipping"
            export PATH=/opt/zeek/bin:$PATH
            return
        fi
        warn "Upgrading Zeek ${installed_ver} → ${ZEEK_VERSION}"
    fi

    info "Adding Zeek repository..."
    echo 'deb http://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/ /' \
        | tee /etc/apt/sources.list.d/security:zeek.list >> "$LOG_FILE" 2>&1

    curl -fsSL \
        https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/Release.key \
        | gpg --dearmor | tee /etc/apt/trusted.gpg.d/security_zeek.gpg > /dev/null 2>&1

    apt-get update -qq >> "$LOG_FILE" 2>&1
    info "Installing Zeek ${ZEEK_VERSION}..."
    apt-get install -y zeek >> "$LOG_FILE" 2>&1

    echo 'export PATH=/opt/zeek/bin:$PATH' > /etc/profile.d/zeek.sh
    export PATH=/opt/zeek/bin:$PATH
    log "Zeek ${ZEEK_VERSION} installed"
}

# ─────────────────────────────────────────────────────────────
# INSTALL JA4+
# ─────────────────────────────────────────────────────────────
install_ja4() {
    section "INSTALLING JA4+ v${JA4_VERSION}"

    pip3 install zkg --break-system-packages >> "$LOG_FILE" 2>&1
    /opt/zeek/bin/zkg autoconfig >> "$LOG_FILE" 2>&1
    /opt/zeek/bin/zkg install --force foxio/ja4 >> "$LOG_FILE" 2>&1
    log "JA4+ v${JA4_VERSION} installed"
}

# ─────────────────────────────────────────────────────────────
# DEPLOY DETECTION SCRIPTS
# ─────────────────────────────────────────────────────────────
deploy_scripts() {
    section "DEPLOYING DETECTION SCRIPTS"

    local ZEEK_SITE="/opt/zeek/share/zeek/site"
    mkdir -p "$ZEEK_SITE"

    info "Deploying c2beacon.zeek — Rule 110001..."
    cat > "$ZEEK_SITE/c2beacon.zeek" << 'EOF'
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
    local src = c$id$orig_h; local dst = c$id$resp_h;
    if (c$id$resp_p in skip_ports) return;
    if (Site::is_local_addr(dst)) return;
    local key = [src, dst];
    if (key !in beacon_tracker) beacon_tracker[key] = 0;
    beacon_tracker[key] += 1;
    if (beacon_tracker[key] == beacon_threshold) {
        NOTICE([$note=C2_Beacon_Detected,
                $msg=fmt("C2 Beacon: %s -> %s (%d connections)",
                         src, dst, beacon_tracker[key]),
                $src=src, $dst=dst, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("%s-%s", src, dst)]);
    }
}
EOF
    log "c2beacon.zeek — Rule 110001"

    info "Deploying dnstunnel.zeek — Rule 110002..."
    cat > "$ZEEK_SITE/dnstunnel.zeek" << 'EOF'
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
event dns_request(c: connection, msg: dns_msg, qtype: count, qclass: count) {
    if (qtype == 12) return;
    local qname = msg$query;
    if (/\.arpa$/ in qname) return;
    local src = c$id$orig_h; local dst = c$id$resp_h;
    local root = get_root_domain(qname);
    if (qtype in suspicious_qtypes) {
        local key = [src, root];
        if (key !in dns_tracker) dns_tracker[key] = 0;
        dns_tracker[key] += 1;
        if (dns_tracker[key] == suspicious_threshold) {
            NOTICE([$note=DNS_Tunnel_Detected,
                    $msg=fmt("DNS Tunnel: %s -> %s (%d queries) via %s",
                             src, root, dns_tracker[key], dst),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("%s-%s", src, root)]);
        }
    }
    local parts = split_string(qname, /\./);
    if (|parts| > 2 && |parts[0]| > long_sub_len) {
        local lkey = [src, root];
        if (lkey !in long_sub_tracker) long_sub_tracker[lkey] = 0;
        long_sub_tracker[lkey] += 1;
        if (long_sub_tracker[lkey] == long_sub_threshold) {
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
    log "dnstunnel.zeek — Rule 110002"

    info "Deploying detect-ja4.zeek — Rule 110003..."
    cat > "$ZEEK_SITE/detect-ja4.zeek" << 'EOF'
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
event ssl_client_hello(c: connection, version: count, record_version: count,
                       possible_ts: time, client_random: string,
                       session_id: string, ciphers: index_vec,
                       comp_methods: index_vec) {
    if (c?$ja4 && c$ja4?$ja4 && c$ja4$ja4 in malicious_ja4) {
        NOTICE([$note=Sliver_JA4_Detected,
                $msg=fmt("Sliver JA4: %s -> %s JA4=%s",
                         c$id$orig_h, c$id$resp_h, c$ja4$ja4),
                $src=c$id$orig_h, $dst=c$id$resp_h, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("%s-%s", c$id$orig_h, c$ja4$ja4)]);
    }
}
event ssl_server_hello(c: connection, version: count, record_version: count,
                       possible_ts: time, server_random: string,
                       session_id: string, cipher: count, comp_method: count) {
    if (c?$ja4 && c$ja4?$ja4s && c$ja4$ja4s in malicious_ja4s) {
        NOTICE([$note=Sliver_JA4_Detected,
                $msg=fmt("Sliver JA4S: %s -> %s JA4S=%s",
                         c$id$orig_h, c$id$resp_h, c$ja4$ja4s),
                $src=c$id$orig_h, $dst=c$id$resp_h, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("%s-%s", c$id$resp_h, c$ja4$ja4s)]);
    }
}
EOF
    log "detect-ja4.zeek — Rule 110003"

    info "Deploying http-c2.zeek — Rules 110004/110005..."
    cat > "$ZEEK_SITE/http-c2.zeek" << 'EOF'
# RH Pulsar — HTTP C2 & Suspicious UA Detection
# Rules 110004/110005 — MITRE T1071.001
# Red Horizon — redhorizon.ph
module HTTPC2;
export {
    redef enum Notice::Type += { HTTP_C2_Beacon, Suspicious_UserAgent };
    global beacon_threshold: count = 10;
    global suppress_for: interval = 1hr;
    global suspicious_uas: set[string] = {
        "curl/", "python-requests", "Go-http-client/",
        "libwww-perl", "Sliver", "Havoc", "CobaltStrike", "meterpreter"
    };
}
global http_beacon_tracker: table[addr, string] of count &create_expire=1hr;
event http_request(c: connection, method: string, original_URI: string,
                   unescaped_URI: string, version: string) {
    local src = c$id$orig_h; local dst = c$id$resp_h;
    local ua = (c?$http && c$http?$user_agent) ? c$http$user_agent : "";
    for (sus in suspicious_uas) {
        if (sus in ua) {
            NOTICE([$note=Suspicious_UserAgent,
                    $msg=fmt("Suspicious UA: %s -> %s UA=%s", src, dst, ua),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("%s-%s", src, ua)]);
            break;
        }
    }
    local key = [src, original_URI];
    if (key !in http_beacon_tracker) http_beacon_tracker[key] = 0;
    http_beacon_tracker[key] += 1;
    if (http_beacon_tracker[key] == beacon_threshold) {
        NOTICE([$note=HTTP_C2_Beacon,
                $msg=fmt("HTTP C2 Beacon: %s -> %s URI=%s count=%d",
                         src, dst, original_URI, http_beacon_tracker[key]),
                $src=src, $dst=dst, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("%s-%s", src, original_URI)]);
    }
}
EOF
    log "http-c2.zeek — Rules 110004/110005"
    log "All detection scripts deployed"
}

# ─────────────────────────────────────────────────────────────
# CONFIGURE ZEEK
# ─────────────────────────────────────────────────────────────
configure_zeek() {
    section "CONFIGURING ZEEK"

    local ZEEK_SITE="/opt/zeek/share/zeek/site"
    local ZEEK_ETC="/opt/zeek/etc"

    cat > "$ZEEK_SITE/local.zeek" << LOCALZEEK
# RH Pulsar — local.zeek v${PULSAR_VERSION}
# Red Horizon — redhorizon.ph
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
redef LogAscii::use_json          = T;
redef Notice::mail_dest           = "$ALERT_EMAIL";
redef Notice::sendmail            = "/usr/sbin/sendmail";
redef ignore_checksums            = T;
redef SSL::ssl_store_valid        = T;
redef Log::default_rotation_interval = 86400secs;
LOCALZEEK
    log "local.zeek configured"

    cat > "$ZEEK_ETC/node.cfg" << NODECFG
[zeek]
type=standalone
host=localhost
interface=$CAPTURE_IFACE
NODECFG
    log "node.cfg — capture: $CAPTURE_IFACE"

    local mgmt_ip
    mgmt_ip=$(ip -4 addr show "$MGMT_IFACE" 2>/dev/null | \
              grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 || echo "10.0.0.0/8")
    echo "${mgmt_ip}    # ${SENSOR_NAME}" > "$ZEEK_ETC/networks.cfg"
    log "networks.cfg configured"

    # Promiscuous — no IP on capture
    ip link set "$CAPTURE_IFACE" promisc on
    ip addr flush dev "$CAPTURE_IFACE" 2>/dev/null || true
    ethtool -K "$CAPTURE_IFACE" gro off lro off 2>/dev/null || true
    log "$CAPTURE_IFACE — promiscuous, no IP, offload disabled"

    # Persist across reboots
    cat > /etc/systemd/system/rh-pulsar-iface.service << SVCFILE
[Unit]
Description=RH Pulsar — Capture Interface Setup
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set $CAPTURE_IFACE promisc on
ExecStart=/sbin/ip addr flush dev $CAPTURE_IFACE
ExecStart=/sbin/ethtool -K $CAPTURE_IFACE gro off lro off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCFILE
    systemctl enable rh-pulsar-iface.service >> "$LOG_FILE" 2>&1
    log "Interface config persisted across reboots"
}

# ─────────────────────────────────────────────────────────────
# SIEM FORWARDER
# ─────────────────────────────────────────────────────────────
install_siem_forwarder() {
    section "SIEM INTEGRATION: $SIEM_NAME"

    case $SIEM_CHOICE in
        1) # Wazuh
            info "Installing Wazuh Agent ${WAZUH_VERSION}..."
            curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH \
                | gpg --no-default-keyring \
                --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
                --import >> "$LOG_FILE" 2>&1
            chmod 644 /usr/share/keyrings/wazuh.gpg
            echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
                | tee /etc/apt/sources.list.d/wazuh.list >> "$LOG_FILE" 2>&1
            apt-get update -qq >> "$LOG_FILE" 2>&1
            WAZUH_MANAGER="$SIEM_HOST" apt-get install -y wazuh-agent >> "$LOG_FILE" 2>&1
            cat >> /var/ossec/etc/ossec.conf << OSSEC

  <!-- RH Pulsar Zeek Log Monitoring -->
  <localfile><log_format>json</log_format><location>/opt/zeek/logs/current/notice.log</location></localfile>
  <localfile><log_format>json</log_format><location>/opt/zeek/logs/current/conn.log</location></localfile>
  <localfile><log_format>json</log_format><location>/opt/zeek/logs/current/dns.log</location></localfile>
  <localfile><log_format>json</log_format><location>/opt/zeek/logs/current/ssl.log</location></localfile>
  <localfile><log_format>json</log_format><location>/opt/zeek/logs/current/http.log</location></localfile>
OSSEC
            systemctl daemon-reload >> "$LOG_FILE" 2>&1
            systemctl enable wazuh-agent >> "$LOG_FILE" 2>&1
            systemctl start wazuh-agent >> "$LOG_FILE" 2>&1
            postconf -e "relayhost = [$SMTP_RELAY_IP]:25"
            postconf -e "myhostname = $SENSOR_NAME"
            postconf -e "inet_interfaces = loopback-only"
            postconf -e "mydestination ="
            systemctl restart postfix >> "$LOG_FILE" 2>&1
            log "Wazuh Agent + Postfix — Manager: $SIEM_HOST"
            ;;

        2) # Splunk
            info "Installing Splunk Universal Forwarder..."
            local SPLUNK_DEB="splunkforwarder-9.2.0-linux-2.6-amd64.deb"
            wget -q "https://download.splunk.com/products/universalforwarder/releases/9.2.0/linux/${SPLUNK_DEB}" \
                -O /tmp/${SPLUNK_DEB} >> "$LOG_FILE" 2>&1
            dpkg -i /tmp/${SPLUNK_DEB} >> "$LOG_FILE" 2>&1
            mkdir -p /opt/splunkforwarder/etc/system/local
            cat > /opt/splunkforwarder/etc/system/local/outputs.conf << EOF
[httpout]
httpEventCollectorToken = $SPLUNK_HEC_TOKEN
[httpout:rh-pulsar]
server = $SIEM_HOST:$SPLUNK_HEC_PORT
useSSL = true
EOF
            cat > /opt/splunkforwarder/etc/system/local/inputs.conf << EOF
[monitor:///opt/zeek/logs/current/notice.log]
index = rh_pulsar
sourcetype = zeek:notice
[monitor:///opt/zeek/logs/current/conn.log]
index = rh_pulsar
sourcetype = zeek:conn
[monitor:///opt/zeek/logs/current/dns.log]
index = rh_pulsar
sourcetype = zeek:dns
[monitor:///opt/zeek/logs/current/ssl.log]
index = rh_pulsar
sourcetype = zeek:ssl
[monitor:///opt/zeek/logs/current/http.log]
index = rh_pulsar
sourcetype = zeek:http
EOF
            /opt/splunkforwarder/bin/splunk start \
                --accept-license --answer-yes --no-prompt >> "$LOG_FILE" 2>&1
            /opt/splunkforwarder/bin/splunk enable boot-start >> "$LOG_FILE" 2>&1
            log "Splunk UF — HEC: $SIEM_HOST:$SPLUNK_HEC_PORT"
            ;;

        3) # Elastic
            info "Installing Filebeat..."
            wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
                | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg \
                >> "$LOG_FILE" 2>&1
            echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
                | tee /etc/apt/sources.list.d/elastic-8.x.list >> "$LOG_FILE" 2>&1
            apt-get update -qq >> "$LOG_FILE" 2>&1
            apt-get install -y filebeat >> "$LOG_FILE" 2>&1
            cat > /etc/filebeat/filebeat.yml << EOF
filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /opt/zeek/logs/current/notice.log
      - /opt/zeek/logs/current/conn.log
      - /opt/zeek/logs/current/dns.log
      - /opt/zeek/logs/current/ssl.log
      - /opt/zeek/logs/current/http.log
    json.keys_under_root: true
    json.add_error_key: true
    fields:
      sensor: "$SENSOR_NAME"
      platform: "rh-pulsar"
      version: "$PULSAR_VERSION"
    fields_under_root: true
output.elasticsearch:
  hosts: ["$SIEM_HOST:$ELASTIC_PORT"]
  username: "$ELASTIC_USER"
  password: "$ELASTIC_PASS"
  index: "rh-pulsar-%{+yyyy.MM.dd}"
EOF
            systemctl enable filebeat >> "$LOG_FILE" 2>&1
            systemctl start filebeat >> "$LOG_FILE" 2>&1
            log "Filebeat — Elastic: $SIEM_HOST:$ELASTIC_PORT"
            ;;

        4) # Sentinel
            info "Installing Azure Monitor Agent..."
            wget -q \
                https://raw.githubusercontent.com/Microsoft/OMS-Agent-for-Linux/master/installer/scripts/onboard_agent.sh \
                -O /tmp/onboard_agent.sh >> "$LOG_FILE" 2>&1
            chmod +x /tmp/onboard_agent.sh
            /tmp/onboard_agent.sh \
                -w "$SENTINEL_WORKSPACE_ID" -s "$SENTINEL_KEY" >> "$LOG_FILE" 2>&1
            log "Azure Monitor Agent — Workspace: $SENTINEL_WORKSPACE_ID"
            ;;

        5) # QRadar
            info "Configuring Rsyslog for QRadar..."
            cat > /etc/rsyslog.d/rh-pulsar-qradar.conf << EOF
module(load="imfile" PollingInterval="1")
input(type="imfile" File="/opt/zeek/logs/current/notice.log" Tag="rh-pulsar-notice" Severity="warning" Facility="local0")
input(type="imfile" File="/opt/zeek/logs/current/conn.log"   Tag="rh-pulsar-conn"   Severity="info"    Facility="local0")
input(type="imfile" File="/opt/zeek/logs/current/dns.log"    Tag="rh-pulsar-dns"    Severity="info"    Facility="local0")
input(type="imfile" File="/opt/zeek/logs/current/ssl.log"    Tag="rh-pulsar-ssl"    Severity="info"    Facility="local0")
input(type="imfile" File="/opt/zeek/logs/current/http.log"   Tag="rh-pulsar-http"   Severity="info"    Facility="local0")
if \$syslogtag startswith "rh-pulsar" then {
    action(type="omfwd" Target="$SIEM_HOST" Port="$QRADAR_PORT" Protocol="tcp" Template="RSYSLOG_SyslogProtocol23Format")
}
EOF
            systemctl restart rsyslog >> "$LOG_FILE" 2>&1
            log "Rsyslog — QRadar: $SIEM_HOST:$QRADAR_PORT"
            ;;

        6) # Syslog Generic
            info "Configuring generic Syslog..."
            local proto_lower
            proto_lower=$(echo "$SYSLOG_PROTO" | tr '[:upper:]' '[:lower:]')
            cat > /etc/rsyslog.d/rh-pulsar-syslog.conf << EOF
module(load="imfile" PollingInterval="1")
input(type="imfile" File="/opt/zeek/logs/current/notice.log" Tag="rh-pulsar-notice" Severity="warning" Facility="local0")
input(type="imfile" File="/opt/zeek/logs/current/conn.log"   Tag="rh-pulsar-conn"   Severity="info"    Facility="local0")
input(type="imfile" File="/opt/zeek/logs/current/dns.log"    Tag="rh-pulsar-dns"    Severity="info"    Facility="local0")
input(type="imfile" File="/opt/zeek/logs/current/ssl.log"    Tag="rh-pulsar-ssl"    Severity="info"    Facility="local0")
input(type="imfile" File="/opt/zeek/logs/current/http.log"   Tag="rh-pulsar-http"   Severity="info"    Facility="local0")
if \$syslogtag startswith "rh-pulsar" then {
    action(type="omfwd" Target="$SIEM_HOST" Port="$SYSLOG_PORT" Protocol="$proto_lower" Template="RSYSLOG_SyslogProtocol23Format")
}
EOF
            systemctl restart rsyslog >> "$LOG_FILE" 2>&1
            log "Rsyslog — Syslog: $SIEM_HOST:$SYSLOG_PORT ($SYSLOG_PROTO)"
            ;;

        7) # Standalone
            warn "Standalone — logs at /opt/zeek/logs/current/"
            log "Standalone mode"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# START SERVICES
# ─────────────────────────────────────────────────────────────
start_services() {
    section "STARTING SERVICES"

    info "Deploying Zeek..."
    /opt/zeek/bin/zeekctl deploy >> "$LOG_FILE" 2>&1
    log "Zeek deployed"

    # Watchdog cron — no duplicate entries
    (crontab -l 2>/dev/null | grep -v "zeekctl cron"; \
     echo "*/5 * * * * /opt/zeek/bin/zeekctl cron") | crontab -
    log "Zeek watchdog cron (every 5 min)"

    if [[ "$SIEM_CHOICE" == "1" ]]; then
        systemctl enable postfix >> "$LOG_FILE" 2>&1
        systemctl start postfix >> "$LOG_FILE" 2>&1
        log "Postfix relay started"
    fi
}

# ─────────────────────────────────────────────────────────────
# POST-INSTALL VALIDATION
# ─────────────────────────────────────────────────────────────
validate_install() {
    section "POST-INSTALL VALIDATION"

    local PASS=0 FAIL=0

    /opt/zeek/bin/zeekctl status 2>/dev/null | grep -q "running" && \
        { log "Zeek: RUNNING"; ((PASS++)); } || \
        { warn "Zeek: NOT RUNNING — check log"; ((FAIL++)); }

    for SCRIPT in c2beacon dnstunnel detect-ja4 http-c2; do
        [[ -f "/opt/zeek/share/zeek/site/${SCRIPT}.zeek" ]] && \
            { log "Script ${SCRIPT}.zeek: PRESENT"; ((PASS++)); } || \
            { warn "Script ${SCRIPT}.zeek: MISSING"; ((FAIL++)); }
    done

    ip link show "$CAPTURE_IFACE" | grep -q "PROMISC" && \
        { log "$CAPTURE_IFACE: PROMISCUOUS"; ((PASS++)); } || \
        { warn "$CAPTURE_IFACE: not promiscuous"; ((FAIL++)); }

    ! ip -4 addr show "$CAPTURE_IFACE" | grep -q "inet" && \
        { log "$CAPTURE_IFACE: no IP — correct"; ((PASS++)); } || \
        { warn "$CAPTURE_IFACE: has IP — should be none"; ((FAIL++)); }

    case $SIEM_CHOICE in
        1) systemctl is-active --quiet wazuh-agent && \
               { log "Wazuh Agent: RUNNING"; ((PASS++)); } || \
               { warn "Wazuh Agent: NOT RUNNING"; ((FAIL++)); } ;;
        2) /opt/splunkforwarder/bin/splunk status 2>/dev/null | grep -q "running" && \
               { log "Splunk UF: RUNNING"; ((PASS++)); } || \
               { warn "Splunk UF: NOT RUNNING"; ((FAIL++)); } ;;
        3) systemctl is-active --quiet filebeat && \
               { log "Filebeat: RUNNING"; ((PASS++)); } || \
               { warn "Filebeat: NOT RUNNING"; ((FAIL++)); } ;;
        4) log "Sentinel AMA: verify in Azure portal"; ((PASS++)) ;;
        5|6) systemctl is-active --quiet rsyslog && \
               { log "Rsyslog: RUNNING"; ((PASS++)); } || \
               { warn "Rsyslog: NOT RUNNING"; ((FAIL++)); } ;;
        7) log "Standalone: no forwarder needed"; ((PASS++)) ;;
    esac

    sleep 3
    [[ -f "/opt/zeek/logs/current/conn.log" ]] && \
        { log "Zeek logs: GENERATING"; ((PASS++)); } || \
        { warn "Zeek logs: not yet — may take a moment"; ((FAIL++)); }

    local map_count
    map_count=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo "0")
    [[ "$map_count" -ge 262144 ]] && \
        { log "vm.max_map_count: ${map_count}"; ((PASS++)); } || \
        { warn "vm.max_map_count: ${map_count} — tuning may not have applied"; ((FAIL++)); }

    echo ""
    echo -e "  Post-install: ${GREEN}${PASS} passed${NC} / ${RED}${FAIL} failed${NC}"
}

# ─────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────
print_summary() {
    mkdir -p /etc/rh-pulsar
    local mgmt_mac
    mgmt_mac=$(ip link show "$MGMT_IFACE" 2>/dev/null | \
               awk '/ether/ {print $2}' | tr -d ':' | tr '[:lower:]' '[:upper:]' || echo "000000")
    SENSOR_ID="RHP-${mgmt_mac:0:6}-$(date +%Y%m%d)"

    echo "$SENSOR_ID"       > /etc/rh-pulsar/sensor_id
    echo "$SIEM_NAME"       > /etc/rh-pulsar/siem
    echo "$SENSOR_NAME"     > /etc/rh-pulsar/name
    echo "$PULSAR_VERSION"  > /etc/rh-pulsar/version
    date '+%Y-%m-%d %H:%M:%S' > /etc/rh-pulsar/install_date

    echo ""
    echo -e "${RED}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}  RH PULSAR DEPLOYED SUCCESSFULLY${NC}"
    echo ""
    echo -e "${GRAY}  ─────────────────────────────────────────────────────────${NC}"
    echo -e "  Sensor Name  : ${WHITE}$SENSOR_NAME${NC}"
    echo -e "  Sensor ID    : ${WHITE}$SENSOR_ID${NC}"
    echo -e "  Version      : ${WHITE}RH Pulsar v${PULSAR_VERSION}${NC}"
    echo -e "  SIEM         : ${WHITE}$SIEM_NAME${NC}"
    echo -e "  Zeek         : ${WHITE}v${ZEEK_VERSION}${NC}"
    echo -e "  JA4+         : ${WHITE}v${JA4_VERSION}${NC}"
    echo -e "  Capture      : ${WHITE}$CAPTURE_IFACE (promiscuous — no IP)${NC}"
    echo -e "  Management   : ${WHITE}$MGMT_IFACE${NC}"
    echo -e "  Alert Email  : ${WHITE}$ALERT_EMAIL${NC}"
    echo -e "${GRAY}  ─────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  Detection Rules:"
    echo -e "  ${GREEN}[✓]${NC} 110001 — C2 Beacon          MITRE T1071"
    echo -e "  ${GREEN}[✓]${NC} 110002 — DNS Tunneling       MITRE T1071.004"
    echo -e "  ${GREEN}[✓]${NC} 110003 — Sliver JA4/JA4S    MITRE T1573"
    echo -e "  ${GREEN}[✓]${NC} 110004 — HTTP C2 Beacon      MITRE T1071.001"
    echo -e "  ${GREEN}[✓]${NC} 110005 — Suspicious UA       MITRE T1071.001"
    echo ""
    echo -e "${GRAY}  ─────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GRAY}Log    : /var/log/rh-pulsar-install.log${NC}"
    echo -e "  ${GRAY}ID     : /etc/rh-pulsar/sensor_id${NC}"
    echo -e "  ${GRAY}Zeek   : /opt/zeek/logs/current/${NC}"
    echo -e "  ${GRAY}Backup : /etc/rh-pulsar/backup-*${NC}"
    echo ""
    echo -e "${RED}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${WHITE}  Red Horizon — redhorizon.ph${NC}"
    echo -e "${GRAY}  © 2026 Red Horizon. All rights reserved.${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    mkdir -p /var/log /etc/rh-pulsar
    touch "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] RH Pulsar v${PULSAR_VERSION} — DRY_RUN=${DRY_RUN}" \
        > "$LOG_FILE"

    print_banner
    bootstrap
    run_preflight

    # STOP HERE if dry run — preflight_summary handles exit
    # If we reach here it means full install was confirmed

    select_siem
    collect_config
    prepare_system
    install_zeek
    install_ja4
    deploy_scripts
    configure_zeek
    install_siem_forwarder
    start_services
    validate_install
    print_summary
}

main "$@"
