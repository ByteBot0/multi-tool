#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Trace Health — LAN/WAN Path Check (Updated Non-Blocking Refresh, IPv4+IPv6)
# =============================================================================

# ---------------- Defaults ----------------
TARGETS=()
TARGETS_FILE=""
FAMILY="auto"
METHOD="icmp"
TCP_PORT="443"
MAX_HOPS="30"
INTERVAL="1"
CYCLES="10"
AUTO_REFRESH="0"  # seconds; 0 disables continuous mode
DNS_RESOLVE=false
PREFER_MTR=true
LOG_DIR="logs/trace-health"

SESSION_ID="${SESSION_ID:-$(date +%s)}"
CURRENT_CHILD_PID=""
REFRESH_PID=""
REFRESH_RUNNING=false
SPIN_CHAR=" "

# ---------------- Utilities ----------------
usage() {
  cat <<EOF
Trace Health — LAN/WAN Path Check

Usage: $0 [options]

Targets:
  -d <target>            Add a target (repeatable or comma-separated)
  --targets-file <file>  File with one target per line

Network:
  --family <auto|v4|v6> IP family
  --method <icmp|udp|tcp> Probe method
  --port <port> TCP port (tcp only)
  -m <max_hops> Max hops
  -i <interval> Interval seconds
  -c <cycles> Cycles per report
  --dns Enable reverse DNS

Behavior:
  --prefer-mtr Prefer mtr
  --no-mtr Force traceroute fallback
  --log-dir <dir> Log directory

  --auto <seconds>       Run continuously: auto-refresh every N seconds

Controls:
  n/p  next/prev target
  a    show all
  r    refresh (runs probes)
  q    quit
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
trim() { sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' ; }

iso_ts() { date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/' ; }
safe_fname() { echo "$1" | tr -c '[:alnum:]._-' '_' | sed 's/^_//;s/_$//' ; }

cleanup() {
  tput cnorm 2>/dev/null || true
  stty echo 2>/dev/null || true
}
kill_running_child() {
  if [[ -n "${CURRENT_CHILD_PID:-}" ]]; then
    kill -TERM -- "-$CURRENT_CHILD_PID" 2>/dev/null || true
    kill -KILL -- "-$CURRENT_CHILD_PID" 2>/dev/null || true
    CURRENT_CHILD_PID=""
  fi
}
on_exit() {
  kill_running_child
  [[ -n "$REFRESH_PID" ]] && kill "$REFRESH_PID" 2>/dev/null || true
  cleanup
}
trap on_exit EXIT INT TERM

ensure_logs() { mkdir -p "$LOG_DIR/reports" ; }

# ---------------- Resolution ----------------
resolve_target() {
  local tgt="$1"
  RESOLVED_IP=""
  RESOLVED_FAMILY=""
  [[ "$tgt" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { RESOLVED_IP="$tgt"; RESOLVED_FAMILY="v4"; return; }
  [[ "$tgt" == *:* ]] && { RESOLVED_IP="$tgt"; RESOLVED_FAMILY="v6"; return; }

  if have getent; then
    if [[ "$FAMILY" != "v6" ]]; then
      RESOLVED_IP="$(getent ahostsv4 "$tgt" 2>/dev/null | awk 'NR==1{print $1}')"
      [[ -n "$RESOLVED_IP" ]] && { RESOLVED_FAMILY="v4"; return; }
    fi
    if [[ "$FAMILY" != "v4" ]]; then
      RESOLVED_IP="$(getent ahostsv6 "$tgt" 2>/dev/null | awk 'NR==1{print $1}')"
      [[ -n "$RESOLVED_IP" ]] && { RESOLVED_FAMILY="v6"; return; }
    fi
  fi
}

# ---------------- Command runner ----------------
run_in_own_pgrp_capture() {
  local cmd="$1"
  local tmp; tmp="$(mktemp)"
  setsid bash -lc "$cmd" >"$tmp" 2>&1 &
  CURRENT_CHILD_PID=$!
  wait "$CURRENT_CHILD_PID" 2>/dev/null || true
  CURRENT_CHILD_PID=""
  cat "$tmp"
  rm -f "$tmp"
}

mtr_flags() {
  local fam="$1"
  local flags=(-r -w -c "$CYCLES" -i "$INTERVAL" -m "$MAX_HOPS")
  [[ "$DNS_RESOLVE" == false ]] && flags+=(-n)
  [[ "$fam" == "v4" ]] && flags+=(-4)
  [[ "$fam" == "v6" ]] && flags+=(-6)
  case "$METHOD" in
    udp) flags+=(-u) ;;
    tcp) flags+=(-T -P "$TCP_PORT") ;;
  esac
  printf "%q " "${flags[@]}"
}

run_mtr_report() {
  local tgt="$1" fam="$2"
  run_in_own_pgrp_capture "mtr $(mtr_flags "$fam") $(printf '%q' "$tgt")"
}

run_traceroute_report() {
  local tgt="$1" fam="$2"
  have traceroute || { echo "traceroute not installed"; return; }
  local args=()
  [[ "$fam" == "v4" ]] && args+=(-4)
  [[ "$fam" == "v6" ]] && args+=(-6)
  [[ "$DNS_RESOLVE" == false ]] && args+=(-n)
  case "$METHOD" in
    icmp) args+=(-I) ;;
    tcp)  args+=(-T -p "$TCP_PORT") ;;
  esac
  args+=(-m "$MAX_HOPS")
  run_in_own_pgrp_capture "traceroute ${args[*]} $(printf '%q' "$tgt")"
}

write_snapshot() {
  local ts="$1" target="$2" ip="$3" fam="$4" method="$5"
  local reached="$6" hops="$7" loss="$8" avg="$9" changed="${10}"
  python3 - <<PY >>"$LOG_DIR/snapshots.jsonl"
import json
print(json.dumps({
  "session": "$SESSION_ID",
  "ts": "$ts",
  "target": "$target",
  "ip": "$ip",
  "family": "$fam",
  "method": "$method",
  "reached": "$reached" == "true",
  "hops": int("$hops") if "$hops".isdigit() else None,
  "worst_loss": float("$loss") if "$loss" else None,
  "worst_avg_ms": float("$avg") if "$avg" else None,
  "path_changed": "$changed" == "true"
}, separators=(",",":")))
PY
}

save_report() {
  local ts="$1" target="$2" fam="$3" method="$4" report="$5"
  local fn="$LOG_DIR/reports/${ts}_$(safe_fname "$target")_${fam}_${method}.txt"
  fn="${fn//:/-}"
  {
    echo "session: $SESSION_ID"
    echo "ts: $ts"
    echo "target: $target"
    echo "family: $fam"
    echo "method: $method"
    echo "----------------------------------------"
    echo "$report"
  } > "$fn"
}

# ---------------- UI ----------------
read_key_nb() {
  local k=""
  IFS= read -rsn1 -t 0.05 k || true
  case "$k" in
    n) echo NEXT ;;
    p) echo PREV ;;
    a) echo ALL ;;
    r) echo REFRESH ;;
    q) echo QUIT ;;
    *) echo "" ;;
  esac
}

