#!/bin/bash
# build-from-source.sh — Build ti-tidl-osrt and ti-tidl-osrt-dev .deb packages
#
# By default, builds TFLite and ONNX Runtime from source (cross-compile x86_64 → aarch64).
# TVM and TIDL Runtime are still downloaded from TI CDN (no public source available).
#
# Source SRCREVs (from meta-edgeai/recipes-tisdk/ti-tidl/ti-tidl.bb, PSDK 11.02.04.00):
#   TensorFlow:   TexasInstruments/tensorflow  branch tidl-j7-2.12  @ 422156a9...
#   ONNX Runtime: TexasInstruments/onnxruntime branch tidl-1.15     @ 5816ccce...
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --prebuilt-osrt       Download tflite+onnxruntime from TI CDN (skip source build)
#   --sdk-path <path>     PSDK SDK checkout; enables source build of arm-tidl delegates
#   --sysroot  <path>     Target sysroot; used to locate aarch64 Python 3.12 headers
#   --toolchain-bin <p>   Cross-compiler bin dir (used with --sdk-path for arm-tidl)
#   --soc <soc>           Target SoC: j784s4|j722s|j721e|j721s2|am62a (default: j784s4)
#   --jobs <N>            Parallel build jobs (default: nproc)
#   --source-dir <path>   Where to clone/cache sources (default: ./build/src)
#   --mirror-dir <path>   Local git mirror directory containing bare repos named
#                         github.com.TexasInstruments.{tensorflow,onnxruntime}.
#   --skip-download       Skip CDN downloads; use existing downloads/
#   --skip-source-build   Skip compilation; use existing build/artifacts/
#
# Environment variables:
#
# Prerequisites (source build):
#   sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cmake ninja-build \
#        wget unzip python3-dev pybind11-dev python3-numpy python3-pip \
#        debhelper devscripts git
#   sudo dpkg --add-architecture arm64
#   sudo apt install python3-dev:arm64
#   pip3 install --user wheel setuptools pybind11 flatbuffers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# TI PSDK 11.02 SRCREVs (from meta-edgeai/recipes-tisdk/ti-tidl/ti-tidl.bb)
SRCREV_TENSORFLOW="422156a973b23bab6b86176a245a66193dccb995"
SRCREV_ONNXRUNTIME="5816ccce5bb4b9b8ce1869bdda397257a8d2028a"

TENSORFLOW_REPO="https://github.com/TexasInstruments/tensorflow.git"
ONNXRUNTIME_REPO="https://github.com/TexasInstruments/onnxruntime.git"

# Local git mirror paths (bare repos; speeds up cloning when available).
# Set via --mirror-dir.
MIRROR_TENSORFLOW=""
MIRROR_ONNXRUNTIME=""

# x86_64 protoc — must execute on the build host, not the aarch64 target
PROTOBUF_VER="21.12"
PROTOC_X86_URL="https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VER}/protoc-${PROTOBUF_VER}-linux-x86_64.zip"

# Cross-compile toolchain prefix
CROSS_PREFIX="aarch64-linux-gnu-"

# TI CDN base URL for artifacts that must be downloaded (tvm, tidlruntime)
TIDL_VER="11_02_04_00"
BASE_URL="https://software-dl.ti.com/jacinto7/esd/tidl-tools/${TIDL_VER}/OSRT_TOOLS/ARM_LINUX/ARAGO"

# CDN-only artifacts (tvm, tidlruntime, and ort Python wheel)
# The onnxruntime Python wheel is included here because bdist_wheel cannot
# run on an x86_64 host when the compiled pybind11 .so is an arm64 binary
# (import would fail).  The C++ library is still built from source; only
# the Python package is fetched from TI's official CDN release.
declare -A CDN_ARTIFACTS=(
    ["tvm-0.18.0-cp312-cp312-linux_aarch64.whl"]=""
    ["tidlruntime-0.1.0-cp312-cp312-linux_aarch64.whl"]=""
    ["onnxruntime_tidl-1.15.0-cp312-cp312-linux_aarch64.whl"]="38c9953b6bef83f6e92012412fe0818dea5741caa790d70c19328bd88fca3056"
)

# Prebuilt OSRT artifacts (used only with --prebuilt-osrt)
declare -A PREBUILT_ARTIFACTS=(
    ["tflite_runtime-2.12.0-cp312-cp312-linux_aarch64.whl"]="94c5f0ccbd5458cfa1327b378c7d479dc7d23979df8f26f091720f850dc02364"
    ["onnxruntime_tidl-1.15.0-cp312-cp312-linux_aarch64.whl"]="38c9953b6bef83f6e92012412fe0818dea5741caa790d70c19328bd88fca3056"
    ["tflite_2.12_aragoj7.tar.gz"]="2ff6878f51595395d84830747da6a8ddbb168eab93e84edd9e5f75cfb33b6b55"
    ["onnx_1.15.0_aragoj7.tar.gz"]="f47dd643168eb330e6849fa60dffc48c6f43cb3f63cfd9079921684795817e3f"
)

