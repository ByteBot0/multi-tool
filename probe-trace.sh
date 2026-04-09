#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# probe-trace.sh — Continuous End-to-End Path Monitor (IPv4 + IPv6)
#
# Goal:
#   Give a quick "where did it break?" view (link/ip/gw/dns/path) for v4 & v6,
#   and write a forensic bundle whenever a failure is detected.
#
# Dependencies (best effort):
#   - ip, ping, getent
#   - mtr (preferred) OR traceroute (fallback)
# =============================================================================

# ---------------- Defaults ----------------
TARGET="google.com"

# How often to run the whole monitor loop.
LOOP_INTERVAL=5

# Path probing details.
PROBE_CYCLES=8
PROBE_INTERVAL=0.2
MAX_HOPS=30
METHOD="icmp"         # icmp|tcp|udp (mtr supports icmp/udp/tcp)
TCP_PORT=443

# Failure heuristics
LOSS_BAD_PCT=50        # first hop with loss >= this is considered "bad"
LOSS_HARD_PCT=100      # loss == this is a "hard" break

# Logging
LOG_DIR="logs/probe-trace"
QUIET=false
NO_UI=false

# Optional: also save a traceroute/mtr report periodically even if OK.
SAVE_OK_EVERY=0        # 0 disables; otherwise seconds

# ---------------- Utils ----------------
have() { command -v "$1" >/dev/null 2>&1; }
ts() { date +"%Y-%m-%d %H:%M:%S"; }
iso_ts() { date +"%Y-%m-%dT%H-%M-%S%z"; }
safe_fname() { echo "$1" | tr -c '[:alnum:]._-' '_' | sed 's/^_//;s/_$//'; }

# TCP reachability check used to avoid false "REACHED=false" in tcp traceroute mode.
# Uses python sockets so it works for both IPv4 and IPv6 without relying on nc/curl.
tcp_connect_ok() {
  local fam="$1" ip="$2" port="$3"
  have python3 || return 1
  python3 - <<'PY' "$fam" "$ip" "$port" >/dev/null 2>&1
import socket, sys
fam = sys.argv[1]
ip  = sys.argv[2]
port = int(sys.argv[3])
af = socket.AF_INET6 if fam == 'v6' else socket.AF_INET
s = socket.socket(af, socket.SOCK_STREAM)
s.settimeout(1.5)
try:
    s.connect((ip, port))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    try:
        s.close()
    except Exception:
        pass
PY
}

mkdir -p "$LOG_DIR/incidents" "$LOG_DIR/reports" 2>/dev/null || true

print() { $QUIET && return 0; echo -e "$*"; }

usage() {
  cat <<EOF
probe-trace.sh — Continuous End-to-End Path Monitor (IPv4 + IPv6)

Usage: $0 [options]

  -t, --target <host/ip>      Target (default: google.com)
  -i, --interval <seconds>    Loop interval (default: 5)
  --cycles <n>                Probes per run (default: 8)
  --probe-interval <sec>      Interval between probes inside mtr (default: 0.2)
  --max-hops <n>              Max hops (default: 30)
  --method <icmp|udp|tcp>     Probe method (default: icmp)
  --port <n>                  TCP port for tcp method (default: 443)
  --loss-bad <pct>            Loss% threshold that marks a hop "bad" (default: 50)
  --loss-hard <pct>           Loss% that marks a hop as "hard break" (default: 100)
  --log-dir <dir>             Logs directory (default: logs/probe-trace)
  --save-ok-every <sec>       Also save OK reports periodically (0 disables)
  --no-ui                     No screen redraw; print one line per loop
  -q, --quiet                 Reduce console output
  -h, --help                  Show help

Examples:
  $0 -t google.com
  $0 -t example.com --method tcp --port 443
EOF
}

# ---------------- Args ----------------
while (( $# )); do
  case "$1" in
    -t|--target) TARGET="$2"; shift 2 ;;
    -i|--interval) LOOP_INTERVAL="$2"; shift 2 ;;
    --cycles) PROBE_CYCLES="$2"; shift 2 ;;
    --probe-interval) PROBE_INTERVAL="$2"; shift 2 ;;
    --max-hops) MAX_HOPS="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --port) TCP_PORT="$2"; shift 2 ;;
    --loss-bad) LOSS_BAD_PCT="$2"; shift 2 ;;
    --loss-hard) LOSS_HARD_PCT="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --save-ok-every) SAVE_OK_EVERY="$2"; shift 2 ;;
    --no-ui) NO_UI=true; shift ;;
    -q|--quiet) QUIET=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR/incidents" "$LOG_DIR/reports" 2>/dev/null || true

