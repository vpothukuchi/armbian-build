#!/bin/bash
# test-board-changes.sh — Run on j784s4-evm as root to validate the
# changes from commit a0129ceba (firmware symlinks, watchdog, service masking).
#
# Usage on board:
#   bash test-board-changes.sh [--no-reboot]
#
set -euo pipefail

NO_REBOOT=0
[[ "${1:-}" == "--no-reboot" ]] && NO_REBOOT=1

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

echo ""
echo "========================================================"
echo " j784s4-evm board validation"
echo "========================================================"

# --------------------------------------------------------------------------
# 1. Firmware symlinks (ti-adas-firmware v1.0.0-4)
# --------------------------------------------------------------------------
echo ""
echo "=== 1. Firmware symlinks ==="

FW_DIR=/usr/lib/firmware

expected_links=(
    j784s4-main-r5f0_0-fw j784s4-main-r5f0_1-fw
    j784s4-main-r5f1_0-fw j784s4-main-r5f1_1-fw
    j784s4-main-r5f2_0-fw j784s4-main-r5f2_1-fw
    j784s4-c71_0-fw j784s4-c71_1-fw j784s4-c71_2-fw j784s4-c71_3-fw
)

all_symlinks_ok=1
for link in "${expected_links[@]}"; do
    lpath="${FW_DIR}/${link}"
    if [[ -L "${lpath}" ]]; then
        target=$(readlink "${lpath}")
        if [[ -f "${FW_DIR}/${target}" ]]; then
            pass "  ${link} -> ${target}"
        else
            fail "  ${link} -> ${target} (target file missing!)"
            all_symlinks_ok=0
        fi
    else
        fail "  ${link} does not exist"
        all_symlinks_ok=0
    fi
done

pkg_ver=$(dpkg-query -W -f='${Version}' ti-adas-firmware 2>/dev/null || echo "not installed")
echo "  ti-adas-firmware package version: ${pkg_ver}"
[[ "${pkg_ver}" == "1.0.0-4" ]] && pass "ti-adas-firmware is v1.0.0-4" \
                                 || fail "ti-adas-firmware is ${pkg_ver} (expected 1.0.0-4)"

# --------------------------------------------------------------------------
# 2. Remoteproc state — nodes must exist (overlay applied); firmware may be
#    running (kernel auto-loads when symlinks present) or offline (no fw).
#    dorprocboot=0 only prevents U-Boot from loading; kernel loads via /lib/firmware.
# --------------------------------------------------------------------------
echo ""
echo "=== 2. Remoteproc state ==="

rproc_count=0; rproc_running=0; rproc_ok=0
for d in /sys/class/remoteproc/remoteproc*; do
    [[ -d "${d}" ]] || continue
    state=$(cat "${d}/state" 2>/dev/null || echo "unknown")
    name=$(cat "${d}/name" 2>/dev/null || echo "?")
    rproc_count=$(( rproc_count + 1 ))
    case "${state}" in
        offline|attached) rproc_ok=$(( rproc_ok + 1 )) ;;
        running)
            rproc_running=$(( rproc_running + 1 ))
            rproc_ok=$(( rproc_ok + 1 ))
            ;;
        *)
            fail "  ${name} state=${state} (unexpected)"
            ;;
    esac
done

if [[ "${rproc_count}" -eq 0 ]]; then
    fail "No remoteproc devices found (overlay not loaded?)"
else
    pass "${rproc_ok}/${rproc_count} remoteproc devices OK (${rproc_running} running with firmware)"
fi

# --------------------------------------------------------------------------
# 3. Vision-apps reserved-memory regions
# --------------------------------------------------------------------------
echo ""
echo "=== 3. DTS overlay / reserved-memory ==="

va_count=$(ls /proc/device-tree/reserved-memory/ 2>/dev/null | grep -ic "vision.apps" || true)
if [[ "${va_count}" -ge 10 ]]; then
    pass "${va_count} vision-apps reserved-memory regions present"
else
    fail "Only ${va_count} vision-apps regions found (expected ≥10)"
fi

# --------------------------------------------------------------------------
# 4. Service masking
# --------------------------------------------------------------------------
echo ""
echo "=== 4. Systemd service masking ==="

masked_services=(
    systemd-networkd.service
    systemd-networkd.socket
    systemd-network-generator.service
    armbian-resize-filesystem.service
)

