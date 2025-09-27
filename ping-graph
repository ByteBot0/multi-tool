#!/bin/bash

# Ping-TUI v15: Dual-column ASCII graph with non-blocking popup summary
# Usage: ./ping-graph.sh [options]

target="google.com"
interval=1
use_color=false
width=30
max_lat=1500
min_lat=50
summary_interval=15  # update log summary every 15s

# -------------------- PARSE OPTIONS --------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
    	    echo "Notes:" 
    	    echo "If you narrow the terminal, use the log to view the graph"
    	    echo "To see other bugs and notes use option --notes"
    	    echo
    	    echo "Usage: $0 [options]"
            echo "Options:"
    	    echo "  --help           Show this help message"
    	    echo "  -d <target>      Target domain or IP (default: google.com)"
    	    echo "  -i <interval>    Ping interval in seconds (default: 1)"
    	    echo "  --color          Enable colored graph (IPv4 green, IPv6 blue)"
    	    exit 0
    	    ;;
    	--notes)
            echo "Notes for Ping-TUI:"
            echo "  - The main data is designed to fit within 80 columns."
            echo "  - Additional info is printed after the graph; scroll right or check the log to see it."
            echo "  - Terminal wrap is disabled; old lines may reflow if you narrow the terminal."
            echo "  - (broken, and just wrong...) Ctrl+V shows a temporary popup summary."
            echo "  - You can customize the target, interval, and enable colors with options."
            exit 0
            ;;
        -d)
            target="$2"
            shift 2
            ;;
        -i)
            interval="$2"
            shift 2
            ;;
        --color)
            use_color=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

log_file="graph-$(date +%Y%m%d-%H%M%S).txt"
echo "Logging to $log_file"

# -------------------- COUNTERS --------------------
start_time=$(date "+%Y-%m-%d %H:%M:%S")
start_epoch=$(date +%s)

ipv4_min=""
ipv4_max=""
ipv4_sum=0
ipv4_count=0
ipv4_failures=0
ipv4_offline=0

ipv6_min=""
ipv6_max=""
ipv6_sum=0
ipv6_count=0
ipv6_failures=0
ipv6_offline=0

total_downtime=0

# -------------------- FUNCTIONS --------------------
get_conn_info() {
    local wifi eth
    wifi=$(nmcli -t -f ACTIVE,SSID dev wifi | awk -F: '$1=="yes"{print $2}')
    [[ -n "$wifi" ]] && { echo "$wifi"; return; }
    eth=$(nmcli -t -f DEVICE,STATE dev status | awk -F: '$2=="connected" && $1 ~ /^e/{print $1}')
    [[ -n "$eth" ]] && { echo "ETH"; return; }
    echo "No Conn"
}

format_conn_info() {
    local raw="$1"
    case "$raw" in
        ETH) echo "  ETH  " ;;
        "No Conn") echo "No Conn" ;;
        *) echo "${raw:0:7}" ;;
    esac
}

scale_latency() {
    local ms="$1"
    [[ -z "$ms" || ! $ms =~ ^[0-9]+(\.[0-9]+)?$ ]] && { echo 0; return; }
    local ms_int
    ms_int=$(printf "%.0f" "$ms")
    if (( ms_int < min_lat )); then
        echo 0
    elif (( ms_int > max_lat )); then
        echo $((width-1))
    else
        echo $(( (ms_int - min_lat) * (width-1) / (max_lat - min_lat) ))
    fi
}

build_col() {
    local pos="$1" width="$2" display="$3"
    local col=""
    if [[ "$display" == "timeout" || -z "$display" ]]; then
        col=$(printf "%${width}s" "")
    else
        for ((i=0;i<width;i++)); do
            [[ "$i" -eq "$pos" ]] && col+="+" || col+=" "
        done
    fi
    echo "$col"
}

draw_header() {
    echo "__TIME_________________IPv4____________________________IPv6_____________SSID/ETH"
}

colorize() {
    local col="$1" type="$2"
    if ! $use_color; then
        echo -n "$col"
        return
    fi
    case "$type" in
        v4) echo -ne "\e[32m$col\e[0m" ;;
        v6) echo -ne "\e[34m$col\e[0m" ;;
        *) echo -n "$col" ;;
    esac
}

update_stats() {
    local val="$1" proto="$2"
    if [[ "$val" == "timeout" ]]; then
        if [[ "$proto" == "v4" ]]; then ((ipv4_failures++)); else ((ipv6_failures++)); fi
    else
        local int_val=$(printf "%.0f" "$val")
        if [[ "$proto" == "v4" ]]; then
            ((ipv4_count++))
            ((ipv4_sum+=int_val))
            [[ -z "$ipv4_min" || int_val<ipv4_min ]] && ipv4_min=$int_val
            [[ -z "$ipv4_max" || int_val>ipv4_max ]] && ipv4_max=$int_val
        else
            ((ipv6_count++))
            ((ipv6_sum+=int_val))
            [[ -z "$ipv6_min" || int_val<ipv6_min ]] && ipv6_min=$int_val
            [[ -z "$ipv6_max" || int_val>ipv6_max ]] && ipv6_max=$int_val
        fi
    fi
}

