#!/bin/bash
# build-from-source.sh — Cross-compile libpvr_mesa_wsi.so from TI's Mesa fork
# and package it as a .deb.
#
# Builds the PowerVR Mesa WSI (Window System Integration) library needed by
# libVK_IMG.so to perform Vulkan surface creation on Wayland/DRM platforms.
#
# Source:   https://gitlab.freedesktop.org/StaticRocket/mesa.git
# Branch:   powervr/24.0.1
# SRCREV:   68af6a102c2298569e77d1aa8bccc1ff61438b3e
# Reference: meta-ti/meta-ti-bsp/recipes-graphics/mesa/mesa-pvr_24.0.1.bb
#
# Prerequisites (on build host or in ti-edgeai-build:noble Docker container):
#   gcc-aarch64-linux-gnu, g++-aarch64-linux-gnu, meson, ninja-build,
#   python3-mako, python3-pyyaml, python3-packaging, pkg-config, bison, flex,
#   libdrm-dev:arm64, libexpat-dev:arm64, libwayland-dev:arm64,
#   libzstd-dev:arm64, libz-dev:arm64, libwayland-egl-backend-dev:arm64,
#   vulkan-headers (>=1.4), glslang-dev, dpkg-dev
#
# Usage:
#   ./build-from-source.sh [OPTIONS]
#
#   --jobs  <N>      Parallel make jobs (default: nproc)
#   --skip-fetch     Skip git clone/fetch; use existing src/ directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GIT_REMOTE="https://gitlab.freedesktop.org/StaticRocket/mesa.git"
BRANCH="powervr/24.0.1"
SRCREV="68af6a102c2298569e77d1aa8bccc1ff61438b3e"
PKG_VERSION="24.0.1"
DEB_REVISION="1"

CROSS_COMPILE="aarch64-linux-gnu-"
JOBS="$(nproc)"
SKIP_FETCH=0

SOURCE_DIR="${SCRIPT_DIR}/src/mesa"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs)        JOBS="$2"; shift ;;
        --skip-fetch)  SKIP_FETCH=1 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Fetch source
# ---------------------------------------------------------------------------
if [[ ${SKIP_FETCH} -eq 0 ]]; then
    echo "==> Cloning mesa-pvr @ ${SRCREV}"
    rm -rf "${SOURCE_DIR}"
    mkdir -p "$(dirname "${SOURCE_DIR}")"
    git clone --branch "${BRANCH}" --depth 50 "${GIT_REMOTE}" "${SOURCE_DIR}"
    git -C "${SOURCE_DIR}" checkout "${SRCREV}"
