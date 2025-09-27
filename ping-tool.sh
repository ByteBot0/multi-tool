#!/bin/bash

# --- Defaults ---
TARGET_HOST="google.com"
INTERVAL=1

# --- Colors ---
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m" # reset

# --- Statistics ---
V4_MIN=999999
V4_MAX=0
V4_TOTAL=0
V4_COUNT=0
V4_FAIL=0
V4_OFFLINE_SECS=0

V6_MIN=999999
V6_MAX=0
V6_TOTAL=0
V6_COUNT=0
V6_FAIL=0
V6_OFFLINE_SECS=0

TOTAL_OFFLINE_SECS=0

START_TIME=$(date +%s)

# --- Usage Function ---
show_help() {
    cat << EOF
Usage: $(basename "$0") [options]

Options:
  -d DOMAIN     Target domain to ping (default: google.com)
  -i INTERVAL   Interval between pings in seconds (default: 1)
  --help        Show this help message and exit

Examples:
  $(basename "$0")              # ping google.com every 1s
  $(basename "$0") -d example.com -i 2
EOF
}

# --- Parse Options ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            TARGET_HOST="$2"
            shift 2
            ;;
        -i)
            INTERVAL="$2"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# --- Connection Detection ---
get_connection_type() {
    if command -v nmcli &> /dev/null; then
        WIFI_SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
        if [[ -n "$WIFI_SSID" ]]; then
            echo "$WIFI_SSID"
            return
        fi
        # Check if ethernet is connected
        if nmcli -t -f DEVICE,TYPE,STATE dev status | grep -q "ethernet:connected"; then
            echo "Ethernet"
            return
        fi
        echo "No Connection"
    else
        echo "Unknown"
    fi
}

# --- Summary on Exit ---
show_summary() {
    END_TIME=$(date +%s)
    RUNTIME=$((END_TIME - START_TIME))

    echo -e "\n\n${CYAN}--- Ping Summary ---${NC}"
    echo "Runtime: ${RUNTIME}s | Total Downtime: ${TOTAL_OFFLINE_SECS}s"

    if (( V4_COUNT > 0 )); then
        V4_AVG=$((V4_TOTAL / V4_COUNT))
        echo -e "IPv4: min=${V4_MIN}ms max=${V4_MAX}ms avg=${V4_AVG}ms | failures=$V4_FAIL | offline=${V4_OFFLINE_SECS}s"
    else
        echo "IPv4: no successful pings"
    fi

    if (( V6_COUNT > 0 )); then
        V6_AVG=$((V6_TOTAL / V6_COUNT))
        echo -e "IPv6: min=${V6_MIN}ms max=${V6_MAX}ms avg=${V6_AVG}ms | failures=$V6_FAIL | offline=${V6_OFFLINE_SECS}s"
    else
        echo "IPv6: no successful pings"
    fi
}

trap show_summary EXIT

# --- Main Loop ---
echo "Starting continuous IPv4 and IPv6 ping to $TARGET_HOST every $INTERVAL second(s)..."
echo "Press Ctrl+C to stop."

while true; do
    CURRENT_TIME=$(date +"%Y-%m-%d %H:%M:%S")
    CURRENT_CONN=$(get_connection_type)

    # Track if each failed this loop
    V4_FAILED=0
    V6_FAILED=0

    # IPv4
    PING_OUTPUT_V4=$(ping4 -c 1 -W 3 "$TARGET_HOST" 2>&1)
    if echo "$PING_OUTPUT_V4" | grep -q "bytes from"; then
        IPV4_ADDRESS=$(echo "$PING_OUTPUT_V4" | head -n 1 | awk '{print $3}' | tr -d '():')
        PING_TIME_V4=$(echo "$PING_OUTPUT_V4" | grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}')

        # update stats
        PTIME=${PING_TIME_V4%.*}
        (( V4_TOTAL += PTIME ))
        (( V4_COUNT++ ))
        (( PTIME < V4_MIN )) && V4_MIN=$PTIME
        (( PTIME > V4_MAX )) && V4_MAX=$PTIME

        V4_RESULT="IPv4 (${GREEN}${IPV4_ADDRESS}${NC}): ${YELLOW}${PING_TIME_V4}ms${NC}"
    else
        V4_RESULT="IPv4: ${RED}Host Unreachable or Timeout${NC}"
        (( V4_FAIL++ ))
        (( V4_OFFLINE_SECS += INTERVAL ))
        V4_FAILED=1
    fi

    # IPv6
    PING_OUTPUT_V6=$(ping6 -c 1 -W 3 "::1" 2>&1)
    if echo "$PING_OUTPUT_V6" | grep -q "bytes from"; then
        IPV6_ADDRESS=$(echo "$PING_OUTPUT_V6" | head -n 1 | awk -F'[()]' '{print $2}')
        PING_TIME_V6=$(echo "$PING_OUTPUT_V6" | grep "time=" | awk -F'time=' '{print $2}' | awk '{print $1}')

        # update stats
        PTIME=${PING_TIME_V6%.*}
        (( V6_TOTAL += PTIME ))
        (( V6_COUNT++ ))
        (( PTIME < V6_MIN )) && V6_MIN=$PTIME
        (( PTIME > V6_MAX )) && V6_MAX=$PTIME

        V6_RESULT="IPv6 (${GREEN}${IPV6_ADDRESS}${NC}): ${YELLOW}${PING_TIME_V6}ms${NC}"
    else
        V6_RESULT="IPv6: ${RED}Host Unreachable or Timeout${NC}"
        (( V6_FAIL++ ))
        (( V6_OFFLINE_SECS += INTERVAL ))
        V6_FAILED=1
    fi

    # Total downtime = both failed
    if (( V4_FAILED == 1 && V6_FAILED == 1 )); then
        (( TOTAL_OFFLINE_SECS += INTERVAL ))
    fi

    echo -e "[$CURRENT_TIME] Conn: ${CYAN}$CURRENT_CONN${NC} | $V4_RESULT | $V6_RESULT"
    sleep "$INTERVAL"
done