for svc in "${masked_services[@]}"; do
    state=$(systemctl is-enabled "${svc}" 2>/dev/null; true)
    if [[ "${state}" == "masked" ]]; then
        pass "${svc} is masked"
    else
        fail "${svc} is '${state}' (expected masked)"
    fi
done

# --------------------------------------------------------------------------
# 5. Watchdog
# --------------------------------------------------------------------------
echo ""
echo "=== 5. Watchdog daemon ==="

if command -v watchdog &>/dev/null || [[ -x /usr/sbin/watchdog ]]; then
    pass "watchdog binary present"

    wdog_default=/etc/default/watchdog
    if [[ -f "${wdog_default}" ]] && grep -q "run_watchdog=1" "${wdog_default}"; then
        pass "/etc/default/watchdog: run_watchdog=1"
    else
        fail "/etc/default/watchdog missing or run_watchdog not 1"
    fi

    wdog_conf=/etc/watchdog.conf
    if [[ -f "${wdog_conf}" ]] && grep -q "watchdog-device" "${wdog_conf}"; then
        pass "/etc/watchdog.conf present"
    else
        fail "/etc/watchdog.conf missing or incomplete"
    fi

    wdog_state=$(systemctl is-enabled watchdog.service 2>/dev/null || echo "not-found")
    [[ "${wdog_state}" == "enabled" ]] && pass "watchdog.service enabled" \
                                       || fail "watchdog.service is ${wdog_state}"

    wdog_active=$(systemctl is-active watchdog.service 2>/dev/null || echo "inactive")
    [[ "${wdog_active}" == "active" ]] && pass "watchdog.service running" \
                                       || fail "watchdog.service is ${wdog_active}"
else
    fail "watchdog binary not found (package not installed)"
fi

# --------------------------------------------------------------------------
# 6. uEnv.txt entries
# --------------------------------------------------------------------------
echo ""
echo "=== 6. uEnv.txt boot configuration ==="

uenv=/boot/uEnv.txt
if [[ -f "${uenv}" ]]; then
    grep -q "dorprocboot=0" "${uenv}" \
        && pass "dorprocboot=0 in uEnv.txt" \
        || fail "dorprocboot=0 NOT in uEnv.txt"
    grep -q "k3-j784s4-vision-apps.dtbo" "${uenv}" \
        && pass "vision-apps overlay in uEnv.txt" \
        || fail "vision-apps overlay NOT in uEnv.txt"
else
    fail "/boot/uEnv.txt not found"
fi

# --------------------------------------------------------------------------
# 7. Quick remoteproc firmware load test (mcu2_0 only)
# --------------------------------------------------------------------------
echo ""
echo "=== 7. Remoteproc firmware load test (mcu2_0) ==="

rproc0="/sys/class/remoteproc/remoteproc0"
if [[ -d "${rproc0}" ]] && [[ "${all_symlinks_ok:-0}" -eq 1 ]]; then
    state_before=$(cat "${rproc0}/state")
    if [[ "${state_before}" == "offline" ]]; then
        echo "  Loading mcu2_0 firmware..."
        if echo start > "${rproc0}/state" 2>/dev/null; then
            sleep 1
            state_after=$(cat "${rproc0}/state")
            if [[ "${state_after}" == "running" ]]; then
                pass "remoteproc0 loaded and running"
                # Stop it again
                echo stop > "${rproc0}/state" 2>/dev/null || true
                sleep 1
                echo "  Stopped remoteproc0 (state: $(cat ${rproc0}/state))"
            else
                fail "remoteproc0 state after start: ${state_after}"
            fi
        else
            fail "echo start > ${rproc0}/state failed"
        fi
    elif [[ "${state_before}" == "running" ]]; then
        pass "remoteproc0 already running (firmware auto-loaded by kernel)"
    else
        echo "  SKIP: remoteproc0 is ${state_before}"
    fi
else
    echo "  SKIP: remoteproc0 not available or symlinks missing"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "========================================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "========================================================"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
    echo "Some checks failed. Review output above."
    exit 1
fi

echo "All checks passed."
if [[ "${NO_REBOOT}" -eq 0 ]]; then
    echo ""
    echo "Rebooting in 5 seconds to validate clean boot timing..."
    echo "(Connect to serial console to observe boot sequence)"
    sleep 5
    reboot
fi
