#!/bin/bash
# build-from-source.sh — Package ti-img-rogue-umlibs as Debian packages.
#
# The umlibs repository contains pre-built arm64 binaries (OpenGL ES, Vulkan,
# OpenCL, tools, firmware) for the TI PowerVR Rogue GPU on j784s4/j721s2.
# No compilation is needed — this script clones the repo and runs `make install`
# into a staging directory, then uses dpkg-deb to create the .deb packages.
#
# Upstream:  https://git.ti.com/git/graphics/ti-img-rogue-umlibs.git
# Reference: meta-ti/recipes-graphics/powervr-umlibs/ti-img-rogue-umlibs_25.2.6850647.bb
# SRCREV:    adcbb5c620ff172da4152c02a2fee8f42dc4c472
# Branch:    linuxws/scarthgap/k6.12/25.2.6850647
#
# Usage:
#   ./build-from-source.sh [--skip-fetch]
#
#   --skip-fetch   Skip git clone/fetch; use existing src/ directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRCREV="adcbb5c620ff172da4152c02a2fee8f42dc4c472"
BRANCH="linuxws/scarthgap/k6.12/25.2.6850647"
GIT_REMOTE="https://git.ti.com/git/graphics/ti-img-rogue-umlibs.git"
TARGET_PRODUCT="j784s4_linux"
BUILD="release"
WINDOW_SYSTEM="lws-generic"
PKG_VERSION="25.2.6850647"
DEB_REVISION="1"
SKIP_FETCH=0

SOURCE_DIR="${SCRIPT_DIR}/src/ti-img-rogue-umlibs"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-fetch) SKIP_FETCH=1 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Fetch source
# ---------------------------------------------------------------------------
if [[ ${SKIP_FETCH} -eq 0 ]]; then
    echo "==> Cloning ti-img-rogue-umlibs @ ${SRCREV}"
    rm -rf "${SOURCE_DIR}"
    mkdir -p "$(dirname "${SOURCE_DIR}")"
    git clone --branch "${BRANCH}" "${GIT_REMOTE}" "${SOURCE_DIR}"
    git -C "${SOURCE_DIR}" checkout "${SRCREV}"
else
    echo "==> Skipping fetch, using ${SOURCE_DIR}"
    [[ -d "${SOURCE_DIR}" ]] || { echo "ERROR: ${SOURCE_DIR} does not exist"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Stage into debian package directory
# ---------------------------------------------------------------------------
STAGING="${SCRIPT_DIR}/staging"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"

echo "==> Installing into staging dir"
make -C "${SOURCE_DIR}" \
    DESTDIR="${STAGING}" \
    TARGET_PRODUCT="${TARGET_PRODUCT}" \
    BUILD="${BUILD}" \
    WINDOW_SYSTEM="${WINDOW_SYSTEM}" \
    install

# Move firmware from lib/firmware → usr/lib/firmware (Ubuntu Noble usrmerge)
if [[ -d "${STAGING}/lib/firmware" ]]; then
    mkdir -p "${STAGING}/usr/lib/firmware"
    cp -a "${STAGING}/lib/firmware/." "${STAGING}/usr/lib/firmware/"
    rm -rf "${STAGING}/lib"
fi

# Add soname symlinks (the .so.N and plain .so files already in repo;
# just make sure ldconfig can find them)
find "${STAGING}/usr/lib" -name "*.so.${PKG_VERSION}" | while read -r versioned; do
    base="${versioned%.${PKG_VERSION}}"
    # .so.1 or .so.N symlink
    so1="${base}.1"
    if [[ ! -e "${so1}" && ! -L "${so1}" ]]; then
        ln -sf "$(basename "${versioned}")" "${so1}"
    fi
    # plain .so symlink
    plain="${base}"
    if [[ ! -e "${plain}" && ! -L "${plain}" ]]; then
        ln -sf "$(basename "${versioned}")" "${plain}"
    fi
done

# ---------------------------------------------------------------------------
# Build single combined .deb: ti-img-rogue-umlibs
# ---------------------------------------------------------------------------
PKGDIR="${SCRIPT_DIR}/ti-img-rogue-umlibs_${PKG_VERSION}-${DEB_REVISION}_arm64"
rm -rf "${PKGDIR}"
mkdir -p "${PKGDIR}/DEBIAN"
cp -a "${STAGING}/." "${PKGDIR}/"

cat > "${PKGDIR}/DEBIAN/control" <<EOF
Package: ti-img-rogue-umlibs
Version: ${PKG_VERSION}-${DEB_REVISION}
Architecture: arm64
Maintainer: Texas Instruments <vijayp@ti.com>
Depends: libdrm2
Description: Userspace libraries for PowerVR Rogue GPU on TI SoCs (j784s4/j721s2)
 Pre-built arm64 libraries for the Imagination Technologies PowerVR Rogue GPU:
 OpenGL ES 1.1, OpenGL ES 2.0, Vulkan, OpenCL, GPU service daemon libraries,
 firmware (rgx.fw.36.53.104.796), and test tools.
 Target product: ${TARGET_PRODUCT}, window system: ${WINDOW_SYSTEM}.
EOF

cat > "${PKGDIR}/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
ldconfig
POSTINST
chmod 0755 "${PKGDIR}/DEBIAN/postinst"

# Fix permissions
find "${PKGDIR}" -not -path "${PKGDIR}/DEBIAN*" -type f -name "*.so*" -exec chmod 0755 {} \;
find "${PKGDIR}" -not -path "${PKGDIR}/DEBIAN*" -type f -name "*.fw" -exec chmod 0644 {} \;
find "${PKGDIR}" -not -path "${PKGDIR}/DEBIAN*" -type f -name "*.sh" -exec chmod 0644 {} \;
find "${PKGDIR}/usr/bin" -type f -exec chmod 0755 {} \; 2>/dev/null || true

dpkg-deb --build --root-owner-group "${PKGDIR}" "${SCRIPT_DIR}/ti-img-rogue-umlibs_${PKG_VERSION}-${DEB_REVISION}_arm64.deb"
rm -rf "${PKGDIR}" "${STAGING}"

echo "==> Built: ${SCRIPT_DIR}/ti-img-rogue-umlibs_${PKG_VERSION}-${DEB_REVISION}_arm64.deb"
