#!/bin/bash
# build-from-source.sh — Build edgeai-apps-utils and edgeai-apps-utils-dev .deb packages
#                        using CMake cross-compilation.
#
# Upstream:  https://git.ti.com/git/edgeai/edgeai-apps-utils.git
# Reference: meta-edgeai/recipes-tisdk/edgeai-components/edgeai-apps-utils.bb
# SRCREV:    0d003eb05afb89d4b6248ce9a33b6599b9629e1d  (PSDK Analytics 11.02)
#
# Prerequisites (cross-compilation in Docker):
#   - aarch64-linux-gnu cross-compiler
#   - cmake, ninja-build, debhelper, devscripts
#   - Target sysroot with ti-vision-apps headers at:
#       <sysroot>/usr/include/processor_sdk/{vision_apps,app_utils,...}
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --sysroot     <path>   aarch64 target sysroot (default: /opt/arm64-sysroot)
#   --mirror      <dir>    Yocto-style bare-clone mirror directory
#   --soc         <soc>    Target SoC (default: j784s4)
#   --jobs        <N>      Parallel build jobs (default: nproc)
#   --skip-fetch           Skip git clone/checkout
#   --skip-build           Skip cmake build, re-use existing outputs
#
# Phase: E1 — no TI package build-time dependencies beyond ti-vision-apps
#              (which must already be overlaid into the sysroot from A2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Pinned SRCREV (from edgeai-apps-utils.bb, PSDK Analytics 11.02)
# ---------------------------------------------------------------------------
SRCREV="0d003eb05afb89d4b6248ce9a33b6599b9629e1d"
GIT_REMOTE="https://git.ti.com/git/edgeai/edgeai-apps-utils.git"
MIRROR_BASENAME="git.ti.com.git.edgeai.edgeai-apps-utils.git"

PKG_VERSION="1.0.0"
DEB_REVISION="1"
LIB_VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SYSROOT="/opt/arm64-sysroot"
MIRROR_DIR=""
SOC="j784s4"
JOBS="$(nproc)"
SKIP_FETCH=0
SKIP_BUILD=0

SRC_DIR="${SCRIPT_DIR}/src/edgeai-apps-utils"
BUILD_DIR="${SCRIPT_DIR}/src/build"
STAGING_DIR="${SCRIPT_DIR}/staging"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sysroot)    SYSROOT="$2";    shift 2 ;;
        --mirror)     MIRROR_DIR="$2"; shift 2 ;;
        --soc)        SOC="$2";        shift 2 ;;
        --jobs)       JOBS="$2";       shift 2 ;;
        --skip-fetch) SKIP_FETCH=1;    shift ;;
        --skip-build) SKIP_BUILD=1;    shift ;;
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
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in aarch64-linux-gnu-gcc cmake ninja dpkg-buildpackage dh; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || \
        error "Missing tools: ${missing[*]}.  Install with:
  sudo apt install gcc-aarch64-linux-gnu cmake ninja-build debhelper devscripts"
}

# ---------------------------------------------------------------------------
# Step 1: Obtain source
# ---------------------------------------------------------------------------
obtain_source() {
    info "=== Obtaining edgeai-apps-utils source at ${SRCREV} ==="
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
}

# ---------------------------------------------------------------------------
# Step 2: CMake cross-compile
# ---------------------------------------------------------------------------
build_from_source() {
    info "=== CMake cross-compiling edgeai-apps-utils ${PKG_VERSION} ==="
    info "  Sysroot: ${SYSROOT}"
    info "  SOC: ${SOC}"

    [[ -d "${SYSROOT}" ]] || error "Sysroot not found: ${SYSROOT}"

    # Generate a cmake toolchain file with the correct sysroot
    local toolchain_file="${SCRIPT_DIR}/src/aarch64-cross.cmake"
    cat > "${toolchain_file}" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
# -Wno-maybe-uninitialized: GCC 13 false-positives on NEON vld1q_lane_s32
# intrinsics in edgeai_dl_pre_proc_armv8_utils.c (U_f/U_s/V_f/V_s are
# initialised by the intrinsic but GCC can't track it through inlining).
set(CMAKE_C_FLAGS   "--sysroot=${SYSROOT} -Wno-maybe-uninitialized")
set(CMAKE_CXX_FLAGS "--sysroot=${SYSROOT} -Wno-maybe-uninitialized")
set(CMAKE_EXE_LINKER_FLAGS    "--sysroot=${SYSROOT}")
set(CMAKE_SHARED_LINKER_FLAGS "--sysroot=${SYSROOT}")
set(CMAKE_FIND_ROOT_PATH "${SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    export SOC="${SOC}"

    cmake \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
        -DTARGET_FS="${SYSROOT}" \
        -DCMAKE_SKIP_RPATH=TRUE \
        -DCMAKE_OUTPUT_DIR="${BUILD_DIR}" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DINSTALL_SRC=ON \
        -GNinja \
        -B "${BUILD_DIR}/cmake-build" \
        -S "${SRC_DIR}" \
        2>&1 | tee "${SCRIPT_DIR}/build-from-source.log"

    cmake --build "${BUILD_DIR}/cmake-build" -- -j"${JOBS}" \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    info "=== Build complete ==="
}

# ---------------------------------------------------------------------------
# Step 3: Install and stage
# ---------------------------------------------------------------------------
install_from_source() {
    info "=== Staging build outputs ==="

    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}"

    cmake --install "${BUILD_DIR}/cmake-build" \
        --prefix /usr \
        --strip \
        DESTDIR="${STAGING_DIR}" \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log" || \
    DESTDIR="${STAGING_DIR}" cmake --install "${BUILD_DIR}/cmake-build" \
        --prefix /usr \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    # Also install source tree to /opt/ (INSTALL_SRC=ON handles this via cmake)
    # The cmake install rule puts the source at /opt/edgeai-apps-utils/
    # Remove the static library — not needed in runtime or dev package
    find "${STAGING_DIR}/usr/lib" -name "*.a" -delete 2>/dev/null || true

    info "Staged library files:"
    find "${STAGING_DIR}/usr/lib" ! -type d 2>/dev/null | sort || true
    info "Staged header files:"
    find "${STAGING_DIR}/usr/include" -name "*.h" 2>/dev/null | sort || true
    info "Staged /opt tree:"
    find "${STAGING_DIR}/opt" -maxdepth 2 2>/dev/null | sort || true
}

# ---------------------------------------------------------------------------
# Step 4: Package into .deb
# ---------------------------------------------------------------------------
package_debs() {
    info "=== Packaging .deb files ==="

    local current_ver
    current_ver=$(dpkg-parsechangelog -l "${SCRIPT_DIR}/debian/changelog" \
                  --show-field Version 2>/dev/null || echo "")
    info "  Package version: ${current_ver}"

    cd "${SCRIPT_DIR}"
    dpkg-buildpackage \
        --build=binary \
        --no-sign \
        --host-arch=arm64 \
        -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    info "=== Produced packages ==="
    ls -lh "${SCRIPT_DIR}/../"edgeai-apps-utils*.deb 2>/dev/null || \
        info "  .deb files are in the parent directory"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Building edgeai-apps-utils ${PKG_VERSION}"

    check_deps

    if [[ "${SKIP_FETCH}" -eq 0 ]]; then
        obtain_source
    fi

    if [[ "${SKIP_BUILD}" -eq 0 ]]; then
        build_from_source
        install_from_source
    else
        info "Skipping build (--skip-build)"
        [[ -d "${STAGING_DIR}" ]] || \
            error "No staging dir: ${STAGING_DIR} — run without --skip-build first"
    fi

    package_debs
}

main "$@"
