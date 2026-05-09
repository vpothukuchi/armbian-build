#!/bin/bash
# build-from-source.sh — Build edgeai-tiovx-modules and -dev .deb packages.
#
# Upstream:  https://git.ti.com/git/edgeai/edgeai-tiovx-modules.git
# Reference: meta-edgeai/recipes-tisdk/edgeai-components/edgeai-tiovx-modules.bb
# SRCREV:    11399cffa14dfb0bff65bf35dcbe04b701391eb8
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --sysroot     <path>   aarch64 target sysroot (default: /opt/arm64-sysroot)
#   --soc         <soc>    Target SoC (default: j784s4)
#   --jobs        <N>      Parallel build jobs (default: nproc)
#   --skip-fetch           Skip git clone/checkout
#   --skip-build           Skip cmake build
#
# Phase: E3 — requires E2 (edgeai-tiovx-kernels-dev) overlaid into sysroot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRCREV="11399cffa14dfb0bff65bf35dcbe04b701391eb8"
GIT_REMOTE="https://git.ti.com/git/edgeai/edgeai-tiovx-modules.git"

PKG_VERSION="1.0.0"
DEB_REVISION="1"

SYSROOT="/opt/arm64-sysroot"
SOC="j784s4"
JOBS="$(nproc)"
SKIP_FETCH=0
SKIP_BUILD=0

SRC_DIR="${SCRIPT_DIR}/src/edgeai-tiovx-modules"
BUILD_DIR="${SCRIPT_DIR}/src/build"
STAGING_DIR="${SCRIPT_DIR}/staging"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sysroot)    SYSROOT="$2"; shift 2 ;;
        --soc)        SOC="$2";     shift 2 ;;
        --jobs)       JOBS="$2";    shift 2 ;;
        --skip-fetch) SKIP_FETCH=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --help)
            sed -n '/^# Usage:/,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

obtain_source() {
    info "=== Obtaining edgeai-tiovx-modules at ${SRCREV} ==="
    mkdir -p "${SCRIPT_DIR}/src"
    if [[ -d "${SRC_DIR}/.git" ]]; then
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    else
        git clone "${GIT_REMOTE}" "${SRC_DIR}"
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    fi
    info "  HEAD: $(git -C "${SRC_DIR}" log -1 --oneline)"
}

build_from_source() {
    info "=== CMake cross-compiling edgeai-tiovx-modules ${PKG_VERSION} ==="
    [[ -d "${SYSROOT}" ]] || error "Sysroot not found: ${SYSROOT}"

    if [[ ! -d "${SYSROOT}/usr/include/edgeai-tiovx-kernels" ]]; then
        error "edgeai-tiovx-kernels headers not found in sysroot (E2 overlay required)"
    fi

    local toolchain_file="${SCRIPT_DIR}/src/aarch64-cross.cmake"
    cat > "${toolchain_file}" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_C_FLAGS   "--sysroot=${SYSROOT}")
set(CMAKE_CXX_FLAGS "--sysroot=${SYSROOT}")
set(CMAKE_EXE_LINKER_FLAGS    "--sysroot=${SYSROOT}")
set(CMAKE_SHARED_LINKER_FLAGS "--sysroot=${SYSROOT}")
set(CMAKE_FIND_ROOT_PATH "${SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

    rm -rf "${BUILD_DIR}"; mkdir -p "${BUILD_DIR}"
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
}

install_from_source() {
    info "=== Staging build outputs ==="
    rm -rf "${STAGING_DIR}"; mkdir -p "${STAGING_DIR}"

    DESTDIR="${STAGING_DIR}" cmake --install "${BUILD_DIR}/cmake-build" --prefix /usr \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    find "${STAGING_DIR}/usr/lib" -name "*.a" -delete 2>/dev/null || true

    info "Staged library files:"
    find "${STAGING_DIR}/usr/lib" ! -type d 2>/dev/null | sort || true
}

package_debs() {
    info "=== Packaging .deb files ==="
    cd "${SCRIPT_DIR}"
    dpkg-buildpackage --build=binary --no-sign --host-arch=arm64 -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    ls -lh "${SCRIPT_DIR}/../"edgeai-tiovx-modules*.deb 2>/dev/null || true
}

main() {
    info "Building edgeai-tiovx-modules ${PKG_VERSION}"
    [[ "${SKIP_FETCH}" -eq 0 ]] && obtain_source
    if [[ "${SKIP_BUILD}" -eq 0 ]]; then
        build_from_source
        install_from_source
    else
        [[ -d "${STAGING_DIR}" ]] || error "No staging dir; run without --skip-build first"
    fi
    package_debs
}

main "$@"
