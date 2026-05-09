#!/bin/bash
# build-from-source.sh — Build edgeai-gst-plugins .deb package.
#
# Upstream:  https://github.com/TexasInstruments/edgeai-gst-plugins.git
# Reference: meta-edgeai/recipes-tisdk/edgeai-components/edgeai-gst-plugins.bb
# SRCREV:    ad59325325ef96cb132600b77f753cd88740501e
#
# Uses Meson + ninja for the build.
#
# Prerequisites (cross-compilation in Docker):
#   - aarch64-linux-gnu cross-compiler, meson, ninja-build, debhelper
#   - pkg-config
#   - Target sysroot with:
#     * edgeai-tiovx-modules headers + lib (E3 overlay)
#     * edgeai-apps-utils headers + lib (E1 overlay)
#     * edgeai-dl-inferer headers + lib (E2 overlay)
#     * ti-tidl-osrt headers + libs (A1, already overlaid)
#     * libgstreamer1.0-dev:arm64, libgstreamer-plugins-base1.0-dev:arm64
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --sysroot     <path>   aarch64 target sysroot (default: /opt/arm64-sysroot)
#   --soc         <soc>    Target SoC (default: j784s4)
#   --jobs        <N>      Parallel build jobs (default: nproc)
#   --skip-fetch           Skip git clone/checkout
#   --skip-build           Skip meson build
#
# Phase: E4 — requires E1+E2+E3 overlaid into sysroot

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRCREV="ad59325325ef96cb132600b77f753cd88740501e"
GIT_REMOTE="https://github.com/TexasInstruments/edgeai-gst-plugins.git"

PKG_VERSION="1.0.0"
DEB_REVISION="1"

SYSROOT="/opt/arm64-sysroot"
SOC="j784s4"
JOBS="$(nproc)"
SKIP_FETCH=0
SKIP_BUILD=0

SRC_DIR="${SCRIPT_DIR}/src/edgeai-gst-plugins"
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
    info "=== Obtaining edgeai-gst-plugins at ${SRCREV} ==="
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
    info "=== Meson cross-compiling edgeai-gst-plugins ${PKG_VERSION} ==="
    [[ -d "${SYSROOT}" ]] || error "Sysroot not found: ${SYSROOT}"

    if [[ ! -d "${SYSROOT}/usr/include/edgeai-tiovx-modules" ]]; then
        error "edgeai-tiovx-modules headers not found in sysroot (E3 overlay required)"
    fi

    # Generate Meson cross-compilation config
    local cross_file="${SCRIPT_DIR}/src/aarch64-meson-cross.ini"
    cat > "${cross_file}" <<EOF
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[properties]
c_args = ['--sysroot=${SYSROOT}']
c_link_args = ['--sysroot=${SYSROOT}']
cpp_args = ['--sysroot=${SYSROOT}']
cpp_link_args = ['--sysroot=${SYSROOT}']
sys_root = '${SYSROOT}'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

    rm -rf "${BUILD_DIR}"; mkdir -p "${BUILD_DIR}"
    export SOC="${SOC}"
    export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
    export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT}/usr/share/pkgconfig"
    export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"

    meson setup \
        --cross-file "${cross_file}" \
        --prefix /usr \
        -Dpkg_config_path="${SRC_DIR}/pkgconfig" \
        "${BUILD_DIR}" \
        "${SRC_DIR}" \
        2>&1 | tee "${SCRIPT_DIR}/build-from-source.log"

    ninja -C "${BUILD_DIR}" -j"${JOBS}" \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
}

install_from_source() {
    info "=== Staging build outputs ==="
    rm -rf "${STAGING_DIR}"; mkdir -p "${STAGING_DIR}"

    DESTDIR="${STAGING_DIR}" ninja -C "${BUILD_DIR}" install \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    # Install source tree to /opt/edgeai-gst-plugins/
    mkdir -p "${STAGING_DIR}/opt/edgeai-gst-plugins"
    rsync -a --exclude=".git" --exclude="build" \
        "${SRC_DIR}/" "${STAGING_DIR}/opt/edgeai-gst-plugins/"

    info "Staged GStreamer plugin files:"
    find "${STAGING_DIR}/usr/lib/gstreamer-1.0" ! -type d 2>/dev/null | sort || true
}

package_debs() {
    info "=== Packaging .deb files ==="
    cd "${SCRIPT_DIR}"
    dpkg-buildpackage --build=binary --no-sign --host-arch=arm64 -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    ls -lh "${SCRIPT_DIR}/../"edgeai-gst-plugins*.deb 2>/dev/null || true
}

main() {
    info "Building edgeai-gst-plugins ${PKG_VERSION}"
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