PKG_VERSION="11.02.04.00"

# Build directories
BUILD_DIR="${SCRIPT_DIR}/build"
SRC_DIR="${BUILD_DIR}/src"
ARTIFACTS_DIR="${BUILD_DIR}/artifacts"
DOWNLOAD_DIR="${SCRIPT_DIR}/downloads"
STAGING_DIR="${SCRIPT_DIR}/staging"

# Options
PREBUILT_OSRT=0
SDK_PATH=""
SYSROOT=""
TOOLCHAIN_BIN=""
SOC="j784s4"
JOBS="$(nproc)"
SKIP_DOWNLOAD=0
SKIP_SOURCE_BUILD=0
MIRROR_DIR=""   # overrides computed MIRROR_TENSORFLOW/MIRROR_ONNXRUNTIME when set

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prebuilt-osrt)     PREBUILT_OSRT=1;       shift ;;
        --sdk-path)          SDK_PATH="$2";         shift 2 ;;
        --sysroot)           SYSROOT="$2";          shift 2 ;;
        --toolchain-bin)     TOOLCHAIN_BIN="$2";    shift 2 ;;
        --soc)               SOC="$2";              shift 2 ;;
        --jobs)              JOBS="$2";             shift 2 ;;
        --source-dir)        SRC_DIR="$2";          shift 2 ;;
        --mirror-dir)        MIRROR_DIR="$2";       shift 2 ;;
        --skip-download)     SKIP_DOWNLOAD=1;       shift ;;
        --skip-source-build) SKIP_SOURCE_BUILD=1;   shift ;;
        --help)
            sed -n '/^# Usage:/,/^# Pre/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# If --mirror-dir was given, it overrides OE_DOWNLOADS-derived mirror paths
if [[ -n "${MIRROR_DIR}" ]]; then
    MIRROR_TENSORFLOW="${MIRROR_DIR}/github.com.TexasInstruments.tensorflow"
    MIRROR_ONNXRUNTIME="${MIRROR_DIR}/github.com.TexasInstruments.onnxruntime"
fi


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in wget unzip tar cmake python3 dpkg-buildpackage dh git; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ "${PREBUILT_OSRT}" -eq 0 ]] && [[ "${SKIP_SOURCE_BUILD}" -eq 0 ]]; then
        for cmd in "${CROSS_PREFIX}gcc" "${CROSS_PREFIX}g++"; do
            command -v "$cmd" &>/dev/null || missing+=("$cmd")
        done
        for mod in pybind11 numpy; do
            python3 -c "import ${mod}" 2>/dev/null || missing+=("python3-${mod}")
        done
        # aarch64 Python 3.12 headers required for cross-compiling Python bindings
        if [[ ! -f "/usr/include/aarch64-linux-gnu/python3.12/pyconfig.h" ]]; then
            missing+=("python3-dev:arm64 (aarch64 Python 3.12 headers)")
        fi
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing prerequisites: ${missing[*]}.
  Install with: sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \\
    cmake ninja-build wget unzip python3-dev python3-dev:arm64 pybind11-dev python3-numpy \\
    debhelper devscripts git
  pip3 install --user pybind11 numpy wheel setuptools flatbuffers"
    fi
}

verify_sha256() {
    local file="$1" expected="$2"
    if [[ -z "$expected" ]]; then
        info "  No checksum for $(basename "$file"), skipping"
        return 0
    fi
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        error "Checksum mismatch for $(basename "$file")
  expected: $expected
  actual:   $actual"
    fi
    info "  Checksum OK: $(basename "$file")"
}

# Clone a repo at a specific revision; use local Yocto mirror when available.
clone_at_rev() {
    local name="$1" remote_url="$2" mirror="$3" rev="$4" dest="$5"

    if [[ -d "${dest}/.git" ]]; then
        local actual
        actual=$(git -C "${dest}" rev-parse HEAD 2>/dev/null || echo "")
        if [[ "${actual}" == "${rev}" ]]; then
            info "  ${name}: already at ${rev:0:12}"
            return 0
        fi
        info "  ${name}: updating to ${rev:0:12}..."
        git -C "${dest}" fetch --depth=1 origin "${rev}" 2>/dev/null \
            || git -C "${dest}" fetch origin
        git -C "${dest}" checkout "${rev}"
        return 0
    fi

    mkdir -p "$(dirname "${dest}")"

    if [[ -d "${mirror}" ]]; then
        # Clone directly from the local bare mirror (no network needed).
        # Set the remote URL to the canonical upstream for documentation purposes.
        info "  ${name}: cloning from local Yocto mirror (offline)..."
        git clone "${mirror}" "${dest}"
        git -C "${dest}" remote set-url origin "${remote_url}"
    else
        info "  ${name}: cloning from ${remote_url}..."
        git clone "${remote_url}" "${dest}"
    fi
    git -C "${dest}" checkout "${rev}"
}

