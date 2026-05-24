#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Passive NDR Sensor Installer
#  Version: 2.1.0
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
[[ "${1:-}" == "--help"    ]] && { echo "Usage: sudo bash install.sh [--dry-run]"; exit 0; }

# Stop spinner on any exit
trap 'spinner_stop 2>/dev/null || true' EXIT INT TERM

# ── Colors ──────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' C='\033[0;36m'
B='\033[0;34m' M='\033[0;35m' N='\033[0m'

# ── Versions ────────────────────────────────────────────────
ZEEK_VER="8.2.0"
WAZUH_VER="4.14.5"
JA4_VER="0.18.8"
PULSAR_VER="2.2.0"

# ── State ───────────────────────────────────────────────────
LOG="/var/log/rh-pulsar-install.log"
PASS=0; WARN=0; FAIL=0
SIEM_CHOICE=""; SIEM_NAME=""
SENSOR_NAME=""; MGMT_IFACE=""; CAP_IFACE=""
ALERT_EMAIL=""; SIEM_HOST=""

# Detected environment
OS_ID=""; OS_VER=""; OS_PRETTY=""
PKG_MGR=""; ZEEK_REPO=""
CLOUD="bare-metal"
ARCH=""

# Progress tracking
TOTAL_STEPS=11
CURRENT_STEP=0

# ── Logging ─────────────────────────────────────────────────
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
ok()   { echo -e "${G}  [✓]${N} $1"; echo "[$(ts)] OK   $1" >> "$LOG"; ((PASS++)) || true; }
warn() { echo -e "${Y}  [!]${N} $1"; echo "[$(ts)] WARN $1" >> "$LOG"; ((WARN++)) || true; }
fail() { echo -e "${R}  [✗]${N} $1"; echo "[$(ts)] FAIL $1" >> "$LOG"; ((FAIL++)) || true; }
die()  { echo -e "${R}  [✗] FATAL: $1${N}"; echo "[$(ts)] FATAL $1" >> "$LOG"; exit 1; }
info() { echo -e "${D}  [→]${N} $1"; }
has()  { command -v "$1" &>/dev/null; }

# ── Progress bar ────────────────────────────────────────────
# ── Spinner (runs in background during long operations) ─────
SPINNER_PID=""
spinner_start() {
    local msg="${1:-Working...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while true; do
            printf "\r  ${C}%s${N} %s " "${frames[$((i % 10))]}" "$msg"
            ((i++)) || true
            sleep 0.1
        done
    ) &
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

# ── Animated progress bar ────────────────────────────────────
progress() {
    spinner_stop
    ((CURRENT_STEP++)) || true
    local target_pct=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local prev_pct=$(( (CURRENT_STEP - 1) * 100 / TOTAL_STEPS ))

    echo ""
    echo -e "${R}  ── PHASE ${CURRENT_STEP}/${TOTAL_STEPS} — $1${N}"

    # Animate from previous % to current %
    local pct=$prev_pct
    while [[ "$pct" -le "$target_pct" ]]; do
        local filled=$(( pct / 5 ))
        local empty=$(( 20 - filled ))
        local bar=""
        for ((i=0; i<filled; i++)); do bar+="█"; done
        for ((i=0; i<empty;  i++)); do bar+="░"; done

        if   [[ "$pct" -lt 40 ]]; then local col="${G}"
        elif [[ "$pct" -lt 75 ]]; then local col="${Y}"
        else                            local col="${R}"; fi

        printf "\r  ${D}[${col}%s${D}]${N} ${W}%d%%${N}  " "$bar" "$pct"
        ((pct+=2)) || true
        sleep 0.03
    done

    # Final state
    local filled=$(( target_pct / 5 ))
    local empty=$(( 20 - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty;  i++)); do bar+="░"; done
    printf "\r  ${D}[${G}%s${D}]${N} ${W}%d%%${N} ${G}✓${N}\n" "$bar" "$target_pct"
    echo ""
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
    echo -e "${D}  Red Horizon — redhorizon.ph${N}"
    [[ "$DRY_RUN" == true ]] && \
        echo -e "\n${C}  ┌─────────────────────────────────────┐${N}\n${C}  │  DRY RUN — no changes will be made  │${N}\n${C}  └─────────────────────────────────────┘${N}"
    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
}

