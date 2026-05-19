#!/bin/bash
# build-from-source.sh — Build edgeai-test-data .deb package.
#
# Downloads test images and videos from TI CDN using the
# download_test_data.sh script bundled in edgeai-gst-apps.
#
# Upstream:  https://github.com/TexasInstruments/edgeai-gst-apps.git
# Reference: meta-edgeai/recipes-tisdk/edgeai-components/edgeai-test-data.bb
# SRCREV:    464f70b2e780bbaed8ab048b4b548f54b75b1661  (edgeai-gst-apps)
#
# The Yocto recipe runs download_test_data.sh with:
#   SOC=j784s4  EDGEAI_SDK_VERSION=11_01_00
#   EDGEAI_DATA_PATH=/opt/edgeai-test-data
#   OOB_DEMO_ASSETS_PATH=/opt/oob-demo-assets
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --soc         <soc>    Target SoC (default: j784s4)
#   --skip-fetch           Skip download (reuse existing test-data/)
#
# Produces: edgeai-test-data_1.0-1_arm64.deb
#   Installs: /opt/edgeai-test-data/  (images + videos for EdgeAI demos)
#             /opt/oob-demo-assets/   (out-of-box demo video clips)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRCREV="464f70b2e780bbaed8ab048b4b548f54b75b1661"
GIT_REMOTE="https://github.com/TexasInstruments/edgeai-gst-apps.git"

PKG_VERSION="1.0"
DEB_REVISION="1"

SOC="j784s4"
EDGEAI_SDK_VERSION="11_01_00"
SKIP_FETCH=0

SRC_DIR="${SCRIPT_DIR}/src/edgeai-gst-apps"
TEST_DATA_DIR="${SCRIPT_DIR}/edgeai-test-data"
OOB_ASSETS_DIR="${SCRIPT_DIR}/oob-demo-assets"
STAGING_DIR="${SCRIPT_DIR}/staging"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --soc)        SOC="$2";      shift 2 ;;
        --skip-fetch) SKIP_FETCH=1;  shift ;;
        --help)
            sed -n '/^# Usage:/,/^$/p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

obtain_test_data() {
    info "=== Downloading EdgeAI test data (SOC=${SOC}, SDK=${EDGEAI_SDK_VERSION}) ==="
    mkdir -p "${SCRIPT_DIR}/src"

    if [[ -d "${SRC_DIR}/.git" ]]; then
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    else
        git clone "${GIT_REMOTE}" "${SRC_DIR}"
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    fi
    info "  HEAD: $(git -C "${SRC_DIR}" log -1 --oneline)"

    rm -rf "${TEST_DATA_DIR}" "${OOB_ASSETS_DIR}"
    mkdir -p "${TEST_DATA_DIR}" "${OOB_ASSETS_DIR}"

    export SOC="${SOC}"
    export EDGEAI_DATA_PATH="${TEST_DATA_DIR}"
    export OOB_DEMO_ASSETS_PATH="${OOB_ASSETS_DIR}"
    export EDGEAI_SDK_VERSION="${EDGEAI_SDK_VERSION}"
    bash "${SRC_DIR}/download_test_data.sh"

    # Yocto recipe creates symlinks from test-data/videos/ to oob-demo-assets/
    cd "${OOB_ASSETS_DIR}"
    for i in *.h264; do
        [[ -f "${i}" ]] || continue
        ln -sf "/opt/oob-demo-assets/${i}" "${TEST_DATA_DIR}/videos/${i}" 2>/dev/null || true
    done

    info "Test data downloaded to ${TEST_DATA_DIR}"
}

install_test_data() {
    info "=== Staging test data ==="
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}/opt/edgeai-test-data"
    mkdir -p "${STAGING_DIR}/opt/oob-demo-assets"
    cp -a "${TEST_DATA_DIR}/." "${STAGING_DIR}/opt/edgeai-test-data/"
    cp -a "${OOB_ASSETS_DIR}/." "${STAGING_DIR}/opt/oob-demo-assets/"
}

package_debs() {
    info "=== Packaging .deb files ==="
    cd "${SCRIPT_DIR}"
    dpkg-buildpackage --build=binary --no-sign --host-arch=arm64 -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    ls -lh "${SCRIPT_DIR}/../"edgeai-test-data*.deb 2>/dev/null || true
}

main() {
    info "Building edgeai-test-data ${PKG_VERSION}"
    [[ "${SKIP_FETCH}" -eq 0 ]] && obtain_test_data
    install_test_data
    package_debs
}

main "$@"
