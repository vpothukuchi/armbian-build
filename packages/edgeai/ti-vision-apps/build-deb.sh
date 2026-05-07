#!/bin/bash
# build-deb.sh — Build ti-vision-apps Debian packages from pre-built IPK artifacts
#
# Source: TI PSDK pre-built IPK artifacts (libtivision-apps from ti-vision-apps.bb)
# Recipe: meta-edgeai/recipes-vision/ti-vision-apps/ti-vision-apps.bb
# Version: 11.02.03 (PSDK Analytics 11.02.00)
#
# Creates two packages:
#   libtivision-apps11.2.0 — runtime: libtivision_apps.so.11.2.0 + opt/imaging + opt/vision_apps
#   libtivision-apps-dev   — development headers (processor_sdk/*)
#
# Usage: ./build-deb.sh [--prebuilt-dir <path>] [--sysroot <path>]
#
# Both pre-built (--prebuilt-dir, default) and source-built artifacts are supported.
# For source build, see build-from-source.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PKG_VERSION="11.02.03"
DEB_REVISION="1"
SOVERSION="11.2.0"

IPK_DIR=""
SYSROOT=""

RUNTIME_IPK_GLOB="libtivision-apps${SOVERSION}_*.ipk"
DEV_IPK_GLOB="libtivision-apps-dev_*.ipk"

STAGING_DIR="${SCRIPT_DIR}/staging"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prebuilt-dir)
            IPK_DIR="$2"; shift 2 ;;
        --sysroot)
            SYSROOT="$2"; shift 2 ;;
        --help)
            echo "Usage: $0 --prebuilt-dir <path> [--sysroot <path>]"
            echo "  --prebuilt-dir   Path to directory containing pre-built IPK files (required)"
            echo "  --sysroot        Path to j784s4 target sysroot (optional)"
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -n "${IPK_DIR}" ]] || { echo "ERROR: --prebuilt-dir is required" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

find_ipk() {
    local pattern="$1"
    local result
    result=$(find "${IPK_DIR}" -maxdepth 1 -name "${pattern}" 2>/dev/null | head -1)
    [[ -n "$result" ]] || error "IPK not found: ${IPK_DIR}/${pattern}"
    echo "$result"
}

extract_ipk() {
    local ipk="$1"
    local dest="$2"
    local tmpdir
    tmpdir=$(mktemp -d)
    (cd "$tmpdir" && ar x "$ipk")
    mkdir -p "$dest"
    if [[ -f "${tmpdir}/data.tar.zst" ]]; then
        zstdcat "${tmpdir}/data.tar.zst" | tar -xC "$dest"
    elif [[ -f "${tmpdir}/data.tar.gz" ]]; then
        tar -xzC "$dest" -f "${tmpdir}/data.tar.gz"
    elif [[ -f "${tmpdir}/data.tar.xz" ]]; then
        tar -xJC "$dest" -f "${tmpdir}/data.tar.xz"
    else
        error "Unrecognized data archive in IPK: $ipk"
    fi
    rm -rf "$tmpdir"
}

check_deps() {
    local missing=()
    for cmd in ar zstdcat tar dpkg-buildpackage dh; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing tools: ${missing[*]}. Install with: sudo apt install binutils zstd debhelper devscripts"
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Stage artifacts from pre-built IPK
# ---------------------------------------------------------------------------
stage_artifacts() {
    info "=== Staging artifacts from pre-built IPK ==="
    info "  IPK directory: ${IPK_DIR}"

    local runtime_ipk dev_ipk
    runtime_ipk=$(find_ipk "${RUNTIME_IPK_GLOB}")
    dev_ipk=$(find_ipk "${DEV_IPK_GLOB}")

    info "  Runtime IPK: $(basename "${runtime_ipk}")"
    info "  Dev IPK:     $(basename "${dev_ipk}")"

    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}/runtime" "${STAGING_DIR}/dev"

    info "  Extracting runtime IPK..."
    extract_ipk "${runtime_ipk}" "${STAGING_DIR}/runtime"

    info "  Extracting dev IPK..."
    extract_ipk "${dev_ipk}" "${STAGING_DIR}/dev"

    # Create the versioned→unversioned symlink that the IPK may not include
    local libdir="${STAGING_DIR}/runtime/usr/lib"
    if [[ -f "${libdir}/libtivision_apps.so.${SOVERSION}" ]]; then
        # SONAME-based symlink: libtivision_apps.so.11.2.0 (no further alias needed for runtime)
        # Unversioned dev symlink will be in -dev package
        :
    else
        error "libtivision_apps.so.${SOVERSION} not found in IPK extract"
    fi

    info "Staging complete."
    info "  Runtime files:"
    find "${STAGING_DIR}/runtime" ! -type d | sort | head -20
    info "  Dev headers (first 5):"
    find "${STAGING_DIR}/dev" -name "*.h" | sort | head -5
}

# ---------------------------------------------------------------------------
# Step 2: Build .deb packages
# ---------------------------------------------------------------------------
build_deb() {
    info "=== Building .deb packages ==="

    ln -snf "${STAGING_DIR}" "${SCRIPT_DIR}/staging"

    local current_ver
    current_ver=$(dpkg-parsechangelog -l "${SCRIPT_DIR}/debian/changelog" \
                  --show-field Version 2>/dev/null || echo "")
    info "  Package version: ${current_ver}"

    dpkg-buildpackage \
        --build=binary \
        --no-sign \
        --host-arch=arm64 \
        -d \
        2>&1 | tee "${SCRIPT_DIR}/build.log"

    info "=== Build complete. Packages: ==="
    ls -lh "${SCRIPT_DIR}/../"*tivision*.deb 2>/dev/null || \
    ls -lh "${SCRIPT_DIR}/../"ti-vision-apps*.deb 2>/dev/null || \
        info "  .deb files are in the parent directory"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Building ti-vision-apps ${PKG_VERSION} Debian packages"
    info ""

    check_deps
    stage_artifacts
    build_deb
}

main "$@"
