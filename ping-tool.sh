#!/bin/bash

# --- Defaults ---
TARGET_HOST="google.com"
INTERVAL=1
use_color=false  # default: black & white
allow_local_ipv6=false  # default: treat local IPv6 replies as failures

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

# --- Parse Options ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|\?)
            echo "Notes:"
            echo "If you narrow the terminal, use the log to view the graph"
            echo "To see other bugs and notes use option --notes"
            echo
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --help, ?            Show this help message"
            echo "  -d <target>          Target domain or IP (default: google.com)"
            echo "  -i <interval>        Ping interval in seconds (default: 1)"
            echo "  --color              Enable colored graph"
            echo "  --allow-local-ipv6   Accept local IPv6 replies (do not treat as downtime)"
            exit 0
            ;;
        --notes)
            echo "Notes for Ping-Tool:"
            echo "- Ping timeout behavior can vary by implementation."
            echo "- Ethernet/Wi-Fi detection depends on nmcli output."
            echo "- Summary downtime counts missed pings as INTERVAL seconds."
            echo "- Consider adding 5ghz/2.4ghz info."
            exit 0
            ;;
        -d)
            TARGET_HOST="$2"
            shift 2
            ;;
        -i)
            INTERVAL="$2"
            shift 2
            ;;
        --color)
            use_color=true
            shift
            ;;
        --allow-local-ipv6)
            allow_local_ipv6=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Pick ping commands (portable) ---
# Some systems don't have ping4/ping6; they use ping -4 / ping -6 instead.
if command -v ping4 >/dev/null 2>&1; then
  PING_V4=(ping4)
else
  PING_V4=(ping -4)
fi

if command -v ping6 >/dev/null 2>&1; then
  PING_V6=(ping6)
else
  PING_V6=(ping -6)
fi

# Helper to optionally wrap text in color codes
color_wrap() {
    local color="$1"; shift
    local text="$*"
    if [ "$use_color" = true ]; then
        echo -e "${color}${text}${NC}"
    else
        echo -e "${text}"
    fi
}