# ---------------------------------------------------------------------------
# Step 1: Download CDN-only artifacts (tvm and tidlruntime; always from CDN)
# ---------------------------------------------------------------------------
download_cdn_artifacts() {
    info "=== Downloading CDN artifacts (tvm, tidlruntime) ==="
    mkdir -p "${DOWNLOAD_DIR}"
    for filename in "${!CDN_ARTIFACTS[@]}"; do
        local dest="${DOWNLOAD_DIR}/${filename}"
        if [[ -f "$dest" ]]; then
            info "  Already present: ${filename}"
        else
            info "  Downloading: ${filename}"
            wget -q --show-progress -O "$dest" "${BASE_URL}/${filename}" \
                || error "Failed to download ${filename}"
        fi
        verify_sha256 "$dest" "${CDN_ARTIFACTS[$filename]}"
    done
}

# ---------------------------------------------------------------------------
# Step 2 (--prebuilt-osrt only): Download tflite + onnxruntime from TI CDN
# ---------------------------------------------------------------------------
download_prebuilt_osrt() {
    info "=== Downloading prebuilt OSRT artifacts from TI CDN ==="
    mkdir -p "${DOWNLOAD_DIR}"
    for filename in "${!PREBUILT_ARTIFACTS[@]}"; do
        local dest="${DOWNLOAD_DIR}/${filename}"
        if [[ -f "$dest" ]]; then
            info "  Already present: ${filename}"
        else
            info "  Downloading: ${filename}"
            wget -q --show-progress -O "$dest" "${BASE_URL}/${filename}" \
                || error "Failed to download ${filename}"
        fi
        verify_sha256 "$dest" "${PREBUILT_ARTIFACTS[$filename]}"
    done
}

# ---------------------------------------------------------------------------
# Step 3: Clone TFLite and ONNX Runtime sources
# ---------------------------------------------------------------------------
fetch_sources() {
    info "=== Fetching source repositories ==="
    mkdir -p "${SRC_DIR}"
    clone_at_rev "tensorflow" "${TENSORFLOW_REPO}" "${MIRROR_TENSORFLOW}" \
        "${SRCREV_TENSORFLOW}" "${SRC_DIR}/tensorflow"
    clone_at_rev "onnxruntime" "${ONNXRUNTIME_REPO}" "${MIRROR_ONNXRUNTIME}" \
        "${SRCREV_ONNXRUNTIME}" "${SRC_DIR}/onnxruntime"
}

# ---------------------------------------------------------------------------
# Step 4a: Cross-compile TFLite static library (libtensorflow-lite.a)
# ---------------------------------------------------------------------------
build_tflite_lib() {
    info "=== Building TFLite static library ==="
    local src="${SRC_DIR}/tensorflow"
    local build="${BUILD_DIR}/tflite_lib"

    mkdir -p "${build}"
    cd "${build}"

    # -include cstdint: GCC 13 requires explicit include for uint32_t etc. in
    # files that rely on transitive includes (TF 2.12 was written for GCC < 13).
    cmake \
        -DCMAKE_C_COMPILER="${CROSS_PREFIX}gcc" \
        -DCMAKE_CXX_COMPILER="${CROSS_PREFIX}g++" \
        -DCMAKE_C_FLAGS="-funsafe-math-optimizations" \
        -DCMAKE_CXX_FLAGS="-funsafe-math-optimizations -include cstdint" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DTFLITE_ENABLE_XNNPACK=ON \
        "${src}/tensorflow/lite"

    cmake --build . -j "${JOBS}" -t tensorflow-lite

    cd "${SCRIPT_DIR}"
    info "  libtensorflow-lite.a: ${build}/libtensorflow-lite.a"
    info "=== TFLite static library build complete ==="
}

