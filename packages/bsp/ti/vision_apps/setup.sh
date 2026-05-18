#!/bin/bash
# /opt/vision_apps/setup.sh — Vision Apps runtime setup for J784S4-EVM
#
# Sets environment variables for TI Vision Apps and manages RTOS firmware
# loading onto the J784S4 remote cores (6x R5F MCU + 4x C71x DSP).
#
# Usage:
#   source /opt/vision_apps/setup.sh           Set env vars in current shell
#   sudo /opt/vision_apps/setup.sh             Load firmware + report status
#   /opt/vision_apps/setup.sh --status         Show all core states
#   sudo /opt/vision_apps/setup.sh --start     Start all offline cores
#   sudo /opt/vision_apps/setup.sh --stop      Stop all running cores
#   sudo /opt/vision_apps/setup.sh --restart   Stop + start all cores
#   /opt/vision_apps/setup.sh --log [file]     Start remote log monitor
#   /opt/vision_apps/setup.sh --help           Show this help

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
VISION_APPS_PATH="${VISION_APPS_PATH:-/opt/vision_apps}"
FW_DIR="/usr/lib/firmware/vision_apps_evm"
REMOTE_LOG_BIN="${VISION_APPS_PATH}/vx_app_arm_remote_log.out"
REMOTE_LOG_DEFAULT="/var/log/vision_apps_remote.log"

# ---------------------------------------------------------------------------
# Environment setup — exported for child processes
# ---------------------------------------------------------------------------
_setup_env() {
    export VISION_APPS_PATH
    export TIDL_ARTIFACTS_PATH="${VISION_APPS_PATH}/test_data/tidl_models"

    # OpenVX zone logging: 0=off, bitmask of zones to enable
    export VX_ZONE_ENABLE="${VX_ZONE_ENABLE:-0}"

    # Memory allocation / RT logging for TI app framework
    export APP_LOG_MEM_ALLOC_ENABLE="${APP_LOG_MEM_ALLOC_ENABLE:-0}"
    export APP_LOG_RT_ENABLE="${APP_LOG_RT_ENABLE:-0}"

    # Ensure shared libraries installed to /usr/lib are found
    case ":${LD_LIBRARY_PATH}:" in
        *":/usr/lib:"*) ;;
        *) export LD_LIBRARY_PATH="/usr/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
    esac

    # Vision Apps binaries may open many DMA buffers
    ulimit -n 65536 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Remoteproc helpers
# ---------------------------------------------------------------------------
_rproc_dirs() {
    # List all remoteproc sysfs directories, sorted numerically
    local d
    for d in /sys/class/remoteproc/remoteproc*; do
        [[ -d "${d}" ]] && echo "${d}"
    done | sort -V
}

_rproc_attr() { cat "${1}/${2}" 2>/dev/null || echo "unknown"; }

_fw_present() {
    local fw="$1"
    [[ -e "/usr/lib/firmware/${fw}" ]] || [[ -L "/usr/lib/firmware/${fw}" ]]
}

# ---------------------------------------------------------------------------
# Status: print table of all remote cores
# ---------------------------------------------------------------------------
_status() {
    local total=0 running=0 offline=0 other=0

    printf "\n%-25s %-32s %-10s %s\n" "Core" "Firmware" "State" "FW Present"
    printf '%0.s-' {1..80}; echo

    while IFS= read -r d; do
        local name fw state fw_tag
        name="$(_rproc_attr "${d}" name)"
        fw="$(_rproc_attr  "${d}" firmware)"
        state="$(_rproc_attr "${d}" state)"
        _fw_present "${fw}" && fw_tag="yes" || fw_tag="MISSING"
        printf "%-25s %-32s %-10s %s\n" "${name}" "${fw}" "${state}" "${fw_tag}"
        (( total++ )) || true
        case "${state}" in
            running) (( running++ )) || true ;;
            offline) (( offline++ )) || true ;;
            *)       (( other++   )) || true ;;
        esac
    done < <(_rproc_dirs)

    printf "\nSummary: %d cores — %d running, %d offline, %d other\n\n" \
        "${total}" "${running}" "${offline}" "${other}"
}

