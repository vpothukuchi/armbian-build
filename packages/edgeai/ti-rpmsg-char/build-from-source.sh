#!/bin/bash
# build-from-source.sh — Build libti-rpmsg-char0 and libti-rpmsg-char-dev .deb packages
#                        from source using autotools cross-compilation.
#
# Upstream:  https://git.ti.com/git/rpmsg/ti-rpmsg-char.git
# Reference: meta-ti/recipes-connectivity/ti-rpmsg-char/ti-rpmsg-char.bb
# SRCREV:    057b1a2  (ships as version 0.6.10, matches meta-ti Yocto recipe)
#
# NOTE: Do NOT advance past 057b1a2. Commit dd47834 ("lib: Do not update local
# endpoint") removes _rpmsg_char_get_local_endpt(), causing rcdev.endpt to be
# set to RPMSG_ADDR_ANY (0xFFFFFFFF) instead of the kernel-assigned dynamic
# port. This breaks TI Vision Apps / TIOVX: host_port_id in all obj_descs gets
# 0xFFFFFFFF, so C7x DSP sends ACKs to port 0xFFFF on Linux (no endpoint there)
# and tivxEventWait() hangs forever. The Yocto meta-ti recipe uses 057b1a2
# which still has _rpmsg_char_get_local_endpt() reading the real port from
# /sys/class/rpmsg/rpmsg<N>/src.
#
# Prerequisites:
#   - aarch64-linux-gnu cross-compiler (gcc-aarch64-linux-gnu on Ubuntu)
#   - debhelper, devscripts
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --cross-compile  <prefix>  Cross-compiler prefix (default: aarch64-linux-gnu-)
#   --sysroot        <path>    Target sysroot for libc and startup objects
#                              Required when libc6-dev-arm64-cross is not fully installed
#   --srcrev         <rev>     Git revision to build (default: 057b1a2)
#   --git-mirror     <path>    Local bare-clone mirror to clone from (optional)
#   --jobs           <N>       Parallel make jobs (default: nproc)
#   --skip-build               Skip compile, use pre-existing build outputs
#
# Example (Ubuntu cross-compiler, PSDK target sysroot):
#   sudo apt install gcc-aarch64-linux-gnu debhelper devscripts automake autoconf libtool
#   ./build-from-source.sh \
#     --sysroot /path/to/psdk/sysroots/j784s4-evm
#
# Example (without sysroot, requires properly installed libc6-dev-arm64-cross):
#   sudo apt install gcc-aarch64-linux-gnu libc6-dev-arm64-cross debhelper devscripts \
#                    automake autoconf libtool
#   ./build-from-source.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CROSS_COMPILE="aarch64-linux-gnu-"
SYSROOT=""
SRCREV="057b1a2"
GIT_MIRROR=""
GIT_REMOTE="https://git.ti.com/git/rpmsg/ti-rpmsg-char.git"
JOBS="$(nproc)"
SKIP_BUILD=0

PKG_VERSION="0.6.10"
DEB_REVISION="1"
SO_VERSION="0.6.10"

SOURCE_DIR="${SCRIPT_DIR}/src/ti-rpmsg-char"
STAGING_DIR="${SCRIPT_DIR}/staging-src"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cross-compile) CROSS_COMPILE="$2"; shift 2 ;;
        --sysroot)       SYSROOT="$2";       shift 2 ;;
        --srcrev)        SRCREV="$2";        shift 2 ;;
        --git-mirror)    GIT_MIRROR="$2";    shift 2 ;;
        --jobs)          JOBS="$2";          shift 2 ;;
        --skip-build)    SKIP_BUILD=1;       shift ;;
        --help)
            sed -n '/^# Usage:/,/^$/p' "$0"
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
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
    local cross_gcc="${CROSS_COMPILE}gcc"
    for cmd in autoconf automake libtool dpkg-buildpackage dh; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    command -v "$cross_gcc" &>/dev/null || missing+=("$cross_gcc")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing tools: ${missing[*]}.  Install with:
  sudo apt install gcc-aarch64-linux-gnu automake autoconf libtool debhelper devscripts"
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Obtain source at the pinned SRCREV
# ---------------------------------------------------------------------------
obtain_source() {
    info "=== Obtaining ti-rpmsg-char source at ${SRCREV} ==="
    mkdir -p "${SCRIPT_DIR}/src"

    if [[ -d "${SOURCE_DIR}/.git" ]]; then
        info "  Source directory already exists: ${SOURCE_DIR}"
        info "  Checking out ${SRCREV}..."
        git -C "${SOURCE_DIR}" checkout "${SRCREV}" --
    else
        if [[ -d "${GIT_MIRROR}" ]]; then
            info "  Cloning from local mirror: ${GIT_MIRROR}"
            git clone "${GIT_MIRROR}" "${SOURCE_DIR}"
        else
            info "  Cloning from upstream: ${GIT_REMOTE}"
            git clone "${GIT_REMOTE}" "${SOURCE_DIR}"
        fi
        git -C "${SOURCE_DIR}" checkout "${SRCREV}" --
    fi

    info "  Source ready at: ${SOURCE_DIR}"
    info "  HEAD: $(git -C "${SOURCE_DIR}" log -1 --oneline)"
}

