#!/bin/bash
# =============================================================
#  RH-Wazuh — Complete Cleanup Script
#  Red Horizon Cybersecurity | MVP Lab v1.0
#  Purpose : Remove ALL Wazuh components, Filebeat, OpenSearch
#            and related configs for a clean slate install
#  Target  : Ubuntu 24.04 LTS
# =============================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Pre-flight ───────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || error "Run as root: sudo bash $0"
}

banner() {
cat << 'EOF'
 __        __              _      ____ _
 \ \      / /_ _ _____   _| |__  / ___| | ___  __ _ _ __
  \ \ /\ / / _` |_  / | | | '_ \| |   | |/ _ \/ _` | '_ \
   \ V  V / (_| |/ /| |_| | | | | |___| |  __/ (_| | | | |
    \_/\_/ \__,_/___|\__,_|_| |_|\____|_|\___|\__,_|_| |_|

Red Horizon — Wazuh Complete Cleanup
EOF
}

confirm() {
    echo ""
    warn "This will REMOVE all Wazuh components, Filebeat, and related data."
    warn "This action is IRREVERSIBLE."
    echo ""
    read -rp "Type YES to continue: " CONFIRM
    [[ "$CONFIRM" == "YES" ]] || { info "Aborted."; exit 0; }
    echo ""
}

# ── Step 1: Stop all services ────────────────────────────────
stop_services() {
    info "Stopping all Wazuh-related services..."
    local services=(
        wazuh-manager
        wazuh-indexer
        wazuh-dashboard
        filebeat
        postfix
    )
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc"
            echo -e "  ${GREEN}stopped${NC} — $svc"
        else
            echo -e "  ${YELLOW}not running${NC} — $svc"
        fi
    done
    success "Services stopped."
}

# ── Step 2: Disable services ─────────────────────────────────
disable_services() {
    info "Disabling services from startup..."
    local services=(
        wazuh-manager
        wazuh-indexer
        wazuh-dashboard
        filebeat
    )
    for svc in "${services[@]}"; do
        systemctl disable "$svc" 2>/dev/null && \
            echo -e "  ${GREEN}disabled${NC} — $svc" || \
            echo -e "  ${YELLOW}not found${NC} — $svc"
    done
    success "Services disabled."
}

# ── Step 3: Remove packages ──────────────────────────────────
remove_packages() {
    info "Removing Wazuh packages..."
    local packages=(
        wazuh-manager
        wazuh-indexer
        wazuh-dashboard
        wazuh-agent
        filebeat
        filebeat-oss
        postfix
        libsasl2-modules
        mailutils
    )
    for pkg in "${packages[@]}"; do
        if dpkg -l "$pkg" &>/dev/null; then
            apt-get remove --purge -y -qq "$pkg"
            echo -e "  ${GREEN}removed${NC} — $pkg"
        else
            echo -e "  ${YELLOW}not installed${NC} — $pkg"
        fi
    done
    apt-get autoremove -y -qq
    apt-get autoclean -qq
    success "Packages removed."
}

# ── Step 4: Remove data directories ─────────────────────────
remove_directories() {
    info "Removing data directories..."
    local dirs=(
        /var/ossec
        /var/lib/wazuh-indexer
        /var/log/wazuh-indexer
        /etc/wazuh-indexer
        /etc/wazuh-dashboard
        /etc/wazuh-manager
        /usr/share/wazuh-indexer
        /usr/share/wazuh-dashboard
        /usr/share/filebeat
        /etc/filebeat
        /var/lib/filebeat
        /var/log/filebeat
        /tmp/wazuh-certificates
        /tmp/wazuh-certs-tool.sh
        /tmp/config.yml
        /tmp/filebeat-oss.deb
        /tmp/wazuh-filebeat.tar.gz
        /opt/rh-pulsar-bundle
    )
    for dir in "${dirs[@]}"; do
        if [[ -e "$dir" ]]; then
            rm -rf "$dir"
            echo -e "  ${GREEN}removed${NC} — $dir"
        else
            echo -e "  ${YELLOW}not found${NC} — $dir"
        fi
    done
    success "Directories cleaned."
}

# ── Step 5: Remove repos and keys ───────────────────────────
remove_repos() {
    info "Removing Wazuh apt repository and keys..."

    [[ -f /etc/apt/sources.list.d/wazuh.list ]] && \
        rm -f /etc/apt/sources.list.d/wazuh.list && \
        echo -e "  ${GREEN}removed${NC} — wazuh.list"

    [[ -f /usr/share/keyrings/wazuh.gpg ]] && \
        rm -f /usr/share/keyrings/wazuh.gpg && \
        echo -e "  ${GREEN}removed${NC} — wazuh.gpg"

    apt-get update -qq
    success "Repos cleaned."
}