# --- Connection Detection ---
get_connection_type() {
    if command -v nmcli &> /dev/null; then
        WIFI_SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
        if [[ -n "$WIFI_SSID" ]]; then
            echo "$WIFI_SSID"
            return
        fi
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

    echo
    echo "$(color_wrap "$CYAN" '--- Ping Summary ---')"
    echo "Runtime: ${RUNTIME}s | Total Downtime: ${TOTAL_OFFLINE_SECS}s"

    if (( V4_COUNT > 0 )); then
        V4_AVG=$((V4_TOTAL / V4_COUNT))
        echo "IPv4: min=${V4_MIN}ms max=${V4_MAX}ms avg=${V4_AVG}ms | failures=${V4_FAIL} | offline=${V4_OFFLINE_SECS}s"
    else
        echo "IPv4: no successful pings"
    fi

    if (( V6_COUNT > 0 )); then
        V6_AVG=$((V6_TOTAL / V6_COUNT))
        echo "IPv6: min=${V6_MIN}ms max=${V6_MAX}ms avg=${V6_AVG}ms | failures=${V6_FAIL} | offline=${V6_OFFLINE_SECS}s"
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
    PING_OUTPUT_V4=$("${PING_V4[@]}" -c 1 -W 3 "$TARGET_HOST" 2>&1)
    if echo "$PING_OUTPUT_V4" | grep -q "bytes from"; then
        IPV4_ADDRESS="$(echo "$PING_OUTPUT_V4" | head -n1 | awk '{
            for(i=1;i<=NF;i++){
                if($i=="from"){ addr=$(i+1); gsub(/[():]/,"",addr); print addr; exit }
                if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:$/){ gsub(/:$/,"",$i); print $i; exit }
                if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && i>1 && $(i-1) ~ /bytes/){ print $i; exit }
            }
        }')"
        if [[ -z "$IPV4_ADDRESS" ]]; then
            IPV4_ADDRESS=$(echo "$PING_OUTPUT_V4" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        fi

        PING_TIME_V4=$(echo "$PING_OUTPUT_V4" | grep -oE 'time=[0-9]+(\.[0-9]+)?' | head -n1 | awk -F= '{print $2}')

        PTIME=${PING_TIME_V4%.*}
        (( V4_TOTAL += PTIME ))
        (( V4_COUNT++ ))
        (( PTIME < V4_MIN )) && V4_MIN=$PTIME
        (( PTIME > V4_MAX )) && V4_MAX=$PTIME

        V4_RESULT="IPv4 ($(color_wrap "$GREEN" "$IPV4_ADDRESS")): $(color_wrap "$YELLOW" "${PING_TIME_V4}ms")"
    else
        V4_RESULT="IPv4: $(color_wrap "$RED" "Host Unreachable or Timeout")"
        (( V4_FAIL++ ))
        (( V4_OFFLINE_SECS += INTERVAL ))
        V4_FAILED=1
    fi

    # IPv6
    PING_OUTPUT_V6=$("${PING_V6[@]}" -c 1 -W 3 "$TARGET_HOST" 2>&1)
    if echo "$PING_OUTPUT_V6" | grep -q "bytes from"; then
        IPV6_ADDRESS=$(echo "$PING_OUTPUT_V6" | head -n 1 | awk -F'[()]' '{print $2}')
        if [[ -z "$IPV6_ADDRESS" ]]; then
            IPV6_ADDRESS=$(echo "$PING_OUTPUT_V6" | head -n 1 | awk '{for(i=1;i<=NF;i++) if($i~/from/) print $(i+1)}' | tr -d '():')
        fi
        IPV6_ADDRESS=${IPV6_ADDRESS,,}  # lowercase for comparisons

        # Determine if reply is local
        is_local_ipv6=false

        # loopback
        if [[ "$IPV6_ADDRESS" == "::1" ]]; then
            is_local_ipv6=true
        fi

        # link-local fe80::
        if [[ "$IPV6_ADDRESS" == fe80:* ]]; then
            is_local_ipv6=true
        fi

        # compare against host's IPv6 addresses (requires ip command)
        if command -v ip &> /dev/null; then
            if ip -6 addr show | grep -qiE "inet6\\s+${IPV6_ADDRESS}"; then
                is_local_ipv6=true
            fi
        fi

        # If reply is local and user did NOT allow local replies, count as failure
        if [[ "$is_local_ipv6" == true && "${allow_local_ipv6:-false}" != true ]]; then
            V6_RESULT="IPv6: $(color_wrap "$RED" "Local reply ignored (treated as down)")"
            (( V6_FAIL++ ))
            (( V6_OFFLINE_SECS += INTERVAL ))
            V6_FAILED=1
        else
            PING_TIME_V6=$(echo "$PING_OUTPUT_V6" | grep -oE 'time=[0-9]+(\.[0-9]+)?' | head -n1 | awk -F= '{print $2}')

            PTIME=${PING_TIME_V6%.*}
            (( V6_TOTAL += PTIME ))
            (( V6_COUNT++ ))
            (( PTIME < V6_MIN )) && V6_MIN=$PTIME
            (( PTIME > V6_MAX )) && V6_MAX=$PTIME

            V6_RESULT="IPv6 ($(color_wrap "$GREEN" "$IPV6_ADDRESS")): $(color_wrap "$YELLOW" "${PING_TIME_V6}ms")"
        fi
    else
        V6_RESULT="IPv6: $(color_wrap "$RED" "Host Unreachable or Timeout")"
        (( V6_FAIL++ ))
        (( V6_OFFLINE_SECS += INTERVAL ))
        V6_FAILED=1
    fi

    # Total downtime = both failed
    if (( V4_FAILED == 1 && V6_FAILED == 1 )); then
        (( TOTAL_OFFLINE_SECS += INTERVAL ))
    fi

    # Connection name colored or plain
    CONN_DISPLAY=$(color_wrap "$CYAN" "$CURRENT_CONN")

    echo -e "[$CURRENT_TIME] Conn: ${CONN_DISPLAY} | ${V4_RESULT} | ${V6_RESULT}"
    sleep "$INTERVAL"
done
