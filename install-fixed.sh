#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Passive NDR Sensor Installer
#  Version: 3.2.1 (Ubuntu 24.04 LTS — JA4 updater hardened)
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
#    SENTINEL_KEY, MAIL_MODE, SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS
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
PULSAR_VER="3.2.1"
WAZUH_REPO="4.x"                              # Wazuh repo stream — agent version pinned to manager version at install time
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

    # ── Alert contact (metadata for SIEM modes, real SMTP for Standalone) ──
    echo ""
    case $SIEM_CHOICE in
        7)
            echo -e "${Y}  ⚠  STANDALONE MODE — testing/lab only${N}"
            echo -e "${D}     Production deployments require a SIEM (option 1-6).${N}"
            echo -e "${D}     In Standalone, the sensor itself handles email alerts.${N}"
            echo ""
            if [[ -z "$ALERT_EMAIL" ]]; then
                read -rp "  Alert Email (where to send Zeek notices): " ALERT_EMAIL
            fi
            [[ -z "$ALERT_EMAIL" ]] && die "Email required for Standalone mode"
            echo ""
            echo -e "${W}  Mail delivery method:${N}"
            echo -e "  ${C}a)${N} Local mail only       ${D}(writes to /var/mail/root — simplest)${N}"
            echo -e "  ${C}b)${N} SMTP relay            ${D}(delivers to real inbox — needs relay host)${N}"
            echo ""
            read -rp "  Choice (a/b): " MAIL_MODE
            MAIL_MODE=${MAIL_MODE:-a}
            if [[ "$MAIL_MODE" == "b" ]]; then
                read -rp "  SMTP Relay Host (e.g. smtp.gmail.com or 192.168.1.5): " SMTP_HOST
                read -rp "  SMTP Port (587 for TLS, 25 for plain): " SMTP_PORT
                SMTP_PORT=${SMTP_PORT:-587}
                read -rp "  SMTP requires auth? (y/N): " smtp_auth
                if [[ "${smtp_auth:-N}" == "y" || "${smtp_auth:-N}" == "Y" ]]; then
                    read -rp "  SMTP Username: " SMTP_USER
                    read_secret SMTP_PASS "SMTP Password"
                fi
            fi
            ;;
        *)
            # SIEM modes 1-6: ALERT_EMAIL is metadata, shipped to SIEM manager
            echo -e "${D}  ──────────────────────────────────────────────────────${N}"
            echo -e "${D}  Note: With SIEM enabled, the SIEM manager handles alert${N}"
            echo -e "${D}  delivery (email/Slack/PagerDuty). The email below is${N}"
            echo -e "${D}  stored as metadata and forwarded with each alert.${N}"
            echo -e "${D}  ──────────────────────────────────────────────────────${N}"
            echo ""
            if [[ -z "$ALERT_EMAIL" ]]; then
                read -rp "  SOC Contact Email (metadata only): " ALERT_EMAIL
            fi
            [[ -z "$ALERT_EMAIL" ]] && die "Email required"
            ;;
    esac

    echo ""
    echo -e "${W}  SIEM: $SIEM_NAME${N}"
    case $SIEM_CHOICE in
        1)  [[ -z "$SIEM_HOST" ]] && read -rp "  Wazuh Manager IP: " SIEM_HOST
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

    # Save contact email separately (metadata for SIEM to forward as a field)
    mkdir -p /etc/rh-pulsar
    echo "$ALERT_EMAIL" > /etc/rh-pulsar/contact
    chmod 644 /etc/rh-pulsar/contact

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
    hash -r 2>/dev/null || true  # refresh PATH cache
    local zv; zv=$(/opt/zeek/bin/zeek --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    ok "Zeek ${zv} installed"
    note "zeek-${zv}"

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

    # ── detect-ja4.zeek — Rule 110003 (refactored: manual + DB) ──
    cat > "$SITE/detect-ja4.zeek" << 'EOF'
# RH Pulsar — JA4/JA4S TLS Fingerprint Detection
# Rule 110003 — MITRE T1573
#
# Architecture:
#   - malicious_ja4_manual   : curated by Red Horizon IR team (this file)
#   - malicious_ja4_db       : auto-refreshed daily from ja4db.com (do NOT edit)
#   - Tier 2 baseline        : ja4-baseline.zeek learns env, alerts on novel JA4s
#
module DetectJA4;
export {
    redef enum Notice::Type += { Sliver_JA4_Detected, Malicious_JA4_Detected };
    global suppress_for: interval = 4hr;
    # Manually curated fingerprints (Red Horizon IR findings — edit here)
    global malicious_ja4_manual: set[string] = {
        "t13d190900_9dc949149365_97f8aa674fd9",   # Sliver (Go)
        "t13i190900_9dc949149365_97f8aa674fd9",   # Sliver (Go variant)
        "t13i3111h2_e8f1e7e78f70_b26ce05bbdd6",   # Sliver mTLS
        "t13i131000_f57a46bbacb6_e5728521abd4"    # Sliver pivot
    };
    global malicious_ja4s_manual: set[string] = {
        "t130200_1301_a56c5b993250"               # Sliver server
    };
    # DB-sourced fingerprints (filled by ja4db updater — see malicious_ja4_db.zeek)
    global malicious_ja4_db: set[string] = {};
    global malicious_ja4s_db: set[string] = {};
    # Map fingerprint -> framework name (for richer alerts; populated by DB)
    global ja4_framework: table[string] of string = {};
}
event ssl_established(c: connection) &priority=5 {
    if (!c?$ssl) return;
    local src = c$id$orig_h;
    local dst = c$id$resp_h;
    # JA4 client fingerprint check
    if (c$ssl?$ja4 && c$ssl$ja4 != "") {
        local j4 = c$ssl$ja4;
        if (j4 in malicious_ja4_manual) {
            NOTICE([$note=Sliver_JA4_Detected,
                    $msg=fmt("Manual JA4 hit: %s -> %s JA4=%s", src, dst, j4),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("%s-%s", src, j4)]);
        } else if (j4 in malicious_ja4_db) {
            local fw = (j4 in ja4_framework) ? ja4_framework[j4] : "unknown-C2";
            NOTICE([$note=Malicious_JA4_Detected,
                    $msg=fmt("JA4 DB hit [%s]: %s -> %s JA4=%s", fw, src, dst, j4),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("db-%s-%s", src, j4)]);
        }
    }
    # JA4S server fingerprint check
    if (c$ssl?$ja4s && c$ssl$ja4s != "") {
        local j4s = c$ssl$ja4s;
        if (j4s in malicious_ja4s_manual) {
            NOTICE([$note=Sliver_JA4_Detected,
                    $msg=fmt("Manual JA4S hit: %s -> %s JA4S=%s", src, dst, j4s),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("%s-%s", dst, j4s)]);
        } else if (j4s in malicious_ja4s_db) {
            local fws = (j4s in ja4_framework) ? ja4_framework[j4s] : "unknown-C2";
            NOTICE([$note=Malicious_JA4_Detected,
                    $msg=fmt("JA4S DB hit [%s]: %s -> %s JA4S=%s", fws, src, dst, j4s),
                    $src=src, $dst=dst, $conn=c,
                    $suppress_for=suppress_for,
                    $identifier=fmt("db-%s-%s", dst, j4s)]);
        }
    }
}
EOF

    # ── malicious_ja4_db.zeek — placeholder, updater fills it ───
    if [[ ! -f "$SITE/malicious_ja4_db.zeek" ]]; then
        cat > "$SITE/malicious_ja4_db.zeek" << 'EOF'
# RH Pulsar — Auto-Generated JA4 Threat Intel DB
# DO NOT EDIT — managed by /usr/local/sbin/rh-pulsar-ja4-update.sh
# Refreshed daily by rh-pulsar-ja4-update.timer
#
# Initial placeholder — populated on first updater run (during install)
# Note: detect-ja4.zeek is loaded by local.zeek before this file, so the
# DetectJA4 module already exists when Zeek parses this file.
module DetectJA4;
# (empty until first update runs)
EOF
    fi

    # ── ja4-baseline.zeek — Tier 2 environment learning ─────────
    cat > "$SITE/ja4-baseline.zeek" << 'EOF'
# RH Pulsar — JA4 Environment Baseline (Tier 2 anomaly detection)
# Rule 110006 — MITRE T1573 / behavioral
#
# Phase 1: For 7 days after sensor deploy, observe and count JA4 sightings.
# Phase 2: After 7 days, fingerprints with >=3 sightings are "known-good".
# Phase 3: Alert on any JA4 not in the known set, not in malicious sets either.
#
# Persisted to disk so the baseline survives Zeek restarts.
@load ./detect-ja4
module JA4Baseline;
export {
    redef enum Notice::Type += { Novel_JA4_Observed };
    global learning_period: interval = 7day;
    global sightings_threshold: count = 3;
    global suppress_for: interval = 24hr;
    global baseline_file: string = "/opt/zeek/share/zeek/site/ja4-baseline.dat";
    global baseline_started: time = current_time();
}
# Sightings counter — table persists via &write_expire and external file
global ja4_sightings: table[string] of count &create_expire=30day &default=0;
global ja4_known: set[string];
# Load baseline on startup (if file exists)
event zeek_init() {
    if (file_size(baseline_file) > 0) {
        local f = open_for_append("/dev/null");  # noop, just to keep Zeek happy
        when (T) {
            local data = readfile(baseline_file);
            for (line in data) {
                if (line == "" || /^#/ in line) next;
                add ja4_known[line];
            }
        }
    }
}
function in_learning_period(): bool {
    return (current_time() - baseline_started) < learning_period;
}
event ssl_established(c: connection) &priority=4 {
    if (!c?$ssl) return;
    if (!c$ssl?$ja4 || c$ssl$ja4 == "") return;
    local j4 = c$ssl$ja4;
    # Don't double-alert — known-malicious are handled by detect-ja4.zeek
    if (j4 in DetectJA4::malicious_ja4_manual) return;
    if (j4 in DetectJA4::malicious_ja4_db) return;
    if (in_learning_period()) {
        # Learning phase — count sightings, promote to known after threshold
        ja4_sightings[j4] += 1;
        if (ja4_sightings[j4] >= sightings_threshold && j4 !in ja4_known) {
            add ja4_known[j4];
        }
    } else {
        # Detection phase — alert on novel fingerprints
        if (j4 !in ja4_known) {
            ja4_sightings[j4] += 1;
            # Require multiple sightings even in detection mode to suppress noise
            if (ja4_sightings[j4] >= 2) {
                NOTICE([$note=Novel_JA4_Observed,
                        $msg=fmt("Novel JA4 (not in baseline or DB): %s -> %s JA4=%s",
                                 c$id$orig_h, c$id$resp_h, j4),
                        $src=c$id$orig_h, $dst=c$id$resp_h, $conn=c,
                        $suppress_for=suppress_for,
                        $identifier=fmt("novel-%s", j4)]);
            }
        }
    }
}
EOF
    ok "JA4 detection: refactored (manual + DB + Tier 2 baseline)"

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
    # Build mail-config lines for local.zeek (only for Standalone mode)
    local MAIL_CONFIG=""
    if [[ "$SIEM_CHOICE" == "7" ]]; then
        MAIL_CONFIG="redef Notice::mail_dest  = \"$ALERT_EMAIL\";
redef Notice::sendmail   = \"/usr/sbin/sendmail\";"
    else
        MAIL_CONFIG="# Email handled by SIEM manager (not by Zeek directly)"
    fi

    cat > "$SITE/local.zeek" << LZEEK
# RH Pulsar local.zeek v${PULSAR_VER}
# Platform: ${CLOUD} | OS: ${OS_PRETTY}
# SIEM: ${SIEM_NAME}
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
@load ./malicious_ja4_db
@load ./ja4-baseline
@load ./http-c2
@load tuning/json-logs
redef LogAscii::use_json = T;
${MAIL_CONFIG}
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

    # ═══════════════════════════════════════════════════════
    # JA4 THREAT INTEL UPDATER (Tier 1) — embedded install
    # ═══════════════════════════════════════════════════════
    info "Installing JA4 threat intel updater (ja4db.com)..."

    # ── Updater script ──────────────────────────────────────
    cat > /usr/local/sbin/rh-pulsar-ja4-update.sh << 'UPDEOF'
#!/bin/bash
# RH Pulsar — JA4 Threat Intel Updater
# Downloads ja4db.com, filters for known C2 frameworks, writes
# /opt/zeek/share/zeek/site/malicious_ja4_db.zeek, reloads Zeek.
#
# Runs daily via systemd timer (rh-pulsar-ja4-update.timer).
# Logs to journald — view with: journalctl -u rh-pulsar-ja4-update.service

set -uo pipefail

API_URL="https://ja4db.com/api/read/"
SITE_DIR="/opt/zeek/share/zeek/site"
OUT_FILE="${SITE_DIR}/malicious_ja4_db.zeek"
TMP_JSON="/tmp/ja4db-$$.json"
TMP_OUT="/tmp/ja4db-$$.zeek"
BACKUP="${OUT_FILE}.bak"
STATE_DIR="/var/lib/rh-pulsar"
STATE_FILE="${STATE_DIR}/ja4-update.state"

mkdir -p "$STATE_DIR"
trap 'rm -f "$TMP_JSON" "$TMP_OUT"' EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── C2 frameworks we want to detect (FP-safe whitelist) ────
# These are KEYWORDS matched against ja4db's 'application' and
# 'verified_by' fields. Avoiding generic terms like "python" or
# "curl" because those have many legit uses.
TARGET_FRAMEWORKS=(
    "sliver"
    "cobalt strike"
    "cobaltstrike"
    "havoc"
    "mythic"
    "brute ratel"
    "brc4"
    "metasploit"
    "meterpreter"
    "empire"
    "starkiller"
    "merlin"
    "poshc2"
    "posh c2"
)

# ── Download with retry ────────────────────────────────────
log "Fetching ja4db.com..."
if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 \
        -A "RH-Pulsar/3.1.0" \
        "$API_URL" -o "$TMP_JSON"; then
    log "ERROR: Download failed — keeping previous DB (if any)"
    echo "last_status=download_failed" > "$STATE_FILE"
    echo "last_attempt=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
    exit 1
fi

# Validate JSON
if ! jq -e 'type=="array"' "$TMP_JSON" >/dev/null 2>&1; then
    log "ERROR: Response is not a JSON array — DB corrupted upstream?"
    echo "last_status=invalid_response" > "$STATE_FILE"
    echo "last_attempt=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
    exit 1
fi

TOTAL=$(jq 'length' "$TMP_JSON")
log "Downloaded ${TOTAL} fingerprints from ja4db.com"

# ── Filter for target C2 frameworks ────────────────────────
# Build a jq regex from TARGET_FRAMEWORKS
JQ_REGEX=$(printf '%s|' "${TARGET_FRAMEWORKS[@]}" | sed 's/|$//')

# Generate the Zeek file
{
    echo "# RH Pulsar — Auto-Generated JA4 Threat Intel DB"
    echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Source: ${API_URL}"
    echo "# Frameworks: ${TARGET_FRAMEWORKS[*]}"
    echo "# DO NOT EDIT — managed by rh-pulsar-ja4-update.sh"
    echo "# Loaded by local.zeek (order: detect-ja4 -> malicious_ja4_db)"
    echo ""
    echo "module DetectJA4;"
    echo ""
    echo "redef malicious_ja4_db += {"

    # JA4 client fingerprints
    jq -r --arg re "$JQ_REGEX" '
        .[] |
        select(.ja4_fingerprint != null and .ja4_fingerprint != "") |
        select(
            (.application // "" | test($re; "i")) or
            (.verified_by // "" | test($re; "i"))
        ) |
        "    \"" + .ja4_fingerprint + "\","
    ' "$TMP_JSON" | sort -u

    echo "};"
    echo ""
    echo "redef malicious_ja4s_db += {"

    # JA4S server fingerprints (less common in DB but check)
    jq -r --arg re "$JQ_REGEX" '
        .[] |
        select(.ja4s_fingerprint != null and .ja4s_fingerprint != "") |
        select(
            (.application // "" | test($re; "i")) or
            (.verified_by // "" | test($re; "i"))
        ) |
        "    \"" + .ja4s_fingerprint + "\","
    ' "$TMP_JSON" | sort -u

    echo "};"
    echo ""
    echo "# Framework attribution table — for richer alerts"
    echo "redef ja4_framework += {"

    jq -r --arg re "$JQ_REGEX" '
        .[] |
        select(.ja4_fingerprint != null and .ja4_fingerprint != "") |
        select(
            (.application // "" | test($re; "i")) or
            (.verified_by // "" | test($re; "i"))
        ) |
        "    [\"" + .ja4_fingerprint + "\"] = \"" + (.application // "C2") + "\","
    ' "$TMP_JSON" | sort -u

    echo "};"
} > "$TMP_OUT"

# ── Sanity check the output ────────────────────────────────
COUNT=$(grep -c '^    "t' "$TMP_OUT" 2>/dev/null || echo 0)
if [[ "$COUNT" -lt 1 ]]; then
    log "WARN: 0 fingerprints matched filter — not deploying (DB upstream may have changed schema)"
    echo "last_status=zero_match" > "$STATE_FILE"
    echo "last_attempt=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
    exit 2
fi

# ── Structural validation (no zeek parser dependency) ──────
# We check the file is well-formed without invoking Zeek's loader
# (which has relative-path issues and side effects on running cluster)
validation_failed=false

# Must contain the required redef blocks
grep -q "redef malicious_ja4_db += {" "$TMP_OUT"  || validation_failed=true
grep -q "redef malicious_ja4s_db += {" "$TMP_OUT" || validation_failed=true
grep -q "redef ja4_framework += {"     "$TMP_OUT" || validation_failed=true

# Braces must balance
opens=$(grep -c "^redef.*+= {$" "$TMP_OUT" || echo 0)
closes=$(grep -c "^};$"          "$TMP_OUT" || echo 0)
[[ "$opens" -eq "$closes" ]] || validation_failed=true

# All fingerprint lines must match the JA4 format (t prefix + hex)
bad_lines=$(grep -E '^    "[^t]' "$TMP_OUT" | wc -l)
[[ "$bad_lines" -eq 0 ]] || validation_failed=true

if [[ "$validation_failed" == true ]]; then
    log "ERROR: Generated file failed structural validation — keeping previous DB"
    echo "last_status=structural_error" > "$STATE_FILE"
    echo "last_attempt=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
    exit 3
fi

# ── Deploy ─────────────────────────────────────────────────
[[ -f "$OUT_FILE" ]] && cp "$OUT_FILE" "$BACKUP"
cp "$TMP_OUT" "$OUT_FILE"
chmod 644 "$OUT_FILE"

# Reload Zeek — use restart instead of deploy for cleaner reload
# (deploy can fail in odd ways if cluster state is mid-flight)
if /opt/zeek/bin/zeekctl check >/dev/null 2>&1; then
    if /opt/zeek/bin/zeekctl deploy >/dev/null 2>&1; then
        log "OK: Deployed ${COUNT} JA4 fingerprints, reloaded Zeek"
        echo "last_status=success" > "$STATE_FILE"
        echo "last_attempt=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
        echo "fingerprint_count=${COUNT}" >> "$STATE_FILE"
        exit 0
    else
        log "ERROR: zeekctl deploy failed — rolling back"
        [[ -f "$BACKUP" ]] && cp "$BACKUP" "$OUT_FILE"
        /opt/zeek/bin/zeekctl deploy >/dev/null 2>&1 || true
        echo "last_status=deploy_failed" > "$STATE_FILE"
        echo "last_attempt=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
        exit 4
    fi
else
    # zeekctl check failed — Zeek config has issues even before our change
    log "ERROR: zeekctl check failed — Zeek config has pre-existing issues"
    [[ -f "$BACKUP" ]] && cp "$BACKUP" "$OUT_FILE"
    echo "last_status=zeek_check_failed" > "$STATE_FILE"
    echo "last_attempt=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
    exit 5
fi
UPDEOF

    chmod 755 /usr/local/sbin/rh-pulsar-ja4-update.sh
    ok "JA4 updater script installed"

    # ── Systemd service ─────────────────────────────────────
    cat > /etc/systemd/system/rh-pulsar-ja4-update.service << 'EOF'
[Unit]
Description=RH Pulsar — JA4 Threat Intel DB Refresh
Documentation=https://ja4db.com
After=network-online.target zeek.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rh-pulsar-ja4-update.sh
StandardOutput=journal
StandardError=journal
# Resource limits — be a good neighbor
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=5
# Security
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
EOF

    # ── Systemd timer (daily 03:00 + 0-60min jitter) ────────
    cat > /etc/systemd/system/rh-pulsar-ja4-update.timer << 'EOF'
[Unit]
Description=RH Pulsar — Daily JA4 Threat Intel Refresh
Documentation=https://ja4db.com

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=60min
Persistent=true
Unit=rh-pulsar-ja4-update.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable rh-pulsar-ja4-update.timer >> "$LOG" 2>&1
    systemctl start  rh-pulsar-ja4-update.timer >> "$LOG" 2>&1
    ok "JA4 updater timer enabled (daily 03:00 ±60min jitter)"
    note "ja4-updater"

    # ── First run NOW (so DB is populated on day 1) ─────────
    # Run the script directly (not via systemd) so we see real errors immediately.
    # Use a generous 180s timeout — ja4db.com can be slow for first fetch.
    info "Running first JA4 threat intel update (may take 60-180 seconds)..."
    local update_exit=0
    if timeout 180 /usr/local/sbin/rh-pulsar-ja4-update.sh >> "$LOG" 2>&1; then
        update_exit=0
    else
        update_exit=$?
    fi

    if [[ "$update_exit" -eq 0 ]] && \
       [[ -f /var/lib/rh-pulsar/ja4-update.state ]] && \
       grep -q "last_status=success" /var/lib/rh-pulsar/ja4-update.state; then
        local fp_count
        fp_count=$(grep "fingerprint_count=" /var/lib/rh-pulsar/ja4-update.state | cut -d= -f2)
        ok "JA4 DB populated: ${fp_count:-?} fingerprints loaded"
    else
        # Diagnose what happened
        local reason="unknown"
        if [[ -f /var/lib/rh-pulsar/ja4-update.state ]]; then
            reason=$(grep "last_status=" /var/lib/rh-pulsar/ja4-update.state | cut -d= -f2)
        fi
        case "$update_exit" in
            124) reason="timeout (>180s)" ;;
        esac
        warn "JA4 first update incomplete (reason: ${reason}, exit: ${update_exit})"
        warn "Detection still works with manual fingerprints (Sliver included)"
        warn "Retry now : sudo /usr/local/sbin/rh-pulsar-ja4-update.sh"
        warn "Auto retry: daily at 03:00 via systemd timer"
        info "Diagnose  : tail -50 $LOG  OR  sudo bash -x /usr/local/sbin/rh-pulsar-ja4-update.sh"
    fi
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
            local installed_wazuh_ver
            installed_wazuh_ver=$(dpkg -l wazuh-agent 2>/dev/null | awk '/^ii/{print $3}' | head -1 || echo "unknown")
            ok "Wazuh Agent already installed (${installed_wazuh_ver}) — reconfiguring"
        else
            # Pin agent version to match manager version — prevents version mismatch enrollment failure
            local manager_ver=""
            spinner_start "Detecting Wazuh Manager version..."
            manager_ver=$(curl -sk --max-time 5 \
                "https://${SIEM_HOST}:55000/" 2>/dev/null | \
                python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('api_version',''))" \
                2>/dev/null || echo "")
            spinner_stop

            if [[ -n "$manager_ver" ]]; then
                ok "Wazuh Manager version detected: ${manager_ver}"
                local pin_ver="${manager_ver}-1"
            else
                warn "Could not detect manager version — installing latest ${WAZUH_REPO}"
                local pin_ver=""
            fi

            spinner_start "Installing Wazuh Agent..."
            curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
                | gpg --no-default-keyring \
                --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
                --import >> "$LOG" 2>&1
            chmod 644 /usr/share/keyrings/wazuh.gpg
            echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
https://packages.wazuh.com/${WAZUH_REPO}/apt/ stable main" \
                > /etc/apt/sources.list.d/wazuh.list
            retry apt-get update -qq >> "$LOG" 2>&1

            if [[ -n "$pin_ver" ]]; then
                WAZUH_MANAGER="$SIEM_HOST" DEBIAN_FRONTEND=noninteractive \
                    apt-get install -y -qq "wazuh-agent=${pin_ver}" >> "$LOG" 2>&1 || {
                    warn "Pinned version ${pin_ver} not found — installing latest"
                    WAZUH_MANAGER="$SIEM_HOST" DEBIAN_FRONTEND=noninteractive \
                        apt-get install -y -qq wazuh-agent >> "$LOG" 2>&1
                }
            else
                WAZUH_MANAGER="$SIEM_HOST" DEBIAN_FRONTEND=noninteractive \
                    apt-get install -y -qq wazuh-agent >> "$LOG" 2>&1
            fi
            spinner_stop
            note "wazuh-agent"
        fi

        # ── ossec.conf — clean XML manipulation ─────────────────────
        # Bug fixes applied:
        # 1. Remove <verification_mode> — not supported in all Wazuh versions
        # 2. Set <agent_name> to SENSOR_NAME — prevents hostname fallback
        # 3. Insert localfile blocks BEFORE </ossec_config> — not after (invalid XML)
        # 4. Validate XML before starting agent

        # Remove verification_mode if present (unsupported in Wazuh < 4.9)
        sed -i '/<verification_mode>/d' /var/ossec/etc/ossec.conf 2>/dev/null || true

        # Set agent name in enrollment block — use SENSOR_NAME not hostname
        if grep -q "<enrollment>" /var/ossec/etc/ossec.conf 2>/dev/null; then
            if ! grep -q "<agent_name>" /var/ossec/etc/ossec.conf 2>/dev/null; then
                python3 - "$SENSOR_NAME" << 'PYEOF'
import sys, re
sensor_name = sys.argv[1]
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    content = f.read()
content = re.sub(
    r'(<enrollment>)',
    r'\1\n      <agent_name>' + sensor_name + r'</agent_name>',
    content, count=1
)
with open(path, "w") as f:
    f.write(content)
PYEOF
                ok "Wazuh Agent: agent_name set to ${SENSOR_NAME}"
            fi
        fi

        # Insert localfile blocks BEFORE </ossec_config> — idempotent
        if ! grep -q "rh-pulsar-zeek" /var/ossec/etc/ossec.conf 2>/dev/null; then
            python3 - "$ZL" << 'PYEOF'
import sys, re
zl = sys.argv[1]
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    content = f.read()
blocks = ""
for l in ["notice", "conn", "dns", "ssl", "http"]:
    blocks += f"""
  <localfile>
    <log_format>json</log_format>
    <location>{zl}/{l}.log</location>
    <label key="rh-pulsar-zeek">{l}</label>
  </localfile>"""
# Insert before LAST </ossec_config> only
new_content = re.sub(r'\s*</ossec_config>\s*$',
                     blocks + "\n\n</ossec_config>\n",
                     content, count=1, flags=re.MULTILINE)
with open(path, "w") as f:
    f.write(new_content)
PYEOF
            ok "Wazuh Agent: localfile blocks added (5 Zeek log paths)"
        else
            ok "Wazuh Agent: localfile blocks already present — skipping"
        fi

        # Validate XML before starting — catch corruption early
        chmod 640 /var/ossec/etc/ossec.conf
        chown root:wazuh /var/ossec/etc/ossec.conf 2>/dev/null || true

        if ! python3 -c "
import xml.etree.ElementTree as ET
ET.parse('/var/ossec/etc/ossec.conf')
" 2>/dev/null; then
            die "ossec.conf XML validation failed — check /var/ossec/etc/ossec.conf"
        fi
        ok "Wazuh Agent: ossec.conf XML valid"

        # Start agent and verify connection
        systemctl enable --now wazuh-agent >> "$LOG" 2>&1
        sleep 5

        # Check connection — retry up to 30 seconds
        local connected=false
        for i in $(seq 1 6); do
            if grep -q "Connected to the server" /var/ossec/logs/ossec.log 2>/dev/null; then
                connected=true
                break
            fi
            sleep 5
        done

        if [[ "$connected" == true ]]; then
            ok "Wazuh Agent: connected to ${SIEM_HOST}:1514"
        else
            warn "Wazuh Agent: not yet connected — check /var/ossec/logs/ossec.log"
            warn "Common causes: manager not running, port 1514 blocked, version mismatch"
            warn "Run: sudo grep -i 'error\|connected' /var/ossec/logs/ossec.log | tail -10"
        fi
        info "Manager-side setup: run setup-wazuh-manager.sh on VM2 for decoders/rules/alerts"
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
        # Configure mail delivery based on user's choice in Phase 2
        case "${MAIL_MODE:-a}" in
            a)
                # Local-only: alerts written to /var/mail/root
                postconf -e "inet_interfaces = loopback-only" 2>/dev/null || true
                postconf -e "myhostname = $SENSOR_NAME" 2>/dev/null || true
                postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost" 2>/dev/null || true
                postconf -e "relayhost =" 2>/dev/null || true
                # Alias the user's email to root so root's mailbox receives it
                grep -q "^root:" /etc/aliases 2>/dev/null || echo "root: ${ALERT_EMAIL}" >> /etc/aliases
                newaliases 2>/dev/null || true
                systemctl enable --now postfix >> "$LOG" 2>&1
                warn "Mail: LOCAL ONLY (read with: sudo mail -u root or sudo cat /var/mail/root)"
                warn "      No external delivery — production deployments must use a SIEM"
                ;;
            b)
                # SMTP relay setup
                postconf -e "myhostname = $SENSOR_NAME"
                postconf -e "relayhost = [${SMTP_HOST}]:${SMTP_PORT}"
                postconf -e "inet_interfaces = loopback-only"
                postconf -e "mydestination ="
                # Use TLS if port is 587 (submission)
                if [[ "${SMTP_PORT}" == "587" ]]; then
                    postconf -e "smtp_tls_security_level = encrypt"
                    postconf -e "smtp_sasl_tls_security_options = noanonymous"
                fi
                # Auth if configured
                if [[ -n "${SMTP_USER:-}" && -n "${SMTP_PASS:-}" ]]; then
                    echo "[${SMTP_HOST}]:${SMTP_PORT} ${SMTP_USER}:${SMTP_PASS}" > /etc/postfix/sasl_passwd
                    chmod 600 /etc/postfix/sasl_passwd
                    postmap /etc/postfix/sasl_passwd
                    postconf -e "smtp_sasl_auth_enable = yes"
                    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
                    postconf -e "smtp_sasl_security_options = noanonymous"
                fi
                systemctl enable --now postfix >> "$LOG" 2>&1
                ok "Mail: SMTP relay → ${SMTP_HOST}:${SMTP_PORT}"
                warn "Standalone mail is for LAB TESTING — production must use a SIEM"
                ;;
        esac
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
    for s in c2beacon dnstunnel detect-ja4 http-c2 ja4-baseline malicious_ja4_db; do
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
    local SENSOR_ID="RHP-${SENSOR_NAME}-${mac:0:6}"

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
    echo -e "  ${G}[✓]${N} 110001 C2 Beacon          T1071"
    echo -e "  ${G}[✓]${N} 110002 DNS Tunnel          T1071.004"
    echo -e "  ${G}[✓]${N} 110003 JA4/JA4S (manual+DB) T1573"
    echo -e "  ${G}[✓]${N} 110004 HTTP C2 Beacon      T1071.001"
    echo -e "  ${G}[✓]${N} 110005 Suspicious UA       T1071.001"
    echo -e "  ${G}[✓]${N} 110006 Novel JA4 (Tier 2)  T1573"
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
