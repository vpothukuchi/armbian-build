#!/bin/bash
# build-from-source.sh — Build ti-adas-firmware .deb package.
#
# Upstream:  https://git.ti.com/git/processor-sdk/psdk_fw.git
# Reference: meta-edgeai/recipes-tisdk/ti-psdk-rtos/ti-adas-firmware.bb
#            (requires ti-edgeai-firmware.bb)
# SRCREV:    579af7d6c4b0172d4824faf16972adbdcd13902b
#
# This is a pre-built firmware package — no cross-compilation needed.
# Clones psdk_fw.git and copies the j784s4/vision_apps_evm/*.out (and
# *.out.signed) firmware blobs into the staging area.  The resulting
# .deb installs them to /usr/lib/firmware/vision_apps_evm/ and registers
# update-alternatives symlinks so remoteproc can load them by the
# canonical names (e.g. j784s4-main-r5f0_0-fw).
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --mirror          <dir>   Yocto-style bare-clone mirror directory
#   --prebuilt-fw-dir <dir>   Use pre-built firmware from this directory
#                             (skips git clone; copies *.out and *.out.signed)
#   --skip-fetch              Skip git clone/checkout (re-use existing src/)
#
# Phase: Firmware (no TI package build-time dependencies)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Pinned SRCREV (from ti-edgeai-firmware.bb, PSDK Analytics 11.02)
# ---------------------------------------------------------------------------
SRCREV="579af7d6c4b0172d4824faf16972adbdcd13902b"
GIT_REMOTE="https://git.ti.com/git/processor-sdk/psdk_fw.git"
MIRROR_BASENAME="git.ti.com.git.processor-sdk.psdk_fw.git"

PKG_VERSION="1.0.0"
DEB_REVISION="1"

# j784s4 firmware subdirectory inside the repo
FW_SUBDIR="j784s4/vision_apps_evm"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MIRROR_DIR=""
PREBUILT_FW_DIR=""
SKIP_FETCH=0

SRC_DIR="${SCRIPT_DIR}/src/psdk_fw"
STAGING_DIR="${SCRIPT_DIR}/staging"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mirror)           MIRROR_DIR="$2";      shift 2 ;;
        --prebuilt-fw-dir)  PREBUILT_FW_DIR="$2"; shift 2 ;;
        --skip-fetch)       SKIP_FETCH=1;         shift ;;
        --help)
            sed -n '/^# Usage:/,/^$/p' "$0"
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in git dpkg-buildpackage dh; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || \
        error "Missing tools: ${missing[*]}. Install with: sudo apt install git debhelper devscripts"
}

# ---------------------------------------------------------------------------
# Step 1: Obtain source
# ---------------------------------------------------------------------------
obtain_source() {
    info "=== Obtaining psdk_fw at ${SRCREV} ==="
    mkdir -p "${SCRIPT_DIR}/src"

    if [[ -d "${SRC_DIR}/.git" ]]; then
        info "  Source directory exists; checking out ${SRCREV}..."
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    else
        local clone_from="${GIT_REMOTE}"
        if [[ -n "${MIRROR_DIR}" && -d "${MIRROR_DIR}/${MIRROR_BASENAME}" ]]; then
            info "  Cloning from local mirror: ${MIRROR_DIR}/${MIRROR_BASENAME}"
            clone_from="${MIRROR_DIR}/${MIRROR_BASENAME}"
        else
            info "  Cloning from upstream: ${GIT_REMOTE}"
        fi
        git clone "${clone_from}" "${SRC_DIR}"
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    fi

    info "  HEAD: $(git -C "${SRC_DIR}" log -1 --oneline)"

    [[ -d "${SRC_DIR}/${FW_SUBDIR}" ]] || \
        error "Firmware directory not found: ${SRC_DIR}/${FW_SUBDIR}"
}

