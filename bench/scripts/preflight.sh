#!/usr/bin/env bash
# Verify and record host conditions that materially affect benchmark results.
#
# Exit status:
#   0  all required checks passed
#   1  at least one required check failed (a measurement run must not proceed)
#   2  usage or environment error
#
# Usage:
#   preflight.sh                 human-readable report
#   preflight.sh --json          machine-readable record for the run manifest
#   preflight.sh --fix           apply the automatable fixes, then re-check
#   preflight.sh --role app      annotate the record with this node's role
set -uo pipefail

FORMAT=text
FIX=0
ROLE="${BENCH_ROLE:-unknown}"

while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --fix) FIX=1 ;;
    --role) shift; ROLE="${1:?--role needs a value}" ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

FAILURES=0
declare -a RESULTS=()

# record <name> <status> <observed> <expected> <note>
record() {
  RESULTS+=("$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"$'\x1f'"$5")
  [ "$2" = "fail" ] && FAILURES=$((FAILURES + 1))
  return 0
}

read_first() {
  # Print the contents of the first readable path, or an empty string.
  local p
  for p in "$@"; do
    if [ -r "$p" ]; then cat "$p" 2>/dev/null; return 0; fi
  done
  return 0
}

# --- CPU frequency governor -------------------------------------------------
# A powersave or schedutil governor produces latency that varies with load
# ramp rate, which is indistinguishable from framework warm-up behavior.
check_governor() {
  local govs
  govs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | paste -sd, -)
  if [ -z "$govs" ]; then
    record cpu_governor warn "unavailable" performance \
      "no cpufreq sysfs; likely a VM or firmware-managed frequency"
    return
  fi
  if [ "$govs" = "performance" ]; then
    record cpu_governor pass "$govs" performance ""
    return
  fi
  if [ "$FIX" = 1 ]; then
    if command -v cpupower >/dev/null 2>&1; then
      sudo cpupower frequency-set -g performance >/dev/null 2>&1
    else
      for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance | sudo tee "$f" >/dev/null 2>&1
      done
    fi
    govs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | paste -sd, -)
  fi
  if [ "$govs" = "performance" ]; then
    record cpu_governor pass "$govs" performance "set by --fix"
  else
    record cpu_governor fail "$govs" performance \
      "run with --fix, or set the governor in firmware"
  fi
}

# --- sysctl checks ----------------------------------------------------------
# Each is a minimum, not an exact value: a host tuned higher is fine.
check_sysctl_min() {
  local key="$1" want="$2" field="${3:-1}"
  local have
  have=$(sysctl -n "$key" 2>/dev/null | awk -v f="$field" '{print $f}')
  if [ -z "$have" ]; then
    record "$key" warn "unavailable" ">= $want" "sysctl key not present"
    return
  fi
  if [ "$have" -ge "$want" ] 2>/dev/null; then
    record "$key" pass "$have" ">= $want" ""
    return
  fi
  if [ "$FIX" = 1 ]; then
    sudo sysctl -w "$key=$want" >/dev/null 2>&1
    have=$(sysctl -n "$key" 2>/dev/null | awk -v f="$field" '{print $f}')
  fi
  if [ "$have" -ge "$want" ] 2>/dev/null; then
    record "$key" pass "$have" ">= $want" "set by --fix"
  else
    record "$key" fail "$have" ">= $want" \
      "at 10k RPS this queue overflows and shows up as connection-reset errors"
  fi
}