write_summary() {
    local end_time="$1"
    local runtime=$(( $(date +%s) - start_epoch ))
    local ipv4_avg=$(( ipv4_count>0 ? ipv4_sum/ipv4_count : 0 ))
    local ipv6_avg=$(( ipv6_count>0 ? ipv6_sum/ipv6_count : 0 ))

    summary="--- Ping Summary ---\n"
    summary+="Runtime: ${runtime}s | Total Downtime: ${total_downtime}s\n"
    summary+="IPv4: min=${ipv4_min:-0}ms max=${ipv4_max:-0}ms avg=${ipv4_avg}ms | failures=${ipv4_failures} | offline=${ipv4_failures}s\n"
    summary+="IPv6: min=${ipv6_min:-0}ms max=${ipv6_max:-0}ms avg=${ipv6_avg}ms | failures=${ipv6_failures} | offline=${ipv6_failures}s\n"
    summary+="Start: $start_time\n"
    summary+="End:   $end_time\n"

    tmp_file=$(mktemp)
    echo -e "$summary" > "$tmp_file"
    tail -n +8 "$log_file" >> "$tmp_file"
    mv "$tmp_file" "$log_file"
}

popup_summary() {
    local end_time="$(date "+%Y-%m-%d %H:%M:%S")"
    local runtime=$(( $(date +%s) - start_epoch ))
    local ipv4_avg=$(( ipv4_count>0 ? ipv4_sum/ipv4_count : 0 ))
    local ipv6_avg=$(( ipv6_count>0 ? ipv6_sum/ipv6_count : 0 ))

    lines=(
        "╔═══════════════════════ Ping Summary ═══════════════════════╗"
        "║ Runtime: ${runtime}s | Total Downtime: ${total_downtime}s"
        "║ IPv4: min=${ipv4_min:-0}ms max=${ipv4_max:-0}ms avg=${ipv4_avg}ms | failures=${ipv4_failures} | offline=${ipv4_failures}s"
        "║ IPv6: min=${ipv6_min:-0}ms max=${ipv6_max:-0}ms avg=${ipv6_avg}ms | failures=${ipv6_failures} | offline=${ipv6_failures}s"
        "║ Start: $start_time"
        "║ End:   $end_time"
        "╚════════════════════════════════════════════════════════════╝"
    )

    tput sc
    tput cup 2 5

    for l in "${lines[@]}"; do
        echo -e "\e[44;97m$l\e[0m"
        tput cud1
    done

    sleep 5

    tput rc
    for ((i=0;i<${#lines[@]};i++)); do
        tput el
        tput cud1
    done
    tput rc
}

# -------------------- INITIAL LOG --------------------
echo -e "--- Ping Summary ---\nRuntime: 0s | Total Downtime: 0s\nIPv4: min=0ms max=0ms avg=0ms | failures=0 | offline=0s\nIPv6: min=0ms max=0ms avg=0ms | failures=0 | offline=0s\nStart: $start_time\nEnd:   \n" > "$log_file"

# Disable wrap, restore on Ctrl+C
trap 'echo -ne "\e[?7h"; write_summary "$(date "+%Y-%m-%d %H:%M:%S")"; exit' INT TERM
echo -ne "\e[?7l"

draw_header
draw_header >> "$log_file"

last_summary=$(date +%s)

# -------------------- MAIN LOOP --------------------
while true; do
    raw_conn=$(get_conn_info)
    conn_info=$(format_conn_info "$raw_conn")

    # IPv4 ping
    v4_raw=$(ping -4 -c 1 -W 1 "$target" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
    v4_display=${v4_raw:-timeout}
    v4_pos=$(scale_latency "$v4_raw")
    update_stats "$v4_display" v4

    # IPv6 ping
    v6_raw=$(ping -6 -c 1 -W 1 "$target" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
    v6_display=${v6_raw:-timeout}
    v6_pos=$(scale_latency "$v6_raw")
    update_stats "$v6_display" v6

    # Count total downtime only if both are timeout
    if [[ "$v4_display" == "timeout" && "$v6_display" == "timeout" ]]; then
        ((total_downtime+=interval))
    fi

    # Timestamps
    time_short=$(date "+%m-%d %H%M")
    time_full=$(date "+%Y-%m-%d %H:%M:%S")

    # Build graph columns
    ipv4_col=$(build_col "$v4_pos" "$width" "$v4_display")
    ipv6_col=$(build_col "$v6_pos" "$width" "$v6_display")

    # Status strings
    v4_status=$([[ "$v4_display" == "timeout" ]] && echo "timeout" || echo "${v4_display} ms")
    v6_status=$([[ "$v6_display" == "timeout" ]] && echo "timeout" || echo "${v6_display} ms")

    # Full output line
    line="$time_short|$(colorize "$ipv4_col" v4)|$(colorize "$ipv6_col" v6)|$conn_info [$time_full] Conn: $raw_conn | IPv4 ($target): $v4_status | IPv6 ($target): $v6_status"

    # Print line and log
    printf "%s\n" "$line" | tee -a "$log_file"

    # Overwrite terminal wrap marker with space
    cols=$(tput cols)
    tput cuu1                 # move up one line
    tput cuf $((cols-1))      # move to last column
    printf " "                # overwrite wrap marker
    tput cud1                 # move back down

    # Update summary every summary_interval seconds
    now=$(date +%s)
    if (( now - last_summary >= summary_interval )); then
        write_summary "$(date "+%Y-%m-%d %H:%M:%S")"
        last_summary=$now
    fi

    # Check for Ctrl+V to show popup
    read -t 0.01 -n 1 key
    [[ $key == $'\x16' ]] && popup_summary &

    sleep "$interval"
done
