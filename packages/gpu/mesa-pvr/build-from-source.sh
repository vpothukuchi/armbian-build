#!/bin/bash
# build-from-source.sh — Cross-compile mesa-pvr and package as a .deb.
#
# Builds the following artefacts from TI's Mesa fork using the GLVND vendor
# approach so that Ubuntu's GLVND dispatch layer (libglvnd0) is kept intact:
#
#   pvr_dri.so         — Gallium DRI driver for the PowerVR Rogue GPU.
#                        Installed to /usr/lib/aarch64-linux-gnu/dri/ so that
#                        the mesa EGL stack automatically uses PVR hardware
#                        for OpenGL ES contexts on Wayland and GBM/DRM.
#
#   tidss_dri.so       — Symlink → pvr_dri.so.  mesa-pvr libgbm opens
#                        "{drm_driver}_dri.so"; the TIDSS DRM driver is named
#                        "tidss", so tidss_dri.so → pvr_dri.so is required.
#
#   libgbm.so.1.0.0    — Mesa 24.0.1 GBM (replaces Ubuntu libgbm1).
#                        This version has a builtin DRI backend (gbm_dri.c)
#                        that calls loader_open_driver() to dlopen pvr_dri.so.
#                        Ubuntu Mesa 25.2 removed this per-driver path.
#
#   libEGL_mesa.so.0   — Mesa 24.0.1 GLVND EGL vendor (replaces Ubuntu
#                        libegl-mesa0).  Built with -Dglvnd=true so it slots
#                        into Ubuntu's GLVND dispatch (libEGL.so.1 from
#                        libglvnd0) without replacing the dispatcher itself.
#                        Both libEGL_mesa.so.0 and libgbm.so.1 come from the
#                        same 24.0.1 build, so their internal struct layouts
#                        are compatible (fixes the SIGBUS from mixing 24.0.1
#                        libgbm with Ubuntu Mesa 25.2 libEGL_mesa.so.0).
#
#   libglapi.so.0.0.0  — Mesa 24.0.1 GL API dispatch (replaces Ubuntu
#                        libglapi-mesa).  libEGL_mesa.so links against the
#                        24.0.1 version; replacing ensures ABI compatibility.
#
#   50_mesa.json       — GLVND EGL vendor JSON descriptor.
#                        Installed to /usr/share/glvnd/egl_vendor.d/ so that
#                        the GLVND dispatcher loads libEGL_mesa.so.0 at
#                        runtime.
#
#   libpvr_mesa_wsi.so — Mesa WSI layer for Vulkan surface creation.
#                        Required by libVK_IMG.so on Wayland/DRM.
#
# Source:    https://gitlab.freedesktop.org/StaticRocket/mesa.git
# Branch:    powervr/24.0.1
# SRCREV:    68af6a102c2298569e77d1aa8bccc1ff61438b3e
# Reference: meta-ti/meta-ti-bsp/recipes-graphics/mesa/mesa-pvr_24.0.1.bb
#
# Prerequisites (on build host or in ti-edgeai-build:noble Docker container):
#   gcc-aarch64-linux-gnu, g++-aarch64-linux-gnu, meson, ninja-build,
#   python3-mako, python3-pyyaml, python3-packaging, pkg-config, bison, flex,
#   libdrm-dev:arm64, libexpat-dev:arm64, libwayland-dev:arm64,
#   libwayland-egl-backend-dev:arm64, libzstd-dev:arm64, libz-dev:arm64,
#   libgbm-dev:arm64, libglvnd-core-dev:arm64, vulkan-headers (>=1.4),
#   glslang-dev, dpkg-dev
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
DEB_REVISION="4"

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
# Meson setup + build
#
# -Dglvnd=true: produce libEGL_mesa.so.0 (GLVND vendor) and 50_mesa.json
#   instead of a monolithic libEGL.so.1.  This lets Ubuntu's libglvnd0
#   (GLVND dispatcher) remain installed while we replace only the mesa
#   vendor implementation.
#
# -Dlibdir=/usr/lib/aarch64-linux-gnu: use Ubuntu's multiarch lib path so
#   that DRI driver search path is hardcoded as /usr/lib/aarch64-linux-gnu/dri
#   instead of /usr/lib/dri (which is wrong on a multiarch Ubuntu system).
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
    -Degl=enabled \
    -Dgles1=disabled \
    -Dgles2=enabled \
    -Dglx=disabled \
    -Dgbm=enabled \
    -Ddri3=enabled \
    -Dglvnd=true \
    -Dllvm=disabled \
    -Dshared-llvm=disabled \
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
    -Dprefix=/usr \
    -Dlibdir=/usr/lib/aarch64-linux-gnu

echo "==> Building mesa-pvr GLVND stack"
ninja -C "${BUILD_DIR}" -j"${JOBS}"