# ═══════════════════════════════════════════════════════════
# DETECT ENVIRONMENT
# ═══════════════════════════════════════════════════════════
detect_env() {
    echo -e "${B}  ── ENVIRONMENT DETECTION${N}"
    echo ""

    # ── Architecture ────────────────────────────────────────
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ok "Architecture: x86_64" ;;
        aarch64) ok "Architecture: ARM64 (aarch64)" ;;
        armv7l)  warn "Architecture: ARMv7 — limited support" ;;
        *)       warn "Architecture: $ARCH — untested" ;;
    esac

    # ── OS Detection ────────────────────────────────────────
    if [[ -f /etc/os-release ]]; then
        OS_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_VER=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_PRETTY=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi

    case "${OS_ID}:${OS_VER}" in
        ubuntu:24.04)
            ok "OS: Ubuntu 24.04 LTS (Noble) — fully supported"
            PKG_MGR="apt"
            ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/"
            ;;
        ubuntu:22.04)
            ok "OS: Ubuntu 22.04 LTS (Jammy) — supported"
            PKG_MGR="apt"
            ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_22.04/"
            ;;
        ubuntu:20.04)
            warn "OS: Ubuntu 20.04 LTS (Focal) — limited support"
            PKG_MGR="apt"
            ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_20.04/"
            ;;
        debian:12)
            ok "OS: Debian 12 (Bookworm) — supported"
            PKG_MGR="apt"
            ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/Debian_12/"
            ;;
        debian:11)
            warn "OS: Debian 11 (Bullseye) — partial support"
            PKG_MGR="apt"
            ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/Debian_11/"
            ;;
        rhel:*|centos:*|rocky:*|almalinux:*)
            warn "OS: ${OS_PRETTY} — RPM-based, experimental"
            PKG_MGR="yum"
            ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/CentOS_8/"
            ;;
        fedora:*)
            warn "OS: Fedora — experimental"
            PKG_MGR="dnf"
            ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/Fedora_37/"
            ;;
        *)
            warn "OS: ${OS_PRETTY:-unknown} — untested, proceeding as Ubuntu"
            PKG_MGR="apt"
            ZEEK_REPO="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/"
            ;;
    esac

    # ── Fix apt sources if malformed (Ubuntu only) ──────────
    if [[ "$PKG_MGR" == "apt" ]]; then
        if apt-get update -qq 2>&1 | grep -q "Malformed\|sources could not be read"; then
            warn "Malformed apt sources detected — auto-fixing..."
            if [[ "$DRY_RUN" != true ]]; then
                local codename; codename=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 || echo "noble")
                cat > /etc/apt/sources.list.d/ubuntu.sources << EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
                apt-get update -qq >> "$LOG" 2>&1 && ok "apt sources repaired" || warn "apt sources still having issues"
            fi
        fi
    fi

    # ── Cloud Provider Detection ────────────────────────────
    echo ""
    echo -e "${D}  Detecting cloud provider...${N}"

    # AWS
    if curl -s --max-time 2 http://169.254.169.254/latest/meta-data/ami-id > /dev/null 2>&1; then
        CLOUD="AWS"
        local region; region=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "unknown")
        local instance; instance=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "unknown")
        ok "Cloud: AWS — Region: ${region} — Instance: ${instance}"

    # Azure
    elif curl -s --max-time 2 -H "Metadata:true" \
        "http://169.254.169.254/metadata/instance?api-version=2021-02-01" > /dev/null 2>&1; then
        CLOUD="Azure"
        local az_loc; az_loc=$(curl -s --max-time 2 -H "Metadata:true" \
            "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text" 2>/dev/null || echo "unknown")
        ok "Cloud: Azure — Location: ${az_loc}"

    # GCP
    elif curl -s --max-time 2 -H "Metadata-Flavor: Google" \
        http://metadata.google.internal/computeMetadata/v1/instance/zone > /dev/null 2>&1; then
        CLOUD="GCP"
        local gcp_zone; gcp_zone=$(curl -s --max-time 2 -H "Metadata-Flavor: Google" \
            http://metadata.google.internal/computeMetadata/v1/instance/zone 2>/dev/null | \
            awk -F/ '{print $NF}' || echo "unknown")
        ok "Cloud: GCP — Zone: ${gcp_zone}"

    # DigitalOcean
    elif curl -s --max-time 2 http://169.254.169.254/metadata/v1/id > /dev/null 2>&1; then
        CLOUD="DigitalOcean"
        local do_region; do_region=$(curl -s --max-time 2 \
            http://169.254.169.254/metadata/v1/region 2>/dev/null || echo "unknown")
        ok "Cloud: DigitalOcean — Region: ${do_region}"

    # Vultr
    elif curl -s --max-time 2 http://169.254.169.254/v1.json > /dev/null 2>&1; then
        CLOUD="Vultr"
        ok "Cloud: Vultr"

    # Hetzner
    elif curl -s --max-time 2 http://169.254.169.254/hetzner/v1/metadata > /dev/null 2>&1; then
        CLOUD="Hetzner"
        ok "Cloud: Hetzner"

    # VMware (check DMI)
    elif grep -qi "vmware" /sys/class/dmi/id/product_name 2>/dev/null || \
         grep -qi "vmware" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        CLOUD="VMware"
        ok "Cloud: VMware (on-premises VM)"

    # VirtualBox
    elif grep -qi "virtualbox\|innotek" /sys/class/dmi/id/product_name 2>/dev/null || \
         grep -qi "virtualbox" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        CLOUD="VirtualBox"
        ok "Cloud: VirtualBox (local VM)"

    # KVM/QEMU
    elif grep -qi "qemu\|kvm" /sys/class/dmi/id/product_name 2>/dev/null || \
         grep -qi "qemu" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        CLOUD="KVM/QEMU"
        ok "Cloud: KVM/QEMU (hypervisor)"

    else
        CLOUD="bare-metal"
        ok "Cloud: bare-metal (physical server)"
    fi

    # ── Cloud-specific notes ─────────────────────────────────
    case $CLOUD in
        AWS)
            info "AWS note: Use VPC Traffic Mirroring for capture interface"
            info "AWS note: ENI in promiscuous mode requires special config"
            ;;
        Azure)
            info "Azure note: Use Azure Network Watcher packet capture"
            info "Azure note: NSG rules may block some SIEM ports"
            ;;
        GCP)
            info "GCP note: Use Packet Mirroring for capture interface"
            ;;
        VMware)
            info "VMware note: Set capture NIC to promiscuous in vSwitch settings"
            info "VMware note: Both NICs should be on same virtual switch"
            ;;
    esac

    echo ""
    echo -e "  ${D}Environment summary:${N}"
    echo -e "  ${D}OS      :${N} ${W}${OS_PRETTY}${N}"
    echo -e "  ${D}Arch    :${N} ${W}${ARCH}${N}"
    echo -e "  ${D}Platform:${N} ${W}${CLOUD}${N}"
    echo -e "  ${D}Pkg mgr :${N} ${W}${PKG_MGR}${N}"
    echo ""
}

