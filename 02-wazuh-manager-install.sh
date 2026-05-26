#!/bin/bash
# =============================================================
#  RH-Wazuh — Manager Full Stack Installer
#  Red Horizon Cybersecurity | MVP Lab v1.0
#  Target OS  : Ubuntu 24.04 LTS
#  Stack      : Wazuh Manager 4.14.5
#               Wazuh Indexer  4.14.5  (OpenSearch / 4GB heap)
#               Wazuh Dashboard 4.14.5
#               Filebeat-OSS   7.10.2
#               Gmail SMTP alerting
#  NICs       : ens33 = NAT (internet / Gmail)
#               ens37 = Host-Only 192.168.112.0/24 (agent comms)
# =============================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Version pins ─────────────────────────────────────────────
WAZUH_VERSION="4.14.5"
FILEBEAT_VERSION="7.10.2"
WAZUH_MAJOR_MINOR="4.x"

# ── Load .env if present ─────────────────────────────────────
ENV_FILE="$(dirname "$0")/.env"
if [[ -f "$ENV_FILE" ]]; then
    info "Loading config from .env..."
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

# ── Config (defaults — override via .env) ────────────────────
HOSTNAME_NEW="${HOSTNAME_NEW:-RH-Wazuh}"
MGMT_IF="${MGMT_IF:-ens33}"
AGENT_IF="${AGENT_IF:-ens37}"
WAZUH_MANAGER_IP="${WAZUH_MANAGER_IP:-192.168.112.10}"
INDEXER_HEAP="${INDEXER_HEAP:-4g}"                # half of 8GB RAM

# Gmail SMTP alerting
SMTP_SERVER="${SMTP_SERVER:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"                        # set in .env
SMTP_PASS="${SMTP_PASS:-}"                        # app password
ALERT_RECIPIENT="${ALERT_RECIPIENT:-}"            # analyst email
ALERT_LEVEL="${ALERT_LEVEL:-10}"                  # min alert level to email

# Enrollment
ENROLLMENT_PASSWORD="${ENROLLMENT_PASSWORD:-RedHorizon@Secure2025!}"

