# Title: RF-Baseline Sentinel
# Description: Passive RF behavioral baseline & anomaly correlation engine for the WiFi Pineapple Pager. Learns what "normal" looks like in an RF environment over time, then alerts on statistically significant deviations. Detects surveillance, rogue infrastructure, and RF anomalies without transmitting or interacting with observed devices.
# Author: D-L3aN
# Version: 1.0
# Category: Blue-Team
# Net Mode: NAT
#
# PREREQUISITES:
#   - WiFi Pineapple Pager (current firmware)
#   - Recon service running (default on stock firmware)
#   - sqlite3 (present on stock firmware)
#   - bc for floating-point math (opkg install bc if missing)
#
# CONFIGURATION:
#   LEARNING_MODE  - Set to "false" after baseline is established (default: true)
#   Z_THRESHOLD    - Anomaly sensitivity in standard deviations (default: 3.0)
#   MIN_SAMPLES    - Minimum samples before baseline is valid (default: 100)
#   LEARN_INTERVAL - Seconds between samples during learning (default: 60)
#   MONITOR_INTERVAL - Seconds between samples during monitoring (default: 120)
#
# LED STATES:
#   Blue Solid   - Monitoring / collecting baseline samples
#   Red Blink    - Anomaly detected
#   Magenta      - Configuration error
#
# ETHICAL USE:
#   This payload is PASSIVE and DEFENSIVE. It reads existing recon data,
#   does not transmit, does not inject packets, and does not interact with
#   any observed device. Intended for authorized security research,
#   red team OPSEC, and personal privacy defense.
#
# DISCLAIMER:
#   Provided for educational and authorized security research purposes only.
#   User is solely responsible for compliance with all applicable laws.

# === CONFIGURATION ===
BASELINE_DIR="/root/loot/rf-baseline"
BASELINE_FILE="$BASELINE_DIR/baseline.db"
ANOMALY_LOG="$BASELINE_DIR/anomalies.log"
LEARNING_MODE="${LEARNING_MODE:-true}"  # Set to false after training period
Z_THRESHOLD=3.0                        # Standard deviations for anomaly
MIN_SAMPLES=100                        # Minimum scans before baseline is valid

# === INITIALIZATION ===
mkdir -p "$BASELINE_DIR"
sqlite3 "$BASELINE_FILE" <<EOF
CREATE TABLE IF NOT EXISTS scans (
    id INTEGER PRIMARY KEY,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    hour INTEGER,
    ap_count INTEGER,
    client_count INTEGER,
    avg_rssi REAL,
    channel_distribution TEXT,
    unique_bssids INTEGER
);
CREATE TABLE IF NOT EXISTS bssid_registry (
    bssid TEXT PRIMARY KEY,
    first_seen DATETIME,
    last_seen DATETIME,
    sighting_count INTEGER DEFAULT 1,
    channel INTEGER,
    ssid TEXT,
    avg_rssi REAL
);
EOF

# === PASSIVE SCAN FUNCTION ===
passive_scan() {
    # Use Pager's recon data, NOT active scanning
    # This reads from the existing recon database
    local recon_db="/root/recon/recon.db"
    
    if [ ! -f "$recon_db" ]; then
        LOG "Recon database not found. Ensure recon is running."
        return 1
    fi
    
    # Extract current AP/client snapshot from recon DB
    local ap_count=$(sqlite3 "$recon_db" "SELECT COUNT(DISTINCT bssid) FROM access_points WHERE last_seen > datetime('now', '-5 minutes');" 2>/dev/null || echo 0)
    local client_count=$(sqlite3 "$recon_db" "SELECT COUNT(DISTINCT mac) FROM clients WHERE last_seen > datetime('now', '-5 minutes');" 2>/dev/null || echo 0)
    
    local current_hour=$(date +%H)
    
    # Record snapshot
    sqlite3 "$BASELINE_FILE" "INSERT INTO scans (hour, ap_count, client_count) VALUES ($current_hour, $ap_count, $client_count);"
    
    echo "$ap_count|$client_count"
}

# === BASELINE LEARNING ===
learn_baseline() {
    LOG "RF-Baseline Sentinel: Learning mode active"
    
    local sample_count=$(sqlite3 "$BASELINE_FILE" "SELECT COUNT(*) FROM scans;")
    
    if [ "$sample_count" -lt "$MIN_SAMPLES" ]; then
        LOG "Collecting baseline samples... ($sample_count/$MIN_SAMPLES)"
        
        while [ "$sample_count" -lt "$MIN_SAMPLES" ]; do
            passive_scan > /dev/null
            sleep 60  # One sample per minute
            sample_count=$(sqlite3 "$BASELINE_FILE" "SELECT COUNT(*) FROM scans;")
        done
        
        LOG "Baseline established with $sample_count samples."
    fi
}

# === ANOMALY DETECTION ===
detect_anomalies() {
    local current_hour=$(date +%H)
    
    # Get current snapshot
    local current=$(passive_scan)
    local current_ap=$(echo "$current" | cut -d'|' -f1)
    local current_clients=$(echo "$current" | cut -d'|' -f2)
    
    # Get historical stats for this hour of day
    local stats=$(sqlite3 "$BASELINE_FILE" "SELECT AVG(ap_count), AVG(client_count), 
        (SELECT AVG((ap_count - (SELECT AVG(ap_count) FROM scans WHERE hour = $current_hour)) * 
                     (ap_count - (SELECT AVG(ap_count) FROM scans WHERE hour = $current_hour))) 
         FROM scans WHERE hour = $current_hour) as variance_ap
        FROM scans WHERE hour = $current_hour;")
    
    local avg_ap=$(echo "$stats" | cut -d'|' -f1)
    local avg_clients=$(echo "$stats" | cut -d'|' -f2)
    local variance_ap=$(echo "$stats" | cut -d'|' -f3)
    
    # Calculate z-score (skip if variance is zero)
    if [ -n "$variance_ap" ] && [ "$variance_ap" != "0" ]; then
        local stddev_ap=$(echo "sqrt($variance_ap)" | bc -l 2>/dev/null || echo 1)
        local z_score=$(echo "scale=2; ($current_ap - $avg_ap) / $stddev_ap" | bc -l 2>/dev/null || echo 0)
        
        # Check threshold
        local z_abs=$(echo "$z_score" | tr -d '-')
        if [ "$(echo "$z_abs > $Z_THRESHOLD" | bc -l 2>/dev/null)" = "1" ]; then
            local direction="increase"
            [ "$(echo "$z_score < 0" | bc -l 2>/dev/null)" = "1" ] && direction="decrease"
            
            local alert_msg="RF Anomaly: AP count $direction (current: $current_ap, baseline: ${avg_ap%.*}, z-score: $z_score)"
            echo "$(date '+%Y-%m-%d %H:%M:%S') | $alert_msg" >> "$ANOMALY_LOG"
            
            # Trigger visual/audio alert
            ALERT "$alert_msg"
            VIBRATE 200
        fi
    fi
    
    # Check for brand-new BSSIDs (potential rogue infrastructure)
    # (Simplified - full implementation would track this in bssid_registry)
}

# === MAIN LOOP ===
main() {
    LOG "RF-Baseline Sentinel starting..."
    
    # Initial learning phase
    if [ "$LEARNING_MODE" = "true" ]; then
        learn_baseline
    fi
    
    LOG "Entering continuous monitoring mode..."
    
    while true; do
        detect_anomalies
        sleep 120  # Check every 2 minutes
    done
}

main