# ═══════════════════════════════════════════════════════════
# PHASE 0 — BOOTSTRAP
# ═══════════════════════════════════════════════════════════
bootstrap() {
    progress "BOOTSTRAP"

    [[ $EUID -ne 0 ]] && die "Run as root: sudo bash install.sh"
    ok "Root"

    case $PKG_MGR in
        apt)   has apt-get   || die "apt-get not found" ;;
        yum)   has yum       || die "yum not found" ;;
        dnf)   has dnf       || die "dnf not found" ;;
        *)     die "Unsupported package manager" ;;
    esac

    # Check apt lock (apt only)
    [[ "$PKG_MGR" == "apt" ]] && \
        fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && \
        die "APT locked by another process — wait and retry"

    # Minimal bootstrap tools
    local need=()
    case $PKG_MGR in
        apt)
            for pkg in curl iproute2 ethtool; do
                dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || need+=("$pkg")
            done
            if [[ ${#need[@]} -gt 0 ]]; then
                [[ "$DRY_RUN" == true ]] && warn "Would install: ${need[*]}" || {
                    apt-get update -qq >> "$LOG" 2>&1
                    apt-get install -y "${need[@]}" -qq >> "$LOG" 2>&1
                    ok "Bootstrap tools: ${need[*]}"
                }
            else
                ok "Bootstrap tools present"
            fi
            ;;
        yum|dnf)
            for pkg in curl iproute ethtool; do
                rpm -q "$pkg" &>/dev/null || need+=("$pkg")
            done
            if [[ ${#need[@]} -gt 0 ]]; then
                [[ "$DRY_RUN" == true ]] && warn "Would install: ${need[*]}" || {
                    $PKG_MGR install -y "${need[@]}" >> "$LOG" 2>&1
                    ok "Bootstrap tools: ${need[*]}"
                }
            else
                ok "Bootstrap tools present"
            fi
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════
# PHASE 1 — PRE-FLIGHT
# ═══════════════════════════════════════════════════════════
preflight() {
    progress "PRE-FLIGHT CHECKS"

    # ── System ──────────────────────────────────────────────
    echo -e "${D}  System${N}"

    [[ $(nproc) -ge 4 ]] && ok "CPU: $(nproc) vCPU" || warn "CPU: $(nproc) vCPU — 4+ recommended"

    local ram_kb; ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    local ram_gb; ram_gb=$(awk '/MemTotal/{printf "%.1f",$2/1024/1024}' /proc/meminfo)
    [[ "$ram_kb" -ge 4194304 ]] && ok "RAM: ${ram_gb}GB" || fail "RAM: ${ram_gb}GB — min 4GB"

    local disk; disk=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    [[ "$disk" -ge 20 ]] && ok "Disk: ${disk}GB free" || fail "Disk: ${disk}GB — min 20GB"

    local swap; swap=$(awk '/SwapTotal/{printf "%.0f",$2/1024}' /proc/meminfo)
    [[ "$swap" -gt 0 ]] && ok "Swap: ${swap}MB" || warn "Swap: none — will create 4GB"

    timedatectl status 2>/dev/null | grep -q "synchronized: yes" && \
        ok "NTP: synchronized" || warn "NTP: not synchronized — will enable"

    # Cloud-specific checks
    case $CLOUD in
        AWS)
            warn "AWS: promiscuous mode on ENI requires VPC Traffic Mirroring"
            info "See: docs.aws.amazon.com/vpc/latest/mirroring/"
            ;;
        Azure)
            warn "Azure: check NSG allows SIEM ports outbound"
            ;;
        VMware)
            info "VMware: ensure vSwitch allows promiscuous mode on capture NIC"
            ;;
    esac

    # ── Network ─────────────────────────────────────────────
    echo ""
    echo -e "${D}  Network${N}"

    curl -s --max-time 8 https://google.com > /dev/null 2>&1 && \
        ok "Internet: reachable" || fail "Internet: unreachable"

    getent hosts download.opensuse.org > /dev/null 2>&1 && \
        ok "DNS: resolving" || warn "DNS: Zeek repo not resolving"

    local iface_count; iface_count=$(ip -br link show | grep -vc "^lo")
    [[ "$iface_count" -ge 2 ]] && ok "Interfaces: ${iface_count}" || \
        warn "Interfaces: ${iface_count} — NDR needs 2 (mgmt + capture)"

    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local state has_ip
        state=$(ip -br link show "$iface" | awk '{print $2}')
        has_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -c "inet" || echo 0)
        if [[ "$has_ip" -gt 0 ]]; then
            local ip; ip=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
            ok "  ${iface}: ${state} — ${ip}"
        else
            ok "  ${iface}: ${state} — no IP (capture-ready)"
        fi
        if has ethtool; then
            local gro; gro=$(ethtool -k "$iface" 2>/dev/null | awk '/generic-receive-offload/{print $2}')
            [[ "$gro" == "on" ]] && warn "  ${iface}: GRO on — will disable"
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

    [[ "$PKG_MGR" == "apt" ]] && {
        fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && \
            fail "APT locked" || ok "APT: free"
        pgrep -x "unattended-upgrade" &>/dev/null && \
            fail "Unattended upgrades running" || ok "No conflicting upgrades"
    }

    if [[ -f /opt/zeek/bin/zeek ]]; then
        local zv; zv=$(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
        [[ "$zv" == "$ZEEK_VER" ]] && ok "Zeek ${zv}: up to date" || \
            warn "Zeek ${zv}: will upgrade to ${ZEEK_VER}"
    else
        ok "Zeek: not installed — clean"
    fi

    for tool in suricata snort; do
        has "$tool" && pgrep -x "$tool" &>/dev/null && \
            fail "${tool}: running — capture conflict" || ok "${tool}: not running"
    done

    [[ -d /sys/kernel/security/apparmor ]] && \
        warn "AppArmor active — may restrict Zeek raw socket" || ok "AppArmor: not active"

    [[ -f /etc/rh-pulsar/sensor_id ]] && \
        warn "Previous RH Pulsar — will upgrade" || ok "Previous install: none"

    # ── Required packages ───────────────────────────────────
    echo ""
    echo -e "${D}  Required packages${N}"

    local missing=()
    case $PKG_MGR in
        apt)
            for pkg in curl wget gnupg2 python3 python3-pip git jq ethtool \
                       libpcap-dev postfix mailutils rsyslog irqbalance; do
                dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || missing+=("$pkg")
            done
            ;;
        yum|dnf)
            for pkg in curl wget gnupg2 python3 python3-pip git jq ethtool \
                       libpcap-devel postfix mailx rsyslog irqbalance; do
                rpm -q "$pkg" &>/dev/null || missing+=("$pkg")
            done
            ;;
    esac

    [[ ${#missing[@]} -eq 0 ]] && ok "All packages present" || \
        warn "${#missing[@]} to install: ${missing[*]}"

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
            echo -e "${D}  Re-check: sudo bash install.sh --dry-run${N}"
        else
            echo -e "${G}  ✓ System ready${N}"
            echo ""
            echo -e "${W}  Run: sudo bash install.sh${N}"
        fi
        echo ""; exit 0
    fi

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${R}  [!] ${FAIL} conflict(s) detected.${N}"
        read -p "  Continue anyway? (y/N): " c || true
        if [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]]; then echo "  Aborted."; exit 1; fi
    else
        read -p "  Continue with installation? (Y/n): " c || true
        c=${c:-Y}
        if [[ "$c" != "y" && "$c" != "Y" ]]; then exit 1; fi
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 2 — SIEM
# ═══════════════════════════════════════════════════════════
select_siem() {
    progress "SIEM SELECTION"

    echo -e "${W}  Select SIEM platform:${N}"
    echo ""
    echo -e "  ${C}1)${N} Wazuh + OpenSearch     ${D}(default RH Pulsar stack)${N}"
    echo -e "  ${C}2)${N} Splunk                 ${D}(Universal Forwarder + HEC)${N}"
    echo -e "  ${C}3)${N} Elastic / ELK          ${D}(Filebeat)${N}"
    echo -e "  ${C}4)${N} Microsoft Sentinel     ${D}(Azure Monitor Agent)${N}"
    echo -e "  ${C}5)${N} IBM QRadar             ${D}(Syslog)${N}"
    echo -e "  ${C}6)${N} Syslog Generic         ${D}(any syslog-compatible SIEM)${N}"
    echo -e "  ${C}7)${N} Standalone             ${D}(Zeek only — no SIEM)${N}"
    echo ""

    # Auto-suggest based on cloud
    case $CLOUD in
        AWS)    info "Detected AWS — Splunk or Elastic recommended (option 2 or 3)" ;;
        Azure)  info "Detected Azure — Sentinel recommended (option 4)" ;;
        GCP)    info "Detected GCP — Elastic or Splunk recommended (option 2 or 3)" ;;
        VMware) info "Detected VMware — Wazuh recommended (option 1)" ;;
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
        *) die "Invalid choice — enter 1-7" ;;
    esac
    ok "SIEM: $SIEM_NAME"
}