# ---------------- Layer checks ----------------
default_gw_v4() { ip route 2>/dev/null | awk '/^default /{print $3; exit}'; }
default_gw_v6() { ip -6 route 2>/dev/null | awk '/^default /{print $3; exit}'; }

check_link() {
  # any non-loopback interface up
  ip -o link show up 2>/dev/null | grep -vq "LOOPBACK"
}

check_ip_v4() { ip -o addr show scope global 2>/dev/null | grep -q "inet "; }
check_ip_v6() { ip -o addr show scope global 2>/dev/null | grep -q "inet6 "; }

check_gateway_health() {
  # args: <gw> <iface> <fam>  (fam: 4 or 6)
  local gw="$1" dev="$2" fam="$3"

  [[ -z "${gw:-}" || -z "${dev:-}" ]] && { echo "FAIL"; return; }

  local icmp_ok=0 neigh_ok=0 tcp_ok=0

  # ICMP (may be blocked by policy)
  if [[ "$fam" == "4" ]]; then
    ping -4 -c1 -W1 "$gw" >/dev/null 2>&1 && icmp_ok=1
  else
    ping -6 -c1 -W1 "$gw" >/dev/null 2>&1 && icmp_ok=1
  fi

  # Neighbor table (works even when ICMP is blocked)
  if ip neigh show "$gw" dev "$dev" 2>/dev/null | grep -Eq 'REACHABLE|STALE|DELAY|PROBE'; then
    neigh_ok=1
  fi

  # TCP connect (best-effort policy detection; may be firewalled)
  for p in 80 443 53; do
    timeout 1 bash -c "</dev/tcp/$gw/$p" >/dev/null 2>&1 && { tcp_ok=1; break; }
  done

  if (( icmp_ok || neigh_ok || tcp_ok )); then
    echo "PASS"
    return
  fi

  # Route exists but we can't touch the GW directly -> likely isolation/policy
  echo "RESTRICTED"
}

primary_iface_v4() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

primary_iface_v6() {
  ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

resolve_v4() { have getent && getent ahostsv4 "$TARGET" 2>/dev/null | awk 'NR==1{print $1}'; }
resolve_v6() { have getent && getent ahostsv6 "$TARGET" 2>/dev/null | awk 'NR==1{print $1}'; }

# Return a space-separated list of unique resolved IPs (best effort).
resolve_all_v4() {
  have getent || return 0
  getent ahostsv4 "$TARGET" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' '
}

resolve_all_v6() {
  have getent || return 0
  getent ahostsv6 "$TARGET" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' '
}

dns_servers() {
  awk '/^nameserver[[:space:]]+/{print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ' || true
}


dns_resolver_chain() {
  local stub upstream
  stub="$(dns_servers)"
  upstream=""
  if have resolvectl; then
    upstream="$(resolvectl status 2>/dev/null | awk '
      /^[[:space:]]*DNS Servers:/ {
        sub(/^[[:space:]]*DNS Servers:[[:space:]]*/, "");
        print;
      }
    ' | tr '\n' ' ' | xargs 2>/dev/null || true)"
  fi
  if [[ -n "$upstream" ]]; then
    echo "${stub:-none} -> ${upstream}"
  else
    echo "${stub:-none}"
  fi
}


# ---------------- Path probing (mtr preferred) ----------------
mtr_flags() {
  local fam="$1"
  local flags=(-r -w -c "$PROBE_CYCLES" -i "$PROBE_INTERVAL" -m "$MAX_HOPS" -n)
  [[ "$fam" == "v4" ]] && flags+=(-4)
  [[ "$fam" == "v6" ]] && flags+=(-6)
  case "$METHOD" in
    icmp) : ;;                # default
    udp)  flags+=(-u) ;;
    tcp)  flags+=(-T -P "$TCP_PORT") ;;
    *)    : ;;
  esac
  printf "%q " "${flags[@]}"
}