# ---------------------------------------------------------------------------
# Step 2: Cross-compile with autotools
# ---------------------------------------------------------------------------
build_from_source() {
    info "=== Cross-compiling ti-rpmsg-char ${PKG_VERSION} ==="
    info "  Cross-compiler prefix: ${CROSS_COMPILE}"

    local host_triple
    # Derive host triple: strip trailing dash from prefix
    host_triple="${CROSS_COMPILE%-}"

    local cc_flags="-O2"
    local ld_flags=""
    if [[ -n "${SYSROOT}" ]]; then
        # --sysroot teaches the compiler where target headers/libs are.
        # -B <sysroot>/usr/lib is required so the linker finds crt startup
        # objects (Scrt1.o, crti.o) even when libc6-dev-arm64-cross is
        # not fully installed on the host.
        cc_flags="${cc_flags} --sysroot=${SYSROOT} -B${SYSROOT}/usr/lib"
        ld_flags="-L${SYSROOT}/usr/lib"
        info "  Sysroot: ${SYSROOT}"
    fi

    cd "${SOURCE_DIR}"

    info "  Running autoreconf..."
    autoreconf --install --force 2>&1 | tee "${SCRIPT_DIR}/build-from-source.log"

    info "  Running configure --host=${host_triple}..."
    ./configure \
        --host="${host_triple}" \
        --prefix=/usr \
        --libdir=/usr/lib \
        CC="${CROSS_COMPILE}gcc" \
        AR="${CROSS_COMPILE}ar" \
        RANLIB="${CROSS_COMPILE}ranlib" \
        STRIP="${CROSS_COMPILE}strip" \
        CFLAGS="${cc_flags}" \
        LDFLAGS="${ld_flags}" \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    info "  Building (make -j${JOBS})..."
    make -j"${JOBS}" 2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    cd "${SCRIPT_DIR}"
    info "=== Build complete ==="
}

# ---------------------------------------------------------------------------
# Step 3: Install and stage outputs
# ---------------------------------------------------------------------------
install_from_source() {
    info "=== Staging build outputs ==="

    local install_root="${STAGING_DIR}/install"
    rm -rf "${install_root}"
    mkdir -p "${install_root}"

    cd "${SOURCE_DIR}"
    make install DESTDIR="${install_root}" \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    cd "${SCRIPT_DIR}"

    # Lay out staging tree expected by debian/rules:
    #   staging/runtime/usr/lib/  — versioned .so + soname symlink
    #   staging/dev/usr/include/  — public headers
    rm -rf "${SCRIPT_DIR}/staging"
    mkdir -p "${SCRIPT_DIR}/staging/runtime/usr/lib"
    mkdir -p "${SCRIPT_DIR}/staging/dev/usr/include"

    # Versioned library and soname symlink (skip static lib and unversioned symlink;
    # unversioned symlink is created by debian/rules for the -dev package)
    find "${install_root}/usr/lib" -name "libti_rpmsg_char.so.*" \
        | while read -r f; do
            cp -a "$f" "${SCRIPT_DIR}/staging/runtime/usr/lib/"
        done
    # Remove the unversioned symlink if it ended up here; -dev rules recreate it
    rm -f "${SCRIPT_DIR}/staging/runtime/usr/lib/libti_rpmsg_char.so"

    # Static library not needed in either package
    rm -f "${SCRIPT_DIR}/staging/runtime/usr/lib/libti_rpmsg_char.a"

    # Headers
    if [[ -d "${install_root}/usr/include" ]]; then
        cp -a "${install_root}/usr/include/." \
              "${SCRIPT_DIR}/staging/dev/usr/include/"
    fi

    info "Staged outputs:"
    info "  Runtime libs:"
    find "${SCRIPT_DIR}/staging/runtime" ! -type d | sort
    info "  Dev headers:"
    find "${SCRIPT_DIR}/staging/dev" -name "*.h" | sort
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

    dpkg-buildpackage \
        --build=binary \
        --no-sign \
        --host-arch=arm64 \
        -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    info "=== Source-built packages ==="
    ls -lh "${SCRIPT_DIR}/../"libti-rpmsg-char*.deb 2>/dev/null || \
        info "  .deb files are in the parent directory"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Building libti-rpmsg-char ${PKG_VERSION} from source"
    info ""

    check_deps

    if [[ "${SKIP_BUILD}" -eq 0 ]]; then
        obtain_source
        build_from_source
    else
        info "Skipping source fetch and compilation (--skip-build)"
        [[ -d "${SOURCE_DIR}" ]] || \
            error "Source directory not found: ${SOURCE_DIR}  (run without --skip-build first)"
    fi

    if [[ -d "${SCRIPT_DIR}/staging/runtime" ]] && [[ "${SKIP_BUILD}" -eq 1 ]]; then
        info "Re-using existing staged outputs"
        info "  Delete ${SCRIPT_DIR}/staging to force re-stage"
    else
        install_from_source
    fi

    package_debs
}

main "$@"