# ---------------------------------------------------------------------------
# Step 4b: Cross-compile TFLite Python wheel (_pywrap_tensorflow_interpreter_wrapper.so)
# ---------------------------------------------------------------------------
build_tflite_wheel() {
    info "=== Building TFLite Python wheel ==="
    local src="${SRC_DIR}/tensorflow"
    local pip_pkg_dir="${src}/tensorflow/lite/tools/pip_package"
    local pip_script="${pip_pkg_dir}/build_pip_package_with_cmake.sh"

    # Install our cross-compile patched build script
    cp "${SCRIPT_DIR}/patches/tflite/build_pip_package_with_cmake.sh" "${pip_script}"
    chmod +x "${pip_script}"

    # ARMCC_PREFIX triggers cross-compile path in the patched script:
    #   - uses aarch64-linux-gnu-gcc/g++ instead of plain gcc/g++
    #   - uses /usr/include/aarch64-linux-gnu/python3.12 for Python headers
    ARMCC_PREFIX="${CROSS_PREFIX}" \
    PYTHON=python3 \
    BUILD_NUM_JOBS="${JOBS}" \
    "${pip_script}" aarch64

    # The wheel is produced under: <pip_pkg_dir>/gen/tflite_pip/python3/dist/
    local wheel_dist="${pip_pkg_dir}/gen/tflite_pip/python3/dist"
    local wheel
    wheel=$(find "${wheel_dist}" -name "tflite_runtime-*.whl" 2>/dev/null | head -1)
    [[ -f "${wheel}" ]] || error "TFLite wheel not found in ${wheel_dist}"

    mkdir -p "${ARTIFACTS_DIR}"
    cp "${wheel}" "${ARTIFACTS_DIR}/"
    info "  TFLite wheel: $(basename "${wheel}")"
    info "=== TFLite Python wheel build complete ==="
}

# ---------------------------------------------------------------------------
# Step 5a: Prepare ONNX Runtime source tree for cross-compile
# ---------------------------------------------------------------------------
prepare_onnxrt() {
    info "=== Preparing ONNX Runtime for cross-compile ==="
    local src="${SRC_DIR}/onnxruntime"

    # Install our CMake cross-compile toolchain file
    cp "${SCRIPT_DIR}/patches/onnxruntime/tool.cmake" "${src}/cmake/tool.cmake"
    info "  Installed tool.cmake (aarch64-linux-gnu cross-compile)"

    # Apply source patches (GCC 13 strict -Werror fixes, etc.)
    for p in "${SCRIPT_DIR}/patches/onnxruntime/"*.patch; do
        [[ -f "${p}" ]] || continue
        info "  Applying patch: $(basename "${p}")"
        git -C "${src}" apply --check "${p}" 2>/dev/null \
            && git -C "${src}" apply "${p}" \
            || info "    (already applied or not needed — skipping)"
    done

    # No git submodule init needed: all ONNX RT external dependencies (pybind11,
    # flatbuffers, nsync, onnx, re2, abseil, etc.) are fetched by CMake FetchContent
    # from URL archives defined in cmake/deps.txt. The entries in .gitmodules
    # (onnx, eigen, emsdk, libprotobuf-mutator, onnxruntime-extensions) are either
    # superseded by FetchContent URLs or only needed for optional features (WASM,
    # tests) that we don't build.
    info "  Skipping git submodule init (all deps use CMake FetchContent)"

    # Download x86_64 protoc: it must run on the BUILD host, not the target.
    # (edgeai-osrt-libs-build uses aarch64 protoc because it builds natively inside
    #  an arm64 Docker container; we cross-compile from x86_64 so we need x86_64.)
    local protoc_dir="${src}/cmake/external/protoc-${PROTOBUF_VER}-linux-x86_64"
    if [[ ! -x "${protoc_dir}/bin/protoc" ]]; then
        info "  Downloading x86_64 protoc ${PROTOBUF_VER}..."
        mkdir -p "${protoc_dir}"
        wget -q --show-progress -O /tmp/protoc-x86_64.zip "${PROTOC_X86_URL}" \
            || error "Failed to download x86_64 protoc from ${PROTOC_X86_URL}"
        unzip -q /tmp/protoc-x86_64.zip -d "${protoc_dir}"
        chmod +x "${protoc_dir}/bin/protoc"
        rm -f /tmp/protoc-x86_64.zip
    fi
    info "  protoc (x86_64): ${protoc_dir}/bin/protoc"
    info "=== ONNX Runtime preparation complete ==="
}

