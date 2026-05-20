#!/bin/bash
# build-deb.sh — Package mesa-pvr Vulkan drivers as a Debian package.
#
# Extracts libpvr_mesa_wsi.so and libvulkan_lvp.so from the Yocto-built
# mesa-vulkan-drivers IPK and packages them as ti-img-pvr-mesa-wsi.deb.
#
# Source IPK:  mesa-vulkan-drivers_24.0.1-r0.0_j784s4_evm.ipk
# Recipe:      meta-ti/meta-ti-bsp/recipes-graphics/mesa/mesa-pvr_24.0.1.bb
# SRCREV:      68af6a102c2298569e77d1aa8bccc1ff61438b3e
#
# Usage:
#   ./build-deb.sh --prebuilt-dir <path>
#
#   --prebuilt-dir <path>   Directory containing mesa-vulkan-drivers_*.ipk
#                           (default: auto-detect from YOCTO_DEPLOY_DIR env var)
#
# Example:
#   IPK_DIR=/mnt/DATA/YOCTO/yocto-build/build/arago-tmp-default-glibc/deploy/ipk/j784s4_evm
#   ./build-deb.sh --prebuilt-dir "$IPK_DIR"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PKG_VERSION="24.0.1"
DEB_REVISION="1"
IPK_GLOB="mesa-vulkan-drivers_${PKG_VERSION}-*.ipk"

IPK_DIR="${YOCTO_DEPLOY_DIR:-}"
PREBUILT_DIR=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prebuilt-dir) PREBUILT_DIR="$2"; shift 2 ;;
        --help)
            echo "Usage: $0 --prebuilt-dir <path>"
            echo "  --prebuilt-dir   Directory containing mesa-vulkan-drivers_*.ipk"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -n "${PREBUILT_DIR}" ]] && IPK_DIR="${PREBUILT_DIR}"
[[ -n "${IPK_DIR}" ]] || {
    echo "ERROR: --prebuilt-dir is required (or set YOCTO_DEPLOY_DIR)" >&2
    echo "Usage: $0 --prebuilt-dir <dir-containing-mesa-vulkan-drivers.ipk>" >&2
    exit 1
}
[[ -d "${IPK_DIR}" ]] || { echo "ERROR: directory not found: ${IPK_DIR}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "==> $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in ar zstd tar dpkg-deb; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || error "Missing tools: ${missing[*]}"
}

extract_ipk() {
    local ipk="$1"
    local dest="$2"
    local tmpdir
    tmpdir=$(mktemp -d)
    (cd "${tmpdir}" && ar x "${ipk}")
    mkdir -p "${dest}"
    if [[ -f "${tmpdir}/data.tar.zst" ]]; then
        zstd -d "${tmpdir}/data.tar.zst" --stdout | tar -xC "${dest}"
    elif [[ -f "${tmpdir}/data.tar.gz" ]]; then
        tar -xzC "${dest}" -f "${tmpdir}/data.tar.gz"
    elif [[ -f "${tmpdir}/data.tar.xz" ]]; then
        tar -xJC "${dest}" -f "${tmpdir}/data.tar.xz"
    else
        error "Unrecognized data archive in IPK: ${ipk}"
    fi
    rm -rf "${tmpdir}"
}

# ---------------------------------------------------------------------------
# Find IPK
# ---------------------------------------------------------------------------
check_deps

IPK_FILE=$(find "${IPK_DIR}" -maxdepth 1 -name "${IPK_GLOB}" 2>/dev/null | head -1)
[[ -n "${IPK_FILE}" ]] || error "IPK not found: ${IPK_DIR}/${IPK_GLOB}"
info "Using IPK: $(basename "${IPK_FILE}")"

# ---------------------------------------------------------------------------
# Extract IPK into staging area
# ---------------------------------------------------------------------------
STAGING="${SCRIPT_DIR}/staging"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"

info "Extracting $(basename "${IPK_FILE}")"
extract_ipk "${IPK_FILE}" "${STAGING}"

# Verify key files are present
[[ -f "${STAGING}/usr/lib/libpvr_mesa_wsi.so" ]] || \
    error "libpvr_mesa_wsi.so not found in IPK"
[[ -f "${STAGING}/usr/lib/libvulkan_lvp.so" ]] || \
    error "libvulkan_lvp.so not found in IPK"

info "Staged files:"
find "${STAGING}" -not -type d | sort

# ---------------------------------------------------------------------------
# Build .deb
# ---------------------------------------------------------------------------
PKGDIR="${SCRIPT_DIR}/ti-img-pvr-mesa-wsi_${PKG_VERSION}-${DEB_REVISION}_arm64"
rm -rf "${PKGDIR}"
mkdir -p "${PKGDIR}/DEBIAN"
cp -a "${STAGING}/." "${PKGDIR}/"

cat > "${PKGDIR}/DEBIAN/control" <<EOF
Package: ti-img-pvr-mesa-wsi
Version: ${PKG_VERSION}-${DEB_REVISION}
Architecture: arm64
Maintainer: Texas Instruments <vijayp@ti.com>
Depends: libwayland-client0, libdrm2, libexpat1, libzstd1, libstdc++6
Description: Mesa PowerVR Vulkan WSI and LVP drivers for TI SoCs
 libpvr_mesa_wsi.so — Mesa Window System Integration (WSI) library
 for the PowerVR Rogue GPU on TI SoCs (j784s4/j721s2).
 Required by libVK_IMG.so to create Vulkan surfaces on Wayland/DRM.
 .
 libvulkan_lvp.so — Mesa lavapipe software Vulkan renderer.
 .
 Built from mesa-pvr ${PKG_VERSION}
 (gitlab.freedesktop.org/StaticRocket/mesa.git @ powervr/${PKG_VERSION}).
EOF

cat > "${PKGDIR}/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
ldconfig
POSTINST
chmod 0755 "${PKGDIR}/DEBIAN/postinst"

find "${PKGDIR}" -not -path "${PKGDIR}/DEBIAN*" -type f -name "*.so*" \
    -exec chmod 0755 {} \;

dpkg-deb --build --root-owner-group "${PKGDIR}" \
    "${SCRIPT_DIR}/ti-img-pvr-mesa-wsi_${PKG_VERSION}-${DEB_REVISION}_arm64.deb"
rm -rf "${PKGDIR}" "${STAGING}"

info "Built: ${SCRIPT_DIR}/ti-img-pvr-mesa-wsi_${PKG_VERSION}-${DEB_REVISION}_arm64.deb"