# ---------------------------------------------------------------------------
# Step 2: Stage firmware files
# ---------------------------------------------------------------------------
stage_firmware() {
    info "=== Staging firmware files ==="

    local fw_dest="${STAGING_DIR}/usr/lib/firmware/vision_apps_evm"
    rm -rf "${STAGING_DIR}"
    mkdir -p "${fw_dest}"

    if [[ -n "${PREBUILT_FW_DIR}" ]]; then
        # Use pre-built firmware directory (e.g. from a Yocto build).
        # Copies all *.out and *.out.signed files found there.
        info "  Copying from prebuilt directory: ${PREBUILT_FW_DIR}"
        [[ -d "${PREBUILT_FW_DIR}" ]] || error "Prebuilt firmware directory not found: ${PREBUILT_FW_DIR}"
        local count=0
        for f in "${PREBUILT_FW_DIR}"/*.out "${PREBUILT_FW_DIR}"/*.out.signed; do
            [[ -f "${f}" ]] || continue
            install -m 0644 "${f}" "${fw_dest}/"
            count=$((count + 1))
        done
        [[ ${count} -gt 0 ]] || error "No *.out / *.out.signed files found in: ${PREBUILT_FW_DIR}"
        info "  Copied ${count} firmware files"
    else
        # Build from git source: unsigned .out files come from the repo;
        # .out.signed files are generated by Yocto secure-binary-image.sh and
        # are NOT in the git tree.  Only the unsigned files are staged here.
        local fw_src="${SRC_DIR}/${FW_SUBDIR}"

        # j784s4 firmware list (from ti-edgeai-firmware.bb FW_LIST:j784s4)
        local -a fw_files=(
            vx_app_rtos_linux_mcu2_0.out
            vx_app_rtos_linux_mcu2_1.out
            vx_app_rtos_linux_mcu3_0.out
            vx_app_rtos_linux_mcu3_1.out
            vx_app_rtos_linux_mcu4_0.out
            vx_app_rtos_linux_mcu4_1.out
            vx_app_rtos_linux_c7x_1.out
            vx_app_rtos_linux_c7x_2.out
            vx_app_rtos_linux_c7x_3.out
            vx_app_rtos_linux_c7x_4.out
        )

        local count=0
        for fw in "${fw_files[@]}"; do
            local src="${fw_src}/${fw}"
            [[ -f "${src}" ]] || error "Firmware file missing: ${src}"
            install -m 0644 "${src}" "${fw_dest}/${fw}"
            count=$((count + 1))
            # Copy signed variant if available (generated by Yocto, not in git)
            if [[ -f "${src}.signed" ]]; then
                install -m 0644 "${src}.signed" "${fw_dest}/${fw}.signed"
                count=$((count + 1))
            fi
        done
        info "  Staged ${count} firmware files"
    fi

    du -sh "${STAGING_DIR}/usr/lib/firmware/vision_apps_evm/"
}

# ---------------------------------------------------------------------------
# Step 3: Package into .deb
# ---------------------------------------------------------------------------
package_deb() {
    info "=== Packaging .deb file ==="

    local current_ver
    current_ver=$(dpkg-parsechangelog -l "${SCRIPT_DIR}/debian/changelog" \
                  --show-field Version 2>/dev/null || echo "")
    info "  Package version: ${current_ver}"

    cd "${SCRIPT_DIR}"
    dpkg-buildpackage \
        --build=binary \
        --no-sign \
        -d \
        2>&1 | tee "${SCRIPT_DIR}/build-from-source.log"

    info "=== Produced packages ==="
    ls -lh "${SCRIPT_DIR}/../"ti-adas-firmware*.deb 2>/dev/null || \
        info "  .deb files are in the parent directory"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Building ti-adas-firmware ${PKG_VERSION}"

    check_deps

    if [[ -n "${PREBUILT_FW_DIR}" ]]; then
        info "  Prebuilt firmware directory: ${PREBUILT_FW_DIR} (skipping git fetch)"
    elif [[ "${SKIP_FETCH}" -eq 0 ]]; then
        obtain_source
    fi

    stage_firmware
    package_deb
}

main "$@"