# ═══════════════════════════════════════════════════════════
# PHASE 3 — CONFIGURATION
# ═══════════════════════════════════════════════════════════
configure() {
    progress "SENSOR CONFIGURATION"

    read -p "  Sensor Name (e.g. RHP-CLIENT01): " SENSOR_NAME || true
    [[ -z "$SENSOR_NAME" ]] && die "Sensor name required"

    echo ""
    info "Available interfaces:"
    ip -br link show | grep -v "^lo" | awk '{print "      "$1" "$2" "$3}'
    echo ""

    read -p "  Management Interface (e.g. ens33): " MGMT_IFACE || true
    ip link show "$MGMT_IFACE" > /dev/null 2>&1 || die "Interface $MGMT_IFACE not found"

    read -p "  Capture Interface  (e.g. ens37): " CAP_IFACE || true
    ip link show "$CAP_IFACE" > /dev/null 2>&1 || die "Interface $CAP_IFACE not found"
    [[ "$CAP_IFACE" == "$MGMT_IFACE" ]] && \
        warn "Same interface for both — OK for testing, not recommended for production"

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
            read -p "  Port (9200): " ELASTIC_PORT || true
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
            read -p "  Port (514): " QRADAR_PORT || true
            QRADAR_PORT=${QRADAR_PORT:-514}
            ;;
        6)
            read -p "  Syslog IP: " SIEM_HOST || true
            read -p "  Port (514): " SYSLOG_PORT || true
            SYSLOG_PORT=${SYSLOG_PORT:-514}
            read -p "  Protocol TCP/UDP (UDP): " SYSLOG_PROTO || true
            SYSLOG_PROTO=${SYSLOG_PROTO:-UDP}
            ;;
        7) SIEM_HOST="localhost" ;;
    esac

    echo ""
    echo -e "${D}  ─────────────────────────────${N}"
    echo -e "  Sensor   : ${W}$SENSOR_NAME${N}"
    echo -e "  SIEM     : ${W}$SIEM_NAME${N}"
    echo -e "  Platform : ${W}$CLOUD${N}"
    echo -e "  OS       : ${W}$OS_PRETTY${N}"
    echo -e "  Mgmt     : ${W}$MGMT_IFACE${N}"
    echo -e "  Capture  : ${W}$CAP_IFACE${N}"
    echo -e "  Email    : ${W}$ALERT_EMAIL${N}"
    [[ "$SIEM_CHOICE" != "7" ]] && echo -e "  SIEM IP  : ${W}$SIEM_HOST${N}"
    echo -e "${D}  ─────────────────────────────${N}"
    echo ""
    read -p "  Confirm? (y/N): " c || true
    if [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]]; then exit 1; fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 4 — SYSTEM PREP