run_mtr() {
  local fam="$1"
  mtr $(mtr_flags "$fam") "$(printf '%q' "$TARGET")" 2>&1 || true
}

run_traceroute() {
  local fam="$1"
  have traceroute || { echo "traceroute not installed"; return 0; }
  local args=()
  [[ "$fam" == "v4" ]] && args+=(-4)
  [[ "$fam" == "v6" ]] && args+=(-6)
  args+=(-n -m "$MAX_HOPS")
  case "$METHOD" in
    icmp) args+=(-I) ;;
    tcp)  args+=(-T -p "$TCP_PORT") ;;
    udp)  : ;;
  esac
  traceroute "${args[@]}" "$TARGET" 2>&1 || true
}

# Parse an mtr report and return:
#   reached (true/false)
#   fail_hop_index (or empty)
#   fail_hop_ip (or empty)
#   fail_hop_loss (or empty)
#   last_hop_index / last_hop_ip
parse_mtr() {
  # args: <target_ip_or_host> <loss_bad_pct> <loss_hard_pct>
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys

target = sys.argv[1]
loss_bad = float(sys.argv[2])
loss_hard = float(sys.argv[3])

lines = sys.stdin.read().splitlines()

hop_re = re.compile(r"^\s*(\d+)\.?\|--\s+(\S+)\s+(\d+(?:\.\d+)?)%\s+")
hops = []
for line in lines:
    m = hop_re.search(line)
    if not m:
        continue
    idx = int(m.group(1))
    host = m.group(2)
    loss = float(m.group(3))
    hops.append((idx, host, loss))

reached = False
last_idx = last_host = None
fail_idx = fail_host = fail_loss = None

if hops:
    last_idx, last_host, last_loss = hops[-1]
    reached = (last_host == target and last_loss < loss_hard)

    # Avoid false breaks on non-responding intermediate hops:
    # only call it a break if loss persists toward the end of the path.
    if last_loss >= loss_bad:
        losses = [h[2] for h in hops]
        for i, (idx, host, loss) in enumerate(hops):
            if loss < loss_bad:
                continue
            tail = losses[i:]
            bad_tail = sum(1 for x in tail if x >= loss_bad) / max(1, len(tail))
            if last_loss >= loss_hard or bad_tail >= 0.6:
                fail_idx, fail_host, fail_loss = idx, host, loss
                break

print(f"reached={'true' if reached else 'false'}")
print(f"fail_idx={'' if fail_idx is None else fail_idx}")
print(f"fail_host={'' if fail_host is None else fail_host}")
print(f"fail_loss={'' if fail_loss is None else fail_loss}")
print(f"last_idx={'' if last_idx is None else last_idx}")
print(f"last_host={'' if last_host is None else last_host}")
print("path=" + (" ".join([h[1] for h in hops]) if hops else ""))
PY
}

