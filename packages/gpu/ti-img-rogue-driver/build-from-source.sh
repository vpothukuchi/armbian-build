#!/bin/bash
# build-from-source.sh — Cross-compile pvrsrvkm.ko and package as a .deb.
#
# Builds the TI PowerVR Rogue kernel module from the TI Graphics git tree
# against the specified Armbian kernel source directory (must be already
# configured and have had `make modules_prepare` or a full build run).
#
# Upstream:  https://git.ti.com/git/graphics/ti-img-rogue-driver.git
# Reference: meta-ti/recipes-bsp/powervr-drivers/ti-img-rogue-driver_25.2.6850647.bb
# SRCREV:    a838ac0074db640ebd1b64be6364417b1bbca3cd
# Branch:    linuxws/scarthgap/k6.12/25.2.6850647
#
# Prerequisites (on build host):
#   gcc-aarch64-linux-gnu, make, dpkg-dev
#
# Usage:
#   ./build-from-source.sh --kernel-dir <path> [OPTIONS]
#
#   --kernel-dir  <path>   Kernel source/build tree (REQUIRED)
#                          e.g. /path/to/armbian-build/cache/sources/linux-kernel-worktree/6.12__k3__arm64
#   --kernel-ver  <ver>    Kernel version string for deb name (default: read from kernel tree)
#   --cross       <pfx>    Cross-compiler prefix (default: aarch64-linux-gnu-)
#   --jobs        <N>      Parallel make jobs (default: nproc)
#   --skip-fetch           Skip git clone/fetch; use existing src/ directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRCREV="a838ac0074db640ebd1b64be6364417b1bbca3cd"
BRANCH="linuxws/scarthgap/k6.12/25.2.6850647"
GIT_REMOTE="https://git.ti.com/git/graphics/ti-img-rogue-driver.git"
TARGET_PRODUCT="j784s4_linux"
BUILD="release"
WINDOW_SYSTEM="lws-generic"
PKG_VERSION="25.2.6850647"
DEB_REVISION="1"

KERNEL_DIR=""
KERNEL_VER=""
CROSS_COMPILE="aarch64-linux-gnu-"
JOBS="$(nproc)"
SKIP_FETCH=0

SOURCE_DIR="${SCRIPT_DIR}/src/ti-img-rogue-driver"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-dir)  KERNEL_DIR="$2";  shift ;;
        --kernel-ver)  KERNEL_VER="$2";  shift ;;
        --cross)       CROSS_COMPILE="$2"; shift ;;
        --jobs)        JOBS="$2"; shift ;;
        --skip-fetch)  SKIP_FETCH=1 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if [[ -z "${KERNEL_DIR}" ]]; then
    echo "ERROR: --kernel-dir is required" >&2
    echo "Usage: $0 --kernel-dir <armbian-kernel-worktree-path> [--kernel-ver <ver>]" >&2
    exit 1
fi

[[ -d "${KERNEL_DIR}" ]] || { echo "ERROR: kernel dir not found: ${KERNEL_DIR}" >&2; exit 1; }

# Auto-detect kernel version from the build tree
if [[ -z "${KERNEL_VER}" ]]; then
    # Read from utsrelease.h — reliable even inside Docker where 'make kernelrelease'
    # may not have access to the git tree to compute LOCALVERSION_AUTO.
    UTSRELEASE="${KERNEL_DIR}/include/generated/utsrelease.h"
    if [[ -f "${UTSRELEASE}" ]]; then
        KERNEL_VER=$(grep -oP '(?<=UTS_RELEASE ")[^"]+' "${UTSRELEASE}")
    else
        KERNEL_VER=$(make -s -C "${KERNEL_DIR}" ARCH=arm64 kernelrelease 2>/dev/null)
    fi
    echo "==> Auto-detected kernel version: ${KERNEL_VER}"
fi

# ---------------------------------------------------------------------------
# Fetch source
# ---------------------------------------------------------------------------
if [[ ${SKIP_FETCH} -eq 0 ]]; then
    echo "==> Cloning ti-img-rogue-driver @ ${SRCREV}"
    rm -rf "${SOURCE_DIR}"
    mkdir -p "$(dirname "${SOURCE_DIR}")"
    git clone --branch "${BRANCH}" "${GIT_REMOTE}" "${SOURCE_DIR}"
    git -C "${SOURCE_DIR}" checkout "${SRCREV}"