# ═══════════════════════════════════════════════════════════
prep_system() {
    progress "SYSTEM PREPARATION"

    # ── Packages per OS ─────────────────────────────────────
    info "Installing packages..."
    spinner_start "Installing packages (this may take a minute)..."
    case $PKG_MGR in
        apt)
            apt-get install -y \
                curl wget gnupg2 apt-transport-https ca-certificates \
                python3 python3-pip git jq ethtool libpcap-dev \
                postfix mailutils rsyslog irqbalance \
                >> "$LOG" 2>&1
            ;;
        yum)
            yum install -y \
                curl wget gnupg2 python3 python3-pip git jq ethtool \
                libpcap-devel postfix mailx rsyslog irqbalance \
                >> "$LOG" 2>&1
            ;;
        dnf)
            dnf install -y \
                curl wget gnupg2 python3 python3-pip git jq ethtool \
                libpcap-devel postfix mailx rsyslog irqbalance \
                >> "$LOG" 2>&1
            ;;
    esac
    spinner_stop
    ok "Packages installed"

    # ── NIC offload ─────────────────────────────────────────
    ethtool -K "$CAP_IFACE" gro off lro off 2>/dev/null || true
    ok "NIC offload disabled on $CAP_IFACE"

    # ── File descriptor limits ───────────────────────────────
    cat > /etc/security/limits.d/rh-pulsar.conf << EOF
* soft nofile 65536
* hard nofile 65536
EOF
    ulimit -n 65536 2>/dev/null || true
    ok "FD limits: 65536"

    # ── Kernel tuning ───────────────────────────────────────
    cat > /etc/sysctl.d/99-rh-pulsar.conf << EOF
vm.max_map_count = 262144
net.core.rmem_max = 134217728
net.core.netdev_max_backlog = 250000
kernel.randomize_va_space = 2
EOF
    sysctl -p /etc/sysctl.d/99-rh-pulsar.conf >> "$LOG" 2>&1
    ok "Kernel tuning applied"

    # ── Swap ────────────────────────────────────────────────
    local swap; swap=$(awk '/SwapTotal/{printf "%.0f",$2/1024}' /proc/meminfo)
    if [[ "$swap" -eq 0 && ! -f /swapfile ]]; then
        info "Creating 4GB swap..."
        fallocate -l 4G /swapfile 2>/dev/null || \
            dd if=/dev/zero of=/swapfile bs=1M count=4096 >> "$LOG" 2>&1
        chmod 600 /swapfile
        mkswap /swapfile >> "$LOG" 2>&1
        swapon /swapfile
        grep -q swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap: 4GB created"
    fi

    # ── Services ────────────────────────────────────────────
    timedatectl set-ntp true 2>/dev/null || true
    systemctl enable --now systemd-timesyncd >> "$LOG" 2>&1 || true
    systemctl enable --now irqbalance >> "$LOG" 2>&1 || true
    ok "NTP + IRQbalance enabled"

    # ── Backup configs ──────────────────────────────────────
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
    progress "INSTALLING ZEEK ${ZEEK_VER}"

    if [[ -f /opt/zeek/bin/zeek ]]; then
        local zv; zv=$(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
        if [[ "$zv" == "$ZEEK_VER" ]]; then
            ok "Zeek ${zv} already installed — skipping"
            export PATH=/opt/zeek/bin:$PATH
            return
        fi
        warn "Upgrading Zeek ${zv} → ${ZEEK_VER}"
    fi

    case $PKG_MGR in
        apt)
            info "Adding Zeek repository..."
            echo "deb ${ZEEK_REPO} /" \
                | tee /etc/apt/sources.list.d/security:zeek.list >> "$LOG" 2>&1
            curl -fsSL "${ZEEK_REPO}Release.key" \
                | gpg --dearmor \
                | tee /etc/apt/trusted.gpg.d/security_zeek.gpg > /dev/null 2>&1
            apt-get update -qq >> "$LOG" 2>&1
            spinner_start "Installing Zeek ${ZEEK_VER} — this takes 2-3 minutes..."
            apt-get install -y zeek >> "$LOG" 2>&1
            spinner_stop
            ;;
        yum|dnf)
            info "Adding Zeek repository (RPM)..."
            local rpm_repo="https://download.opensuse.org/repositories/security:/zeek/CentOS_8/security:zeek.repo"
            $PKG_MGR install -y "$rpm_repo" >> "$LOG" 2>&1 || \
                curl -fsSL "$rpm_repo" -o /etc/yum.repos.d/zeek.repo >> "$LOG" 2>&1
            spinner_start "Installing Zeek ${ZEEK_VER}..."
            $PKG_MGR install -y zeek >> "$LOG" 2>&1
            spinner_stop
            ;;
    esac

    echo 'export PATH=/opt/zeek/bin:$PATH' > /etc/profile.d/zeek.sh
    export PATH=/opt/zeek/bin:$PATH
    ok "Zeek ${ZEEK_VER} installed"
}