# ── Banner ───────────────────────────────────────────────────
banner() {
cat << 'EOF'
 ____  _   _  __        __               _
|  _ \| | | | \ \      / /_ _ _____   _| |__
| |_) | |_| |  \ \ /\ / / _` |_  / | | | '_ \
|  _ <|  _  |   \ V  V / (_| |/ /| |_| | | | |
|_| \_\_| |_|    \_/\_/ \__,_/___|\__,_|_| |_|

Red Horizon — Wazuh Manager Stack Installer v4.14.5
EOF
}

# ── Pre-flight ───────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || error "Run as root: sudo bash $0"
}

check_os() {
    . /etc/os-release
    [[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] \
        || warn "Tested on Ubuntu 24.04. Proceeding anyway..."
}

check_ram() {
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
    [[ $TOTAL_RAM_GB -ge 7 ]] \
        || warn "Less than 8GB RAM detected (${TOTAL_RAM_GB}GB). OpenSearch may be slow."
    success "RAM: ${TOTAL_RAM_GB}GB detected."
}

check_interfaces() {
    ip link show "$MGMT_IF"  &>/dev/null || error "Interface ${MGMT_IF} not found."
    ip link show "$AGENT_IF" &>/dev/null || error "Interface ${AGENT_IF} not found."
    success "Interfaces ${MGMT_IF} and ${AGENT_IF} detected."
}

check_smtp_config() {
    if [[ -z "$SMTP_USER" || -z "$SMTP_PASS" || -z "$ALERT_RECIPIENT" ]]; then
        warn "Gmail SMTP not fully configured in .env — email alerting will be skipped."
        SMTP_ENABLED=false
    else
        SMTP_ENABLED=true
        success "Gmail SMTP configured for ${SMTP_USER}."
    fi
}

# ── Step 1: System prep ──────────────────────────────────────
set_hostname() {
    info "Setting hostname to ${HOSTNAME_NEW}..."
    hostnamectl set-hostname "$HOSTNAME_NEW"
    grep -q "$HOSTNAME_NEW" /etc/hosts \
        || sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME_NEW}/" /etc/hosts
    success "Hostname set."
}

system_update() {
    info "Updating system packages..."
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        curl wget gnupg2 apt-transport-https lsb-release \
        software-properties-common ca-certificates \
        net-tools jq unzip openssl
    success "System updated."
}

# ── Step 2: Wazuh repo ───────────────────────────────────────
add_wazuh_repo() {
    info "Adding Wazuh ${WAZUH_VERSION} repository..."
    curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
        | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] \
https://packages.wazuh.com/${WAZUH_MAJOR_MINOR}/apt/ stable main" \
        > /etc/apt/sources.list.d/wazuh.list
    apt-get update -qq
    success "Wazuh repo added."
}

# ── Step 3: Wazuh Indexer (OpenSearch) ──────────────────────
install_indexer() {
    info "Installing Wazuh Indexer ${WAZUH_VERSION}..."
    apt-get install -y -qq wazuh-indexer="${WAZUH_VERSION}-*"

    # JVM heap — 4g for 8GB system (50% rule)
    info "Tuning OpenSearch JVM heap to ${INDEXER_HEAP}..."
    cat > /etc/wazuh-indexer/jvm.options.d/rh-heap.options << EOF
-Xms${INDEXER_HEAP}
-Xmx${INDEXER_HEAP}
EOF

    # opensearch.yml — bind to manager IP
    cat > /etc/wazuh-indexer/opensearch.yml << EOF
network.host: "${WAZUH_MANAGER_IP}"
node.name: "rh-wazuh-indexer"
cluster.initial_master_nodes:
  - "rh-wazuh-indexer"
cluster.name: "rh-wazuh-cluster"
path.data: /var/lib/wazuh-indexer
path.logs: /var/log/wazuh-indexer
plugins.security.ssl.http.enabled: true
plugins.security.ssl.http.pemcert_filepath: /etc/wazuh-indexer/certs/indexer.pem
plugins.security.ssl.http.pemkey_filepath: /etc/wazuh-indexer/certs/indexer-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: /etc/wazuh-indexer/certs/root-ca.pem
plugins.security.ssl.transport.pemcert_filepath: /etc/wazuh-indexer/certs/indexer.pem
plugins.security.ssl.transport.pemkey_filepath: /etc/wazuh-indexer/certs/indexer-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: /etc/wazuh-indexer/certs/root-ca.pem
plugins.security.ssl.transport.enforce_hostname_verification: false
plugins.security.authcz.admin_dn:
  - "CN=admin,OU=Wazuh,O=Wazuh,L=California,C=US"
plugins.security.nodes_dn:
  - "CN=rh-wazuh-indexer,OU=Wazuh,O=Wazuh,L=California,C=US"
EOF

    success "Wazuh Indexer installed."
}

# ── Step 4: Generate TLS certificates ───────────────────────
generate_certs() {
    info "Generating TLS certificates..."
    CERT_DIR="/etc/wazuh-indexer/certs"
    mkdir -p "$CERT_DIR"

    # Use Wazuh's cert tool
    curl -fsSL \
        "https://packages.wazuh.com/${WAZUH_MAJOR_MINOR}/wazuh-certs-tool.sh" \
        -o /tmp/wazuh-certs-tool.sh
    chmod +x /tmp/wazuh-certs-tool.sh

    cat > /tmp/config.yml << EOF
nodes:
  indexer:
    - name: rh-wazuh-indexer
      ip: "${WAZUH_MANAGER_IP}"
  server:
    - name: rh-wazuh-manager
      ip: "${WAZUH_MANAGER_IP}"
  dashboard:
    - name: rh-wazuh-dashboard
      ip: "${WAZUH_MANAGER_IP}"
EOF

    bash /tmp/wazuh-certs-tool.sh -A -c /tmp/config.yml

    # Distribute certs to indexer
    tar -xf ./wazuh-certificates.tar -C /tmp/
    cp /tmp/wazuh-certificates/rh-wazuh-indexer.pem     "${CERT_DIR}/indexer.pem"
    cp /tmp/wazuh-certificates/rh-wazuh-indexer-key.pem "${CERT_DIR}/indexer-key.pem"
    cp /tmp/wazuh-certificates/root-ca.pem              "${CERT_DIR}/root-ca.pem"
    cp /tmp/wazuh-certificates/admin.pem                "${CERT_DIR}/admin.pem"
    cp /tmp/wazuh-certificates/admin-key.pem            "${CERT_DIR}/admin-key.pem"

    chmod 500 "$CERT_DIR"
    chmod 400 "${CERT_DIR}"/*.pem

    # Save cert bundle for sensor deployment packages
    BUNDLE_DIR="/opt/rh-pulsar-bundle"
    mkdir -p "$BUNDLE_DIR"
    cp /tmp/wazuh-certificates/root-ca.pem "${BUNDLE_DIR}/rh-ca.pem"
    cp /tmp/wazuh-certificates/rh-wazuh-manager.pem     "${BUNDLE_DIR}/"
    cp /tmp/wazuh-certificates/rh-wazuh-manager-key.pem "${BUNDLE_DIR}/"

    success "TLS certificates generated. Sensor bundle saved to ${BUNDLE_DIR}."
}

start_indexer() {
    info "Starting Wazuh Indexer..."
    systemctl daemon-reload
    systemctl enable wazuh-indexer
    systemctl start wazuh-indexer

    # Wait for indexer to be ready
    info "Waiting for Indexer to be ready..."
    for i in {1..30}; do
        if curl -fsSk \
            --cert /etc/wazuh-indexer/certs/admin.pem \
            --key  /etc/wazuh-indexer/certs/admin-key.pem \
            "https://${WAZUH_MANAGER_IP}:9200" &>/dev/null; then
            success "Indexer is up."
            break
        fi
        sleep 5
        [[ $i -eq 30 ]] && error "Indexer failed to start in 150s. Check: journalctl -u wazuh-indexer"
    done

    # Initialize security plugin
    export JAVA_HOME=/usr/share/wazuh-indexer/jdk
    bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
        -cd /etc/wazuh-indexer/opensearch-security/ \
        -nhnv \
        -cacert /etc/wazuh-indexer/certs/root-ca.pem \
        -cert   /etc/wazuh-indexer/certs/admin.pem \
        -key    /etc/wazuh-indexer/certs/admin-key.pem \
        -h "${WAZUH_MANAGER_IP}" \
        -p 9200 || warn "Security init may need manual run — check indexer logs."

    success "Indexer initialized."
}

# ── Step 5: Wazuh Manager ────────────────────────────────────
install_manager() {
    info "Installing Wazuh Manager ${WAZUH_VERSION}..."
    apt-get install -y -qq wazuh-manager="${WAZUH_VERSION}-*"
    success "Wazuh Manager installed."
}

configure_manager() {
    info "Configuring Wazuh Manager..."
    OSSEC_CONF="/var/ossec/etc/ossec.conf"

    # Backup original
    cp "$OSSEC_CONF" "${OSSEC_CONF}.bak"

    # Enrollment password
    cat > /var/ossec/etc/authd.pass << EOF
${ENROLLMENT_PASSWORD}
EOF
    chmod 640 /var/ossec/etc/authd.pass
    chown root:wazuh /var/ossec/etc/authd.pass

    # Patch ossec.conf — enrollment, alerts, email
    python3 << PYEOF
import xml.etree.ElementTree as ET

tree = ET.parse('${OSSEC_CONF}')
root = tree.getroot()

# Enable enrollment with password
auth = root.find('.//auth')
if auth is not None:
    use_pass = auth.find('use_password')
    if use_pass is None:
        use_pass = ET.SubElement(auth, 'use_password')
    use_pass.text = 'yes'

    disabled = auth.find('disabled')
    if disabled is not None:
        disabled.text = 'no'

# Email alerts
global_el = root.find('global')
if global_el is not None:
    def set_or_create(parent, tag, val):
        el = parent.find(tag)
        if el is None:
            el = ET.SubElement(parent, tag)
        el.text = val

    set_or_create(global_el, 'email_notification', '${SMTP_ENABLED}')
    set_or_create(global_el, 'smtp_server', '${SMTP_SERVER}')
    set_or_create(global_el, 'email_from', '${SMTP_USER}')
    set_or_create(global_el, 'email_to', '${ALERT_RECIPIENT}')
    set_or_create(global_el, 'email_maxperhour', '12')
    set_or_create(global_el, 'alerts_log', 'yes')

tree.write('${OSSEC_CONF}')
print("ossec.conf updated.")
PYEOF

    # Custom rules for Zeek log integration
    mkdir -p /var/ossec/etc/rules
    cat > /var/ossec/etc/rules/rh_zeek_rules.xml << 'RULES'
<!-- Red Horizon — Zeek NDR Detection Rules -->
<group name="zeek,ndr,red_horizon">

  <!-- SSH Brute Force from Zeek -->
  <rule id="100001" level="10">
    <if_sid>5551</if_sid>
    <field name="zeek.ssh.auth_success">false</field>
    <description>RH-Pulsar: SSH brute force attempt detected via Zeek</description>
    <mitre><id>T1110.001</id></mitre>
    <group>authentication_failed,brute_force</group>
  </rule>

  <!-- DNS Exfiltration indicator -->
  <rule id="100002" level="12">
    <decoded_as>json</decoded_as>
    <field name="zeek.dns.qtype_name">TXT</field>
    <field name="zeek.dns.query">\.{40,}</field>
    <description>RH-Pulsar: Possible DNS exfiltration — long TXT query detected</description>
    <mitre><id>T1071.004</id></mitre>
    <group>data_exfiltration,dns</group>
  </rule>

  <!-- Port scan detection -->
  <rule id="100003" level="10">
    <decoded_as>json</decoded_as>
    <field name="zeek.conn.conn_state">S0</field>
    <description>RH-Pulsar: Port scan detected — unanswered SYN connections</description>
    <mitre><id>T1046</id></mitre>
    <group>network_scan,recon</group>
  </rule>

  <!-- HTTP SQLi indicator -->
  <rule id="100004" level="12">
    <decoded_as>json</decoded_as>
    <field name="zeek.http.uri">select|union|insert|drop|--|%27|%3B</field>
    <description>RH-Pulsar: SQL injection attempt detected in HTTP URI</description>
    <mitre><id>T1190</id></mitre>
    <group>web_attack,sqli</group>
  </rule>

  <!-- Zeek notice — any high severity -->
  <rule id="100005" level="10">
    <decoded_as>json</decoded_as>
    <field name="zeek.notice.note">.</field>
    <description>RH-Pulsar: Zeek notice generated — $(zeek.notice.note)</description>
    <group>zeek_notice,ids</group>
  </rule>

  <!-- New host on network -->
  <rule id="100006" level="6">
    <decoded_as>json</decoded_as>
    <field name="zeek.known_hosts.host">.</field>
    <description>RH-Pulsar: New host observed on network — $(zeek.known_hosts.host)</description>
    <mitre><id>T1078</id></mitre>
    <group>network_discovery</group>
  </rule>

</group>
RULES

    success "Wazuh Manager configured."
}

start_manager() {
    info "Starting Wazuh Manager..."
    systemctl daemon-reload
    systemctl enable wazuh-manager
    systemctl start wazuh-manager
    sleep 5
    systemctl is-active --quiet wazuh-manager \
        && success "Wazuh Manager running." \
        || error "Wazuh Manager failed to start. Check: journalctl -u wazuh-manager"
}

# ── Step 6: Filebeat ─────────────────────────────────────────
install_filebeat() {
    info "Installing Filebeat-OSS ${FILEBEAT_VERSION}..."
    curl -fsSL \
        "https://packages.wazuh.com/${WAZUH_MAJOR_MINOR}/apt/pool/main/f/filebeat/filebeat-oss_${FILEBEAT_VERSION}_amd64.deb" \
        -o /tmp/filebeat-oss.deb
    dpkg -i /tmp/filebeat-oss.deb
    success "Filebeat-OSS installed."
}

configure_filebeat() {
    info "Configuring Filebeat..."

    # Download Wazuh module for Filebeat
    curl -fsSL \
        "https://packages.wazuh.com/${WAZUH_MAJOR_MINOR}/filebeat/wazuh-filebeat-0.4.tar.gz" \
        -o /tmp/wazuh-filebeat.tar.gz
    tar -xzf /tmp/wazuh-filebeat.tar.gz -C /usr/share/filebeat/module/

    # Main filebeat.yml
    cat > /etc/filebeat/filebeat.yml << EOF
filebeat.modules:
  - module: wazuh
    alerts:
      enabled: true
    archives:
      enabled: false

setup.template.json.enabled: true
setup.template.json.path: '/etc/filebeat/wazuh-template.json'
setup.template.json.name: 'wazuh'
setup.template.overwrite: true
setup.ilm.enabled: false

output.elasticsearch:
  hosts:
    - "https://${WAZUH_MANAGER_IP}:9200"
  protocol: https
  username: "admin"
  password: "admin"
  ssl.certificate_authorities:
    - /etc/filebeat/certs/root-ca.pem

logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat
  keepfiles: 7
  permissions: 0644
EOF

    # Copy CA cert for Filebeat → Indexer TLS
    mkdir -p /etc/filebeat/certs
    cp /opt/rh-pulsar-bundle/rh-ca.pem /etc/filebeat/certs/root-ca.pem

    # Download Wazuh template
    curl -fsSL \
        "https://raw.githubusercontent.com/wazuh/wazuh/${WAZUH_MAJOR_MINOR}/extensions/elasticsearch/7.x/wazuh-template.json" \
        -o /etc/filebeat/wazuh-template.json

    systemctl daemon-reload
    systemctl enable filebeat
    systemctl start filebeat
    sleep 3
    systemctl is-active --quiet filebeat \
        && success "Filebeat running." \
        || warn "Filebeat may have issues — check: journalctl -u filebeat"
}

# ── Step 7: Wazuh Dashboard ──────────────────────────────────
install_dashboard() {
    info "Installing Wazuh Dashboard ${WAZUH_VERSION}..."
    apt-get install -y -qq wazuh-dashboard="${WAZUH_VERSION}-*"

    DASH_CONF="/etc/wazuh-dashboard/opensearch_dashboards.yml"
    cat > "$DASH_CONF" << EOF
server.host: "0.0.0.0"
server.port: 443
opensearch.hosts: ["https://${WAZUH_MANAGER_IP}:9200"]
opensearch.ssl.verificationMode: certificate
opensearch.username: "kibanaserver"
opensearch.password: "kibanaserver"
opensearch.requestHeadersAllowlist: ["securitytenant","Authorization"]
opensearch_security.multitenancy.enabled: false
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
server.ssl.enabled: true
server.ssl.key: "/etc/wazuh-dashboard/certs/dashboard-key.pem"
server.ssl.certificate: "/etc/wazuh-dashboard/certs/dashboard.pem"
opensearch.ssl.certificateAuthorities:
  - "/etc/wazuh-dashboard/certs/root-ca.pem"
EOF

    # Dashboard certs
    DASH_CERT_DIR="/etc/wazuh-dashboard/certs"
    mkdir -p "$DASH_CERT_DIR"
    cp /tmp/wazuh-certificates/rh-wazuh-dashboard.pem     "${DASH_CERT_DIR}/dashboard.pem"
    cp /tmp/wazuh-certificates/rh-wazuh-dashboard-key.pem "${DASH_CERT_DIR}/dashboard-key.pem"
    cp /tmp/wazuh-certificates/root-ca.pem                "${DASH_CERT_DIR}/root-ca.pem"
    chmod 500 "$DASH_CERT_DIR"
    chmod 400 "${DASH_CERT_DIR}"/*.pem

    systemctl daemon-reload
    systemctl enable wazuh-dashboard
    systemctl start wazuh-dashboard
    sleep 5
    systemctl is-active --quiet wazuh-dashboard \
        && success "Wazuh Dashboard running." \
        || warn "Dashboard may need a moment — check: journalctl -u wazuh-dashboard"
}

# ── Step 8: Gmail SMTP alerting ──────────────────────────────
configure_gmail() {
    if [[ "$SMTP_ENABLED" == "false" ]]; then
        warn "Skipping Gmail config — SMTP credentials not set in .env"
        return
    fi

    info "Configuring Gmail SMTP alerting..."

    # Install postfix for mail relay
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        postfix libsasl2-modules mailutils

    # Postfix main.cf
    postconf -e "relayhost = [${SMTP_SERVER}]:${SMTP_PORT}"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_tls_security_level = encrypt"
    postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
    postconf -e "smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated defer_unauth_destination"

    # SASL credentials
    echo "[${SMTP_SERVER}]:${SMTP_PORT} ${SMTP_USER}:${SMTP_PASS}" \
        > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd

    systemctl restart postfix
    systemctl enable postfix

    # Test email
    echo "Red Horizon Wazuh Stack installed successfully on $(hostname) at $(date)" \
        | mail -s "[RH-Wazuh] Stack Installation Complete" "$ALERT_RECIPIENT" \
        && success "Test email sent to ${ALERT_RECIPIENT}." \
        || warn "Test email failed — verify Gmail app password and less-secure app access."
}

# ── Step 9: Firewall ─────────────────────────────────────────
configure_firewall() {
    info "Configuring UFW firewall..."
    apt-get install -y -qq ufw

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Wazuh Manager ports
    ufw allow in on "$AGENT_IF" to any port 1514 proto tcp  comment "Wazuh agent comms"
    ufw allow in on "$AGENT_IF" to any port 1514 proto udp  comment "Wazuh agent comms"
    ufw allow in on "$AGENT_IF" to any port 1515 proto tcp  comment "Wazuh enrollment"
    ufw allow in on "$AGENT_IF" to any port 55000 proto tcp comment "Wazuh API"

    # Dashboard (HTTPS)
    ufw allow 443/tcp comment "Wazuh Dashboard"

    # OpenSearch (internal only — bind to agent IF)
    ufw allow in on "$AGENT_IF" to any port 9200 proto tcp comment "OpenSearch API"

    # SSH management
    ufw allow in on "$MGMT_IF" to any port 22 proto tcp comment "SSH mgmt"

    # SMTP out (NAT interface)
    ufw allow out on "$MGMT_IF" to any port 587 proto tcp comment "Gmail SMTP"

    ufw --force enable
    success "Firewall configured."
}

# ── Step 10: Generate .env template for sensor ───────────────
generate_sensor_env() {
    info "Generating sensor .env template..."
    cat > /opt/rh-pulsar-bundle/sensor.env << EOF
# ============================================================
#  RH-Pulsar Sensor Config — generated by Wazuh Manager setup
#  Copy this to your sensor VM as .env alongside
#  01-zeek-install.sh before running the install.
# ============================================================

# Wazuh Manager
WAZUH_MANAGER_IP=${WAZUH_MANAGER_IP}
ENROLLMENT_PASSWORD=${ENROLLMENT_PASSWORD}
AGENT_NAME=RH-Pulsar-01          # Change per deployment

# Sensor network
CAPTURE_IF=ens37
MGMT_IF=ens33

# Client identifier (used in agent grouping)
CLIENT_NAME=RedHorizon-Lab
EOF

    success "Sensor .env saved to /opt/rh-pulsar-bundle/sensor.env"
    info "Copy /opt/rh-pulsar-bundle/ to your sensor VM to complete deployment."
}

# ── Validate ─────────────────────────────────────────────────
validate_stack() {
    info "Validating full stack..."
    echo ""
    for svc in wazuh-indexer wazuh-manager filebeat wazuh-dashboard; do
        if systemctl is-active --quiet "$svc"; then
            echo -e "  ${GREEN}●${NC} ${svc} — running"
        else
            echo -e "  ${RED}●${NC} ${svc} — NOT running"
        fi
    done
    echo ""
}

# ── Summary ──────────────────────────────────────────────────
print_summary() {
cat << EOF

${BOLD}══════════════════════════════════════════════════════${NC}
${GREEN}  RH-Wazuh Stack Install Complete — v${WAZUH_VERSION}${NC}
${BOLD}══════════════════════════════════════════════════════${NC}

  Hostname         : ${HOSTNAME_NEW}
  Manager IP       : ${WAZUH_MANAGER_IP}
  Agent IF         : ${AGENT_IF}  (port 1514/1515)
  Mgmt IF          : ${MGMT_IF}   (NAT / Gmail)

  Wazuh Manager    : /var/ossec/
  Wazuh Indexer    : port 9200  (heap: ${INDEXER_HEAP})
  Wazuh Dashboard  : https://${WAZUH_MANAGER_IP}
  Filebeat         : /etc/filebeat/
  Enrollment pass  : ${ENROLLMENT_PASSWORD}

  Sensor bundle    : /opt/rh-pulsar-bundle/
    ├── rh-ca.pem       ← copy to sensor
    └── sensor.env      ← rename to .env on sensor

${BOLD}Dashboard login:${NC}
  URL  : https://${WAZUH_MANAGER_IP}
  User : admin
  Pass : admin   ← CHANGE THIS after first login

${BOLD}Next steps:${NC}
  1. Change default admin password in Dashboard
  2. Copy /opt/rh-pulsar-bundle/ to RH-Pulsar VM
  3. Run 01-zeek-install.sh on sensor (with .env)
  4. Confirm agent appears in Dashboard → Agents
  5. Run Kali attack and verify alerts flow

${BOLD}Useful commands:${NC}
  systemctl status wazuh-manager
  /var/ossec/bin/agent_control -l     — list connected agents
  /var/ossec/bin/ossec-logtest        — test rules
  journalctl -u wazuh-indexer -f      — indexer logs

EOF
}

# ── Main ─────────────────────────────────────────────────────
main() {
    banner
    check_root
    check_os
    check_ram
    check_interfaces
    check_smtp_config
    set_hostname
    system_update
    add_wazuh_repo
    install_indexer
    generate_certs
    start_indexer
    install_manager
    configure_manager
    start_manager
    install_filebeat
    configure_filebeat
    install_dashboard
    configure_gmail
    configure_firewall
    generate_sensor_env
    validate_stack
    print_summary
}

main "$@"
