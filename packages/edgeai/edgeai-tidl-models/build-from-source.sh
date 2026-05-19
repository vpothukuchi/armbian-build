#!/bin/bash
# build-from-source.sh — Build edgeai-tidl-models .deb package.
#
# Downloads pre-trained TIDL models from TI CDN/GitHub into /opt/model_zoo/
# using the download_models.sh script bundled in edgeai-gst-apps.
#
# Upstream:  https://github.com/TexasInstruments/edgeai-gst-apps.git
# Reference: meta-edgeai/recipes-tisdk/edgeai-components/edgeai-tidl-models.bb
# SRCREV:    464f70b2e780bbaed8ab048b4b548f54b75b1661  (edgeai-gst-apps, same tag)
#
# The Yocto recipe runs download_models.sh --recommended with:
#   SOC=j784s4  EDGEAI_SDK_VERSION=11_02_00
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --soc         <soc>    Target SoC (default: j784s4)
#   --skip-fetch           Skip download (reuse existing model_zoo/)
#
# Produces: edgeai-tidl-models_1.0-1_arm64.deb
#   Installs: /opt/model_zoo/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRCREV="464f70b2e780bbaed8ab048b4b548f54b75b1661"
GIT_REMOTE="https://github.com/TexasInstruments/edgeai-gst-apps.git"

PKG_VERSION="1.0"
DEB_REVISION="1"

SOC="j784s4"
EDGEAI_SDK_VERSION="11_02_00"
SKIP_FETCH=0

SRC_DIR="${SCRIPT_DIR}/src/edgeai-gst-apps"
# download_models.sh uses DEST_DIR=../model_zoo/ relative to its own location
# (src/edgeai-gst-apps/), so models land in src/model_zoo/, not the package root.
MODEL_ZOO_DIR="${SCRIPT_DIR}/src/model_zoo"
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

obtain_models() {
    info "=== Downloading TIDL models (SOC=${SOC}, SDK=${EDGEAI_SDK_VERSION}) ==="
    mkdir -p "${SCRIPT_DIR}/src"

    if [[ -d "${SRC_DIR}/.git" ]]; then
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    else
        git clone "${GIT_REMOTE}" "${SRC_DIR}"
        git -C "${SRC_DIR}" checkout "${SRCREV}" --
    fi
    info "  HEAD: $(git -C "${SRC_DIR}" log -1 --oneline)"

    rm -rf "${MODEL_ZOO_DIR}"
    mkdir -p "${MODEL_ZOO_DIR}"
    cd "${MODEL_ZOO_DIR}"

    export SOC="${SOC}"
    export EDGEAI_SDK_VERSION="${EDGEAI_SDK_VERSION}"
    export MODEL_ZOO_PATH="${MODEL_ZOO_DIR}"
    bash "${SRC_DIR}/download_models.sh" --recommended

    info "Models downloaded: $(find "${MODEL_ZOO_DIR}" -mindepth 1 -maxdepth 1 -type d | wc -l) model directories"
}

install_models() {
    info "=== Staging model_zoo ==="
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}/opt/model_zoo"
    cp -a "${MODEL_ZOO_DIR}/." "${STAGING_DIR}/opt/model_zoo/"
}

package_debs() {
    info "=== Packaging .deb files ==="
    cd "${SCRIPT_DIR}"
    dpkg-buildpackage --build=binary --no-sign --host-arch=arm64 -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    ls -lh "${SCRIPT_DIR}/../"edgeai-tidl-models*.deb 2>/dev/null || true
}

main() {
    info "Building edgeai-tidl-models ${PKG_VERSION}"
    [[ "${SKIP_FETCH}" -eq 0 ]] && obtain_models
    install_models
    package_debs
}

main "$@"