DRI_SO=$(find "${BUILD_DIR}" -name "pvr_dri.so" | head -1)
WSI_LIB="${BUILD_DIR}/src/pvr/wsi/libpvr_mesa_wsi.so"
GBM_LIB=$(find "${BUILD_DIR}/src/gbm" -name "libgbm.so.1.0.0" | head -1)
EGL_LIB=$(find "${BUILD_DIR}/src/egl" -name "libEGL_mesa.so.0.0.0" | head -1)
GLAPI_LIB=$(find "${BUILD_DIR}/src/mapi/shared-glapi" -name "libglapi.so.0.0.0" | head -1)
EGL_JSON=$(find "${BUILD_DIR}" -name "50_mesa.json" | head -1)

[[ -n "${DRI_SO}" && -f "${DRI_SO}" ]] || {
    echo "ERROR: pvr_dri.so not found after build under ${BUILD_DIR}" >&2
    exit 1
}
[[ -f "${WSI_LIB}" ]] || {
    echo "ERROR: libpvr_mesa_wsi.so not found after build" >&2
    exit 1
}
[[ -n "${GBM_LIB}" && -f "${GBM_LIB}" ]] || {
    echo "ERROR: libgbm.so.1.0.0 not found under ${BUILD_DIR}/src/gbm" >&2
    exit 1
}
[[ -n "${EGL_LIB}" && -f "${EGL_LIB}" ]] || {
    echo "ERROR: libEGL_mesa.so.0.0.0 not found under ${BUILD_DIR}/src/egl" >&2
    echo "  (Did the build use -Dglvnd=true?  Expected GLVND vendor, not libEGL.so.1)" >&2
    exit 1
}
[[ -n "${GLAPI_LIB}" && -f "${GLAPI_LIB}" ]] || {
    echo "ERROR: libglapi.so.0.0.0 not found under ${BUILD_DIR}/src/mapi/shared-glapi" >&2
    exit 1
}
[[ -n "${EGL_JSON}" && -f "${EGL_JSON}" ]] || {
    echo "ERROR: 50_mesa.json not found after build" >&2
    exit 1
}

echo "==> pvr_dri.so:            $(ls -lh "${DRI_SO}")"
echo "==> libpvr_mesa_wsi.so:    $(ls -lh "${WSI_LIB}")"
echo "==> libgbm.so.1.0.0:       $(ls -lh "${GBM_LIB}")"
echo "==> libEGL_mesa.so.0.0.0:  $(ls -lh "${EGL_LIB}")"
echo "==> libglapi.so.0.0.0:     $(ls -lh "${GLAPI_LIB}")"
echo "==> 50_mesa.json:          $(ls -lh "${EGL_JSON}")"

# ---------------------------------------------------------------------------
# Package as .deb
#
# Artefacts packaged:
#   pvr_dri.so           → /usr/lib/aarch64-linux-gnu/dri/pvr_dri.so
#   tidss_dri.so         → symlink → pvr_dri.so
#   libgbm.so.1.0.0      → /usr/lib/aarch64-linux-gnu/libgbm.so.1.0.0
#   libEGL_mesa.so.0.0.0 → /usr/lib/aarch64-linux-gnu/libEGL_mesa.so.0.0.0
#   libglapi.so.0.0.0    → /usr/lib/aarch64-linux-gnu/libglapi.so.0.0.0
#   50_mesa.json         → /usr/share/glvnd/egl_vendor.d/50_mesa.json
#   libpvr_mesa_wsi.so   → /usr/lib/aarch64-linux-gnu/libpvr_mesa_wsi.so
# ---------------------------------------------------------------------------
DRI_INSTALL_DIR="usr/lib/aarch64-linux-gnu/dri"
LIB_DIR="usr/lib/aarch64-linux-gnu"
GLVND_JSON_DIR="usr/share/glvnd/egl_vendor.d"

PKGDIR="${SCRIPT_DIR}/ti-img-pvr-mesa-wsi_${PKG_VERSION}-${DEB_REVISION}_arm64"
rm -rf "${PKGDIR}"
mkdir -p "${PKGDIR}/DEBIAN"
mkdir -p "${PKGDIR}/${DRI_INSTALL_DIR}"
mkdir -p "${PKGDIR}/${LIB_DIR}"
mkdir -p "${PKGDIR}/${GLVND_JSON_DIR}"

# DRI gallium driver + tidss alias
install -m 0755 "${DRI_SO}"  "${PKGDIR}/${DRI_INSTALL_DIR}/pvr_dri.so"
# tidss_dri.so: mesa-pvr libgbm calls loader_open_driver("tidss") on card1,
# which resolves to tidss_dri.so → pvr_dri.so → __driDriverGetExtensions_tidss().
ln -sf pvr_dri.so "${PKGDIR}/${DRI_INSTALL_DIR}/tidss_dri.so"

# Vulkan WSI for libVK_IMG.so
install -m 0755 "${WSI_LIB}" "${PKGDIR}/${LIB_DIR}/libpvr_mesa_wsi.so"

