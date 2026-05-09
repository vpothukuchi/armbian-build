#!/bin/bash
# build-from-source.sh — Build edgeai-dl-inferer and -dev .deb packages
#                        using CMake cross-compilation.
#
# Upstream:  https://git.ti.com/git/edgeai/edgeai-dl-inferer.git
# Reference: meta-edgeai/recipes-tisdk/edgeai-components/edgeai-dl-inferer.bb
# SRCREV:    d06b07d3058b1859df0e32c3ca545b70b8cf3ec9  (PSDK Analytics 11.02)
#
# Prerequisites (cross-compilation in Docker):
#   - aarch64-linux-gnu cross-compiler, cmake, ninja-build, debhelper
#   - Target sysroot with:
#     * edgeai-apps-utils headers + lib (E1 overlay)
#     * ti-tidl-osrt headers + libs (A1, already overlaid for A3)
#     * libyaml-cpp-dev:arm64, libopencv-dev:arm64 (in sysroot)
#     * ti-vision-apps headers (A2, already overlaid)
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --sysroot     <path>   aarch64 target sysroot (default: /opt/arm64-sysroot)
#   --soc         <soc>    Target SoC (default: j784s4)
#   --jobs        <N>      Parallel build jobs (default: nproc)
#   --skip-fetch           Skip git clone/checkout
#   --skip-build           Skip cmake build
#
# Note: TVM runtime and test applications are disabled at build time.
#   TVM is not used by the robotics SDK (-DUSE_TVM_RT=OFF).
#   Tests require OpenCV which is not in the cross-sysroot.
#
# Phase: E2 — requires E1 (edgeai-apps-utils-dev) overlaid into sysroot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRCREV="d06b07d3058b1859df0e32c3ca545b70b8cf3ec9"
GIT_REMOTE="https://git.ti.com/git/edgeai/edgeai-dl-inferer.git"

PKG_VERSION="1.0.0"
DEB_REVISION="1"

SYSROOT="/opt/arm64-sysroot"
SOC="j784s4"
JOBS="$(nproc)"
SKIP_FETCH=0
SKIP_BUILD=0

SRC_DIR="${SCRIPT_DIR}/src/edgeai-dl-inferer"
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

check_deps() {
    local missing=()
    for cmd in aarch64-linux-gnu-gcc cmake ninja dpkg-buildpackage dh; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || error "Missing tools: ${missing[*]}"
}

obtain_source() {
    info "=== Obtaining edgeai-dl-inferer at ${SRCREV} ==="
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
    info "=== CMake cross-compiling edgeai-dl-inferer ${PKG_VERSION} ==="
    [[ -d "${SYSROOT}" ]] || error "Sysroot not found: ${SYSROOT}"

    if [[ ! -d "${SYSROOT}/usr/include/edgeai-apps-utils" ]]; then
        error "edgeai-apps-utils headers not found in sysroot (E1 overlay required)"
    fi

    # Remove test_cpp and examples from build: they are not installed by the
    # packaging, tests require OpenCV (not in cross-sysroot), and examples
    # require the full TFLite static lib search tree (not worth the complexity).
    sed -i '/^add_subdirectory(tests\/test_cpp)/d' "${SRC_DIR}/CMakeLists.txt"
    sed -i '/^add_subdirectory(examples)/d'        "${SRC_DIR}/CMakeLists.txt"

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
    # pkg-config needs to search the arm64 sysroot for yaml-cpp, etc.
    export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
    export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT}/usr/share/pkgconfig"
    export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"

    cmake \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
        -DTARGET_FS="${SYSROOT}" \
        -DCMAKE_SKIP_RPATH=TRUE \
        -DCMAKE_OUTPUT_DIR="${BUILD_DIR}" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DINSTALL_SRC=ON \
        -DUSE_TVM_RT=OFF \
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

    # Keep .a static libs — they are the deliverables (this library is static-only).
    # Remove cmake config files (not needed for packaging).
    rm -rf "${STAGING_DIR}/usr/cmake" 2>/dev/null || true

    info "Staged library files:"
    find "${STAGING_DIR}/usr/lib" ! -type d 2>/dev/null | sort || true
    info "Staged include directories:"
    find "${STAGING_DIR}/usr/include" -maxdepth 1 ! -type d 2>/dev/null | sort || true
    find "${STAGING_DIR}/usr/include" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true
    info "Staged Python modules:"
    find "${STAGING_DIR}" -name "*.py" 2>/dev/null | sort || true
}

package_debs() {
    info "=== Packaging .deb files ==="
    cd "${SCRIPT_DIR}"
    dpkg-buildpackage --build=binary --no-sign --host-arch=arm64 -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    ls -lh "${SCRIPT_DIR}/../"edgeai-dl-inferer*.deb 2>/dev/null || true
}

main() {
    info "Building edgeai-dl-inferer ${PKG_VERSION}"
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