# ---------------------------------------------------------------------------
# Start: write 'start' to each offline core whose firmware symlink exists
# ---------------------------------------------------------------------------
_start() {
    local started=0 failed=0 skipped=0

    while IFS= read -r d; do
        local name state fw
        name="$(_rproc_attr "${d}" name)"
        state="$(_rproc_attr "${d}" state)"
        fw="$(_rproc_attr   "${d}" firmware)"

        if [[ "${state}" == "running" ]]; then
            printf "  [SKIP]  %-25s already running\n" "${name}"
            (( skipped++ )) || true
            continue
        fi

        if ! _fw_present "${fw}"; then
            printf "  [SKIP]  %-25s firmware '%s' not found\n" "${name}" "${fw}"
            (( skipped++ )) || true
            continue
        fi

        if [[ "${state}" != "offline" ]]; then
            printf "  [SKIP]  %-25s unexpected state '%s'\n" "${name}" "${state}"
            (( skipped++ )) || true
            continue
        fi

        printf "  [START] %-25s %-30s ... " "${name}" "(${fw})"
        if echo "start" > "${d}/state" 2>/dev/null; then
            # Poll up to 5 s for running state
            local i=0
            while [[ "$(_rproc_attr "${d}" state)" != "running" ]] && (( i < 50 )); do
                sleep 0.1; (( i++ )) || true
            done
            local final_state
            final_state="$(_rproc_attr "${d}" state)"
            if [[ "${final_state}" == "running" ]]; then
                echo "OK"
                (( started++ )) || true
            else
                printf "TIMEOUT (state=%s)\n" "${final_state}"
                (( failed++ )) || true
            fi
        else
            echo "FAILED (permission denied?)"
            (( failed++ )) || true
        fi
    done < <(_rproc_dirs)

    printf "\nStarted: %d  Failed: %d  Skipped: %d\n\n" \
        "${started}" "${failed}" "${skipped}"
    [[ "${failed}" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Stop: write 'stop' to each running core
# ---------------------------------------------------------------------------
_stop() {
    local stopped=0 failed=0

    while IFS= read -r d; do
        local name state
        name="$(_rproc_attr "${d}" name)"
        state="$(_rproc_attr "${d}" state)"

        if [[ "${state}" != "running" ]]; then
            printf "  [SKIP]  %-25s state is '%s'\n" "${name}" "${state}"
            continue
        fi

        printf "  [STOP]  %-25s ... " "${name}"
        if echo "stop" > "${d}/state" 2>/dev/null; then
            echo "OK"
            (( stopped++ )) || true
        else
            echo "FAILED"
            (( failed++ )) || true
        fi
    done < <(_rproc_dirs)

    printf "\nStopped: %d  Failed: %d\n\n" "${stopped}" "${failed}"
    [[ "${failed}" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Remote log monitor
# ---------------------------------------------------------------------------
_start_log() {
    local logfile="${1:-${REMOTE_LOG_DEFAULT}}"

    if [[ ! -x "${REMOTE_LOG_BIN}" ]]; then
        echo "Remote log binary not found: ${REMOTE_LOG_BIN}" >&2
        echo "Install ti-vision-apps-data to get vx_app_arm_remote_log.out" >&2
        return 1
    fi

    echo "Starting remote log monitor → ${logfile}"
    nohup "${REMOTE_LOG_BIN}" > "${logfile}" 2>&1 &
    local pid=$!
    echo "PID: ${pid}"
    echo "${pid}" > /var/run/vision_apps_remote_log.pid 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# When sourced: only export env vars, then return immediately
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    _setup_env
    echo "Vision Apps environment set (VISION_APPS_PATH=${VISION_APPS_PATH})"
    return 0
fi

# When executed directly: set env then dispatch action
_setup_env

_action="${1:-}"

case "${_action}" in
    --status)
        _status
        ;;

    --start)
        if [[ "${EUID}" -ne 0 ]]; then
            echo "ERROR: --start requires root (remoteproc state writes are root-only)" >&2
            exit 1
        fi
        _start
        ;;

    --stop)
        if [[ "${EUID}" -ne 0 ]]; then
            echo "ERROR: --stop requires root" >&2
            exit 1
        fi
        _stop
        ;;

    --restart)
        if [[ "${EUID}" -ne 0 ]]; then
            echo "ERROR: --restart requires root" >&2
            exit 1
        fi
        echo "=== Stopping remote cores ==="
        _stop
        echo "=== Starting remote cores ==="
        _start
        ;;

    --log)
        _start_log "${2:-}"
        ;;

    --help|-h)
        sed -n '/^# Usage:/,/^# -----------/{ /^# -----/d; s/^# \?//; p }' "$0"
        ;;

    "")
        # Default: load firmware (if root) then show status
        if [[ "${EUID}" -eq 0 ]]; then
            echo "=== Loading firmware on offline remote cores ==="
            _start
        else
            echo "NOTE: Run as root (sudo $0) to load firmware onto remote cores."
            echo "      Environment variables have been set."
            echo ""
        fi
        _status
        ;;

    *)
        echo "Unknown option: ${_action}" >&2
        echo "Use --help for usage." >&2
        exit 1
        ;;
esac