# --- ephemeral port range ---------------------------------------------------
# The load generator opens tens of thousands of sockets. A narrow range
# exhausts them mid-trial and the run dies with EADDRNOTAVAIL.
check_port_range() {
  local lo hi span
  lo=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | awk '{print $1}')
  hi=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | awk '{print $2}')
  if [ -z "$lo" ] || [ -z "$hi" ]; then
    record ip_local_port_range warn "unavailable" "span >= 32768" ""
    return
  fi
  span=$((hi - lo))
  if [ "$span" -ge 32768 ]; then
    record ip_local_port_range pass "$lo $hi (span $span)" "span >= 32768" ""
    return
  fi
  if [ "$FIX" = 1 ]; then
    sudo sysctl -w "net.ipv4.ip_local_port_range=1024 65535" >/dev/null 2>&1
    lo=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | awk '{print $1}')
    hi=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | awk '{print $2}')
    span=$((hi - lo))
  fi
  if [ "$span" -ge 32768 ]; then
    record ip_local_port_range pass "$lo $hi (span $span)" "span >= 32768" "set by --fix"
  else
    record ip_local_port_range fail "$lo $hi (span $span)" "span >= 32768" \
      "the load generator will exhaust ephemeral ports mid-trial"
  fi
}

# --- conntrack --------------------------------------------------------------
# A loaded conntrack table drops packets silently. Absent is better than large.
check_conntrack() {
  if [ ! -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
    record nf_conntrack pass "module not loaded" "absent or >= 1048576" \
      "best case: no connection tracking on the benchmark path"
    return
  fi
  local max cur
  max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
  cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
  if [ "${max:-0}" -ge 1048576 ] 2>/dev/null; then
    record nf_conntrack pass "max=$max count=$cur" ">= 1048576" ""
  else
    record nf_conntrack fail "max=$max count=$cur" ">= 1048576" \
      "table overflow drops packets and looks like framework packet loss"
  fi
}

# --- swap -------------------------------------------------------------------
# Any swap in use on the app node makes memory measurements meaningless.
check_swap() {
  local used
  used=$(free -b 2>/dev/null | awk '/^Swap:/ {print $3}')
  used="${used:-0}"
  if [ "$used" -eq 0 ] 2>/dev/null; then
    record swap_in_use pass "0" "0" ""
  else
    record swap_in_use fail "$used bytes" "0" \
      "swapped pages make RSS comparisons across frameworks invalid"
  fi
}

# --- clock sync -------------------------------------------------------------
# Latency percentiles are compared across three hosts. Unsynchronized clocks
# make cross-node correlation of a spike impossible.
check_clock() {
  local synced=""
  if command -v timedatectl >/dev/null 2>&1; then
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  fi
  case "$synced" in
    yes|true) record clock_sync pass "NTP synchronized" synchronized "" ;;
    no|false) record clock_sync fail "not synchronized" synchronized \
        "enable systemd-timesyncd or chrony on every node" ;;
    *) record clock_sync warn "unknown" synchronized "timedatectl unavailable" ;;
  esac
}

