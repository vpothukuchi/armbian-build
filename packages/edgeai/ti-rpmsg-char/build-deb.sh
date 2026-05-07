#!/bin/bash
# build-deb.sh — Build libti-rpmsg-char0 and libti-rpmsg-char-dev .deb packages
#               from pre-built IPK artifacts.
#
# Upstream:  https://git.ti.com/git/rpmsg/ti-rpmsg-char.git
# Reference: meta-ti/recipes-connectivity/ti-rpmsg-char/ti-rpmsg-char.bb
# Version:   0.6.10
#
# For building from source instead, see build-from-source.sh.
#
# Usage: ./build-deb.sh --prebuilt-dir <path>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PKG_VERSION="0.6.10"
DEB_REVISION="1"

IPK_DIR=""

# IPK filenames (glob-matched since they may contain git hash)
RUNTIME_IPK_GLOB="libti-rpmsg-char0_*.ipk"
DEV_IPK_GLOB="libti-rpmsg-char-dev_*.ipk"

STAGING_DIR="${SCRIPT_DIR}/staging"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prebuilt-dir)
            IPK_DIR="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 --prebuilt-dir <path>"
            echo "  --prebuilt-dir   Path to directory containing pre-built IPK files (required)"
            exit 0
            ;;
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
    result=$(find "${IPK_DIR}" -maxdepth 1 -name "${pattern}" | head -1)
    [[ -n "$result" ]] || error "IPK not found: ${IPK_DIR}/${pattern}"
    echo "$result"
}

extract_ipk() {
    local ipk="$1"
    local dest="$2"
    local tmpdir
    tmpdir=$(mktemp -d)
    ar x "$ipk" --output="$tmpdir" 2>/dev/null || {
        cd "$tmpdir" && ar x "$ipk" && cd - > /dev/null
    }
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

    info "Staging complete."
    info "  Runtime libs:"
    find "${STAGING_DIR}/runtime" -name "*.so*" | sort
    info "  Dev headers:"
    find "${STAGING_DIR}/dev" -name "*.h" | head -5
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
    ls -lh "${SCRIPT_DIR}/../"libti-rpmsg-char*.deb 2>/dev/null || \
        info "  .deb files are in the parent directory"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Building libti-rpmsg-char ${PKG_VERSION} Debian packages"
    info ""

    check_deps
    stage_artifacts
    build_deb
}

main "$@"
