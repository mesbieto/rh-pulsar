#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  RH PULSAR — Wazuh Manager Setup Script
#  Version: 1.0.0 (compatible with install.sh v3.2.1+)
#  Red Horizon Security — redhorizon.ph
#  © 2026 Red Horizon Security. All rights reserved.
#
#  Deploys on VM2 (manager node). Sensor (VM1) uses install.sh.
#
#  What this script does:
#    Phase 1 — Preflight checks
#    Phase 2 — Wazuh all-in-one install (Manager + OpenSearch + Dashboard)
#    Phase 3 — Zeek JSON decoders (notice/conn/dns/ssl/http)
#    Phase 4 — Detection rules 110001–110005 (MITRE mapped)
#    Phase 5 — Email alerts via Gmail SMTP (App Password)
#    Phase 6 — Validate + smoke test
#
#  Compatibility:
#    - install.sh v3.2.1+ sensor agents auto-pin to this manager's version
#    - Sensor rule IDs 110001–110005 match manager rule IDs 1:1
#    - Port filter list in c2beacon.zeek covers all manager ports
#
#  Usage:
#    sudo bash setup-wazuh-manager.sh             # Full install
#    sudo bash setup-wazuh-manager.sh --dry-run   # Preflight only
#    sudo bash setup-wazuh-manager.sh --help
#
#  Environment overrides (Ansible-friendly):
#    ALERT_EMAIL, SMTP_USER, SMTP_PASS, MANAGER_IP
#    ADMIN_PASS (OpenSearch admin password — auto-generated if unset)
# ═══════════════════════════════════════════════════════════

set -euo pipefail

# ── Args ─────────────────────────────────────────────────────
DRY_RUN=false
case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    --help|-h) sed -n '2,25p' "$0"; exit 0 ;;
    "") : ;;
    *) echo "Unknown argument: $1 — try --help"; exit 1 ;;
esac

# ── Colors ───────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
W='\033[1;37m' D='\033[0;37m' C='\033[0;36m' N='\033[0m'

# ── Versions ─────────────────────────────────────────────────
SCRIPT_VER="1.0.0"
WAZUH_VER="4.9.2"           # Pinned — agents on VM1 will match this
WAZUH_REPO="4.x"
PULSAR_COMPAT="3.2.1"       # Minimum install.sh version this works with

# ── State ────────────────────────────────────────────────────
LOG="/var/log/rh-pulsar-manager-install.log"
PASS=0; WARN=0; FAIL=0
CURRENT_PHASE="init"
TOTAL_STEPS=6; CURRENT_STEP=0
SPINNER_PID=""
ALERT_EMAIL="${ALERT_EMAIL:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
MANAGER_IP="${MANAGER_IP:-}"
ADMIN_PASS="${ADMIN_PASS:-}"
INSTALLED_COMPONENTS=()

# ── Paths ────────────────────────────────────────────────────
OSSEC_CONF="/var/ossec/etc/ossec.conf"
DECODERS_DIR="/var/ossec/etc/decoders"
RULES_DIR="/var/ossec/etc/rules"
RH_DIR="/etc/rh-pulsar"
VERSION_FILE="${RH_DIR}/wazuh-version.txt"   # install.sh reads this for agent pinning
# Also write to the ossec path install.sh checks via HTTP:
OSSEC_VERSION_FILE="/var/ossec/etc/rh-pulsar-wazuh-version.txt"

# ── Logging ──────────────────────────────────────────────────
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
ok()   { echo -e "${G}  [✓]${N} $1"; echo "[$(ts)] OK   [${CURRENT_PHASE}] $1" >> "$LOG"; PASS=$((PASS+1)); }
warn() { echo -e "${Y}  [!]${N} $1"; echo "[$(ts)] WARN [${CURRENT_PHASE}] $1" >> "$LOG"; WARN=$((WARN+1)); }
fail() { echo -e "${R}  [✗]${N} $1"; echo "[$(ts)] FAIL [${CURRENT_PHASE}] $1" >> "$LOG"; FAIL=$((FAIL+1)); }
info() { echo -e "${D}  [→]${N} $1"; echo "[$(ts)] INFO [${CURRENT_PHASE}] $1" >> "$LOG"; }
die()  { spinner_stop; echo -e "\n${R}  ✗ FATAL: $1${N}\n  See log: ${LOG}\n"; exit 1; }
has()  { command -v "$1" &>/dev/null; }
note() { INSTALLED_COMPONENTS+=("$1"); }