# ---------------------------------------------------------------------------
# Step 5b: Cross-compile ONNX Runtime shared lib + Python wheel
# ---------------------------------------------------------------------------
build_onnxrt() {
    info "=== Building ONNX Runtime ==="
    local src="${SRC_DIR}/onnxruntime"
    local build_dir="${BUILD_DIR}/onnxruntime"
    local protoc="${src}/cmake/external/protoc-${PROTOBUF_VER}-linux-x86_64/bin/protoc"
    local release_dir="${build_dir}/Release"

    mkdir -p "${build_dir}"
    cd "${src}"

    # NOTE: --build_wheel is intentionally absent.  When cross-compiling x86_64 →
    # arm64, the pybind11 .so compiled by CMake is an arm64 binary; running
    # bdist_wheel on the x86_64 host would try to import it and fail with a
    # "cannot execute binary file" or ELF mismatch error.  The Python wheel
    # is downloaded from TI CDN as part of CDN_ARTIFACTS instead.
    python3 tools/ci_build/build.py \
        --build_dir "${build_dir}" \
        --config Release \
        --build_shared_lib \
        --cmake_extra_defines \
            "CMAKE_TOOLCHAIN_FILE=${src}/cmake/tool.cmake" \
            "onnxruntime_USE_TIDL=ON" \
        --path_to_protoc_exe "${protoc}" \
        --skip_tests \
        --parallel "${JOBS}"

    # Collect the C++ shared library into artifacts/
    mkdir -p "${ARTIFACTS_DIR}"

    local so
    so=$(find "${release_dir}" -maxdepth 1 -name "libonnxruntime.so.*" | head -1)
    [[ -f "${so}" ]] || error "libonnxruntime.so.* not found in ${release_dir}"
    cp "${so}" "${ARTIFACTS_DIR}/"
    info "  Shared lib: $(basename "${so}")"
    info "  Python wheel will come from TI CDN (onnxruntime_tidl in CDN_ARTIFACTS)"

    cd "${SCRIPT_DIR}"
    info "=== ONNX Runtime build complete ==="
}

# ---------------------------------------------------------------------------
# Step 6 (optional): Build arm-tidl delegates from SDK source
#
# Requires --sdk-path pointing to a PSDK checkout where ti-vision-apps has
# already been built (arm-tidl/rt links against tiovx and vision_apps libs).
# ---------------------------------------------------------------------------
build_arm_tidl() {
    [[ -n "${SDK_PATH}" ]] || return 0

    info "=== Building arm-tidl delegates from source ==="
    info "  SDK path:      ${SDK_PATH}"
    info "  Sysroot:       ${SYSROOT}"
    info "  Toolchain bin: ${TOOLCHAIN_BIN}"
    info "  SOC:           ${SOC}"

    [[ -d "${SDK_PATH}/sdk_builder" ]] \
        || error "SDK not found: ${SDK_PATH}/sdk_builder"
    [[ -d "${SDK_PATH}/tidl_j7/arm-tidl" ]] \
        || error "arm-tidl not found: ${SDK_PATH}/tidl_j7/arm-tidl"
    [[ -d "${SDK_PATH}/tiovx" ]] \
        || error "tiovx not found (ti-vision-apps must be built first): ${SDK_PATH}/tiovx"

    local MPU_CPU="A72"
    [[ "${SOC}" == "am62a" ]] && MPU_CPU="A53"
    local GCC_LINUX_ARM_ROOT="${TOOLCHAIN_BIN%/bin/aarch64-oe-linux}"

    cd "${SDK_PATH}/sdk_builder"
    ln -snf "${SYSROOT}" "${SDK_PATH}/targetfs"

    make -j"${JOBS}" \
        SOC="${SOC}" \
        PSDK_PATH="${SDK_PATH}" \
        PROFILE=release \
        BUILD_LINUX_MPU=yes \
        TARGET_CPU="${MPU_CPU}" \
        TARGET_OS=LINUX \
        TIDL_PATH="${SDK_PATH}/tidl_j7" \
        TF_REPO_PATH="${ARTIFACTS_DIR}" \
        GCC_LINUX_ARM_ROOT="${GCC_LINUX_ARM_ROOT}" \
        LINUX_SYSROOT_ARM="${SYSROOT}" \
        TREAT_WARNINGS_AS_ERROR=0 \
        tidl_rt

    cd "${SCRIPT_DIR}"
    info "=== arm-tidl build complete ==="
}