# ═══════════════════════════════════════════════════════════
# PHASE 6 — JA4+
# ═══════════════════════════════════════════════════════════
install_ja4() {
    progress "INSTALLING JA4+ v${JA4_VER}"

    # Skip if already installed
    if sudo /opt/zeek/bin/zkg list 2>/dev/null | grep -q "foxio/ja4"; then
        ok "JA4+ already installed — skipping"
        return
    fi

    info "Installing zkg..."
    spinner_start "Installing zkg package manager..."
    pip3 install zkg --break-system-packages --ignore-installed GitPython >> "$LOG" 2>&1
    spinner_stop

    info "Configuring zkg..."
    /opt/zeek/bin/zkg autoconfig >> "$LOG" 2>&1

    spinner_start "Installing JA4+ v${JA4_VER}..."
    /opt/zeek/bin/zkg install --force foxio/ja4 >> "$LOG" 2>&1
    spinner_stop
    ok "JA4+ v${JA4_VER} installed"

    # Silence websockets warning
    pip3 install websockets --break-system-packages >> "$LOG" 2>&1 || true
}

# ═══════════════════════════════════════════════════════════
# PHASE 7 — DETECTION SCRIPTS
# ═══════════════════════════════════════════════════════════
deploy_scripts() {
    progress "DEPLOYING DETECTION SCRIPTS"

    local SITE="/opt/zeek/share/zeek/site"
    mkdir -p "$SITE"

    # c2beacon.zeek — Rule 110001
    info "c2beacon.zeek — Rule 110001 — MITRE T1071"
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
                $msg=fmt("C2 Beacon: %s -> %s (%d connections)",
                         src, dst, beacon_tracker[src, dst]),
                $src=src, $dst=dst, $conn=c,
                $suppress_for=suppress_for,
                $identifier=fmt("%s-%s", src, dst)]);
    }
}
EOF
    ok "c2beacon.zeek — Rule 110001"

    # dnstunnel.zeek — Rule 110002
    info "dnstunnel.zeek — Rule 110002 — MITRE T1071.004"
    cat > "$SITE/dnstunnel.zeek" << 'EOF'
# RH Pulsar — DNS Tunnel Detection v5
# Rule 110002 — MITRE T1071.004
# Red Horizon — redhorizon.ph
module DNSTunnel;
export {
    redef enum Notice::Type += { DNS_Tunnel_Detected };
    global suspicious_threshold: count = 100;
    global long_sub_threshold: count = 5;
    global long_sub_len: count = 20;
    global suppress_for: interval = 1hr;
    # TXT=16 MX=15 AAAA=28 ANY=255 NULL=0 — classic tunnel types
    # A=1 also included for high-volume long subdomain detection
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
    # Classic tunnel record types — fire on volume threshold
    if (qtype in suspicious_qtypes) {
        if ([src, root] !in dns_tracker) dns_tracker[src, root] = 0;
        dns_tracker[src, root] += 1;
        if (dns_tracker[src, root] == suspicious_threshold) {
            NOTICE([$note=DNS_Tunnel_Detected,
                    $msg=fmt("DNS Tunnel: %s querying %s (%d queries, type=%d) via %s",
                             src, root, dns_tracker[src, root], qtype, dst),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("%s-%s", src, root)]);
        }
    }
    # Long subdomain — fires on any query type including A
    # Catches DGA and DNS tunnel tools regardless of record type
    local parts = split_string(query, /\./);
    if (|parts| > 2 && |parts[0]| > long_sub_len) {
        if ([src, root] !in long_sub_tracker) long_sub_tracker[src, root] = 0;
        long_sub_tracker[src, root] += 1;
        if (long_sub_tracker[src, root] == long_sub_threshold) {
            NOTICE([$note=DNS_Tunnel_Detected,
                    $msg=fmt("DNS Tunnel (Long Subdomain): %s -> %s subdomain_len=%d type=%d via %s",
                             src, root, |parts[0]|, qtype, dst),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("longsub-%s-%s", src, root)]);
        }
    }
}
EOF
    ok "dnstunnel.zeek — Rule 110002"

    # detect-ja4.zeek — Rule 110003
    info "detect-ja4.zeek — Rule 110003 — MITRE T1573"
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
    info "http-c2.zeek — Rules 110004/110005 — MITRE T1071.001"
    cat > "$SITE/http-c2.zeek" << 'EOF'