else
    echo "==> Skipping fetch, using ${SOURCE_DIR}"
    [[ -d "${SOURCE_DIR}" ]] || { echo "ERROR: ${SOURCE_DIR} does not exist"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Meson cross-compilation file
#
# If running inside the ti-edgeai-build:noble Docker container, use the
# pre-built arm64 sysroot at /opt/arm64-sysroot/.  On other hosts, rely on
# system-wide aarch64-linux-gnu-pkg-config and multiarch packages.
# ---------------------------------------------------------------------------
SYSROOT="${ARM64_SYSROOT:-}"
if [[ -z "${SYSROOT}" && -d "/opt/arm64-sysroot" ]]; then
    SYSROOT="/opt/arm64-sysroot"
fi

CROSS_FILE="${SCRIPT_DIR}/aarch64-cross.ini"
cat > "${CROSS_FILE}" <<EOF
[binaries]
c     = 'aarch64-linux-gnu-gcc'
cpp   = 'aarch64-linux-gnu-g++'
ar    = 'aarch64-linux-gnu-ar'
nm    = 'aarch64-linux-gnu-nm'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args   = ['--sysroot=${SYSROOT}']
cpp_args = ['--sysroot=${SYSROOT}']
c_link_args   = ['--sysroot=${SYSROOT}']
cpp_link_args = ['--sysroot=${SYSROOT}']

[properties]
sys_root = '${SYSROOT}'
pkg_config_libdir = '${SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT}/usr/share/pkgconfig'

[host_machine]
system     = 'linux'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'
EOF

# ---------------------------------------------------------------------------
# Meson setup + build (pvr gallium + pvr vulkan = provides libpvr_mesa_wsi.so)
# ---------------------------------------------------------------------------
BUILD_DIR="${SCRIPT_DIR}/build"
rm -rf "${BUILD_DIR}"

echo "==> Configuring mesa-pvr with meson"
meson setup "${BUILD_DIR}" "${SOURCE_DIR}" \
    --cross-file "${CROSS_FILE}" \
    --buildtype=release \
    -Dgallium-drivers=pvr \
    -Dvulkan-drivers=pvr \
    -Dplatforms=wayland \
    -Degl=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dglx=disabled \
    -Dllvm=disabled \
    -Dshared-llvm=disabled \
    -Dgbm=disabled \
    -Ddri3=disabled \
    -Dosmesa=false \
    -Dgallium-nine=false \
    -Dgallium-opencl=disabled \
    -Dgallium-rusticl=false \
    -Dgallium-va=disabled \
    -Dgallium-vdpau=disabled \
    -Dgallium-xa=disabled \
    -Dintel-clc=disabled \
    -Dmicrosoft-clc=disabled \
    -Dvideo-codecs=[] \
    -Dprefix=/usr

echo "==> Building libpvr_mesa_wsi.so"
ninja -C "${BUILD_DIR}" -j"${JOBS}" src/pvr/wsi/libpvr_mesa_wsi.so

WSI_LIB="${BUILD_DIR}/src/pvr/wsi/libpvr_mesa_wsi.so"
[[ -f "${WSI_LIB}" ]] || {
    echo "ERROR: libpvr_mesa_wsi.so not found after build" >&2
    exit 1
}

echo "==> Built: $(ls -lh "${WSI_LIB}")"

# ---------------------------------------------------------------------------
# Package as .deb
# ---------------------------------------------------------------------------
PKGDIR="${SCRIPT_DIR}/ti-img-pvr-mesa-wsi_${PKG_VERSION}-${DEB_REVISION}_arm64"
rm -rf "${PKGDIR}"
mkdir -p "${PKGDIR}/DEBIAN"
mkdir -p "${PKGDIR}/usr/lib"

install -m 0755 "${WSI_LIB}" "${PKGDIR}/usr/lib/libpvr_mesa_wsi.so"

cat > "${PKGDIR}/DEBIAN/control" <<EOF
Package: ti-img-pvr-mesa-wsi
Version: ${PKG_VERSION}-${DEB_REVISION}
Architecture: arm64
Maintainer: Texas Instruments <vijayp@ti.com>
Depends: libwayland-client0, libdrm2, libexpat1, libzstd1, libstdc++6
Description: Mesa PowerVR WSI library for TI SoCs
 libpvr_mesa_wsi.so — Mesa Window System Integration (WSI) library for
 the PowerVR Rogue GPU on TI SoCs (j784s4/j721s2).
 Required by libVK_IMG.so to create Vulkan surfaces on Wayland/DRM.
 Built from mesa-pvr ${PKG_VERSION} (gitlab.freedesktop.org/StaticRocket/mesa.git
 @ ${SRCREV}).
EOF

cat > "${PKGDIR}/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
ldconfig
POSTINST
chmod 0755 "${PKGDIR}/DEBIAN/postinst"

dpkg-deb --build --root-owner-group "${PKGDIR}" \
    "${SCRIPT_DIR}/ti-img-pvr-mesa-wsi_${PKG_VERSION}-${DEB_REVISION}_arm64.deb"
rm -rf "${PKGDIR}"

echo "==> Built: ${SCRIPT_DIR}/ti-img-pvr-mesa-wsi_${PKG_VERSION}-${DEB_REVISION}_arm64.deb"
