rh-pulsar
Passive Network Detection & Response Platform
Red Horizon Security — redhorizon.ph

WHAT IS RH PULSAR
RH Pulsar is a passive NDR sensor built on Zeek 8.2.0 with JA4+ TLS fingerprinting. It monitors every connection on your network without touching a single endpoint and detects advanced threats in under 5 seconds. All detection rules are mapped to MITRE ATT&CK. Alerts are delivered automatically to your SOC analyst inbox.
No agents. No network impact. Invisible to attackers.

DETECTION RULES
RuleDetectionMITRESeverity110001C2 Beacon — repeated connection patternT1071Level 12110002DNS Tunneling — subdomain abuse and record type analysisT1071.004Level 14110003Sliver C2 — JA4 and JA4S TLS fingerprint matchT1573Level 10110004HTTP C2 Beacon — same URI hit 10+ timesT1071.001Level 12110005Suspicious User-Agent — curl, python-requests, Sliver, Havoc, CobaltStrikeT1071.001Level 10

SUPPORTED SIEM INTEGRATIONS

Wazuh + OpenSearch (default RH Pulsar stack)
Splunk Enterprise / Cloud (Universal Forwarder + HEC)
Elastic / ELK Stack (Filebeat)
Microsoft Sentinel (Azure Monitor Agent)
IBM QRadar (Syslog forwarding)
Syslog Generic (any syslog-compatible SIEM)
Standalone (Zeek only — no SIEM)


REQUIREMENTS
ItemMinimumRecommendedOSUbuntu 24.04 LTSUbuntu 24.04 LTSCPU2 vCPU4 vCPURAM4GB8GBDisk20GB free120GBNetwork2 interfaces2 interfaces
Two network interfaces are required — one for management and one for passive capture. The capture interface must have no IP address assigned.

INSTALLATION
Step 1 — Clone the repository
git clone https://github.com/mesbieto/rh-pulsar.git
cd rh-pulsar
Step 2 — Make the installer executable
chmod +x rh-pulsar-installer.sh
Step 3 — Run the dry run first
Always run the dry run before installing. It checks your system for conflicts and tells you exactly what will be installed. Nothing is changed during a dry run.
sudo bash rh-pulsar-installer.sh --dry-run
Review the output. The dry run will show:

Passed checks in green
Warnings in yellow — handled automatically during install
Conflicts in red — must be resolved before proceeding

Step 4 — Resolve any conflicts
The most common conflicts on a fresh server are:
Disk space too low — expand your VM disk to at least 120GB then run:
sudo growpart /dev/sda 3
sudo resize2fs /dev/sda3
Only one network interface — add a second NIC in your hypervisor before installing. The capture interface needs no IP address.
Step 5 — Run the full installer
Once the dry run shows no conflicts:
sudo bash rh-pulsar-installer.sh
You will be prompted for:

SIEM platform selection (1–7)
Sensor name
Management interface
Capture interface
SOC alert email
SIEM host IP or credentials

Step 6 — Verify deployment
sudo /opt/zeek/bin/zeekctl status
ls /opt/zeek/logs/current/
Zeek should show running and logs should be generating.

WHAT THE INSTALLER DOES
PHASE 0   Bootstrap — installs minimal tools needed for checks
PHASE 1   Pre-flight — 9 categories of system checks
PHASE 2   SIEM selection
PHASE 3   Sensor configuration
PHASE 4   System preparation — kernel tuning, limits, firewall
PHASE 5   Zeek 8.2.0 installation
PHASE 6   JA4+ v0.18.8 installation
PHASE 7   Detection scripts deployment
PHASE 8   Zeek configuration
PHASE 9   SIEM forwarder installation
PHASE 10  Services start
PHASE 11  Post-install validation
PHASE 12  Deployment summary

AFTER INSTALLATION
PathContents/opt/zeek/logs/current/Live Zeek logs/opt/zeek/share/zeek/site/Detection scripts/etc/rh-pulsar/sensor_idUnique sensor ID/etc/rh-pulsar/siemSIEM platform name/etc/rh-pulsar/backup-*Config backups/var/log/rh-pulsar-install.logFull install log

ARCHITECTURE
NETWORK TRAFFIC
      ↓
ZEEK SENSOR (capture interface — no IP — promiscuous mode)
      ↓
DETECTION SCRIPTS (c2beacon, dnstunnel, detect-ja4, http-c2)
      ↓
SIEM FORWARDER (Wazuh Agent / Filebeat / Splunk UF / Rsyslog)
      ↓
SIEM PLATFORM (Wazuh / Elastic / Splunk / Sentinel / QRadar)
      ↓
SOC ANALYST INBOX — alert delivered under 5 seconds

ZEEK WATCHDOG
A cron job is installed automatically to keep Zeek running:
*/5 * * * * /opt/zeek/bin/zeekctl cron
This checks Zeek health every 5 minutes and restarts it if it crashes.

COMMON ISSUES
Zeek not starting after install — check the capture interface is in promiscuous mode:
ip link show ens37 | grep PROMISC
If not set:
sudo ip link set ens37 promisc on
sudo ip addr flush dev ens37
Wazuh Agent not connecting — verify the Wazuh Manager IP is reachable:
ping YOUR_WAZUH_MANAGER_IP
No logs generating — check Zeek status:
sudo /opt/zeek/bin/zeekctl status
sudo /opt/zeek/bin/zeekctl deploy
AppArmor blocking Zeek — if Zeek fails to capture due to AppArmor:
sudo aa-complain /opt/zeek/bin/zeek

UPDATING DETECTION RULES
To add or modify detection scripts:
cd /opt/zeek/share/zeek/site/
sudo nano c2beacon.zeek
sudo /opt/zeek/bin/zeekctl deploy

VALIDATED AGAINST

Sliver C2 v1.7.1-0kali4 — HTTPS port 443
dnscat2 — DNS tunnel port 53
Python3 HTTP server + curl loop — port 80
All 5 rules confirmed firing end-to-end in live environment


STACK VERSIONS
ComponentVersionZeek8.2.0JA4+0.18.8Wazuh Agent4.14.5Ubuntu24.04 LTS

LICENSE
© 2026 Red Horizon Security. All rights reserved.
Unauthorized use, reproduction, or distribution is prohibited.
Detection scripts, configuration, and installer are proprietary to Red Horizon Security.

CONTACT
Red Horizon Security
redhorizon.ph
