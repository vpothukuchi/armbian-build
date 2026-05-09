#!/bin/bash
# build-from-source.sh — Build edgeai-tiovx-kernels and -dev .deb packages
#                        using CMake cross-compilation.
#
# Upstream:  https://git.ti.com/git/edgeai/edgeai-tiovx-kernels.git
# Reference: meta-edgeai/recipes-tisdk/edgeai-components/edgeai-tiovx-kernels.bb
# SRCREV:    f81cdbcd12c15894165a348ea4844060b3c2499b  (PSDK Analytics 11.02)
#
# Prerequisites (cross-compilation in Docker):
#   - aarch64-linux-gnu cross-compiler, cmake, ninja-build, debhelper
#   - Target sysroot with:
#     * ti-vision-apps headers (/usr/include/processor_sdk/...)
#     * edgeai-apps-utils headers (/usr/include/edgeai-apps-utils/)
#     * libedgeai-apps-utils.so (from E1 overlay)
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --sysroot     <path>   aarch64 target sysroot (default: /opt/arm64-sysroot)
#   --mirror      <dir>    Yocto-style bare-clone mirror directory
#   --soc         <soc>    Target SoC (default: j784s4)
#   --jobs        <N>      Parallel build jobs (default: nproc)
#   --skip-fetch           Skip git clone/checkout
#   --skip-build           Skip cmake build
#
# Phase: E2 — requires E1 (edgeai-apps-utils-dev) overlaid into sysroot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRCREV="f81cdbcd12c15894165a348ea4844060b3c2499b"
GIT_REMOTE="https://git.ti.com/git/edgeai/edgeai-tiovx-kernels.git"
MIRROR_BASENAME="git.ti.com.git.edgeai.edgeai-tiovx-kernels.git"

PKG_VERSION="1.0.0"
DEB_REVISION="1"

SYSROOT="/opt/arm64-sysroot"
MIRROR_DIR=""
SOC="j784s4"
JOBS="$(nproc)"
SKIP_FETCH=0
SKIP_BUILD=0

SRC_DIR="${SCRIPT_DIR}/src/edgeai-tiovx-kernels"
BUILD_DIR="${SCRIPT_DIR}/src/build"
STAGING_DIR="${SCRIPT_DIR}/staging"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sysroot)    SYSROOT="$2";    shift 2 ;;
        --mirror)     MIRROR_DIR="$2"; shift 2 ;;
        --soc)        SOC="$2";        shift 2 ;;
        --jobs)       JOBS="$2";       shift 2 ;;
        --skip-fetch) SKIP_FETCH=1;    shift ;;
        --skip-build) SKIP_BUILD=1;    shift ;;
        --help)
            sed -n '/^# Usage:/,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in aarch64-linux-gnu-gcc cmake ninja dpkg-buildpackage dh; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || error "Missing tools: ${missing[*]}"
}

obtain_source() {
    info "=== Obtaining edgeai-tiovx-kernels at ${SRCREV} ==="
    mkdir -p "${SCRIPT_DIR}/src"

    if [[ -d "${SRC_DIR}/.git" ]]; then
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    else
        local clone_from="${GIT_REMOTE}"
        if [[ -n "${MIRROR_DIR}" && -d "${MIRROR_DIR}/${MIRROR_BASENAME}" ]]; then
            clone_from="${MIRROR_DIR}/${MIRROR_BASENAME}"
            info "  Cloning from local mirror"
        fi
        git clone "${clone_from}" "${SRC_DIR}"
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    fi
    info "  HEAD: $(git -C "${SRC_DIR}" log -1 --oneline)"
}

build_from_source() {
    info "=== CMake cross-compiling edgeai-tiovx-kernels ${PKG_VERSION} ==="
    [[ -d "${SYSROOT}" ]] || error "Sysroot not found: ${SYSROOT}"

    # Check sysroot has edgeai-apps-utils headers (E1 overlay)
    if [[ ! -d "${SYSROOT}/usr/include/edgeai-apps-utils" ]]; then
        error "edgeai-apps-utils headers not found in sysroot.
  Overlay edgeai-apps-utils-dev_*.deb into the sysroot before building edgeai-tiovx-kernels:
    dpkg-deb -x edgeai-apps-utils-dev_*.deb ${SYSROOT}"
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
}

install_from_source() {
    info "=== Staging build outputs ==="
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}"

    DESTDIR="${STAGING_DIR}" cmake --install "${BUILD_DIR}/cmake-build" \
        --prefix /usr \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    find "${STAGING_DIR}/usr/lib" -name "*.a" -delete 2>/dev/null || true
    rm -rf "${STAGING_DIR}/usr/cmake" 2>/dev/null || true

    info "Staged library files:"
    find "${STAGING_DIR}/usr/lib" ! -type d 2>/dev/null | sort || true
}

package_debs() {
    info "=== Packaging .deb files ==="
    cd "${SCRIPT_DIR}"
    dpkg-buildpackage --build=binary --no-sign --host-arch=arm64 -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    ls -lh "${SCRIPT_DIR}/../"edgeai-tiovx-kernels*.deb 2>/dev/null || true
}

main() {
    info "Building edgeai-tiovx-kernels ${PKG_VERSION}"
    check_deps
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