# --- recorded-only observations ---------------------------------------------
# These never fail the run. They must simply be identical across trials, which
# verify-manifest.sh enforces by comparing recorded values.
observe() {
  local smt thp cpu_model cores kernel nic
  smt=$(read_first /sys/devices/system/cpu/smt/control)
  [ -z "$smt" ] && smt="unavailable"
  thp=$(read_first /sys/kernel/mm/transparent_hugepage/enabled)
  thp=$(printf '%s' "$thp" | grep -o '\[[a-z]*\]' | tr -d '[]')
  [ -z "$thp" ] && thp="unavailable"
  cpu_model=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [ -z "$cpu_model" ] && cpu_model="unknown"
  cores=$(nproc 2>/dev/null || echo 0)
  kernel=$(uname -r)

  record smt_control observe "$smt" "identical across trials" ""
  record transparent_hugepages observe "$thp" "identical across trials" ""
  record cpu_model observe "$cpu_model" "identical across nodes" ""
  record cpu_count observe "$cores" "identical across nodes" ""
  record kernel observe "$kernel" "identical across nodes" ""

  # Steal time: non-zero means this host is not exclusively ours.
  # /proc/stat columns after the "cpu" label are: user nice system idle iowait
  # irq softirq steal guest guest_nice -- so steal is field 9.
  local steal
  steal=$(awk '/^cpu / {print $9}' /proc/stat 2>/dev/null)
  record cpu_steal_ticks observe "${steal:-unknown}" "0 on bare metal" \
    "non-zero indicates shared tenancy; discard such trials"

  # NIC ring buffers, recorded per interface that is up and not loopback.
  if command -v ethtool >/dev/null 2>&1; then
    for nic_path in /sys/class/net/*; do
      [ -e "$nic_path" ] || continue
      nic="${nic_path##*/}"
      [ "$nic" = "lo" ] && continue
      [ "$(cat "/sys/class/net/$nic/operstate" 2>/dev/null)" = "up" ] || continue
      local rx rxmax
      rx=$(ethtool -g "$nic" 2>/dev/null | awk '/^Current hardware settings:/,0' | awk -F': *' '/^RX:/ {print $2; exit}')
      rxmax=$(ethtool -g "$nic" 2>/dev/null | awk '/^Pre-set maximums:/,/^Current/' | awk -F': *' '/^RX:/ {print $2; exit}')
      record "nic_${nic}_rx_ring" observe "${rx:-unknown}/${rxmax:-unknown}" \
        "at hardware maximum" "raise with: ethtool -G $nic rx ${rxmax:-max}"
      record "nic_${nic}_mtu" observe "$(cat "/sys/class/net/$nic/mtu" 2>/dev/null)" \
        "9000 on a jumbo-frame fabric" ""
    done
  else
    record nic_rings observe "ethtool missing" "at hardware maximum" \
      "install ethtool to record NIC settings"
  fi
}

check_governor
check_sysctl_min net.core.somaxconn 65535
check_sysctl_min net.ipv4.tcp_max_syn_backlog 65535
check_sysctl_min net.core.netdev_max_backlog 16384
check_sysctl_min fs.file-max 1000000
check_port_range
check_conntrack
check_swap
check_clock
observe

json_escape() {
  # `printf '%s'` rather than a heredoc: a heredoc appends a newline, which
  # would end up inside every string in the manifest.
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null \
    || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

if [ "$FORMAT" = json ]; then
  printf '{\n  "role": %s,\n' "$(json_escape "$ROLE")"
  printf '  "hostname": %s,\n' "$(json_escape "$(hostname)")"
  printf '  "recorded_at": %s,\n' "$(json_escape "$(date -Is)")"
  printf '  "failures": %d,\n' "$FAILURES"
  printf '  "checks": [\n'
  first=1
  for row in "${RESULTS[@]}"; do
    IFS=$'\x1f' read -r name status observed expected note <<<"$row"
    [ $first -eq 0 ] && printf ',\n'
    first=0
    printf '    {"name": %s, "status": %s, "observed": %s, "expected": %s, "note": %s}' \
      "$(json_escape "$name")" "$(json_escape "$status")" \
      "$(json_escape "$observed")" "$(json_escape "$expected")" "$(json_escape "$note")"
  done
  printf '\n  ]\n}\n'
else
  printf '%-28s %-8s %-34s %s\n' CHECK STATUS OBSERVED EXPECTED
  printf '%.0s-' {1..110}; printf '\n'
  for row in "${RESULTS[@]}"; do
    IFS=$'\x1f' read -r name status observed expected note <<<"$row"
    printf '%-28s %-8s %-34s %s\n' "$name" "$status" "$observed" "$expected"
    [ -n "$note" ] && printf '%-28s %-8s %s\n' "" "" "-> $note"
  done
  printf '\n'
  if [ "$FAILURES" -eq 0 ]; then
    echo "all required checks passed on $(hostname) (role: $ROLE)"
  else
    echo "$FAILURES required check(s) failed on $(hostname) (role: $ROLE)"
    echo "a measurement run must not proceed; try: $0 --fix"
  fi
fi

[ "$FAILURES" -eq 0 ] || exit 1