# GBM library (replaces libgbm1; must come from same 24.0.1 build as libEGL_mesa.so)
install -m 0755 "${GBM_LIB}" "${PKGDIR}/${LIB_DIR}/libgbm.so.1.0.0"
ln -sf libgbm.so.1.0.0 "${PKGDIR}/${LIB_DIR}/libgbm.so.1"
ln -sf libgbm.so.1.0.0 "${PKGDIR}/${LIB_DIR}/libgbm.so"

# GLVND EGL vendor (replaces libegl-mesa0; same 24.0.1 build = compatible struct layout)
install -m 0755 "${EGL_LIB}" "${PKGDIR}/${LIB_DIR}/libEGL_mesa.so.0.0.0"
ln -sf libEGL_mesa.so.0.0.0 "${PKGDIR}/${LIB_DIR}/libEGL_mesa.so.0"
ln -sf libEGL_mesa.so.0.0.0 "${PKGDIR}/${LIB_DIR}/libEGL_mesa.so"

# GL API dispatch (replaces libglapi-mesa; must match the libEGL_mesa.so build)
install -m 0755 "${GLAPI_LIB}" "${PKGDIR}/${LIB_DIR}/libglapi.so.0.0.0"
ln -sf libglapi.so.0.0.0 "${PKGDIR}/${LIB_DIR}/libglapi.so.0"
ln -sf libglapi.so.0.0.0 "${PKGDIR}/${LIB_DIR}/libglapi.so"

# GLVND EGL vendor JSON — tells Ubuntu's libglvnd0 dispatcher to load our libEGL_mesa.so.0
install -m 0644 "${EGL_JSON}" "${PKGDIR}/${GLVND_JSON_DIR}/50_mesa.json"

cat > "${PKGDIR}/DEBIAN/control" <<EOF
Package: ti-img-pvr-mesa-wsi
Version: ${PKG_VERSION}-${DEB_REVISION}
Architecture: arm64
Maintainer: Texas Instruments <vijayp@ti.com>
Depends: libglvnd0, libwayland-client0, libdrm2, libexpat1, libzstd1, libstdc++6
Provides: libgbm1 (= ${PKG_VERSION}), libegl-mesa0 (= ${PKG_VERSION}), libglapi-mesa (= ${PKG_VERSION})
Replaces: libgbm1, libegl-mesa0, libglapi-mesa
Conflicts: libgbm1, libegl-mesa0, libglapi-mesa
Description: Mesa 24.0.1 PowerVR GLVND EGL stack for TI SoCs
 Complete Mesa 24.0.1 GLVND EGL vendor stack with PowerVR DRI driver
 for the PowerVR Rogue GPU (j784s4/j721s2), built from TI's mesa-pvr
 fork (gitlab.freedesktop.org/StaticRocket/mesa.git @ ${SRCREV}).
 .
 pvr_dri.so — Gallium DRI driver for PowerVR hardware acceleration.
 tidss_dri.so — Symlink alias required by mesa-pvr libgbm.
 .
 libEGL_mesa.so.0 — Mesa GLVND EGL vendor (replaces libegl-mesa0).
 Built with -Dglvnd=true to slot into Ubuntu's libglvnd0 dispatcher.
 Both libEGL_mesa.so.0 and libgbm.so.1 are from the same 24.0.1 build,
 ensuring compatible struct gbm_dri_device layout (fixes SIGBUS crash
 that occurs when mixing Mesa 24.0.1 libgbm with Mesa 25.2 libEGL).
 .
 libgbm.so.1 — Mesa 24.0.1 GBM (replaces libgbm1).  This version uses
 the per-driver DRI module loader path (loader_open_driver) to dlopen
 pvr_dri.so.  Ubuntu Mesa 25.2 removed this path in favour of a
 monolithic gallium that has no PVR driver.
 .
 libglapi.so.0 — Mesa GL API dispatch (replaces libglapi-mesa).
 Must match the libEGL_mesa.so.0 build for ABI compatibility.
 .
 libpvr_mesa_wsi.so — Mesa Window System Integration (WSI) library.
 Required by libVK_IMG.so to create Vulkan surfaces on Wayland/DRM.
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
echo "    pvr_dri.so           → /${DRI_INSTALL_DIR}/pvr_dri.so"
echo "    tidss_dri.so         → /${DRI_INSTALL_DIR}/tidss_dri.so (symlink → pvr_dri.so)"
echo "    libgbm.so.1.0.0      → /${LIB_DIR}/libgbm.so.1.0.0 (replaces libgbm1)"
echo "    libEGL_mesa.so.0.0.0 → /${LIB_DIR}/libEGL_mesa.so.0.0.0 (replaces libegl-mesa0)"
echo "    libglapi.so.0.0.0    → /${LIB_DIR}/libglapi.so.0.0.0 (replaces libglapi-mesa)"
echo "    50_mesa.json         → /${GLVND_JSON_DIR}/50_mesa.json"
echo "    libpvr_mesa_wsi.so   → /${LIB_DIR}/libpvr_mesa_wsi.so"
