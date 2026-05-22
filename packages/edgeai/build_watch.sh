#!/bin/bash
# build_watch.sh — Monitor build_armbian.sh progress and detect hangs.
#
# Usage:
#   bash build_watch.sh [LOG_FILE] [STALL_MINUTES]
#
#   LOG_FILE       Build log to watch (default: /tmp/build.log)
#   STALL_MINUTES  Alert threshold in minutes with no log activity (default: 15)
#
# Run in a second terminal while the build is running.
# Prints a one-line status every 30 s; turns red if the log goes stale.

set -euo pipefail

LOG="${1:-/tmp/build.log}"
STALL_MIN="${2:-15}"
STALL_SEC=$(( STALL_MIN * 60 ))
POLL=30   # seconds between status lines

RED='\033[0;31m'
YLW='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'

die() { echo "$*" >&2; exit 1; }

[[ -f "$LOG" ]] || die "Log file not found: $LOG"

current_phase() {
    # Match lines containing "=== <text> ===" but not the progress bar [====]
    strings "$LOG" 2>/dev/null | grep "=== [A-Za-z]" | grep -v "Build sequence\|Build complete\|Clean" \
        | tail -1 | sed 's/.*=== //;s/ ===.*//' || true
}

log_age_sec() {
    local mod
    mod=$(stat -c %Y "$LOG" 2>/dev/null) || { echo 9999; return; }
    echo $(( $(date +%s) - mod ))
}

docker_container() {
    docker ps --format "{{.ID}}\t{{.Status}}" 2>/dev/null | head -1
}

build_pid() {
    pgrep -f "build_armbian.sh" 2>/dev/null | head -1 || true
}

fmt_age() {
    local s=$1
    if   (( s < 60  )); then echo "${s}s ago"
    elif (( s < 3600)); then printf "%dm %02ds ago" $(( s/60 )) $(( s%60 ))
    else                     printf "%dh %02dm ago" $(( s/3600 )) $(( (s%3600)/60 ))
    fi
}

log_size() {
    stat -c %s "$LOG" 2>/dev/null || echo 0
}

echo ""
echo "  Build watchdog — log: $LOG   stall threshold: ${STALL_MIN}m"
echo "  Press Ctrl-C to stop watching."
echo ""
printf "  %-22s  %-30s  %-14s  %s\n" "TIME" "PHASE" "LOG UPDATED" "STATUS"
printf "  %-22s  %-30s  %-14s  %s\n" "----" "-----" "-----------" "------"

prev_size=0
warned=0

while true; do
    now=$(date '+%Y-%m-%d %H:%M:%S')
    phase=$(current_phase)
    age=$(log_age_sec)
    age_str=$(fmt_age "$age")
    size=$(log_size)
    delta=$(( size - prev_size ))
    prev_size=$size
    pid=$(build_pid)
    container=$(docker_container)

    if [[ -z "$pid" ]]; then
        # No build process — check if it finished or died
        if strings "$LOG" 2>/dev/null | grep -q "=== Build complete ===" 2>/dev/null; then
            echo -e "  ${GRN}${now}  BUILD COMPLETE${RST}"
        else
            echo -e "  ${RED}${now}  BUILD PROCESS GONE (no 'Build complete' in log)${RST}"
        fi
        exit 0
    fi

    if (( age > STALL_SEC )); then
        color=$RED
        status="⚠  STALLED ${age_str} — possible hang!"
        warned=1
    elif (( age > STALL_SEC / 2 )); then
        color=$YLW
        status="!  Slow: no output for ${age_str}"
    else
        color=$GRN
        status="✓  +${delta}B"
        warned=0
    fi

    phase_short="${phase:0:30}"
    [[ -z "$phase_short" ]] && phase_short="(starting...)"

    printf "  ${color}%-22s  %-30s  %-14s  %s${RST}\n" \
        "$now" "$phase_short" "$age_str" "$status"

    sleep "$POLL"
done
