#!/bin/bash
# build-deb.sh — Build ti-tidl-osrt and ti-tidl-osrt-dev .deb packages
#
# Sources: TI EdgeAI PSDK Analytics 11.02.00 / tidl-tools 11_02_04_00
# Yocto reference: meta-edgeai/recipes-tisdk/ti-tidl/ti-tidl-osrt.bb
#
# Usage: ./build-deb.sh [--skip-download]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Configuration (mirrors ti-tidl-osrt.bb)
# ---------------------------------------------------------------------------

TIDL_VER="11_02_04_00"
BASE_URL="https://software-dl.ti.com/jacinto7/esd/tidl-tools/${TIDL_VER}/OSRT_TOOLS/ARM_LINUX/ARAGO"

PKG_VERSION="11.02.04.00"
DEB_REVISION="1"

declare -A ARTIFACTS=(
    ["tflite_runtime-2.12.0-cp312-cp312-linux_aarch64.whl"]="94c5f0ccbd5458cfa1327b378c7d479dc7d23979df8f26f091720f850dc02364"
    ["onnxruntime_tidl-1.15.0-cp312-cp312-linux_aarch64.whl"]="38c9953b6bef83f6e92012412fe0818dea5741caa790d70c19328bd88fca3056"
    ["tvm-0.18.0-cp312-cp312-linux_aarch64.whl"]=""
    ["tidlruntime-0.1.0-cp312-cp312-linux_aarch64.whl"]=""
    ["tflite_2.12_aragoj7.tar.gz"]="2ff6878f51595395d84830747da6a8ddbb168eab93e84edd9e5f75cfb33b6b55"
    ["onnx_1.15.0_aragoj7.tar.gz"]="f47dd643168eb330e6849fa60dffc48c6f43cb3f63cfd9079921684795817e3f"
)

DOWNLOAD_DIR="${SCRIPT_DIR}/downloads"
STAGING_DIR="${SCRIPT_DIR}/staging"
SKIP_DOWNLOAD=0

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --skip-download) SKIP_DOWNLOAD=1 ;;
        --help)
            echo "Usage: $0 [--skip-download]"
            echo "  --skip-download  Skip downloading artifacts (use existing downloads/)"
            exit 0
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in wget unzip tar dpkg-buildpackage dh; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing tools: ${missing[*]}. Install with: sudo apt install wget unzip debhelper devscripts"
    fi
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    if [[ -z "$expected" ]]; then
        info "  No checksum for $(basename "$file"), skipping verification"
        return 0
    fi
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        error "Checksum mismatch for $(basename "$file")\n  expected: $expected\n  actual:   $actual"
    fi
    info "  Checksum OK: $(basename "$file")"
}

# ---------------------------------------------------------------------------
# Step 1: Download artifacts
# ---------------------------------------------------------------------------
download_artifacts() {
    info "=== Downloading artifacts ==="
    mkdir -p "${DOWNLOAD_DIR}"

    for filename in "${!ARTIFACTS[@]}"; do
        local dest="${DOWNLOAD_DIR}/${filename}"
        if [[ -f "$dest" ]]; then
            info "  Already present: ${filename}"
        else
            info "  Downloading: ${filename}"
            wget -q --show-progress -O "$dest" "${BASE_URL}/${filename}" \
                || error "Failed to download ${filename}"
        fi
        verify_sha256 "$dest" "${ARTIFACTS[$filename]}"
    done
    info "All artifacts downloaded."
}