path_probe() {
  local fam="$1"
  local report="" parser_out="" reached="false" fail_idx="" fail_host="" fail_loss="" last_idx="" last_host=""
  local path_line="" path_sig=""
  local target_ip="$TARGET"

  # If TARGET is a hostname, resolve it to an IP for the chosen family so "reached" is reliable.
  if [[ ! "$TARGET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [[ "$TARGET" != *:* ]]; then
    if [[ "$fam" == "v4" ]]; then
      target_ip="$(resolve_v4 || true)"
    else
      target_ip="$(resolve_v6 || true)"
    fi
    [[ -z "$target_ip" ]] && target_ip="$TARGET"
  fi

  if have mtr; then
    report="$(run_mtr "$fam")"
    parser_out="$(printf "%s" "$report" | parse_mtr "$target_ip" "$LOSS_BAD_PCT" "$LOSS_HARD_PCT")"
    reached="$(awk -F= '/^reached=/{print $2}' <<<"$parser_out")"
    fail_idx="$(awk -F= '/^fail_idx=/{print $2}' <<<"$parser_out")"
    fail_host="$(awk -F= '/^fail_host=/{print $2}' <<<"$parser_out")"
    fail_loss="$(awk -F= '/^fail_loss=/{print $2}' <<<"$parser_out")"
    last_idx="$(awk -F= '/^last_idx=/{print $2}' <<<"$parser_out")"
    last_host="$(awk -F= '/^last_host=/{print $2}' <<<"$parser_out")"
    path_line="$(awk -F= '/^path=/{sub(/^path=/,"");print}' <<<"$parser_out" | tail -n1)"
    if [[ -n "$path_line" ]] && have sha1sum; then
      path_sig="$(printf "%s" "$path_line" | sha1sum | awk '{print $1}')"
    else
      path_sig="$path_line"
    fi

    # In TCP mode, mtr/traceroute-style "reached" can be false even when the
    # destination is reachable (final hop may not reply to traceroute probes).
    # Treat a successful TCP connect to the chosen target IP:port as reached.
    if [[ "$METHOD" == "tcp" && "$reached" != "true" && -n "$target_ip" ]]; then
      if tcp_connect_ok "$fam" "$target_ip" "$TCP_PORT"; then
        reached="true"
      fi
    fi
  else
    report="$(run_traceroute "$fam")"
    # traceroute parsing is weaker; treat "* * *" at end as not reached.
    reached="$(tail -n 1 <<<"$report" | grep -q "*" && echo false || echo true)"
    fail_idx=""; fail_host=""; fail_loss=""; last_idx=""; last_host=""

    # Same false-negative protection for TCP mode when using traceroute fallback.
    if [[ "$METHOD" == "tcp" && "$reached" != "true" && -n "$target_ip" ]]; then
      if tcp_connect_ok "$fam" "$target_ip" "$TCP_PORT"; then
        reached="true"
      fi
    fi
  fi

  printf '%s\n' "REPORT<<EOF" "$report" "EOF" \
    "reached=$reached" \
    "fail_idx=$fail_idx" \
    "fail_host=$fail_host" \
    "fail_loss=$fail_loss" \
    "last_idx=$last_idx" \
    "last_host=$last_host" \
    "path=$path_line" \
    "path_sig=$path_sig"
}

# ---------------- Incident bundling ----------------
write_incident() {
  local incident_id="$1" why="$2" fam="$3" layer_summary="$4" report="$5"
  local dir="$LOG_DIR/incidents/$incident_id"
  mkdir -p "$dir"

  {
    echo "time: $(ts)"
    echo "incident: $incident_id"
    echo "target: $TARGET"
    echo "family: $fam"
    echo "why: $why"
    echo "summary: $layer_summary"
  } > "$dir/incident.txt"

  # Capture useful local state
  ip addr show > "$dir/ip_addr.txt" 2>&1 || true
  ip route show > "$dir/ip_route_v4.txt" 2>&1 || true
  ip -6 route show > "$dir/ip_route_v6.txt" 2>&1 || true
# Extra per-interface snapshots (useful for DHCP/renewal issues)
if [[ -n "${GW4_IFACE:-}" ]]; then
  ip -4 addr show dev "$GW4_IFACE" > "$dir/ip4_addr_${GW4_IFACE}.txt" 2>&1 || true
  ip neigh show dev "$GW4_IFACE" > "$dir/ip4_neigh_${GW4_IFACE}.txt" 2>&1 || true
fi
if [[ -n "${GW6_IFACE:-}" ]]; then
  ip -6 addr show dev "$GW6_IFACE" > "$dir/ip6_addr_${GW6_IFACE}.txt" 2>&1 || true
  ip -6 neigh show dev "$GW6_IFACE" > "$dir/ip6_neigh_${GW6_IFACE}.txt" 2>&1 || true
fi
  (cat /etc/resolv.conf 2>/dev/null || true) > "$dir/resolv.conf"
if command -v resolvectl >/dev/null 2>&1; then
  resolvectl status > "$dir/resolvectl_status.txt" 2>&1 || true
fi
  (date; uname -a) > "$dir/system.txt" 2>&1 || true

  # Save the probe report
  printf "%s\n" "$report" > "$dir/path_report.txt"
}

save_report() {
  local fam="$1" status="$2" report="$3"
  local fn="$LOG_DIR/reports/$(iso_ts)_$(safe_fname "$TARGET")_${fam}_${METHOD}_${status}.txt"
  if [[ -z "$report" ]]; then
    {
      echo "time: $(ts)"
      echo "target: $TARGET"
      echo "family: $fam"
      echo "status: $status"
      echo "note: no path report was captured (failed before probe or tool returned empty output)"
    } > "$fn"
  else
    printf "%s\n" "$report" > "$fn"
  fi
}

layer_report() {
  # args: fam layer_fail dns_servers dns_answers chosen_ip gw
  local fam="$1" layer_fail="$2" dns_srv="$3" dns_ans="$4" chosen="$5" gw="$6"
  {
    echo "time: $(ts)"
    echo "target: $TARGET"
    echo "family: $fam"
    echo "layer_fail: $layer_fail"
    echo "dns_servers: ${dns_srv:-none}"
    echo "dns_answers: ${dns_ans:-none}"
    echo "chosen_ip: ${chosen:-none}"
    echo "default_gw: ${gw:-none}"
    echo
    echo "--- ip addr (short) ---"
    ip -o addr show 2>/dev/null || true
    echo
    echo "--- routes ---"
    ip route show 2>/dev/null || true
    ip -6 route show 2>/dev/null || true
  }
}

wrap_report_header() {
  # args: fam status summary dns_used resolved_all
  local fam="$1" status="$2" summary="$3" dns_used="$4" resolved_all="$5"
  {
    echo "time: $(ts)"
    echo "target: $TARGET"
    echo "family: $fam"
    echo "status: $status"
    echo "dns_servers: ${dns_used:-unknown}"
    echo "resolved_ips: ${resolved_all:-none}"
    echo "summary: $summary"
    echo
  }
}

# ---------------- UI ----------------
draw_ui() {
  local now="$1"
  local v4_summary="$2" v6_summary="$3"
  local v4_line="$4" v6_line="$5"

  if $NO_UI; then
    print "[$now] $v4_line | $v6_line"
    return
  fi

  tput civis 2>/dev/null || true
  tput clear 2>/dev/null || true
  echo "probe-trace — End-to-End Path Monitor"
  echo "Target: $TARGET   Method: $METHOD   Loop: ${LOOP_INTERVAL}s   Probes: ${PROBE_CYCLES}x@${PROBE_INTERVAL}s"
  echo "Loss thresholds: bad>=$LOSS_BAD_PCT% hard=$LOSS_HARD_PCT%"
  echo "Time: $now"
  echo
  printf "%-5s %-6s %-6s %-10s %-6s %-10s %-7s %-6s %-20s\n" "FAM" "LINK" "IP" "GW" "DNS" "REACHED" "CHG" "STAB" "FAIL (hop/loss)"
  printf "%-5s %-6s %-6s %-10s %-6s %-10s %-7s %-6s %-20s\n" "----" "----" "----" "----" "----" "-------" "---" "----" "---------------"
  echo "$v4_summary"
  echo "$v6_summary"
  echo
  echo "Details:"
  echo "  v4: $v4_line"
  echo "  v6: $v6_line"
  echo
  echo "Logs: $LOG_DIR"
  echo "Ctrl+C to stop"
}

cleanup() { tput cnorm 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# ---------------- State ----------------
LAST_STATE_V4=""
LAST_STATE_V6=""
LAST_OK_SAVE=0

# Path change detection
LAST_PATH_V4=""
LAST_PATH_V6=""

# Path stability (only counts when a probe signature exists)
PROBE_COUNT_V4=0
PROBE_COUNT_V6=0
PATH_CHANGE_COUNT_V4=0
PATH_CHANGE_COUNT_V6=0

# ---------------- Main loop ----------------
while true; do
  NOW="$(ts)"

  # Link is shared across families
  LINK_OK="NO"; check_link && LINK_OK="YES"

  # ---------------- v4 checks ----------------
  DNS_SRV="$(dns_resolver_chain)"
  IP4_OK="NO"; check_ip_v4 && IP4_OK="YES"
  GW4_STATE="NONE"; GW4_OK="NO"; GW4_GW="$(default_gw_v4)"; GW4_IFACE="$(primary_iface_v4 || true)";
  if [[ -n "${GW4_GW:-}" ]]; then
    GW4_STATE="$(check_gateway_health "$GW4_GW" "${GW4_IFACE:-}" 4)";
    [[ "$GW4_STATE" == "PASS" || "$GW4_STATE" == "RESTRICTED" ]] && GW4_OK="$GW4_STATE"
  fi
  DNS4_IP=""; DNS4_ALL=""; DNS4_OK="NO";
  DNS4_ALL="$(resolve_all_v4 || true)"; DNS4_IP="$(resolve_v4 || true)";
  [[ -n "$DNS4_IP" ]] && DNS4_OK="YES"

  V4_REACHED="false"; V4_FAIL=""; V4_FAIL_LOSS=""; V4_REPORT=""; V4_LAYER_FAIL=""; V4_PATH_SIG=""; V4_PATH_CHANGED="NO"
  if [[ "$LINK_OK" != "YES" ]]; then V4_LAYER_FAIL="link";
  elif [[ "$IP4_OK" != "YES" ]]; then V4_LAYER_FAIL="ip";
  elif [[ -z "${GW4_GW:-}" ]]; then V4_LAYER_FAIL="gateway(no_default_route)";
  elif [[ "$DNS4_OK" != "YES" ]]; then V4_LAYER_FAIL="dns";
  else
    OUT="$(path_probe v4)"
    V4_REPORT="$(awk '/^REPORT<<EOF$/{f=1;next} /^EOF$/{f=0} f{print}' <<<"$OUT")"
    V4_REACHED="$(awk -F= '/^reached=/{print $2}' <<<"$OUT" | tail -n1)"
    V4_FAIL="$(awk -F= '/^fail_host=/{print $2}' <<<"$OUT" | tail -n1)"
    V4_FAIL_IDX="$(awk -F= '/^fail_idx=/{print $2}' <<<"$OUT" | tail -n1)"
    V4_FAIL_LOSS="$(awk -F= '/^fail_loss=/{print $2}' <<<"$OUT" | tail -n1)"
    V4_PATH_SIG="$(awk -F= '/^path_sig=/{print $2}' <<<"$OUT" | tail -n1)"
    if [[ "$V4_REACHED" != "true" ]]; then V4_LAYER_FAIL="path"; fi
  fi

  # If we failed before probing, make sure the saved report is informative.
  if [[ -n "${V4_LAYER_FAIL:-}" && "${V4_LAYER_FAIL:-}" != "none" && -z "${V4_REPORT:-}" ]]; then
    V4_REPORT="$(layer_report v4 "$V4_LAYER_FAIL" "$DNS_SRV" "$DNS4_ALL" "$DNS4_IP" "$(default_gw_v4)")"
  fi

  # ---------------- v6 checks ----------------
  IP6_OK="NO"; check_ip_v6 && IP6_OK="YES"
  GW6_STATE="NONE"; GW6_OK="NO"; GW6_GW="$(default_gw_v6)"; GW6_IFACE="$(primary_iface_v6 || true)";
  if [[ -n "${GW6_GW:-}" ]]; then
    GW6_STATE="$(check_gateway_health "$GW6_GW" "${GW6_IFACE:-}" 6)";
    [[ "$GW6_STATE" == "PASS" || "$GW6_STATE" == "RESTRICTED" ]] && GW6_OK="$GW6_STATE"
  fi
  DNS6_IP=""; DNS6_ALL=""; DNS6_OK="NO";
  DNS6_ALL="$(resolve_all_v6 || true)"; DNS6_IP="$(resolve_v6 || true)";
  [[ -n "$DNS6_IP" ]] && DNS6_OK="YES"

  V6_REACHED="false"; V6_FAIL=""; V6_FAIL_LOSS=""; V6_REPORT=""; V6_LAYER_FAIL=""; V6_PATH_SIG=""; V6_PATH_CHANGED="NO"
  if [[ "$LINK_OK" != "YES" ]]; then V6_LAYER_FAIL="link";
  elif [[ "$IP6_OK" != "YES" ]]; then V6_LAYER_FAIL="ip(no_global_v6)";
  elif [[ -z "${GW6_GW:-}" ]]; then V6_LAYER_FAIL="gateway(no_default_route_v6)";
  elif [[ "$DNS6_OK" != "YES" ]]; then V6_LAYER_FAIL="dns";
  else
    OUT="$(path_probe v6)"
    V6_REPORT="$(awk '/^REPORT<<EOF$/{f=1;next} /^EOF$/{f=0} f{print}' <<<"$OUT")"
    V6_REACHED="$(awk -F= '/^reached=/{print $2}' <<<"$OUT" | tail -n1)"
    V6_FAIL="$(awk -F= '/^fail_host=/{print $2}' <<<"$OUT" | tail -n1)"
    V6_FAIL_IDX="$(awk -F= '/^fail_idx=/{print $2}' <<<"$OUT" | tail -n1)"
    V6_FAIL_LOSS="$(awk -F= '/^fail_loss=/{print $2}' <<<"$OUT" | tail -n1)"
    V6_PATH_SIG="$(awk -F= '/^path_sig=/{print $2}' <<<"$OUT" | tail -n1)"
    if [[ "$V6_REACHED" != "true" ]]; then V6_LAYER_FAIL="path"; fi
  fi

  if [[ -n "${V6_LAYER_FAIL:-}" && "${V6_LAYER_FAIL:-}" != "none" && -z "${V6_REPORT:-}" ]]; then
    V6_REPORT="$(layer_report v6 "$V6_LAYER_FAIL" "$DNS_SRV" "$DNS6_ALL" "$DNS6_IP" "$(default_gw_v6)")"
  fi

  # ---------------- Path change detection ----------------
  # Only meaningful when we successfully ran a path probe (i.e., have a signature).
  if [[ -n "${V4_PATH_SIG:-}" ]]; then
    PROBE_COUNT_V4=$((PROBE_COUNT_V4+1))
    if [[ -n "${LAST_PATH_V4:-}" && "${V4_PATH_SIG}" != "${LAST_PATH_V4}" ]]; then
      V4_PATH_CHANGED="YES"
      PATH_CHANGE_COUNT_V4=$((PATH_CHANGE_COUNT_V4+1))
    fi
    LAST_PATH_V4="$V4_PATH_SIG"
  fi
  if [[ -n "${V6_PATH_SIG:-}" ]]; then
    PROBE_COUNT_V6=$((PROBE_COUNT_V6+1))
    if [[ -n "${LAST_PATH_V6:-}" && "${V6_PATH_SIG}" != "${LAST_PATH_V6}" ]]; then
      V6_PATH_CHANGED="YES"
      PATH_CHANGE_COUNT_V6=$((PATH_CHANGE_COUNT_V6+1))
    fi
    LAST_PATH_V6="$V6_PATH_SIG"
  fi

  # ---------------- Build summaries ----------------
  V4_FAIL_FIELD="-"
  [[ -n "${V4_FAIL_IDX:-}" || -n "${V4_FAIL_LOSS:-}" ]] && V4_FAIL_FIELD="${V4_FAIL_IDX:-?}/${V4_FAIL_LOSS:-?}% ${V4_FAIL:-}"
  V6_FAIL_FIELD="-"
  [[ -n "${V6_FAIL_IDX:-}" || -n "${V6_FAIL_LOSS:-}" ]] && V6_FAIL_FIELD="${V6_FAIL_IDX:-?}/${V6_FAIL_LOSS:-?}% ${V6_FAIL:-}"

  V4_STAB="--"; (( PROBE_COUNT_V4 > 0 )) && V4_STAB="$(( 100 - (PATH_CHANGE_COUNT_V4 * 100 / PROBE_COUNT_V4) ))%"
  V4_ROW=$(printf "%-5s %-6s %-6s %-10s %-6s %-10s %-7s %-6s %-20s" "v4" "$LINK_OK" "$IP4_OK" "${GW4_OK}" "$DNS4_OK" "${V4_REACHED}" "${V4_PATH_CHANGED}" "$V4_STAB" "$V4_FAIL_FIELD")
  V6_STAB="--"; (( PROBE_COUNT_V6 > 0 )) && V6_STAB="$(( 100 - (PATH_CHANGE_COUNT_V6 * 100 / PROBE_COUNT_V6) ))%"
  V6_ROW=$(printf "%-5s %-6s %-6s %-10s %-6s %-10s %-7s %-6s %-20s" "v6" "$LINK_OK" "$IP6_OK" "${GW6_OK}" "$DNS6_OK" "${V6_REACHED}" "${V6_PATH_CHANGED}" "$V6_STAB" "$V6_FAIL_FIELD")

  V4_LINE="link=$LINK_OK ip=$IP4_OK gw=${GW4_OK}(gw=${GW4_GW:-none} dev=${GW4_IFACE:-?}) dns=$DNS4_OK(srv=${DNS_SRV:-none} ans=${DNS4_ALL:-none} use=${DNS4_IP:-none}) reached=${V4_REACHED} path_chg=${V4_PATH_CHANGED} layer_fail=${V4_LAYER_FAIL:-none}"
  V6_LINE="link=$LINK_OK ip=$IP6_OK gw=${GW6_OK}(gw=${GW6_GW:-none} dev=${GW6_IFACE:-?}) dns=$DNS6_OK(srv=${DNS_SRV:-none} ans=${DNS6_ALL:-none} use=${DNS6_IP:-none}) reached=${V6_REACHED} path_chg=${V6_PATH_CHANGED} layer_fail=${V6_LAYER_FAIL:-none}"

  draw_ui "$NOW" "$V4_ROW" "$V6_ROW" "$V4_LINE" "$V6_LINE"

  # If the path changed, save a report + incident even if everything is still reachable.
  if [[ "${V4_PATH_CHANGED:-NO}" == "YES" ]]; then
    ID="$(date +%s)_v4_pathchg"
    REPORT_COMBINED="$(wrap_report_header v4 PATHCHG "$V4_LINE" "$DNS_SRV" "$DNS4_ALL")$V4_REPORT"
    write_incident "$ID" "path_changed" "v4" "$V4_LINE" "$REPORT_COMBINED"
    save_report v4 PATHCHG "$REPORT_COMBINED"
  fi
  if [[ "${V6_PATH_CHANGED:-NO}" == "YES" ]]; then
    ID="$(date +%s)_v6_pathchg"
    REPORT_COMBINED="$(wrap_report_header v6 PATHCHG "$V6_LINE" "$DNS_SRV" "$DNS6_ALL")$V6_REPORT"
    write_incident "$ID" "path_changed" "v6" "$V6_LINE" "$REPORT_COMBINED"
    save_report v6 PATHCHG "$REPORT_COMBINED"
  fi

  # ---------------- Incident detection ----------------
  STATE_V4="$LINK_OK/$IP4_OK/${GW4_OK}/$DNS4_OK/$V4_REACHED/${V4_LAYER_FAIL:-none}"
  STATE_V6="$LINK_OK/$IP6_OK/${GW6_OK}/$DNS6_OK/$V6_REACHED/${V6_LAYER_FAIL:-none}"

  if [[ "$STATE_V4" != "$LAST_STATE_V4" ]]; then
    if [[ "${V4_LAYER_FAIL:-}" != "" && "${V4_LAYER_FAIL:-}" != "none" ]]; then
      ID="$(date +%s)_v4"
      write_incident "$ID" "layer_fail=${V4_LAYER_FAIL}" "v4" "$V4_LINE" "$V4_REPORT"
      save_report v4 FAIL "$V4_REPORT"
    fi
    LAST_STATE_V4="$STATE_V4"
  fi

  if [[ "$STATE_V6" != "$LAST_STATE_V6" ]]; then
    if [[ "${V6_LAYER_FAIL:-}" != "" && "${V6_LAYER_FAIL:-}" != "none" ]]; then
      ID="$(date +%s)_v6"
      write_incident "$ID" "layer_fail=${V6_LAYER_FAIL}" "v6" "$V6_LINE" "$V6_REPORT"
      save_report v6 FAIL "$V6_REPORT"
    fi
    LAST_STATE_V6="$STATE_V6"
  fi

  # Optional periodic OK report
  if [[ "$SAVE_OK_EVERY" != "0" ]]; then
    now_s=$(date +%s)
    if (( now_s - LAST_OK_SAVE >= SAVE_OK_EVERY )); then
      [[ -n "$V4_REPORT" ]] && save_report v4 OK "$V4_REPORT"
      [[ -n "$V6_REPORT" ]] && save_report v6 OK "$V6_REPORT"
      LAST_OK_SAVE=$now_s
    fi
  fi

  sleep "$LOOP_INTERVAL"
done