# ── Step 6: Remove systemd unit files ───────────────────────
remove_systemd() {
    info "Removing leftover systemd unit files..."
    local units=(
        /etc/systemd/system/wazuh-manager.service
        /etc/systemd/system/wazuh-indexer.service
        /etc/systemd/system/wazuh-dashboard.service
        /etc/systemd/system/filebeat.service
    )
    for unit in "${units[@]}"; do
        if [[ -f "$unit" ]]; then
            rm -f "$unit"
            echo -e "  ${GREEN}removed${NC} — $unit"
        fi
    done
    systemctl daemon-reload
    success "Systemd units cleaned."
}

# ── Step 7: Remove postfix / mail config ─────────────────────
remove_mail() {
    info "Cleaning mail configuration..."
    local mail_files=(
        /etc/postfix/sasl_passwd
        /etc/postfix/sasl_passwd.db
        /etc/postfix/main.cf.bak
    )
    for f in "${mail_files[@]}"; do
        [[ -f "$f" ]] && rm -f "$f" && \
            echo -e "  ${GREEN}removed${NC} — $f"
    done
    success "Mail config cleaned."
}

# ── Step 8: Reset firewall ───────────────────────────────────
reset_firewall() {
    info "Resetting UFW firewall rules..."
    if command -v ufw &>/dev/null; then
        ufw --force reset
        ufw --force disable
        success "UFW reset and disabled."
    else
        warn "UFW not installed — skipping."
    fi
}

# ── Step 9: Check for leftover processes ─────────────────────
check_processes() {
    info "Checking for leftover Wazuh processes..."
    local found=false
    for proc in wazuh ossec filebeat; do
        if pgrep -f "$proc" &>/dev/null; then
            warn "Process still running: $proc"
            pkill -f "$proc" 2>/dev/null || true
            found=true
        fi
    done
    [[ "$found" == "false" ]] && success "No leftover processes found."
}

# ── Step 10: Verify clean state ──────────────────────────────
verify_clean() {
    info "Verifying clean state..."
    echo ""
    local issues=0

    # Check packages
    for pkg in wazuh-manager wazuh-indexer wazuh-dashboard filebeat; do
        if dpkg -l "$pkg" &>/dev/null; then
            echo -e "  ${RED}STILL INSTALLED${NC} — $pkg"
            ((issues++))
        else
            echo -e "  ${GREEN}confirmed removed${NC} — $pkg"
        fi
    done

    # Check directories
    for dir in /var/ossec /var/lib/wazuh-indexer /etc/wazuh-indexer; do
        if [[ -d "$dir" ]]; then
            echo -e "  ${RED}STILL EXISTS${NC} — $dir"
            ((issues++))
        else
            echo -e "  ${GREEN}confirmed removed${NC} — $dir"
        fi
    done

    # Check services
    for svc in wazuh-manager wazuh-indexer wazuh-dashboard filebeat; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${RED}STILL RUNNING${NC} — $svc"
            ((issues++))
        else
            echo -e "  ${GREEN}confirmed stopped${NC} — $svc"
        fi
    done

    echo ""
    if [[ $issues -eq 0 ]]; then
        success "System is clean. Ready for fresh install."
    else
        warn "${issues} issue(s) found above — review before proceeding."
    fi
}

# ── Summary ──────────────────────────────────────────────────
print_summary() {
cat << EOF

${BOLD}══════════════════════════════════════════════${NC}
${GREEN}  RH-Wazuh — Clean Slate Complete${NC}
${BOLD}══════════════════════════════════════════════${NC}

${BOLD}Next steps:${NC}
  1. Reboot recommended before fresh install
     sudo reboot

  2. After reboot, fill in your .env
     cp .env.template .env && nano .env

  3. Run the fresh manager installer
     sudo bash 02-wazuh-manager-install.sh

EOF
}

# ── Main ─────────────────────────────────────────────────────
main() {
    banner
    check_root
    confirm
    stop_services
    disable_services
    remove_packages
    remove_directories
    remove_repos
    remove_systemd
    remove_mail
    reset_firewall
    check_processes
    verify_clean
    print_summary
}

main "$@"