# RH Pulsar — HTTP C2 & Suspicious UA Detection
# Rules 110004/110005 — MITRE T1071.001
# Red Horizon — redhorizon.ph
#
# Uses http_message_done at priority -5 to ensure full HTTP
# context (including User-Agent) is available before detection.
# This fixes the timing issue where http_request fires before
# headers are fully parsed by the HTTP analyzer.
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

# Fires after full HTTP request is parsed — ensures UA is available
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
        NOTICE([$note         = Suspicious_UserAgent,
                $msg          = fmt("Suspicious UA: %s -> %s UA=%s", src, dst, ua),
                $src          = src,
                $dst          = dst,
                $conn         = c,
                $suppress_for = suppress_for,
                $identifier   = fmt("ua-%s-%s", src, ua)]);
    }

    # Rule 110004 — HTTP C2 Beacon (URI repetition)
    if (uri != "") {
        if ([src, uri] !in http_beacon_tracker)
            http_beacon_tracker[src, uri] = 0;
        http_beacon_tracker[src, uri] += 1;

        if (http_beacon_tracker[src, uri] == beacon_threshold) {
            NOTICE([$note         = HTTP_C2_Beacon,
                    $msg          = fmt("HTTP C2 Beacon: %s -> %s URI=%s count=%d",
                                        src, dst, uri,
                                        http_beacon_tracker[src, uri]),
                    $src          = src,
                    $dst          = dst,
                    $conn         = c,
                    $suppress_for = suppress_for,
                    $identifier   = fmt("beacon-%s-%s", src, uri)]);
        }
    }
}
EOF
    ok "http-c2.zeek — Rules 110004/110005"
}

# ═══════════════════════════════════════════════════════════
# PHASE 8 — ZEEK CONFIG
# ═══════════════════════════════════════════════════════════
configure_zeek() {
    progress "CONFIGURING ZEEK"

    local SITE="/opt/zeek/share/zeek/site"
    local ETC="/opt/zeek/etc"

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
    ok "local.zeek configured"

    cat > "$ETC/node.cfg" << EOF
[zeek]
type=standalone
host=localhost
interface=$CAP_IFACE
EOF
    ok "node.cfg — capture: $CAP_IFACE"

    local mgmt_ip
    mgmt_ip=$(ip -4 addr show "$MGMT_IFACE" 2>/dev/null | \
              grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 || echo "10.0.0.0/8")
    echo "${mgmt_ip}    # ${SENSOR_NAME}" > "$ETC/networks.cfg"
    ok "networks.cfg: $mgmt_ip"

    # Capture interface setup
    # SAFETY: never flush management interface — would kill SSH
    if [[ "$CAP_IFACE" == "$MGMT_IFACE" ]]; then
        warn "$CAP_IFACE is management interface — skipping IP flush to preserve SSH"
        ip link set "$CAP_IFACE" promisc on
        ethtool -K "$CAP_IFACE" gro off lro off 2>/dev/null || true
        ok "$CAP_IFACE — promiscuous, offload off (IP preserved — same as mgmt)"
    else
        ip link set "$CAP_IFACE" up
        ip link set "$CAP_IFACE" promisc on
        ip addr flush dev "$CAP_IFACE" 2>/dev/null || true
        ethtool -K "$CAP_IFACE" gro off lro off 2>/dev/null || true
        ok "$CAP_IFACE — up, promiscuous, no IP, offload off"
    fi

    # Persist across reboots — only if dedicated capture interface
    if [[ "$CAP_IFACE" != "$MGMT_IFACE" ]]; then
        cat > /etc/systemd/system/rh-pulsar-iface.service << EOF
[Unit]
Description=RH Pulsar capture interface setup
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
        ok "Interface config persisted across reboots"
    else
        ok "Single NIC mode — interface persistence skipped"
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 9 — SIEM FORWARDER
# ═══════════════════════════════════════════════════════════
install_forwarder() {
    progress "SIEM INTEGRATION: $SIEM_NAME"

    local ZL="/opt/zeek/logs/current"

    case $SIEM_CHOICE in
    1) # Wazuh
        info "Installing Wazuh Agent ${WAZUH_VER}..."
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
        for l in notice conn dns ssl http; do
            cat >> /var/ossec/etc/ossec.conf << EOF
  <localfile><log_format>json</log_format><location>${ZL}/${l}.log</location></localfile>
EOF
        done
        systemctl enable --now wazuh-agent >> "$LOG" 2>&1
        postconf -e "relayhost = [${SMTP_IP:-$SIEM_HOST}]:25" 2>/dev/null || true
        postconf -e "myhostname = $SENSOR_NAME" 2>/dev/null || true
        postconf -e "inet_interfaces = loopback-only" 2>/dev/null || true
        postconf -e "mydestination =" 2>/dev/null || true
        systemctl enable --now postfix >> "$LOG" 2>&1
        ok "Wazuh Agent + Postfix configured — Manager: $SIEM_HOST"
        ;;
    2) # Splunk
        info "Installing Splunk Universal Forwarder..."
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
        ok "Splunk UF configured — $SIEM_HOST:$SPLUNK_PORT"
        ;;
    3) # Elastic
        info "Installing Filebeat..."
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
      - ${ZL}/*.log
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
        ok "Filebeat configured — $SIEM_HOST:$ELASTIC_PORT"
        ;;
    4) # Sentinel
        info "Installing Azure Monitor Agent..."
        wget -q \
            https://raw.githubusercontent.com/Microsoft/OMS-Agent-for-Linux/master/installer/scripts/onboard_agent.sh \
            -O /tmp/oms.sh >> "$LOG" 2>&1
        chmod +x /tmp/oms.sh
        /tmp/oms.sh -w "$SENTINEL_WS" -s "$SENTINEL_KEY" >> "$LOG" 2>&1
        ok "Azure Monitor Agent — Workspace: $SENTINEL_WS"
        ;;
    5|6) # QRadar / Syslog
        local tgt_host tgt_port tgt_proto
        [[ "$SIEM_CHOICE" == "5" ]] && {
            tgt_host="$SIEM_HOST"
            tgt_port="${QRADAR_PORT:-514}"
            tgt_proto="tcp"
        }
        [[ "$SIEM_CHOICE" == "6" ]] && {
            tgt_host="$SIEM_HOST"
            tgt_port="${SYSLOG_PORT:-514}"
            tgt_proto=$(echo "${SYSLOG_PROTO:-UDP}" | tr '[:upper:]' '[:lower:]')
        }
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
# PHASE 10 — START SERVICES
# ═══════════════════════════════════════════════════════════
start_services() {
    progress "STARTING SERVICES"

    spinner_start "Deploying Zeek sensor..."
    /opt/zeek/bin/zeekctl deploy >> "$LOG" 2>&1
    spinner_stop
    ok "Zeek deployed"

    # Watchdog cron — no duplicates
    (crontab -l 2>/dev/null | grep -v "zeekctl cron"; \
     echo "*/5 * * * * /opt/zeek/bin/zeekctl cron") | crontab -
    ok "Watchdog cron — every 5 min"
}