# ---------------------------------------------------------------------------
# Step 7: Stage all artifacts into staging/{python,lib,include}/
#
# Layout expected by debian/rules:
#   staging/python/   → /usr/lib/python3/dist-packages/
#   staging/lib/*.so* → /usr/lib/
#   staging/lib/*.a   → /usr/lib/   (dev package)
#   staging/lib/tflite_2.12/ → /usr/lib/tflite_2.12/  (dev package)
#   staging/include/  → /usr/include/  (dev package)
# ---------------------------------------------------------------------------
stage_artifacts() {
    info "=== Staging artifacts ==="
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}"/{python,lib,include,tmp}

    # --- Python wheels (unpack into staging/python/) ---

    local tfl_wheel
    if [[ "${PREBUILT_OSRT}" -eq 1 ]]; then
        tfl_wheel=$(find "${DOWNLOAD_DIR}" -name "tflite_runtime-*.whl" | head -1)
    else
        tfl_wheel=$(find "${ARTIFACTS_DIR}" -name "tflite_runtime-*.whl" | head -1)
    fi
    [[ -f "${tfl_wheel}" ]] || error "TFLite wheel not found"
    info "  Unpacking TFLite wheel: $(basename "${tfl_wheel}")"
    unzip -q "${tfl_wheel}" -d "${STAGING_DIR}/python"

    # The ort Python wheel is always in DOWNLOAD_DIR (onnxruntime_tidl-*.whl).
    # In source mode: CDN_ARTIFACTS downloads it there alongside tvm/tidlruntime.
    # In prebuilt mode: PREBUILT_ARTIFACTS downloads it there as well.
    local ort_wheel
    ort_wheel=$(find "${DOWNLOAD_DIR}" -name "onnxruntime*.whl" | head -1)
    [[ -f "${ort_wheel}" ]] || error "ONNX Runtime wheel not found in ${DOWNLOAD_DIR}"
    info "  Unpacking ONNX RT wheel: $(basename "${ort_wheel}")"
    unzip -q "${ort_wheel}" -d "${STAGING_DIR}/python"

    local tvm_wheel
    tvm_wheel=$(find "${DOWNLOAD_DIR}" -name "tvm-*.whl" | head -1)
    [[ -f "${tvm_wheel}" ]] || error "TVM wheel not found in ${DOWNLOAD_DIR}"
    info "  Unpacking TVM wheel"
    unzip -q "${tvm_wheel}" -d "${STAGING_DIR}/python"

    local tidlrt_wheel
    tidlrt_wheel=$(find "${DOWNLOAD_DIR}" -name "tidlruntime-*.whl" | head -1)
    [[ -f "${tidlrt_wheel}" ]] || error "tidlruntime wheel not found in ${DOWNLOAD_DIR}"
    info "  Unpacking tidlruntime wheel"
    unzip -q "${tidlrt_wheel}" -d "${STAGING_DIR}/python"

    # --- TFLite C++ library + headers ---
    if [[ "${PREBUILT_OSRT}" -eq 1 ]]; then
        _stage_tflite_prebuilt
    else
        _stage_tflite_source
    fi

    # --- ONNX Runtime C++ library + headers ---
    if [[ "${PREBUILT_OSRT}" -eq 1 ]]; then
        _stage_onnxrt_prebuilt
    else
        _stage_onnxrt_source
    fi

    # --- tidlruntime: extract libtidlruntime.a and headers from wheel ---
    if [[ -f "${STAGING_DIR}/python/tidlruntime/lib/libtidlruntime.a" ]]; then
        cp "${STAGING_DIR}/python/tidlruntime/lib/libtidlruntime.a" \
            "${STAGING_DIR}/lib/"
    fi
    if [[ -d "${STAGING_DIR}/python/tidlruntime/include" ]]; then
        cp -r "${STAGING_DIR}/python/tidlruntime/include" \
            "${STAGING_DIR}/include/tidlruntime"
    fi

    # --- TVM shared lib symlinks ---
    # tvm.so lives inside the Python package; /usr/lib/libtvm.so symlinks to it
    if [[ -f "${STAGING_DIR}/python/tvm/libtvm.so" ]]; then
        ln -sf "python3/dist-packages/tvm/libtvm.so" \
            "${STAGING_DIR}/lib/libtvm.so"
        ln -sf "python3/dist-packages/tvm/libtvm_runtime.so" \
            "${STAGING_DIR}/lib/libtvm_runtime.so"
    fi

    # --- Source-built arm-tidl delegate .so files (optional) ---
    if [[ -n "${SDK_PATH}" ]]; then
        local MPU_CPU="A72"
        [[ "${SOC}" == "am62a" ]] && MPU_CPU="A53"
        local SOC_UPPER="${SOC^^}"
        find "${SDK_PATH}/tidl_j7/arm-tidl" \
            -path "*/out/${SOC_UPPER}/${MPU_CPU}/LINUX/release/*.so*" ! -type d \
            | while read -r f; do
                cp -a "$f" "${STAGING_DIR}/lib/"
                info "    + $(basename "$f")"
            done
    fi

    info "Staging complete."
    info "  Python packages: $(ls "${STAGING_DIR}/python/")"
    info "  Libraries:"
    find "${STAGING_DIR}/lib" -maxdepth 2 \( -name "*.so*" -o -name "*.a" \) | sort
}

