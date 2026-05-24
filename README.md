# rh-pulsar
Passive NDR Sensor — Red Horizon

Detects C2 beaconing, DNS tunneling, TLS anomalies, and HTTP C2 in under 5 seconds. Zero agents. Zero network impact.

---

## Requirements
- Ubuntu 24.04 LTS
- 4 vCPU / 8GB RAM / 120GB disk
- 2 network interfaces (management + capture)

---

## Quick Start

```bash
git clone https://github.com/mesbieto/rh-pulsar.git
cd rh-pulsar
chmod +x rh-pulsar-installer.sh

# Check system readiness first
sudo bash rh-pulsar-installer.sh --dry-run

# Install
sudo bash rh-pulsar-installer.sh
```

---

## Supported SIEM
Wazuh, Splunk, Elastic, Microsoft Sentinel, IBM QRadar, Syslog, Standalone

---

## Detection Rules

| Rule | Detection | MITRE |
|---|---|---|
| 110001 | C2 Beacon | T1071 |
| 110002 | DNS Tunneling | T1071.004 |
| 110003 | Sliver JA4/JA4S | T1573 |
| 110004 | HTTP C2 Beacon | T1071.001 |
| 110005 | Suspicious User-Agent | T1071.001 |

---

## After Install
```bash
# Check Zeek status
sudo /opt/zeek/bin/zeekctl status

# View live logs
ls /opt/zeek/logs/current/

# Install log
cat /var/log/rh-pulsar-install.log
```

---

© 2026 Red Horizon — redhorizon.ph