# ---------------- Parse args ----------------
while (( $# > 0 )); do
  case "$1" in
    -d) IFS=',' read -ra x <<<"$2"; TARGETS+=("${x[@]}"); shift 2 ;;
    --targets-file) TARGETS_FILE="$2"; shift 2 ;;
    --family) FAMILY="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --port) TCP_PORT="$2"; shift 2 ;;
    -m) MAX_HOPS="$2"; shift 2 ;;
    -i) INTERVAL="$2"; shift 2 ;;
    -c) CYCLES="$2"; shift 2 ;;
    --dns) DNS_RESOLVE=true; shift ;;
    --prefer-mtr) PREFER_MTR=true; shift ;;
    --no-mtr) PREFER_MTR=false; shift ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --auto|--watch) AUTO_REFRESH="$2"; shift 2 ;;
    --help|-h|\?) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

(( ${#TARGETS[@]} == 0 )) && TARGETS=("google.com")
ensure_logs

# ---------------- Runtime ----------------
tput civis
stty -echo

HAS_DRAWN=false
SHOW_ALL=false
TAB=0
LAST_TS="(no runs yet)"
NEEDS_REDRAW=true
LAST_AUTO_EPOCH=0

declare -A REPORTS REACHED HOPS LOSS AVG PATH_CHANGED

# ---------------- Non-blocking refresh ----------------
refresh_all() {
  local ts; ts="$(iso_ts)"
  for t in "${TARGETS[@]}"; do
    # Attempt both v4 and v6 if auto
    local families=()
    if [[ "$FAMILY" == "auto" ]]; then
      families=(v4 v6)
    else
      families=("$FAMILY")
    fi

    for fam in "${families[@]}"; do
      resolve_target "$t"
      local ip="${RESOLVED_IP:-}"
      local report reached="false"

      if [[ "$PREFER_MTR" == true && $(have mtr; echo $?) -eq 0 ]]; then
        report="$(run_mtr_report "$t" "$fam")"
        reached="$(grep -q '|--' <<<"$report" && echo true || echo false)"
      else
        report="$(run_traceroute_report "$t" "$fam")"
      fi

      REPORTS["$t:$fam"]="$report"
      REACHED["$t:$fam"]="$reached"

      write_snapshot "$ts" "$t" "$ip" "$fam" "$METHOD" "$reached" "0" "" "" "false"
      [[ "$reached" != "true" ]] && save_report "$ts" "$t" "$fam" "$METHOD" "$report"
    done
  done
  LAST_TS="$ts"
  NEEDS_REDRAW=true
}


# ---------------- Draw UI ----------------
draw_screen() {
  tput cup 0 0
  tput ed  # clear screen
  echo "Trace Health — LAN/WAN Path Check"
  echo "Session: $SESSION_ID   Last run: $LAST_TS"
  echo "Targets: ${#TARGETS[@]}   Method: $METHOD   Family: $FAMILY"
  if [[ "$REFRESH_RUNNING" == true ]]; then
    printf "Checking LAN/WAN health... %s   (n/p to change target, a=all, q=quit)\n" "$SPIN_CHAR"
  else
    if [[ "${AUTO_REFRESH:-0}" != "0" ]]; then
      echo "Auto mode: refreshing every ${AUTO_REFRESH}s (press q to quit)."
    else
      echo "Idle. Press [r] to refresh (runs probes)."
    fi
  fi
  echo "Keys: [n] next  [p] prev  [a] all  [r] refresh  [q] quit"
  echo "------------------------------------------------------------"

  if [[ "$SHOW_ALL" == true ]]; then
    for t in "${TARGETS[@]}"; do
      for fam in v4 v6; do
        echo "Target: $t ($fam)"
        echo "${REPORTS["$t:$fam"]:-<no data>}"
        echo "============================================================"
      done
    done
  else
    t="${TARGETS[$TAB]}"
    for fam in v4 v6; do
      echo "Viewing [$TAB/$(( ${#TARGETS[@]} - 1 ))]: $t ($fam)"
      echo
      echo "${REPORTS["$t:$fam"]:-<no data>}"
      echo
    done
  fi
}

# ---------------- Spinner ----------------

spinner() {
  local pid=$1
  local sp='|/-\\'
  local i=0
  local action=""
  REFRESH_RUNNING=true
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) %4 ))
    SPIN_CHAR="${sp:$i:1}"

    # handle keys while refresh running
    action="$(read_key_nb)"
    case "$action" in
      NEXT)
        TAB=$(( (TAB + 1) % ${#TARGETS[@]} ))
        NEEDS_REDRAW=true
        ;;
      PREV)
        TAB=$(( (TAB - 1 + ${#TARGETS[@]}) % ${#TARGETS[@]} ))
        NEEDS_REDRAW=true
        ;;
      ALL)
        SHOW_ALL=!$SHOW_ALL
        NEEDS_REDRAW=true
        ;;
      QUIT)
        kill "$pid" 2>/dev/null || true
        pkill -P "$pid" 2>/dev/null || true
        break
        ;;
      *)
        ;;
    esac

    # redraw to reflect navigation + spinner animation
    draw_screen
    sleep 0.1
  done
  REFRESH_RUNNING=false
  SPIN_CHAR=" "
  NEEDS_REDRAW=true
}

# ---------------- Main loop ----------------
while true; do
  if [[ "$NEEDS_REDRAW" == true ]]; then
    draw_screen
    NEEDS_REDRAW=false
  fi

  [[ "$HAS_DRAWN" == false ]] && { HAS_DRAWN=true; refresh_all; }

# Auto refresh (continuous mode)
if [[ "${AUTO_REFRESH:-0}" != "0" ]]; then
  now_epoch="$(date +%s)"
  if (( LAST_AUTO_EPOCH == 0 )); then
    LAST_AUTO_EPOCH="$now_epoch"
  fi
  if (( now_epoch - LAST_AUTO_EPOCH >= AUTO_REFRESH )); then
    LAST_AUTO_EPOCH="$now_epoch"
    if [[ -z "$REFRESH_PID" ]] || ! kill -0 "$REFRESH_PID" 2>/dev/null; then
      ( refresh_all ) &
      REFRESH_PID=$!
      spinner "$REFRESH_PID"
      NEEDS_REDRAW=true
    fi
  fi
fi

  case "$(read_key_nb)" in
    NEXT)
      TAB=$(( (TAB + 1) % ${#TARGETS[@]} ))
      NEEDS_REDRAW=true
      ;;
    PREV)
      TAB=$(( (TAB - 1 + ${#TARGETS[@]}) % ${#TARGETS[@]} ))
      NEEDS_REDRAW=true
      ;;
    ALL)
      SHOW_ALL=!$SHOW_ALL
      NEEDS_REDRAW=true
      ;;
    REFRESH)
      if [[ -n "$REFRESH_PID" ]] && kill -0 "$REFRESH_PID" 2>/dev/null; then
        : # already running
      else
        ( refresh_all ) &
        REFRESH_PID=$!
        spinner "$REFRESH_PID"
      fi
      ;;
    QUIT)
      break
      ;;
  esac

  sleep 0.05
done

exit 0