_stage_tflite_prebuilt() {
    info "  Staging TFLite C++ artifacts from prebuilt tarball..."
    local tmp="${STAGING_DIR}/tmp/tfl_lib"
    mkdir -p "${tmp}"
    tar -xzf "${DOWNLOAD_DIR}/tflite_2.12_aragoj7.tar.gz" -C "${tmp}"
    # Flatten the single top-level directory
    local top
    top=$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -1)
    [[ -n "$top" ]] && { mv "${top}"/* "${tmp}/"; rmdir "${top}"; }
    cp -r "${tmp}/tensorflow" "${STAGING_DIR}/include/"
    cp -r "${tmp}/tflite_2.12" "${STAGING_DIR}/lib/"
    cp "${tmp}/libtensorflow-lite.a" "${STAGING_DIR}/lib/"
}

_stage_tflite_source() {
    info "  Staging TFLite C++ artifacts from source build..."
    local src="${SRC_DIR}/tensorflow"
    local build="${BUILD_DIR}/tflite_lib"

    [[ -f "${build}/libtensorflow-lite.a" ]] \
        || error "libtensorflow-lite.a not found in ${build} — run source build first"

    # Main static library
    cp "${build}/libtensorflow-lite.a" "${STAGING_DIR}/lib/"

    # Headers: tensorflow/lite/ subtree (installed as staging/include/tensorflow/lite/)
    # Copy only .h and .fbs files to avoid packaging cmake build artifacts
    # (e.g. tools/pip_package/gen/ contains compiler-detection binaries that
    # confuse dh_strip during Debian packaging).
    mkdir -p "${STAGING_DIR}/include/tensorflow/lite"
    find "${src}/tensorflow/lite" \( -name "*.h" -o -name "*.fbs" \) \
        | while read -r f; do
            rel="${f#${src}/tensorflow/lite/}"
            install -Dm644 "$f" "${STAGING_DIR}/include/tensorflow/lite/${rel}"
        done

    # Additional static libs → tflite_2.12/ preserving CMake subdirectory structure.
    # The edgeai_dl_inferer.pc references paths like -L/usr/lib/tflite_2.12/ruy-build,
    # -L/usr/lib/tflite_2.12/xnnpack-build, etc., matching the Yocto install layout
    # where each CMake _deps/*-build/ tree maps to tflite_2.12/<dep-name>/.
    mkdir -p "${STAGING_DIR}/lib/tflite_2.12"

    # Iterate over each _deps/*-build directory, preserving its internal tree.
    for dep_dir in "${build}/_deps/"*-build; do
        [[ -d "${dep_dir}" ]] || continue
        local dep_name
        dep_name="$(basename "${dep_dir}")"
        local dest="${STAGING_DIR}/lib/tflite_2.12/${dep_name}"
        mkdir -p "${dest}"
        find "${dep_dir}" -name "*.a" 2>/dev/null | while IFS= read -r f; do
            rel="${f#${dep_dir}/}"
            install -Dm644 "${f}" "${dest}/${rel}"
        done
        # ruy-build: CMake places its .a files in a ruy/ subdirectory, but Yocto
        # (and edgeai_dl_inferer.pc) expects them flat in ruy-build/.
        # Promote ruy/libruy_*.a to ruy-build/ top level.
        if [[ "${dep_name}" == "ruy-build" ]]; then
            find "${dep_dir}/ruy" -maxdepth 1 -name "*.a" 2>/dev/null \
                | while IFS= read -r f; do
                    cp -n "${f}" "${dest}/" 2>/dev/null || true
                done
        fi
    done

    # pthreadpool is a top-level CMake build dir (not inside _deps/).
    mkdir -p "${STAGING_DIR}/lib/tflite_2.12/pthreadpool"
    find "${build}/pthreadpool" -maxdepth 1 -name "*.a" 2>/dev/null \
        | while IFS= read -r f; do
            cp "${f}" "${STAGING_DIR}/lib/tflite_2.12/pthreadpool/" 2>/dev/null || true
        done

    info "  tflite_2.12/ contains $(find "${STAGING_DIR}/lib/tflite_2.12" -name "*.a" | wc -l) .a files"
}

_stage_onnxrt_prebuilt() {
    info "  Staging ONNX Runtime C++ artifacts from prebuilt tarball..."
    local tmp="${STAGING_DIR}/tmp/ort_lib"
    mkdir -p "${tmp}"
    tar -xzf "${DOWNLOAD_DIR}/onnx_1.15.0_aragoj7.tar.gz" -C "${tmp}"
    # Flatten the single top-level directory
    local top
    top=$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -1)
    [[ -n "$top" ]] && { mv "${top}"/* "${tmp}/"; rmdir "${top}"; }
    cp "${tmp}/libonnxruntime.so.1.15.0" "${STAGING_DIR}/lib/"
    ln -sf "libonnxruntime.so.1.15.0" "${STAGING_DIR}/lib/libonnxruntime.so"
    rm -rf "${tmp}/onnxruntime/csharp" 2>/dev/null || true
    # Install headers at the Yocto-compatible path:
    # usr/include/onnxruntime/include/onnxruntime/core/session/...
    # (matching the layout expected by edgeai-dl-inferer CMake:
    #  ONNXRT_INSTALL_DIR=${FS}/usr/include/onnxruntime → include/onnxruntime)
    mkdir -p "${STAGING_DIR}/include/onnxruntime/include"
    cp -r "${tmp}/onnxruntime" "${STAGING_DIR}/include/onnxruntime/include/"
}

_stage_onnxrt_source() {
    info "  Staging ONNX Runtime C++ artifacts from source build..."
    local src="${SRC_DIR}/onnxruntime"

    # Shared library: check ARTIFACTS_DIR first (normal path after build_onnxrt),
    # then Release/ directly (fallback when --skip-source-build was used and
    # build_onnxrt never ran to copy the .so to artifacts/).
    local so
    so=$(find "${ARTIFACTS_DIR}" -name "libonnxruntime.so.*" | head -1)
    if [[ -z "${so}" ]]; then
        so=$(find "${BUILD_DIR}/onnxruntime/Release" -maxdepth 1 \
                  -name "libonnxruntime.so.*" 2>/dev/null | head -1)
    fi
    [[ -f "${so}" ]] || error "libonnxruntime.so.* not found in ${ARTIFACTS_DIR} or Release/"
    cp "${so}" "${STAGING_DIR}/lib/"
    local soname
    soname=$(basename "${so}")
    ln -sf "${soname}" "${STAGING_DIR}/lib/libonnxruntime.so"

    # Headers: staged at Yocto-compatible path
    # usr/include/onnxruntime/include/onnxruntime/core/session/...
    mkdir -p "${STAGING_DIR}/include/onnxruntime/include"
    if [[ -d "${src}/include/onnxruntime" ]]; then
        cp -r "${src}/include/onnxruntime" "${STAGING_DIR}/include/onnxruntime/include/"
    elif [[ -d "${src}/include" ]]; then
        find "${src}/include" -name "*.h" \
            | while read -r h; do
                rel="${h#${src}/include/}"
                install -Dm644 "$h" "${STAGING_DIR}/include/onnxruntime/include/${rel}"
            done
    else
        warn "ONNX RT headers not found in ${src}/include"
    fi
    rm -rf "${STAGING_DIR}/include/onnxruntime/include/onnxruntime/csharp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 8: Build .deb packages
# ---------------------------------------------------------------------------
package_debs() {
    info "=== Packaging .deb files ==="
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
    ls -lh "${SCRIPT_DIR}/../"ti-tidl-osrt*.deb 2>/dev/null \
        || info "  .deb files are in the parent directory"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Building ti-tidl-osrt ${PKG_VERSION}"
    if [[ "${PREBUILT_OSRT}" -eq 1 ]]; then
        info "Mode: --prebuilt-osrt (all from TI CDN)"
    else
        info "Mode: source build (TFLite + ONNX RT cross-compiled; tvm/tidlruntime from CDN)"
        info "  TFLite   SRCREV: ${SRCREV_TENSORFLOW:0:12}..."
        info "  ONNX RT  SRCREV: ${SRCREV_ONNXRUNTIME:0:12}..."
        info "  Cross prefix:    ${CROSS_PREFIX}"
    fi
    [[ -n "${SDK_PATH}" ]] && info "  arm-tidl SDK:    ${SDK_PATH} (SOC=${SOC})"
    echo ""

    check_deps

    if [[ "${SKIP_DOWNLOAD}" -eq 0 ]]; then
        download_cdn_artifacts
        [[ "${PREBUILT_OSRT}" -eq 1 ]] && download_prebuilt_osrt
    fi

    if [[ "${PREBUILT_OSRT}" -eq 0 ]] && [[ "${SKIP_SOURCE_BUILD}" -eq 0 ]]; then
        fetch_sources
        build_tflite_lib
        build_tflite_wheel
        prepare_onnxrt
        build_onnxrt
    fi

    [[ -n "${SDK_PATH}" ]] && build_arm_tidl

    stage_artifacts
    package_debs
}

main "$@"