else
    echo "==> Skipping fetch, using ${SOURCE_DIR}"
    [[ -d "${SOURCE_DIR}" ]] || { echo "ERROR: ${SOURCE_DIR} does not exist"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Build the kernel module
# ---------------------------------------------------------------------------
echo "==> Building pvrsrvkm.ko for kernel ${KERNEL_VER}"
echo "    KERNELDIR=${KERNEL_DIR}"

make -C "${SOURCE_DIR}" \
    -j"${JOBS}" \
    KERNELDIR="${KERNEL_DIR}" \
    BUILD="${BUILD}" \
    PVR_BUILD_DIR="${TARGET_PRODUCT}" \
    WINDOW_SYSTEM="${WINDOW_SYSTEM}" \
    ARCH=arm64 \
    CROSS_COMPILE="${CROSS_COMPILE}"

KBUILD_DIR="${SOURCE_DIR}/binary_${TARGET_PRODUCT}_${WINDOW_SYSTEM}_${BUILD}/target_aarch64/kbuild"
[[ -f "${KBUILD_DIR}/pvrsrvkm.ko" ]] || {
    echo "ERROR: pvrsrvkm.ko not found after build at ${KBUILD_DIR}" >&2
    exit 1
}

echo "==> pvrsrvkm.ko built successfully"
ls -lh "${KBUILD_DIR}/pvrsrvkm.ko"

# ---------------------------------------------------------------------------
# Package as .deb
# ---------------------------------------------------------------------------
INSTALL_MODDIR="lib/modules/${KERNEL_VER}/updates"
PKGDIR="${SCRIPT_DIR}/ti-img-rogue-driver_${PKG_VERSION}-${DEB_REVISION}_arm64"
rm -rf "${PKGDIR}"
mkdir -p "${PKGDIR}/DEBIAN"
mkdir -p "${PKGDIR}/${INSTALL_MODDIR}"

# Copy only pvrsrvkm.ko — do NOT use `make modules_install` as that runs
# depmod and creates modules.alias/modules.dep which conflict with linux-image.
# The postinst runs `depmod -a` to regenerate those files on the target.
install -m 0644 "${KBUILD_DIR}/pvrsrvkm.ko" "${PKGDIR}/${INSTALL_MODDIR}/pvrsrvkm.ko"

cat > "${PKGDIR}/DEBIAN/control" <<EOF
Package: ti-img-rogue-driver
Version: ${PKG_VERSION}-${DEB_REVISION}
Architecture: arm64
Maintainer: Texas Instruments <vijayp@ti.com>
Depends: ti-img-rogue-umlibs
Description: Kernel module for PowerVR Rogue GPU on TI SoCs (j784s4/j721s2)
 pvrsrvkm.ko — the PowerVR Services kernel module from the TI Graphics tree.
 Built for kernel ${KERNEL_VER}, target product ${TARGET_PRODUCT}.
 Source: git.ti.com/git/graphics/ti-img-rogue-driver.git @ ${SRCREV}
EOF

cat > "${PKGDIR}/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
# Regenerate module deps for every kernel version that has pvrsrvkm installed.
# This covers the case where a kernel deb upgrade re-runs depmod first and
# drops the out-of-tree pvrsrvkm.ko from modules.dep.
for _ko in /lib/modules/*/updates/pvrsrvkm.ko; do
    _kver=$(echo "$_ko" | cut -d/ -f4)
    depmod -a "$_kver"
done
POSTINST
chmod 0755 "${PKGDIR}/DEBIAN/postinst"

dpkg-deb --build --root-owner-group "${PKGDIR}" \
    "${SCRIPT_DIR}/ti-img-rogue-driver_${PKG_VERSION}-${DEB_REVISION}_arm64.deb"
rm -rf "${PKGDIR}"

echo "==> Built: ${SCRIPT_DIR}/ti-img-rogue-driver_${PKG_VERSION}-${DEB_REVISION}_arm64.deb"
