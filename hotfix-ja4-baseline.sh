#!/bin/bash
# RH Pulsar — Quick fix for v3.2.0/3.2.1 ja4-baseline.zeek Zeek syntax error
# Applies to: any VM where Zeek won't start due to "unknown identifier readfile"
# Run: sudo bash hotfix-ja4-baseline.sh

set -e

SITE="/opt/zeek/share/zeek/site"
TARGET="$SITE/ja4-baseline.zeek"
BACKUP="$TARGET.broken-$(date +%Y%m%d-%H%M%S)"

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }
[[ -d "$SITE" ]] || { echo "Zeek site dir not found at $SITE"; exit 1; }

echo "─ Backing up broken file..."
[[ -f "$TARGET" ]] && cp "$TARGET" "$BACKUP" && echo "  Saved: $BACKUP"

echo "─ Writing fixed ja4-baseline.zeek..."
cat > "$TARGET" << 'EOF'
# RH Pulsar — JA4 Environment Baseline (Tier 2 anomaly detection)
# Rule 110006 — MITRE T1573 / behavioral
#
# Phase 1: For 7 days after sensor deploy, observe and count JA4 sightings.
# Phase 2: After 7 days, fingerprints with >=3 sightings are "known-good".
# Phase 3: Alert on any JA4 not in the known set, not in malicious sets either.
#
# Note: Baseline is held in memory. If Zeek restarts, learning restarts.
module JA4Baseline;
export {
    redef enum Notice::Type += { Novel_JA4_Observed };
    global learning_period: interval = 7day;
    global sightings_threshold: count = 3;
    global novel_alert_threshold: count = 2;
    global suppress_for: interval = 24hr;
}
global baseline_started: time = current_time();
global ja4_sightings: table[string] of count &create_expire=30day &default=0;
global ja4_known: set[string] &create_expire=30day;

function in_learning_period(): bool {
    return (current_time() - baseline_started) < learning_period;
}

event ssl_established(c: connection) &priority=4 {
    if (!c?$ssl) return;
    if (!c$ssl?$ja4) return;
    if (c$ssl$ja4 == "") return;
    local j4 = c$ssl$ja4;
    if (j4 in DetectJA4::malicious_ja4_manual) return;
    if (j4 in DetectJA4::malicious_ja4_db) return;

    if (in_learning_period()) {
        ja4_sightings[j4] = ja4_sightings[j4] + 1;
        if (ja4_sightings[j4] >= sightings_threshold && j4 !in ja4_known) {
            add ja4_known[j4];
        }
    } else {
        if (j4 !in ja4_known) {
            ja4_sightings[j4] = ja4_sightings[j4] + 1;
            if (ja4_sightings[j4] >= novel_alert_threshold) {
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

echo "─ Validating with zeekctl check..."
if /opt/zeek/bin/zeekctl check >/dev/null 2>&1; then
    echo "  ✓ Zeek config valid"
else
    echo "  ✗ zeekctl check still failed — see: /opt/zeek/bin/zeekctl check"
    /opt/zeek/bin/zeekctl check
    exit 1
fi

echo "─ Deploying Zeek..."
if /opt/zeek/bin/zeekctl deploy >/dev/null 2>&1; then
    echo "  ✓ Zeek deployed successfully"
else
    echo "  ✗ zeekctl deploy failed"
    exit 1
fi

echo ""
echo "✓ Hotfix complete. Run validate.sh to confirm detection is working:"
echo "    sudo bash validate.sh"