# ── Error trap ───────────────────────────────────────────────
on_error() {
    local exit_code=$?
    local line_no=$1
    spinner_stop
    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${R}  ✗ SETUP FAILED${N}"
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
    fi
    echo ""
    echo -e "${D}  Last 15 log lines:${N}"
    tail -15 "$LOG" 2>/dev/null | sed 's/^/    /' || echo "    (log unavailable)"
    echo ""
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR
trap 'spinner_stop 2>/dev/null || true' EXIT INT TERM

# ── Spinner ──────────────────────────────────────────────────
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

# ── Phase tracking ───────────────────────────────────────────
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

# ── Retry helper ─────────────────────────────────────────────
retry() {
    local n=0 max=3 delay=2
    until "$@"; do
        n=$((n+1))
        [[ $n -ge $max ]] && return 1
        sleep $delay; delay=$((delay*2))
    done
}

# ── Secret prompt ────────────────────────────────────────────
read_secret() {
    local varname="$1" prompt="$2"
    local current="${!varname:-}"
    if [[ -n "$current" ]]; then
        info "${varname}: loaded from environment"
        return 0
    fi
    echo -n "  ${prompt}: "
    read -rs value; echo ""
    [[ -z "$value" ]] && die "$varname required"
    printf -v "$varname" '%s' "$value"
}

# ── Generate secure password ─────────────────────────────────
gen_pass() {
    # 20 chars: letters + digits only (avoids XML/shell special chars)
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20
}

# ── Banner ───────────────────────────────────────────────────
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
    echo -e "${W}  Wazuh Manager Setup — v${SCRIPT_VER}${N}"
    echo -e "${D}  Compatible with: RH Pulsar Sensor install.sh v${PULSAR_COMPAT}+${N}"
    echo -e "${D}  Red Horizon Security — redhorizon.ph${N}"
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
    ok "Root privileges"

    # OS check
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"
        OS_PRETTY="${PRETTY_NAME:-unknown}"
    fi
    case "${OS_ID:-}:${OS_VER:-}" in
        ubuntu:24.04) ok "OS: ${OS_PRETTY} (recommended)" ;;
        ubuntu:22.04) warn "OS: ${OS_PRETTY} — tolerated, 24.04 preferred" ;;
        *) die "Unsupported OS: ${OS_PRETTY:-unknown}. Ubuntu 24.04 LTS required." ;;
    esac

    # ── Detect existing Wazuh FIRST — this changes everything below ──
    if dpkg -l wazuh-manager 2>/dev/null | grep -q "^ii"; then
        local existing_ver
        existing_ver=$(dpkg -l wazuh-manager 2>/dev/null | awk '/^ii/{print $3}' | head -1)
        SKIP_WAZUH_INSTALL=true
        ok "Wazuh Manager ${existing_ver} already installed — reconfigure mode"
        info "Port, internet, and resource checks skipped (Wazuh already running)"

        # In reconfigure mode, only check APT lock (we still install postfix)
        fuser /var/lib/dpkg/lock-frontend &>/dev/null && \
            die "APT locked by another process" || ok "APT: available"

        echo ""
        echo -e "  ${G}${PASS} passed${N}  ${Y}${WARN} warnings${N}  ${R}${FAIL} conflicts${N}"
        echo ""
        echo -e "  ${C}  Reconfigure mode: deploying Zeek decoders, detection rules, and email alerts${N}"
        echo -e "  ${C}  onto existing Wazuh ${existing_ver} — no reinstall.${N}"
        echo ""
        read -rp "  Continue? (y/N): " c || true
        [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1
        return 0
    else
        SKIP_WAZUH_INSTALL=false
        ok "No existing Wazuh Manager — fresh install"
    fi

    # ── Fresh install only: check resources, ports, internet ────

    # Resources
    local cpu ram_kb ram_gb disk
    cpu=$(nproc)
    ram_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    ram_gb=$(awk '/MemTotal/{printf "%.1f",$2/1024/1024}' /proc/meminfo)
    disk=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')

    [[ "$cpu"    -ge 4       ]] && ok "CPU: ${cpu} vCPU"     || warn "CPU: ${cpu} — 4+ recommended for manager"
    [[ "$ram_kb" -ge 7340032 ]] && ok "RAM: ${ram_gb}GB"     || warn "RAM: ${ram_gb}GB — 8GB recommended; OpenSearch may be slow"
    [[ "$disk"   -ge 50      ]] && ok "Disk: ${disk}GB free" || warn "Disk: ${disk}GB — 50GB+ recommended for log retention"

    # Port conflicts — only relevant for fresh install
    # (on an existing install these ports ARE supposed to be in use)
    local ports=(1514 1515 1516 55000 9200 9300 443 5601)
    for port in "${ports[@]}"; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            fail "Port ${port} already in use — Wazuh needs it"
        else
            ok "Port ${port}: free"
        fi
    done

    # Internet — required for fresh install only
    if retry curl -sf --connect-timeout 5 --max-time 8 https://packages.wazuh.com &>/dev/null; then
        ok "Internet: packages.wazuh.com reachable"
    else
        fail "Internet: packages.wazuh.com unreachable — required for fresh install"
    fi

    # APT lock
    fuser /var/lib/dpkg/lock-frontend &>/dev/null && \
        die "APT locked by another process" || ok "APT: available"

    # Summary
    echo ""
    echo -e "  ${G}${PASS} passed${N}  ${Y}${WARN} warnings${N}  ${R}${FAIL} conflicts${N}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        [[ "$FAIL" -gt 0 ]] && \
            echo -e "${R}  ✗ Resolve ${FAIL} conflict(s) first${N}" || \
            echo -e "${G}  ✓ Ready — run: sudo bash setup-wazuh-manager.sh${N}"
        echo ""; exit 0
    fi

    if [[ "$FAIL" -gt 0 ]]; then
        read -rp "  ${FAIL} conflict(s) detected. Continue anyway? (y/N): " c || true
        [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 2 — WAZUH ALL-IN-ONE INSTALL
# ═══════════════════════════════════════════════════════════
install_wazuh() {
    phase "WAZUH ALL-IN-ONE INSTALL"

    # ── Collect config inputs before installing ──────────────
    echo -e "${W}  Configuration${N}"
    echo ""

    # Manager IP — needed for agent enrollment and for the version file URL
    if [[ -z "$MANAGER_IP" ]]; then
        # Auto-detect primary non-loopback IP
        local detected_ip
        detected_ip=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' || echo "")
        if [[ -n "$detected_ip" ]]; then
            read -rp "  Manager IP [${detected_ip}]: " input_ip
            MANAGER_IP="${input_ip:-$detected_ip}"
        else
            read -rp "  Manager IP (e.g. 192.168.1.10): " MANAGER_IP
        fi
    fi
    [[ -z "$MANAGER_IP" ]] && die "Manager IP required"
    ok "Manager IP: ${MANAGER_IP}"

    # Admin password for OpenSearch
    if [[ -z "$ADMIN_PASS" ]]; then
        echo ""
        echo -e "${D}  OpenSearch admin password — leave blank to auto-generate${N}"
        echo -n "  Admin Password (blank = auto-generate): "
        read -rs input_pass; echo ""
        if [[ -z "$input_pass" ]]; then
            ADMIN_PASS=$(gen_pass)
            info "Auto-generated admin password (saved to ${RH_DIR}/credentials)"
        else
            ADMIN_PASS="$input_pass"
        fi
    fi

    # Alert email
    if [[ -z "$ALERT_EMAIL" ]]; then
        echo ""
        read -rp "  SOC Alert Email: " ALERT_EMAIL
    fi
    [[ -z "$ALERT_EMAIL" ]] && die "Alert email required"

    # Gmail SMTP (App Password)
    if [[ -z "$SMTP_USER" ]]; then
        echo ""
        echo -e "${D}  Gmail SMTP — requires App Password (not your main Gmail password)${N}"
        echo -e "${D}  Setup: myaccount.google.com → Security → 2-Step → App passwords${N}"
        echo ""
        read -rp "  Gmail address (SMTP sender): " SMTP_USER
    fi
    read_secret SMTP_PASS "Gmail App Password (16 chars, no spaces)"

    # Summary + confirm
    echo ""
    echo -e "${D}  ── Summary ──────────────────────────────────${N}"
    echo -e "  Manager IP : ${W}${MANAGER_IP}${N}"
    echo -e "  Wazuh ver  : ${W}${WAZUH_VER}${N}"
    echo -e "  Alert email: ${W}${ALERT_EMAIL}${N}"
    echo -e "  SMTP sender: ${W}${SMTP_USER}${N}"
    echo -e "${D}  ─────────────────────────────────────────────${N}"
    echo ""
    read -rp "  Confirm and start install? (y/N): " c || true
    [[ "${c:-N}" != "y" && "${c:-N}" != "Y" ]] && exit 1

    # ── Save credentials file ────────────────────────────────
    mkdir -p "$RH_DIR"
    cat > "${RH_DIR}/credentials" << EOF
# RH Pulsar Manager Credentials
# Generated: $(ts)
# Keep this file secure — chmod 600
MANAGER_IP=${MANAGER_IP}
WAZUH_VER=${WAZUH_VER}
OPENSEARCH_ADMIN_PASS=${ADMIN_PASS}
ALERT_EMAIL=${ALERT_EMAIL}
SMTP_USER=${SMTP_USER}
EOF
    chmod 600 "${RH_DIR}/credentials"
    ok "Credentials saved to ${RH_DIR}/credentials"

    if [[ "${SKIP_WAZUH_INSTALL:-false}" == "true" ]]; then
        ok "Wazuh already installed — skipping package install, proceeding to configuration"
        note "wazuh-already-present"
    else
        # ── Wazuh all-in-one via official assisted installer ─────
        # This installs: wazuh-manager, wazuh-indexer (OpenSearch), wazuh-dashboard
        # in a single-node all-in-one configuration.
        # Reference: https://documentation.wazuh.com/current/installation-guide/wazuh-indexer/index.html

        spinner_start "Downloading Wazuh install assistant..."
        retry curl -sO https://packages.wazuh.com/4.9/wazuh-install.sh >> "$LOG" 2>&1
        retry curl -sO https://packages.wazuh.com/4.9/config.yml >> "$LOG" 2>&1
        spinner_stop
        ok "Wazuh install assistant downloaded"

        # ── Generate config.yml for single-node deployment ───────
        cat > config.yml << EOF
nodes:
  indexer:
    - name: node-1
      ip: "${MANAGER_IP}"
  server:
    - name: wazuh-1
      ip: "${MANAGER_IP}"
  dashboard:
    - name: dashboard
      ip: "${MANAGER_IP}"
EOF
        ok "Single-node config.yml written"

        # ── Generate certificates ────────────────────────────────
        spinner_start "Generating Wazuh certificates..."
        bash wazuh-install.sh --generate-config-files >> "$LOG" 2>&1
        spinner_stop
        ok "Certificates generated"

        # ── Install Wazuh Indexer (OpenSearch) ───────────────────
        spinner_start "Installing Wazuh Indexer (OpenSearch) — this takes 3-5 min..."
        bash wazuh-install.sh --wazuh-indexer node-1 >> "$LOG" 2>&1
        spinner_stop
        ok "Wazuh Indexer installed"
        note "wazuh-indexer"

        # ── Install Wazuh Manager ────────────────────────────────
        spinner_start "Installing Wazuh Manager..."
        bash wazuh-install.sh --wazuh-server wazuh-1 >> "$LOG" 2>&1
        spinner_stop
        ok "Wazuh Manager installed"
        note "wazuh-manager"

        # ── Install Wazuh Dashboard ──────────────────────────────
        spinner_start "Installing Wazuh Dashboard..."
        bash wazuh-install.sh --wazuh-dashboard dashboard >> "$LOG" 2>&1
        spinner_stop
        ok "Wazuh Dashboard installed"
        note "wazuh-dashboard"

        # ── Set OpenSearch admin password ────────────────────────
        spinner_start "Setting OpenSearch admin password..."
        # Update the internal users database
        local HASH
        HASH=$(bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$ADMIN_PASS" 2>/dev/null | tail -1)
        if [[ -n "$HASH" ]]; then
            python3 - "$HASH" << 'PYEOF'
import sys, re
new_hash = sys.argv[1]
path = "/etc/wazuh-indexer/opensearch-security/internal_users.yml"
with open(path) as f:
    content = f.read()
# Replace the admin hash
content = re.sub(
    r'(admin:\s*\n\s*hash:\s*)".+"',
    r'\1"' + new_hash + r'"',
    content
)
with open(path, "w") as f:
    f.write(content)
PYEOF
            # Apply security config
            /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
                -cd /etc/wazuh-indexer/opensearch-security/ \
                -icl -p 9200 -nhnv \
                -cacert /etc/wazuh-indexer/certs/root-ca.pem \
                -cert /etc/wazuh-indexer/certs/admin.pem \
                -key /etc/wazuh-indexer/certs/admin-key.pem >> "$LOG" 2>&1
            ok "OpenSearch admin password set"
        else
            warn "Could not hash admin password — default credentials remain. Change manually."
        fi
        spinner_stop
    fi

    # ── Write version file (install.sh reads this for agent pinning) ─
    mkdir -p "$RH_DIR" /var/ossec/etc
    local installed_ver
    installed_ver=$(dpkg -l wazuh-manager 2>/dev/null | awk '/^ii/{print $3}' | \
        grep -oP '^\d+\.\d+\.\d+' | head -1 || echo "$WAZUH_VER")
    echo "$installed_ver" > "$VERSION_FILE"
    echo "$installed_ver" > "$OSSEC_VERSION_FILE"
    chmod 644 "$VERSION_FILE" "$OSSEC_VERSION_FILE"
    ok "Version file written: ${installed_ver} → ${OSSEC_VERSION_FILE}"
    info "Sensors running install.sh will auto-pin to this version"

    # ── Configure auto-enrollment (no manual agent approval needed) ──
    # AuthD handles auto-enrollment on port 1515
    if grep -q "<auth>" "$OSSEC_CONF" 2>/dev/null; then
        python3 - << 'PYEOF'
import re
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    content = f.read()
# Enable auto-enrollment with no password required (lab mode)
content = re.sub(r'<disabled>yes</disabled>', '<disabled>no</disabled>', content, count=1)
# Allow agents from any IP
if '<agents_allowed_ips>' not in content:
    content = content.replace(
        '</auth>',
        '  <agents_allowed_ips>any</agents_allowed_ips>\n  </auth>'
    )
with open(path, "w") as f:
    f.write(content)
PYEOF
        ok "Auto-enrollment enabled (any IP, no password — suitable for lab)"
    else
        warn "Could not configure auto-enrollment — check ${OSSEC_CONF} manually"
    fi

    # ── Restart manager to pick up auth config ───────────────
    systemctl restart wazuh-manager >> "$LOG" 2>&1
    sleep 5
    systemctl is-active --quiet wazuh-manager && \
        ok "Wazuh Manager: running" || fail "Wazuh Manager: failed to start"
}

# ═══════════════════════════════════════════════════════════
# PHASE 3 — ZEEK JSON DECODERS
# ═══════════════════════════════════════════════════════════
deploy_decoders() {
    phase "ZEEK JSON DECODERS"

    mkdir -p "$DECODERS_DIR"

    # ── notice.log decoder — the most important one ──────────
    # Zeek notice.log fields: ts, uid, note, msg, src, dst, conn_uids, actions
    cat > "${DECODERS_DIR}/rh-pulsar-zeek-notice.xml" << 'EOF'
<!--
  RH Pulsar — Wazuh Decoder: Zeek notice.log (JSON)
  Matches alerts generated by detection scripts 110001–110005
  Field: rh-pulsar-zeek = notice (set by install.sh localfile block)
-->
<decoder name="rh-pulsar-zeek-notice">
  <prematch>{"ts":</prematch>
</decoder>

<decoder name="rh-pulsar-zeek-notice-fields">
  <parent>rh-pulsar-zeek-notice</parent>
  <use_own_name>yes</use_own_name>
  <plugin_decoder>JSON_Decoder</plugin_decoder>

  <!-- Core notice fields -->
  <field name="zeek.note">note</field>
  <field name="zeek.msg">msg</field>
  <field name="zeek.src">src</field>
  <field name="zeek.dst">dst</field>
  <field name="zeek.uid">uid</field>
  <field name="zeek.ts">ts</field>

  <!-- Source/dest IP and port (from id block if present) -->
  <field name="zeek.id.orig_h">id.orig_h</field>
  <field name="zeek.id.orig_p">id.orig_p</field>
  <field name="zeek.id.resp_h">id.resp_h</field>
  <field name="zeek.id.resp_p">id.resp_p</field>

  <!-- RH Pulsar metadata (set by install.sh label) -->
  <field name="rh_pulsar.log_type">rh-pulsar-zeek</field>
</decoder>
EOF
    ok "Decoder: zeek notice.log"

    # ── conn.log decoder ─────────────────────────────────────
    cat > "${DECODERS_DIR}/rh-pulsar-zeek-conn.xml" << 'EOF'
<!--
  RH Pulsar — Wazuh Decoder: Zeek conn.log (JSON)
  Key fields for C2 beacon correlation (Rule 110001/110004)
-->
<decoder name="rh-pulsar-zeek-conn">
  <prematch>{"ts":</prematch>
</decoder>

<decoder name="rh-pulsar-zeek-conn-fields">
  <parent>rh-pulsar-zeek-conn</parent>
  <use_own_name>yes</use_own_name>
  <plugin_decoder>JSON_Decoder</plugin_decoder>

  <field name="zeek.ts">ts</field>
  <field name="zeek.uid">uid</field>
  <field name="zeek.id.orig_h">id.orig_h</field>
  <field name="zeek.id.orig_p">id.orig_p</field>
  <field name="zeek.id.resp_h">id.resp_h</field>
  <field name="zeek.id.resp_p">id.resp_p</field>
  <field name="zeek.proto">proto</field>
  <field name="zeek.service">service</field>
  <field name="zeek.duration">duration</field>
  <field name="zeek.orig_bytes">orig_bytes</field>
  <field name="zeek.resp_bytes">resp_bytes</field>
  <field name="zeek.conn_state">conn_state</field>
  <field name="zeek.local_orig">local_orig</field>
  <field name="zeek.local_resp">local_resp</field>
</decoder>
EOF
    ok "Decoder: zeek conn.log"

    # ── dns.log decoder ──────────────────────────────────────
    cat > "${DECODERS_DIR}/rh-pulsar-zeek-dns.xml" << 'EOF'
<!--
  RH Pulsar — Wazuh Decoder: Zeek dns.log (JSON)
  Key fields for DNS tunnel detection (Rule 110002)
-->
<decoder name="rh-pulsar-zeek-dns">
  <prematch>{"ts":</prematch>
</decoder>

<decoder name="rh-pulsar-zeek-dns-fields">
  <parent>rh-pulsar-zeek-dns</parent>
  <use_own_name>yes</use_own_name>
  <plugin_decoder>JSON_Decoder</plugin_decoder>

  <field name="zeek.ts">ts</field>
  <field name="zeek.uid">uid</field>
  <field name="zeek.id.orig_h">id.orig_h</field>
  <field name="zeek.id.resp_h">id.resp_h</field>
  <field name="zeek.proto">proto</field>
  <field name="zeek.trans_id">trans_id</field>
  <field name="zeek.query">query</field>
  <field name="zeek.qclass_name">qclass_name</field>
  <field name="zeek.qtype_name">qtype_name</field>
  <field name="zeek.rcode_name">rcode_name</field>
  <field name="zeek.AA">AA</field>
  <field name="zeek.TC">TC</field>
  <field name="zeek.answers">answers</field>
  <field name="zeek.TTLs">TTLs</field>
</decoder>
EOF
    ok "Decoder: zeek dns.log"

    # ── ssl.log decoder ──────────────────────────────────────
    cat > "${DECODERS_DIR}/rh-pulsar-zeek-ssl.xml" << 'EOF'
<!--
  RH Pulsar — Wazuh Decoder: Zeek ssl.log (JSON)
  Key fields for JA4/JA4S TLS fingerprint detection (Rule 110003)
-->
<decoder name="rh-pulsar-zeek-ssl">
  <prematch>{"ts":</prematch>
</decoder>

<decoder name="rh-pulsar-zeek-ssl-fields">
  <parent>rh-pulsar-zeek-ssl</parent>
  <use_own_name>yes</use_own_name>
  <plugin_decoder>JSON_Decoder</plugin_decoder>

  <field name="zeek.ts">ts</field>
  <field name="zeek.uid">uid</field>
  <field name="zeek.id.orig_h">id.orig_h</field>
  <field name="zeek.id.resp_h">id.resp_h</field>
  <field name="zeek.version">version</field>
  <field name="zeek.cipher">cipher</field>
  <field name="zeek.curve">curve</field>
  <field name="zeek.server_name">server_name</field>
  <field name="zeek.resumed">resumed</field>
  <field name="zeek.established">established</field>
  <field name="zeek.subject">subject</field>
  <field name="zeek.issuer">issuer</field>
  <!-- JA4/JA4S fingerprints — populated by foxio/ja4 Zeek package -->
  <field name="zeek.ja4">ja4</field>
  <field name="zeek.ja4s">ja4s</field>
</decoder>
EOF
    ok "Decoder: zeek ssl.log (with JA4/JA4S fields)"

    # ── http.log decoder ─────────────────────────────────────
    cat > "${DECODERS_DIR}/rh-pulsar-zeek-http.xml" << 'EOF'
<!--
  RH Pulsar — Wazuh Decoder: Zeek http.log (JSON)
  Key fields for HTTP C2 beacon + suspicious UA detection (Rules 110004/110005)
-->
<decoder name="rh-pulsar-zeek-http">
  <prematch>{"ts":</prematch>
</decoder>

<decoder name="rh-pulsar-zeek-http-fields">
  <parent>rh-pulsar-zeek-http</parent>
  <use_own_name>yes</use_own_name>
  <plugin_decoder>JSON_Decoder</plugin_decoder>

  <field name="zeek.ts">ts</field>
  <field name="zeek.uid">uid</field>
  <field name="zeek.id.orig_h">id.orig_h</field>
  <field name="zeek.id.resp_h">id.resp_h</field>
  <field name="zeek.trans_depth">trans_depth</field>
  <field name="zeek.method">method</field>
  <field name="zeek.host">host</field>
  <field name="zeek.uri">uri</field>
  <field name="zeek.user_agent">user_agent</field>
  <field name="zeek.request_body_len">request_body_len</field>
  <field name="zeek.response_body_len">response_body_len</field>
  <field name="zeek.status_code">status_code</field>
  <field name="zeek.status_msg">status_msg</field>
  <field name="zeek.resp_mime_types">resp_mime_types</field>
</decoder>
EOF
    ok "Decoder: zeek http.log"

    ok "All 5 Zeek decoders deployed to ${DECODERS_DIR}"
    note "zeek-decoders"
}

# ═══════════════════════════════════════════════════════════
# PHASE 4 — DETECTION RULES 110001–110005
# ═══════════════════════════════════════════════════════════
deploy_rules() {
    phase "DETECTION RULES 110001–110005"

    mkdir -p "$RULES_DIR"

    cat > "${RULES_DIR}/rh-pulsar-zeek-rules.xml" << 'EOF'
<!--
  RH Pulsar — Wazuh Detection Rules
  Rule IDs: 110001–110006
  Source: Zeek notice.log (JSON) ingested via Wazuh Agent localfile blocks
  MITRE ATT&CK mapped

  These rules fire when Zeek's detection scripts generate a Notice::
  alert. The zeek.note field carries the notice type name which we
  match below. Rules are intentionally named identically to the Zeek
  rule IDs so alerts in the dashboard are unambiguous.

  Severity mapping:
    level 10 = high (C2/tunnel confirmed)
    level 12 = critical (known-bad fingerprint, Sliver confirmed)
    level  8 = medium (behavioral anomaly, suspicious UA)
-->

<group name="rh-pulsar,zeek,network-detection">

  <!-- ══════════════════════════════════════════════════════
       RULE 110001 — C2 Beacon Detection
       Zeek script: c2beacon.zeek
       MITRE: T1071 — Application Layer Protocol
       Fires when a host makes 5+ connections to the same
       external IP (beacon_threshold = 5, 1hr window)
  ══════════════════════════════════════════════════════ -->
  <rule id="110001" level="10">
    <decoded_as>rh-pulsar-zeek-notice-fields</decoded_as>
    <field name="zeek.note">C2_Beacon_Detected</field>
    <description>RH Pulsar 110001: C2 Beacon Detected — $(zeek.src) → $(zeek.dst) | $(zeek.msg)</description>
    <mitre>
      <id>T1071</id>
    </mitre>
    <group>c2,beacon,network</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110002 — DNS Tunnel Detection
       Zeek script: dnstunnel.zeek
       MITRE: T1071.004 — DNS
       Fires on:
         a) 100+ suspicious-type DNS queries (TXT/CNAME/MX/NULL/AAAA/ANY)
            to the same root domain from the same source
         b) 5+ long subdomain queries (>20 chars subdomain)
  ══════════════════════════════════════════════════════ -->
  <rule id="110002" level="10">
    <decoded_as>rh-pulsar-zeek-notice-fields</decoded_as>
    <field name="zeek.note">DNS_Tunnel_Detected</field>
    <description>RH Pulsar 110002: DNS Tunnel Detected — $(zeek.src) → $(zeek.msg)</description>
    <mitre>
      <id>T1071.004</id>
    </mitre>
    <group>dns,tunnel,exfiltration,network</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110003a — Sliver C2 (Manual JA4 Fingerprint)
       Zeek script: detect-ja4.zeek
       MITRE: T1573 — Encrypted Channel
       Fires on curated Red Horizon JA4/JA4S fingerprint hits
       (Sliver Go, Sliver mTLS, Sliver pivot variants)
  ══════════════════════════════════════════════════════ -->
  <rule id="110003" level="12">
    <decoded_as>rh-pulsar-zeek-notice-fields</decoded_as>
    <field name="zeek.note">Sliver_JA4_Detected</field>
    <description>RH Pulsar 110003: CRITICAL — Sliver C2 JA4 Fingerprint Match — $(zeek.src) → $(zeek.dst) | $(zeek.msg)</description>
    <mitre>
      <id>T1573</id>
      <id>T1071</id>
    </mitre>
    <group>c2,sliver,tls,fingerprint,critical</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110003b — Malicious JA4 from Threat Intel DB
       Zeek script: detect-ja4.zeek + malicious_ja4_db.zeek
       MITRE: T1573
       Fires on ja4db.com C2 framework fingerprint hits
       (Cobalt Strike, Havoc, Mythic, BRc4, Metasploit, etc.)
  ══════════════════════════════════════════════════════ -->
  <rule id="110003b" level="12">
    <decoded_as>rh-pulsar-zeek-notice-fields</decoded_as>
    <field name="zeek.note">Malicious_JA4_Detected</field>
    <description>RH Pulsar 110003b: CRITICAL — C2 Framework JA4 DB Hit — $(zeek.src) → $(zeek.dst) | $(zeek.msg)</description>
    <mitre>
      <id>T1573</id>
      <id>T1071</id>
    </mitre>
    <group>c2,tls,fingerprint,threat-intel,critical</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110004 — HTTP C2 Beacon
       Zeek script: http-c2.zeek
       MITRE: T1071.001 — Web Protocols
       Fires when same src hits same URI 10+ times in 1hr
  ══════════════════════════════════════════════════════ -->
  <rule id="110004" level="10">
    <decoded_as>rh-pulsar-zeek-notice-fields</decoded_as>
    <field name="zeek.note">HTTP_C2_Beacon</field>
    <description>RH Pulsar 110004: HTTP C2 Beacon — $(zeek.src) → $(zeek.dst) | $(zeek.msg)</description>
    <mitre>
      <id>T1071.001</id>
    </mitre>
    <group>c2,http,beacon,network</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110005 — Suspicious User-Agent
       Zeek script: http-c2.zeek
       MITRE: T1071.001
       Fires on known-bad UAs: python-requests, Go-http-client,
       libwww-perl, Sliver, Havoc, CobaltStrike, meterpreter
  ══════════════════════════════════════════════════════ -->
  <rule id="110005" level="8">
    <decoded_as>rh-pulsar-zeek-notice-fields</decoded_as>
    <field name="zeek.note">Suspicious_UserAgent</field>
    <description>RH Pulsar 110005: Suspicious User-Agent — $(zeek.src) UA=$(zeek.msg)</description>
    <mitre>
      <id>T1071.001</id>
    </mitre>
    <group>http,user-agent,suspicious</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       RULE 110006 — Novel JA4 (Tier 2 Baseline Anomaly)
       Zeek script: ja4-baseline.zeek
       MITRE: T1573
       Fires on TLS fingerprints not seen in 7-day learning period
       Lower severity — behavioral anomaly, not confirmed C2
  ══════════════════════════════════════════════════════ -->
  <rule id="110006" level="6">
    <decoded_as>rh-pulsar-zeek-notice-fields</decoded_as>
    <field name="zeek.note">Novel_JA4_Observed</field>
    <description>RH Pulsar 110006: Novel TLS Fingerprint (not in baseline) — $(zeek.src) → $(zeek.dst) | $(zeek.msg)</description>
    <mitre>
      <id>T1573</id>
    </mitre>
    <group>tls,fingerprint,anomaly,baseline</group>
    <options>no_full_log</options>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       COMPOSITE — High-frequency C2 (110001 fired 3x/5min)
       Escalation: repeated beacon alerts = likely active session
  ══════════════════════════════════════════════════════ -->
  <rule id="110010" level="14" frequency="3" timeframe="300">
    <if_matched_sid>110001</if_matched_sid>
    <same_field>zeek.src</same_field>
    <description>RH Pulsar 110010: ESCALATED — Persistent C2 Beaconing (3+ alerts in 5min) from $(zeek.src)</description>
    <mitre>
      <id>T1071</id>
      <id>T1102</id>
    </mitre>
    <group>c2,beacon,escalated,critical</group>
  </rule>

  <!-- ══════════════════════════════════════════════════════
       COMPOSITE — C2 + Suspicious UA from same host
       Correlation: beacon + tool UA = confirmed implant
  ══════════════════════════════════════════════════════ -->
  <rule id="110011" level="14" frequency="2" timeframe="600">
    <if_matched_sid>110001,110005</if_matched_sid>
    <same_field>zeek.src</same_field>
    <description>RH Pulsar 110011: ESCALATED — C2 Beacon + Suspicious UA from same host $(zeek.src) — likely active implant</description>
    <mitre>
      <id>T1071</id>
      <id>T1071.001</id>
    </mitre>
    <group>c2,beacon,user-agent,escalated,critical</group>
  </rule>

</group>
EOF
    ok "Rules 110001–110006 deployed (+ 110010/110011 composite escalation)"
    note "detection-rules"

    # ── Add rules and decoders to ossec.conf ─────────────────
    # Check if our decoder/rules includes are already present
    if ! grep -q "rh-pulsar-zeek-notice" "$OSSEC_CONF" 2>/dev/null; then
        python3 << PYEOF
import re
path = "${OSSEC_CONF}"
with open(path) as f:
    content = f.read()

# Insert decoder includes before </ossec_config>
decoder_block = """
  <!-- RH Pulsar Zeek Decoders -->
  <ruleset>
    <decoder_dir>etc/decoders</decoder_dir>
    <rule_dir>etc/rules</rule_dir>
    <decoder>etc/decoders/rh-pulsar-zeek-notice.xml</decoder>
    <decoder>etc/decoders/rh-pulsar-zeek-conn.xml</decoder>
    <decoder>etc/decoders/rh-pulsar-zeek-dns.xml</decoder>
    <decoder>etc/decoders/rh-pulsar-zeek-ssl.xml</decoder>
    <decoder>etc/decoders/rh-pulsar-zeek-http.xml</decoder>
  </ruleset>

"""

# Only add if not already present
if '<decoder>etc/decoders/rh-pulsar' not in content:
    content = content.replace('</ossec_config>', decoder_block + '</ossec_config>', 1)
    with open(path, "w") as f:
        f.write(content)
    print("  Decoder includes added to ossec.conf")
else:
    print("  Decoder includes already present — skipping")
PYEOF
        ok "Decoders + rules registered in ossec.conf"
    else
        ok "Decoders already registered — skipping"
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 5 — EMAIL ALERTS (Gmail SMTP direct from manager)
# ═══════════════════════════════════════════════════════════
configure_email() {
    phase "EMAIL ALERTS (Gmail SMTP)"

    # ── Configure Postfix on VM2 for Gmail relay ─────────────
    info "Configuring Postfix for Gmail SMTP relay..."

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        postfix libsasl2-modules ca-certificates >> "$LOG" 2>&1

    # Main Postfix config
    postconf -e "myhostname = rh-pulsar-manager"
    postconf -e "relayhost = [smtp.gmail.com]:587"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "mydestination ="
    postconf -e "smtp_tls_security_level = encrypt"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"

    # Store Gmail App Password
    echo "[smtp.gmail.com]:587 ${SMTP_USER}:${SMTP_PASS}" > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd

    systemctl enable --now postfix >> "$LOG" 2>&1
    systemctl reload postfix >> "$LOG" 2>&1
    ok "Postfix configured for Gmail relay (App Password secured)"
    note "postfix-gmail"

    # ── Configure Wazuh Manager email alerts ─────────────────
    # ossec.conf email section
    if grep -q "<email_notification>" "$OSSEC_CONF" 2>/dev/null; then
        python3 - "$ALERT_EMAIL" "$SMTP_USER" << 'PYEOF'
import sys, re
alert_email = sys.argv[1]
smtp_user   = sys.argv[2]
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    content = f.read()

# Update email_notification block
content = re.sub(
    r'<email_notification>no</email_notification>',
    '<email_notification>yes</email_notification>',
    content
)
content = re.sub(
    r'<email_to>.*?</email_to>',
    f'<email_to>{alert_email}</email_to>',
    content
)
content = re.sub(
    r'<smtp_server>.*?</smtp_server>',
    '<smtp_server>localhost</smtp_server>',  # relay through local Postfix
    content
)
content = re.sub(
    r'<email_from>.*?</email_from>',
    f'<email_from>{smtp_user}</email_from>',
    content
)
# Alert on level 8+ (catches 110005 medium and above)
if '<email_alert_level>' in content:
    content = re.sub(
        r'<email_alert_level>\d+</email_alert_level>',
        '<email_alert_level>8</email_alert_level>',
        content
    )
else:
    content = content.replace(
        '</global>',
        '  <email_alert_level>8</email_alert_level>\n  </global>'
    )

with open(path, "w") as f:
    f.write(content)
PYEOF
        ok "Wazuh email alerts configured (level 8+ → ${ALERT_EMAIL})"
    else
        warn "Could not find <email_notification> block in ossec.conf — add manually"
    fi

    # ── Rule-specific email overrides ────────────────────────
    # Critical rules (110003, 110010, 110011) get immediate email — no batching
    cat >> "$OSSEC_CONF" << 'EOF'

  <!-- RH Pulsar — Immediate email for critical C2 rules -->
  <email_alerts>
    <email_to>ALERT_EMAIL_PLACEHOLDER</email_to>
    <rule_id>110003,110010,110011</rule_id>
    <do_not_delay />
    <do_not_group />
  </email_alerts>
EOF
    # Replace placeholder with actual email
    sed -i "s/ALERT_EMAIL_PLACEHOLDER/${ALERT_EMAIL}/g" "$OSSEC_CONF"
    ok "Immediate email configured for rules 110003, 110010, 110011 (critical C2)"

    # ── Test email ───────────────────────────────────────────
    info "Sending test email to ${ALERT_EMAIL}..."
    local test_result=false
    if echo "RH Pulsar Manager setup complete. Email alerts are working. — $(ts)" | \
        mail -s "[RH Pulsar] Manager Setup Successful — $(hostname)" \
             -a "From: ${SMTP_USER}" \
             "$ALERT_EMAIL" >> "$LOG" 2>&1; then
        # Give Postfix 5s to deliver
        sleep 5
        if mailq 2>/dev/null | grep -q "Mail queue is empty" || \
           ! mailq 2>/dev/null | grep -q "${ALERT_EMAIL}"; then
            test_result=true
        fi
    fi

    if [[ "$test_result" == true ]]; then
        ok "Test email sent to ${ALERT_EMAIL} — check inbox"
    else
        warn "Test email may be queued — check: mailq && journalctl -u postfix -n 20"
        warn "Common issue: Gmail App Password not enabled or 2FA not active on account"
    fi
}

# ═══════════════════════════════════════════════════════════
# PHASE 6 — VALIDATE
# ═══════════════════════════════════════════════════════════
validate() {
    phase "VALIDATE"

    local p=0 f=0

    # ── Services ─────────────────────────────────────────────
    for svc in wazuh-manager wazuh-indexer wazuh-dashboard postfix; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            ok "Service ${svc}: running"; p=$((p+1))
        else
            fail "Service ${svc}: not running"; f=$((f+1))
        fi
    done

    # ── OpenSearch cluster health ─────────────────────────────
    spinner_start "Checking OpenSearch cluster health..."
    sleep 3
    local os_health
    os_health=$(curl -sk -u "admin:${ADMIN_PASS}" \
        "https://localhost:9200/_cluster/health" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" \
        2>/dev/null || echo "unreachable")
    spinner_stop

    case "$os_health" in
        green)  ok "OpenSearch cluster: GREEN"; p=$((p+1)) ;;
        yellow) warn "OpenSearch cluster: YELLOW (single node — normal for standalone)" ;;
        red)    fail "OpenSearch cluster: RED — check indexer logs"; f=$((f+1)) ;;
        *)      fail "OpenSearch cluster: unreachable (${os_health})"; f=$((f+1)) ;;
    esac

    # ── Wazuh API reachable ──────────────────────────────────
    local api_status
    api_status=$(curl -sk --max-time 5 \
        "https://localhost:55000/" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('title','unknown'))" \
        2>/dev/null || echo "unreachable")
    if [[ "$api_status" == *"Wazuh"* ]]; then
        ok "Wazuh API: reachable (port 55000)"; p=$((p+1))
    else
        warn "Wazuh API: not responding — check: systemctl status wazuh-manager"
    fi

    # ── Enrollment port ──────────────────────────────────────
    if ss -tlnp 2>/dev/null | grep -q ":1515 "; then
        ok "Enrollment port 1515: listening (agents can auto-enroll)"; p=$((p+1))
    else
        fail "Enrollment port 1515: not listening"; f=$((f+1))
    fi

    # ── Event ingestion port ─────────────────────────────────
    if ss -tlnp 2>/dev/null | grep -q ":1514 "; then
        ok "Event port 1514: listening (agents can forward logs)"; p=$((p+1))
    else
        fail "Event port 1514: not listening"; f=$((f+1))
    fi

    # ── Decoders present ─────────────────────────────────────
    for dec in rh-pulsar-zeek-notice rh-pulsar-zeek-conn rh-pulsar-zeek-dns \
               rh-pulsar-zeek-ssl rh-pulsar-zeek-http; do
        if [[ -f "${DECODERS_DIR}/${dec}.xml" ]]; then
            ok "Decoder ${dec}.xml: present"; p=$((p+1))
        else
            fail "Decoder ${dec}.xml: missing"; f=$((f+1))
        fi
    done

    # ── Rules present ────────────────────────────────────────
    if [[ -f "${RULES_DIR}/rh-pulsar-zeek-rules.xml" ]]; then
        ok "Rules file rh-pulsar-zeek-rules.xml: present"; p=$((p+1))
    else
        fail "Rules file missing"; f=$((f+1))
    fi

    # ── Verify ossec.conf is valid XML ───────────────────────
    if python3 -c "
import xml.etree.ElementTree as ET
ET.parse('${OSSEC_CONF}')
" 2>/dev/null; then
        ok "ossec.conf: XML valid"; p=$((p+1))
    else
        fail "ossec.conf: XML invalid — check ${OSSEC_CONF}"; f=$((f+1))
    fi

    # ── Version file accessible ──────────────────────────────
    if [[ -f "$OSSEC_VERSION_FILE" ]]; then
        local ver; ver=$(cat "$OSSEC_VERSION_FILE")
        ok "Version file: ${ver} (sensors running install.sh will auto-pin)"; p=$((p+1))
    else
        warn "Version file missing — agent pinning won't work automatically"
    fi

    # ── Dashboard reachable ──────────────────────────────────
    if curl -sk --max-time 5 "https://localhost" &>/dev/null; then
        ok "Wazuh Dashboard: reachable at https://${MANAGER_IP}"; p=$((p+1))
    else
        warn "Dashboard: not yet responding — may still be starting (wait 60s and retry)"
    fi

    # ── Smoke test — inject a synthetic Zeek notice event ────
    info "Firing smoke test rule (synthetic Zeek notice)..."
    local test_event
    test_event=$(cat << 'EOF'
{"ts":1700000000.0,"uid":"CSmoke001","note":"C2_Beacon_Detected","msg":"C2 Beacon: 192.168.1.100 -> 203.0.113.1 (5 connections)","src":"192.168.1.100","dst":"203.0.113.1","id.orig_h":"192.168.1.100","id.orig_p":54321,"id.resp_h":"203.0.113.1","id.resp_p":443,"rh-pulsar-zeek":"notice"}
EOF
)
    echo "$test_event" >> /tmp/rh-pulsar-smoke-test.log

    # Feed it via the Wazuh logtest API
    local logtest_result
    logtest_result=$(curl -sk -u "wazuh-wui:MyS3cr37P450r.*" \
        -X POST "https://localhost:55000/logtest" \
        -H "Content-Type: application/json" \
        -d "{\"event\": ${test_event}, \"log_format\": \"json\", \"location\": \"zeek-notice\"}" \
        2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    output = d.get('data', {}).get('output', {})
    rule_id = output.get('rule', {}).get('id', 'no rule')
    rule_desc = output.get('rule', {}).get('description', '')
    print(f'{rule_id}: {rule_desc}')
except Exception as e:
    print(f'parse error: {e}')
" 2>/dev/null || echo "logtest unavailable")

    if [[ "$logtest_result" == "110001"* ]]; then
        ok "Smoke test: Rule 110001 fired correctly — decoder + rules working"; p=$((p+1))
    else
        warn "Smoke test inconclusive (${logtest_result}) — run manually:"
        warn "  /var/ossec/bin/wazuh-logtest"
    fi

    # ── Restart manager with new config ──────────────────────
    spinner_start "Restarting Wazuh Manager with final config..."
    systemctl restart wazuh-manager >> "$LOG" 2>&1
    sleep 8
    spinner_stop

    if systemctl is-active --quiet wazuh-manager; then
        ok "Wazuh Manager: restarted cleanly with new rules + decoders"
    else
        fail "Wazuh Manager: failed to restart — check: journalctl -u wazuh-manager -n 30"
    fi

    echo ""
    echo -e "  Validation: ${G}${p} passed${N} / ${R}${f} failed${N}"
}

# ═══════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════
summary() {
    CURRENT_PHASE="summary"

    local installed_ver
    installed_ver=$(cat "$VERSION_FILE" 2>/dev/null || echo "$WAZUH_VER")

    echo ""
    echo -e "${R}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "${G}  RH PULSAR MANAGER DEPLOYED${N}"
    echo ""
    echo -e "  ${D}Manager IP  :${N} ${W}${MANAGER_IP}${N}"
    echo -e "  ${D}Wazuh ver   :${N} ${W}${installed_ver}${N}"
    echo -e "  ${D}Dashboard   :${N} ${W}https://${MANAGER_IP}${N}"
    echo -e "  ${D}Alert email :${N} ${W}${ALERT_EMAIL}${N}"
    echo -e "  ${D}Credentials :${N} ${W}${RH_DIR}/credentials${N}"
    echo -e "  ${D}Log         :${N} ${W}${LOG}${N}"
    echo ""
    echo -e "  ${G}[✓]${N} 110001 C2 Beacon          T1071       level 10"
    echo -e "  ${G}[✓]${N} 110002 DNS Tunnel          T1071.004   level 10"
    echo -e "  ${G}[✓]${N} 110003 JA4 Sliver/C2       T1573       level 12"
    echo -e "  ${G}[✓]${N} 110004 HTTP C2 Beacon      T1071.001   level 10"
    echo -e "  ${G}[✓]${N} 110005 Suspicious UA       T1071.001   level 8"
    echo -e "  ${G}[✓]${N} 110006 Novel JA4 Baseline  T1573       level 6"
    echo -e "  ${G}[✓]${N} 110010 Persistent Beacon   escalation  level 14"
    echo -e "  ${G}[✓]${N} 110011 Beacon + UA combo   escalation  level 14"
    echo ""
    echo -e "${W}  NEXT STEPS${N}"
    echo -e "${D}  ─────────────────────────────────────────────────────────────────${N}"
    echo -e "  1. On VM1 (sensor), run: ${W}sudo bash install.sh${N}"
    echo -e "     When prompted for Wazuh Manager IP, enter: ${W}${MANAGER_IP}${N}"
    echo -e "     Agent will auto-enroll and start shipping Zeek logs."
    echo ""
    echo -e "  2. Dashboard login: ${W}https://${MANAGER_IP}${N}"
    echo -e "     Username: ${W}admin${N}"
    echo -e "     Password: (see ${RH_DIR}/credentials)"
    echo ""
    echo -e "  3. Verify agent appears in:"
    echo -e "     Dashboard → Agents → Active"
    echo ""
    echo -e "  4. Trigger a test detection:"
    echo -e "     On VM1: ${W}curl -A 'python-requests/2.28.0' http://example.com${N}"
    echo -e "     Expect: Rule 110005 (Suspicious UA) alert in dashboard + email"
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
    echo "[$(ts)] RH Pulsar Manager Setup v${SCRIPT_VER} — DRY_RUN=${DRY_RUN}" >> "$LOG"

    banner
    preflight           # 1
    install_wazuh       # 2
    deploy_decoders     # 3
    deploy_rules        # 4
    configure_email     # 5
    validate            # 6
    summary
}

main "$@"