# ---------------------------------------------------------------------------
# Step 2: Stage artifacts (mirrors Yocto do_install logic)
# ---------------------------------------------------------------------------
stage_artifacts() {
    info "=== Staging artifacts ==="
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}"/{python,lib,include,tmp}

    local tmp="${STAGING_DIR}/tmp"

    # --- tflite_runtime wheel ---
    info "  Unpacking tflite_runtime wheel..."
    unzip -q "${DOWNLOAD_DIR}/tflite_runtime-2.12.0-cp312-cp312-linux_aarch64.whl" \
        -d "${STAGING_DIR}/python"

    # --- onnxruntime_tidl wheel ---
    info "  Unpacking onnxruntime_tidl wheel..."
    unzip -q "${DOWNLOAD_DIR}/onnxruntime_tidl-1.15.0-cp312-cp312-linux_aarch64.whl" \
        -d "${STAGING_DIR}/python"

    # --- tvm wheel ---
    info "  Unpacking tvm wheel..."
    unzip -q "${DOWNLOAD_DIR}/tvm-0.18.0-cp312-cp312-linux_aarch64.whl" \
        -d "${STAGING_DIR}/python"

    # --- tidlruntime wheel ---
    info "  Unpacking tidlruntime wheel..."
    unzip -q "${DOWNLOAD_DIR}/tidlruntime-0.1.0-cp312-cp312-linux_aarch64.whl" \
        -d "${STAGING_DIR}/python"

    # --- tflite C++ libs + headers ---
    # Tarball layout: tflite_2.12_aragoj7/{libtensorflow-lite.a, tensorflow/, tflite_2.12/}
    # Yocto recipe: mv ${S}/tfl_lib/*/* ${S}/tfl_lib  → flatten one level
    info "  Unpacking tflite_2.12 C++ artifacts..."
    mkdir -p "${tmp}/tfl_lib"
    tar -xzf "${DOWNLOAD_DIR}/tflite_2.12_aragoj7.tar.gz" -C "${tmp}/tfl_lib"
    # Flatten: move contents of the single top-level dir up
    local tfl_top
    tfl_top=$(find "${tmp}/tfl_lib" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [[ -n "$tfl_top" ]]; then
        mv "${tfl_top}"/* "${tmp}/tfl_lib/"
        rmdir "${tfl_top}"
    fi
    # Headers: tensorflow/
    cp -r "${tmp}/tfl_lib/tensorflow" "${STAGING_DIR}/include/"
    # Static libs dir: tflite_2.12/
    cp -r "${tmp}/tfl_lib/tflite_2.12" "${STAGING_DIR}/lib/"
    # Main static lib
    cp "${tmp}/tfl_lib/libtensorflow-lite.a" "${STAGING_DIR}/lib/"

    # --- onnxruntime C++ libs + headers ---
    # Tarball layout: onnx_1.15.0_aragoj7/{libonnxruntime.so*, onnxruntime/}
    # Yocto recipe: mv ${S}/ort_lib/*/* ${S}/ort_lib  → flatten one level
    info "  Unpacking onnx_1.15.0 C++ artifacts..."
    mkdir -p "${tmp}/ort_lib"
    tar -xzf "${DOWNLOAD_DIR}/onnx_1.15.0_aragoj7.tar.gz" -C "${tmp}/ort_lib"
    # Flatten
    local ort_top
    ort_top=$(find "${tmp}/ort_lib" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [[ -n "$ort_top" ]]; then
        mv "${ort_top}"/* "${tmp}/ort_lib/"
        rmdir "${ort_top}"
    fi
    # Shared lib
    cp "${tmp}/ort_lib/libonnxruntime.so.1.15.0" "${STAGING_DIR}/lib/"
    ln -sf "libonnxruntime.so.1.15.0" "${STAGING_DIR}/lib/libonnxruntime.so"
    # Headers: onnxruntime/ (remove csharp like Yocto recipe)
    rm -rf "${tmp}/ort_lib/onnxruntime/csharp" 2>/dev/null || true
    cp -r "${tmp}/ort_lib/onnxruntime" "${STAGING_DIR}/include/"

    # --- Symlinks from Python wheels into lib/ and include/ ---
    info "  Creating library symlinks from Python packages..."

    # tidlruntime: libtidlruntime.a from wheel into lib/
    if [[ -d "${STAGING_DIR}/python/tidlruntime/lib" ]]; then
        cp "${STAGING_DIR}/python/tidlruntime/lib/libtidlruntime.a" \
            "${STAGING_DIR}/lib/" 2>/dev/null || \
            info "  Warning: libtidlruntime.a not found in tidlruntime wheel"
    fi
    # tidlruntime headers
    if [[ -d "${STAGING_DIR}/python/tidlruntime/include" ]]; then
        cp -r "${STAGING_DIR}/python/tidlruntime/include" \
            "${STAGING_DIR}/include/tidlruntime"
    fi

    # tvm: libtvm.so and libtvm_runtime.so — symlinks from /usr/lib/ → ../lib/python3/dist-packages/tvm/
    # When installed: /usr/lib/libtvm.so → /usr/lib/python3/dist-packages/tvm/libtvm.so
    if [[ -f "${STAGING_DIR}/python/tvm/libtvm.so" ]]; then
        ln -sf "python3/dist-packages/tvm/libtvm.so" \
            "${STAGING_DIR}/lib/libtvm.so"
        ln -sf "python3/dist-packages/tvm/libtvm_runtime.so" \
            "${STAGING_DIR}/lib/libtvm_runtime.so"
    fi

    # tvm headers
    mkdir -p "${STAGING_DIR}/include/tvm/tvm"
    if [[ -d "${STAGING_DIR}/python/tvm" ]]; then
        (cd "${STAGING_DIR}/python/tvm" && \
         find . -name "*.h" -o -name "*.hpp" | \
         while read -r hdr; do
             mkdir -p "${STAGING_DIR}/include/tvm/tvm/$(dirname "$hdr")"
             cp "$hdr" "${STAGING_DIR}/include/tvm/tvm/${hdr}"
         done)
    fi

    # onnxruntime symlink from Python wheel location into lib
    if [[ -f "${STAGING_DIR}/python/onnxruntime_tidl/capi/libonnxruntime.so.1.15.0" ]]; then
        cp "${STAGING_DIR}/python/onnxruntime_tidl/capi/libonnxruntime.so.1.15.0" \
            "${STAGING_DIR}/lib/" 2>/dev/null || true
    fi

    info "Staging complete. Layout:"
    find "${STAGING_DIR}" -maxdepth 3 \( -name "*.so*" -o -name "*.a" \) | sort
}

# ---------------------------------------------------------------------------
# Step 3: Build .deb packages
# ---------------------------------------------------------------------------
build_deb() {
    info "=== Building .deb packages ==="

    # Create a symlink so debian/rules can find the staging dir
    ln -snf "${STAGING_DIR}" "${SCRIPT_DIR}/staging"

    # dpkg-buildpackage needs the source tree to have the right version
    # Verify changelog version matches
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
    ls -lh "${SCRIPT_DIR}/../"*.deb 2>/dev/null || \
    ls -lh "${SCRIPT_DIR}/../"ti-tidl-osrt*.deb 2>/dev/null || \
    info "  .deb files are in the parent directory of this package"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Building ti-tidl-osrt ${PKG_VERSION} Debian packages"
    info "Source: ${BASE_URL}"
    info ""

    check_deps

    if [[ "$SKIP_DOWNLOAD" -eq 0 ]]; then
        download_artifacts
    else
        info "Skipping download (--skip-download)"
        # Still verify what's present
        for filename in "${!ARTIFACTS[@]}"; do
            [[ -f "${DOWNLOAD_DIR}/${filename}" ]] || \
                error "Missing download: ${DOWNLOAD_DIR}/${filename}"
            verify_sha256 "${DOWNLOAD_DIR}/${filename}" "${ARTIFACTS[$filename]}"
        done
    fi

    stage_artifacts
    build_deb
}

main "$@"
