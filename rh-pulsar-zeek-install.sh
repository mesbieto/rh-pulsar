#!/bin/bash
# =============================================================
#  RH-Pulsar — Zeek NDR Sensor Installer
#  Red Horizon Cybersecurity | MVP Lab v1.0
#  Target OS : Ubuntu 24.04 LTS
#  Capture IF: ens37 (promiscuous / mirror)
#  Mgmt IF   : ens33 (management / Filebeat out)
# =============================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Config ───────────────────────────────────────────────────
HOSTNAME_NEW="RH-Pulsar"
CAPTURE_IF="ens37"
MGMT_IF="ens33"
ZEEK_VERSION="7.0"                         # LTS branch
ZEEK_PREFIX="/opt/zeek"
ZEEK_LOG_DIR="${ZEEK_PREFIX}/logs/current"
ZEEK_CONF="${ZEEK_PREFIX}/etc/node.cfg"
ZEEK_NETWORKS="${ZEEK_PREFIX}/etc/networks.cfg"
LOCAL_NETS="192.168.112.0/24"

# ── Pre-flight ───────────────────────────────────────────────
banner() {
cat << 'EOF'
 ____  _   _       ____        _
|  _ \| | | |     |  _ \ _   _| |___  __ _ _ __
| |_) | |_| |_____| |_) | | | | / __|/ _` | '__|
|  _ <|  _  |_____|  __/| |_| | \__ \ (_| | |
|_| \_\_| |_|     |_|    \__,_|_|___/\__,_|_|

Red Horizon — NDR Sensor Installer
EOF
}

check_root() {
    [[ $EUID -eq 0 ]] || error "Run as root: sudo bash $0"
}

check_os() {
    . /etc/os-release
    [[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] \
        || warn "Tested on Ubuntu 24.04. Proceeding anyway..."
}

check_interfaces() {
    ip link show "$CAPTURE_IF" &>/dev/null \
        || error "Capture interface ${CAPTURE_IF} not found. Check VMware NIC assignment."
    ip link show "$MGMT_IF" &>/dev/null \
        || error "Management interface ${MGMT_IF} not found."
    success "Interfaces ${MGMT_IF} and ${CAPTURE_IF} detected."
}

# ── Step 1: System prep ──────────────────────────────────────
set_hostname() {
    info "Setting hostname to ${HOSTNAME_NEW}..."
    hostnamectl set-hostname "$HOSTNAME_NEW"
    # Update /etc/hosts if not already present
    grep -q "$HOSTNAME_NEW" /etc/hosts \
        || sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME_NEW}/" /etc/hosts
    success "Hostname set."
}

system_update() {
    info "Updating system packages..."
    apt-get update -qq
    apt-get upgrade -y -qq
    success "System updated."
}

install_deps() {
    info "Installing build dependencies..."
    apt-get install -y -qq \
        curl gnupg2 lsb-release software-properties-common \
        cmake make gcc g++ flex bison libpcap-dev libssl-dev \
        python3 python3-dev swig zlib1g-dev libmaxminddb-dev \
        libkrb5-dev libmaxminddb0 mmdb-bin \
        net-tools tcpdump git jq
    success "Dependencies installed."
}

# ── Step 2: Zeek install ─────────────────────────────────────
add_zeek_repo() {
    info "Adding Zeek ${ZEEK_VERSION} repository..."
    CODENAME=$(lsb_release -cs)
    echo "deb http://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/ /" \
        > /etc/apt/sources.list.d/zeek.list
    curl -fsSL \
        "https://download.opensuse.org/repositories/security:zeek/xUbuntu_24.04/Release.key" \
        | gpg --dearmor > /etc/apt/trusted.gpg.d/zeek.gpg
    apt-get update -qq
    success "Zeek repo added."
}

install_zeek() {
    info "Installing Zeek (this may take a few minutes)..."
    apt-get install -y -qq zeek
    # Symlink for convenience
    [[ -f /usr/local/bin/zeek ]] || ln -sf "${ZEEK_PREFIX}/bin/zeek" /usr/local/bin/zeek
    [[ -f /usr/local/bin/zeekctl ]] || ln -sf "${ZEEK_PREFIX}/bin/zeekctl" /usr/local/bin/zeekctl
    # Add to PATH permanently
    echo "export PATH=\$PATH:${ZEEK_PREFIX}/bin" > /etc/profile.d/zeek.sh
    export PATH="$PATH:${ZEEK_PREFIX}/bin"
    success "Zeek installed: $(zeek --version 2>&1 | head -1)"
}

# ── Step 3: Configure Zeek ───────────────────────────────────
configure_zeek() {
    info "Configuring Zeek node..."

    # node.cfg — standalone sensor on ens37
    cat > "$ZEEK_CONF" << EOF
[logger]
type=logger
host=localhost

[manager]
type=manager
host=localhost

[proxy-1]
type=proxy
host=localhost

[worker-1]
type=worker
host=localhost
interface=${CAPTURE_IF}
EOF

    # networks.cfg — tell Zeek about your local segment
    cat > "$ZEEK_NETWORKS" << EOF
# Red Horizon Lab — local network definition
${LOCAL_NETS}    RH-Lab Internal Network
EOF

    # local.zeek — enable key detection scripts
    cat > "${ZEEK_PREFIX}/share/zeek/site/local.zeek" << 'EOF'
##############################################################
# RH-Pulsar local.zeek — Red Horizon NDR sensor config
##############################################################

# ── Core logs ────────────────────────────────────────────────
@load base/frameworks/logging
@load base/protocols/conn
@load base/protocols/dns
@load base/protocols/http
@load base/protocols/ftp
@load base/protocols/smtp
@load base/protocols/ssh
@load base/protocols/ssl
@load base/protocols/rdp
@load base/protocols/smb
@load base/frameworks/files

# ── Detection ────────────────────────────────────────────────
@load policy/frameworks/notice/do-log
@load policy/protocols/conn/known-hosts
@load policy/protocols/conn/known-services
@load policy/protocols/dns/detect-external-names
@load policy/protocols/http/detect-sqli
@load policy/protocols/http/detect-webapps
@load policy/protocols/ssh/detect-bruteforcing
@load policy/protocols/ssl/detect-MITM-proxy
@load policy/protocols/ssl/validate-certs
@load policy/protocols/ftp/detect

# ── File extraction markers ──────────────────────────────────
@load base/frameworks/files/magic
@load policy/frameworks/files/hash-all-files
@load policy/frameworks/files/detect-MHR

# ── Redef: JSON log output ───────────────────────────────────
redef LogAscii::use_json = T;

# ── Alert on new hosts ───────────────────────────────────────
redef Known::host_store_expiry = 1day;
EOF

    success "Zeek configured."
}

# ── Step 4: Promiscuous mode on capture interface ────────────
set_promiscuous() {
    info "Setting ${CAPTURE_IF} to promiscuous mode..."

    # Persistent via systemd-networkd override
    mkdir -p /etc/systemd/network
    cat > "/etc/systemd/network/10-${CAPTURE_IF}-promisc.link" << EOF
[Match]
OriginalName=${CAPTURE_IF}

[Link]
Promiscuous=yes
EOF

    # Also set immediately
    ip link set "$CAPTURE_IF" promisc on
    ip link set "$CAPTURE_IF" up

    success "Promiscuous mode enabled on ${CAPTURE_IF}."
}

# ── Step 5: Zeek systemd service ────────────────────────────
install_service() {
    info "Installing Zeek as a systemd service..."

    cat > /etc/systemd/system/zeek.service << EOF
[Unit]
Description=Red Horizon Pulsar — Zeek NDR Sensor
Documentation=https://docs.zeek.org
After=network.target
Wants=network.target

[Service]
Type=forking
User=root
ExecStartPre=${ZEEK_PREFIX}/bin/zeekctl check
ExecStart=${ZEEK_PREFIX}/bin/zeekctl start
ExecStop=${ZEEK_PREFIX}/bin/zeekctl stop
ExecReload=${ZEEK_PREFIX}/bin/zeekctl reload
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Set up ZeekControl cron for log rotation
    (crontab -l 2>/dev/null; echo "*/5 * * * * ${ZEEK_PREFIX}/bin/zeekctl cron") | crontab -

    systemctl daemon-reload
    systemctl enable zeek.service
    success "Zeek service installed and enabled."
}

# ── Step 6: Deploy ───────────────────────────────────────────
deploy_zeek() {
    info "Running zeekctl deploy..."
    "${ZEEK_PREFIX}/bin/zeekctl" deploy || \
        warn "zeekctl deploy encountered issues — check: zeekctl diag"
    success "Zeek deployed."
}

# ── Step 7: Validate ────────────────────────────────────────
validate() {
    info "Validating Zeek is running..."
    sleep 3
    if "${ZEEK_PREFIX}/bin/zeekctl" status | grep -q "running"; then
        success "Zeek is RUNNING on ${CAPTURE_IF}"
    else
        warn "Zeek may not be running. Check: zeekctl diag"
    fi

    info "Log directory contents:"
    ls -lh "$ZEEK_LOG_DIR" 2>/dev/null || warn "Log dir empty — generate traffic to populate."
}

# ── Summary ──────────────────────────────────────────────────
print_summary() {
cat << EOF

${BOLD}══════════════════════════════════════════════${NC}
${GREEN}  RH-Pulsar — Zeek Install Complete${NC}
${BOLD}══════════════════════════════════════════════${NC}

  Hostname     : ${HOSTNAME_NEW}
  Capture IF   : ${CAPTURE_IF}  (promiscuous)
  Mgmt IF      : ${MGMT_IF}
  Zeek prefix  : ${ZEEK_PREFIX}
  Log output   : ${ZEEK_LOG_DIR}
  Log format   : JSON (Filebeat-ready)

${BOLD}Next steps:${NC}
  1. Generate traffic (run Kali attack from 192.168.112.x)
  2. Verify logs: tail -f ${ZEEK_LOG_DIR}/conn.log
  3. Install Filebeat → Wazuh (run rh-filebeat-install.sh)

${BOLD}Useful commands:${NC}
  zeekctl status   — check sensor health
  zeekctl diag     — view errors
  zeekctl stop     — stop sensor
  zeekctl start    — start sensor

EOF
}

# ── Main ─────────────────────────────────────────────────────
main() {
    banner
    check_root
    check_os
    check_interfaces
    set_hostname
    system_update
    install_deps
    add_zeek_repo
    install_zeek
    configure_zeek
    set_promiscuous
    install_service
    deploy_zeek
    validate
    print_summary
}

main "$@"