# ═══════════════════════════════════════════════════════════
# PHASE 11 — VALIDATE + SUMMARY
# ═══════════════════════════════════════════════════════════
validate_and_summary() {
    progress "VALIDATION"

    local p=0 f=0

    /opt/zeek/bin/zeekctl status 2>/dev/null | grep -q "running" && \
        { ok "Zeek: running"; ((p++)); } || { warn "Zeek: not running — run zeekctl deploy"; ((f++)); }

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
        7) ok "Standalone: no forwarder needed"; ((p++)) ;;
    esac

    sleep 3
    [[ -f "/opt/zeek/logs/current/conn.log" ]] && \
        { ok "Zeek logs: generating"; ((p++)); } || \
        { warn "Zeek logs: not yet — generate traffic to trigger"; ((f++)); }

    # ── Final Summary ────────────────────────────────────────
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
    echo "$OS_PRETTY"   > /etc/rh-pulsar/os
    date '+%Y-%m-%d %H:%M:%S' > /etc/rh-pulsar/install_date

    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${G}  RH PULSAR DEPLOYED SUCCESSFULLY${N}"
    echo ""
    echo -e "  ${D}Sensor   :${N} ${W}$SENSOR_NAME${N}"
    echo -e "  ${D}ID       :${N} ${W}$SENSOR_ID${N}"
    echo -e "  ${D}Version  :${N} ${W}RH Pulsar v${PULSAR_VER}${N}"
    echo -e "  ${D}SIEM     :${N} ${W}$SIEM_NAME${N}"
    echo -e "  ${D}Platform :${N} ${W}$CLOUD${N}"
    echo -e "  ${D}OS       :${N} ${W}$OS_PRETTY${N}"
    echo -e "  ${D}Zeek     :${N} ${W}v${ZEEK_VER}${N}"
    echo -e "  ${D}JA4+     :${N} ${W}v${JA4_VER}${N}"
    echo -e "  ${D}Capture  :${N} ${W}$CAP_IFACE (promiscuous — no IP)${N}"
    echo -e "  ${D}Mgmt     :${N} ${W}$MGMT_IFACE${N}"
    echo -e "  ${D}Email    :${N} ${W}$ALERT_EMAIL${N}"
    echo ""
    echo -e "  ${G}[✓]${N} 110001 C2 Beacon       T1071"
    echo -e "  ${G}[✓]${N} 110002 DNS Tunnel       T1071.004"
    echo -e "  ${G}[✓]${N} 110003 Sliver JA4/JA4S  T1573"
    echo -e "  ${G}[✓]${N} 110004 HTTP C2 Beacon   T1071.001"
    echo -e "  ${G}[✓]${N} 110005 Suspicious UA    T1071.001"
    echo ""
    echo -e "  ${D}Validation : ${G}${p} passed${N} / ${R}${f} failed${N}"
    echo -e "  ${D}Logs       : /opt/zeek/logs/current/${N}"
    echo -e "  ${D}Install log: $LOG${N}"
    echo -e "  ${D}Sensor ID  : /etc/rh-pulsar/sensor_id${N}"
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
    detect_env     # Auto-detect OS, cloud, arch — fixes apt sources too

    bootstrap      # Phase 0
    preflight      # Phase 1 — exits if dry-run

    select_siem    # Phase 2
    configure      # Phase 3
    prep_system    # Phase 4
    install_zeek   # Phase 5
    install_ja4    # Phase 6
    deploy_scripts # Phase 7
    configure_zeek # Phase 8
    install_forwarder # Phase 9
    start_services # Phase 10
    validate_and_summary # Phase 11
}

main "$@"
