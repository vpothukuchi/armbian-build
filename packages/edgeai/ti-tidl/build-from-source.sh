#!/bin/bash
# build-from-source.sh — Build ti-tidl arm-tidl delegate libraries from source.
#
# Upstream:  git.ti.com/git/processor-sdk-vision/arm-tidl.git
# Reference: meta-edgeai/recipes-tisdk/ti-tidl/ti-tidl.bb
#
# SRCREVs (from ti-tidl.bb for PSDK Analytics 11.02.x):
#   arm-tidl:    81fefa6907b933230f7ef62710a5e9440487f628  (branch master)
#   concerto:    f5541b85b9973ca47680d1a6d970bf61a126daa8  (branch main)
#   onnxruntime: 5816ccce5bb4b9b8ce1869bdda397257a8d2028a  (TI fork, branch tidl-1.15)
#   tensorflow:  422156a973b23bab6b86176a245a66193dccb995  (TI fork, branch tidl-j7-2.12)
#   protobuf:    f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c  (branch main)
#
# Builds 4 TIDL delegate shared libraries:
#   libvx_tidl_rt.so.1.0
#   libtidl_tfl_delegate.so.1.0
#   libtidl_onnxrt_EP.so.1.0
#   libtidlrt_EP.so.1.0
#
# Prerequisites (cross-compilation in Docker or bare metal):
#   - aarch64-oe-linux-* cross-compiler on PATH
#     (Docker OE shim or native OE toolchain)
#   - debhelper, devscripts, dpkg-dev
#   - make, git
#   - Target sysroot containing:
#     * ti-vision-apps dev headers:
#         /usr/include/processor_sdk/{ivision,tiovx,vision_apps,app_utils,tidl_j7}
#     * Shared libs for linking:
#         /usr/lib/libtivision_apps.so
#         /usr/lib/libti_rpmsg_char.so
#     * Standard aarch64 libc/sysroot (for --sysroot cross-link)
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --sysroot    <path>    Path to aarch64 target sysroot (REQUIRED).
#                          Must contain ti-vision-apps headers + shared libs.
#   --target-soc <soc>     Target SoC identifier. (default: J784S4)
#                          Supported: J784S4, J721E, J721S2, J742S2, J722S, AM62A
#   --mirror     <dir>     Directory containing Yocto-style bare-clone git mirrors.
#                          Expected mirror basenames:
#                            git.ti.com.git.processor-sdk-vision.arm-tidl.git
#                            git.ti.com.git.processor-sdk.concerto.git
#                            github.com.TexasInstruments.onnxruntime
#                            github.com.TexasInstruments.tensorflow
#                            github.com.protocolbuffers.protobuf.git
#   --jobs       <N>       Parallel make jobs (default: nproc)
#   --skip-fetch           Re-use existing src/ checkouts; skip all git operations
#   --skip-build           Re-use existing build outputs; skip make
#
# Example (Docker, using local mirrors and vision-apps staging sysroot):
#   ./build-from-source.sh \
#     --sysroot /workspace/ti-vision-apps/staging-src/rootfs \
#     --mirror  /mirrors
#
# Example (bare metal):
#   ./build-from-source.sh \
#     --sysroot /path/to/armbian-rootfs-with-ti-packages

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Pinned SRCREVs (from ti-tidl.bb PSDK Analytics 11.02.x)
# ---------------------------------------------------------------------------
SRCREV_ARM_TIDL="81fefa6907b933230f7ef62710a5e9440487f628"
SRCREV_CONCERTO="f5541b85b9973ca47680d1a6d970bf61a126daa8"
SRCREV_ONNXRUNTIME="5816ccce5bb4b9b8ce1869bdda397257a8d2028a"
SRCREV_TENSORFLOW="422156a973b23bab6b86176a245a66193dccb995"
SRCREV_PROTOBUF="f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c"

# Remote URLs (fallback when no local mirror)
REMOTE_ARM_TIDL="https://git.ti.com/git/processor-sdk-vision/arm-tidl.git"
REMOTE_CONCERTO="https://git.ti.com/git/processor-sdk/concerto.git"
REMOTE_ONNXRUNTIME="https://github.com/TexasInstruments/onnxruntime.git"
REMOTE_TENSORFLOW="https://github.com/TexasInstruments/tensorflow.git"
REMOTE_PROTOBUF="https://github.com/protocolbuffers/protobuf.git"

# Mirror basenames (Yocto bitbake git fetcher naming convention)
MIRROR_BASENAME_ARM_TIDL="git.ti.com.git.processor-sdk-vision.arm-tidl.git"
MIRROR_BASENAME_CONCERTO="git.ti.com.git.processor-sdk.concerto.git"
MIRROR_BASENAME_ONNXRUNTIME="github.com.TexasInstruments.onnxruntime"
MIRROR_BASENAME_TENSORFLOW="github.com.TexasInstruments.tensorflow"
MIRROR_BASENAME_PROTOBUF="github.com.protocolbuffers.protobuf.git"

PKG_VERSION="1.0.0"
DEB_REVISION="1"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SYSROOT=""
TARGET_SOC="J784S4"
MIRROR_DIR=""
JOBS="$(nproc)"
SKIP_FETCH=0
SKIP_BUILD=0

SRC_DIR="${SCRIPT_DIR}/src"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sysroot)     SYSROOT="$2";    shift 2 ;;
        --target-soc)  TARGET_SOC="$2"; shift 2 ;;
        --mirror)      MIRROR_DIR="$2"; shift 2 ;;
        --jobs)        JOBS="$2";       shift 2 ;;
        --skip-fetch)  SKIP_FETCH=1;    shift ;;
        --skip-build)  SKIP_BUILD=1;    shift ;;
        --help)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
validate_inputs() {
    [[ -n "${SYSROOT}" ]] || error \
        "--sysroot is required. Pass the path to an aarch64 target sysroot
  that has ti-vision-apps headers and libtivision_apps.so + libti_rpmsg_char.so.

  Quick option: use the ti-vision-apps build staging directory:
    --sysroot /workspace/ti-vision-apps/staging-src/rootfs
  (after building ti-vision-apps and adding libti_rpmsg_char.so to it)"

    [[ -d "${SYSROOT}" ]] || error "Sysroot not found: ${SYSROOT}"

    # Validate key header paths exist in sysroot
    local sdk_headers="${SYSROOT}/usr/include/processor_sdk"
    for subdir in ivision tiovx vision_apps app_utils tidl_j7; do
        [[ -d "${sdk_headers}/${subdir}" ]] || \
            warn "Sysroot missing ${sdk_headers}/${subdir} — arm-tidl may fail to compile"
    done

    # Validate cross-compiler is available
    if ! command -v aarch64-oe-linux-gcc &>/dev/null; then
        error "aarch64-oe-linux-gcc not found on PATH.
  In Docker: the OE shim in /opt/cross-oe/bin should already be on PATH.
  Bare metal: install gcc-aarch64-linux-gnu and use the OE compat shim, or
              install an OE toolchain with aarch64-oe-linux-gcc."
    fi
}

# ---------------------------------------------------------------------------
# Map TARGET_SOC to output path components
#
# Concerto TARGET_COMBO for Linux ARM: <SOC>:LINUX:<CPU>:1:release:GCC_LINUX_ARM
# Output dir: out/<SOC>/<CPU>/LINUX/release/
# ---------------------------------------------------------------------------
soc_to_output_components() {
    local soc="${TARGET_SOC^^}"   # uppercase
    case "${soc}" in
        J784S4|J721S2|J721E|J742S2)  SOC_NAME="${soc}"; MPU_CPU="A72" ;;
        AM62A|J722S)                  SOC_NAME="${soc}"; MPU_CPU="A53" ;;
        *) error "Unsupported TARGET_SOC '${TARGET_SOC}'. Supported: J784S4 J721E J721S2 J742S2 J722S AM62A" ;;
    esac
    OUT_SUBDIR="${SOC_NAME}/${MPU_CPU}/LINUX/release"
    info "  Target SoC: ${SOC_NAME}, CPU: ${MPU_CPU}, output subdir: out/${OUT_SUBDIR}/"
}

# ---------------------------------------------------------------------------
# Step 1: Obtain sources
# ---------------------------------------------------------------------------
obtain_sources() {
    info "=== Fetching source repositories ==="
    mkdir -p "${SRC_DIR}"

    clone_or_update() {
        local dest_name="$1"
        local srcrev="$2"
        local mirror_basename="$3"
        local remote_url="$4"
        local dest="${SRC_DIR}/${dest_name}"

        if [[ -d "${dest}/.git" ]]; then
            info "  ${dest_name}: already present, checking out ${srcrev:0:10}..."
            git -C "${dest}" checkout "${srcrev}" -- 2>/dev/null || \
                git -C "${dest}" fetch --no-tags origin && git -C "${dest}" checkout "${srcrev}" --
            return
        fi

        local clone_src
        if [[ -n "${MIRROR_DIR}" && -d "${MIRROR_DIR}/${mirror_basename}" ]]; then
            info "  ${dest_name}: cloning from local mirror..."
            clone_src="${MIRROR_DIR}/${mirror_basename}"
        else
            info "  ${dest_name}: cloning from ${remote_url}..."
            clone_src="${remote_url}"
        fi

        git clone "${clone_src}" "${dest}"
        git -C "${dest}" checkout "${srcrev}" --
    }

    clone_or_update "arm-tidl"    "${SRCREV_ARM_TIDL}"    "${MIRROR_BASENAME_ARM_TIDL}"    "${REMOTE_ARM_TIDL}"
    clone_or_update "concerto"    "${SRCREV_CONCERTO}"    "${MIRROR_BASENAME_CONCERTO}"    "${REMOTE_CONCERTO}"
    clone_or_update "onnxruntime" "${SRCREV_ONNXRUNTIME}" "${MIRROR_BASENAME_ONNXRUNTIME}" "${REMOTE_ONNXRUNTIME}"
    clone_or_update "tensorflow"  "${SRCREV_TENSORFLOW}"  "${MIRROR_BASENAME_TENSORFLOW}"  "${REMOTE_TENSORFLOW}"
    clone_or_update "protobuf"    "${SRCREV_PROTOBUF}"    "${MIRROR_BASENAME_PROTOBUF}"    "${REMOTE_PROTOBUF}"

    info "Source repos ready:"
    for repo in arm-tidl concerto onnxruntime tensorflow protobuf; do
        echo "  ${SRC_DIR}/${repo}: $(git -C "${SRC_DIR}/${repo}" log -1 --oneline)"
    done
}

# ---------------------------------------------------------------------------
# Step 2: Build
#
# Mirrors exactly the do_compile in ti-tidl.bb:
#   PSDK_INSTALL_PATH=${WORKDIR}
#   GCC_LINUX_ARM_ROOT= (empty — use CROSS_COMPILE_LINARO from PATH)
#   CROSS_COMPILE_LINARO=aarch64-oe-linux-
#   LINUX_SYSROOT_ARM=${STAGING_DIR_TARGET}
#   ... (other paths set from staged sysroot and source checkouts)
# ---------------------------------------------------------------------------
build_arm_tidl() {
    info "=== Building arm-tidl delegates ==="
    info "  SoC: ${SOC_NAME}/${MPU_CPU}"
    info "  Sysroot: ${SYSROOT}"
    info "  Sources: ${SRC_DIR}"

    local sdk_inc="${SYSROOT}/usr/include/processor_sdk"
    local arm_tidl_src="${SRC_DIR}/arm-tidl"
    local log="${SCRIPT_DIR}/build-from-source.log"

    info "  Compiler: $(aarch64-oe-linux-gcc --version 2>&1 | head -1)"

    # Run make for all 4 targets (rt + 3 delegates).
    # make -C src/arm-tidl sets CWD to src/arm-tidl for the whole build.
    #
    # Key variable notes:
    #   TIDL_PATH: parent of arm-tidl source dir → arm-tidl/tiovx_kernels/include
    #              is found via sysroot's tidl_j7 staging path.
    #   GCC_LINUX_ARM_ROOT: empty → compiler invoked as $(CROSS_COMPILE_LINARO)gcc
    #   LINUX_SYSROOT_ARM: full aarch64 sysroot (for --sysroot linker flag)
    #   TREAT_WARNINGS_AS_ERROR=0: match Yocto recipe (avoids build failures on
    #                               new compiler versions)
    make \
        -C "${arm_tidl_src}" \
        -j"${JOBS}" \
        GCC_LINUX_ARM_ROOT="" \
        CROSS_COMPILE_LINARO="aarch64-oe-linux-" \
        TARGET_SOC="${TARGET_SOC}" \
        PSDK_INSTALL_PATH="${SRC_DIR}" \
        CONCERTO_ROOT="${SRC_DIR}/concerto" \
        TF_REPO_PATH="${SRC_DIR}/tensorflow" \
        ONNX_REPO_PATH="${SRC_DIR}/onnxruntime" \
        TIDL_PROTOBUF_PATH="${SRC_DIR}/protobuf" \
        TIDL_PATH="${sdk_inc}/tidl_j7" \
        LINUX_SYSROOT_ARM="${SYSROOT}" \
        LINUX_FS_PATH="${SYSROOT}" \
        IVISION_PATH="${sdk_inc}/ivision" \
        TIOVX_PATH="${sdk_inc}/tiovx" \
        VISION_APPS_PATH="${sdk_inc}/vision_apps" \
        APP_UTILS_PATH="${sdk_inc}/app_utils" \
        TREAT_WARNINGS_AS_ERROR=0 \
        2>&1 | tee "${log}"

    info "=== Build complete ==="
}

# ---------------------------------------------------------------------------
# Step 3: Verify outputs
# ---------------------------------------------------------------------------
verify_outputs() {
    info "=== Verifying build outputs ==="
    local arm_tidl_src="${SRC_DIR}/arm-tidl"
    local ok=1

    for delegate in rt tfl_delegate onnxrt_ep tidlrt_ep; do
        local lib
        case "${delegate}" in
            rt)          lib="libvx_tidl_rt.so.1.0" ;;
            tfl_delegate) lib="libtidl_tfl_delegate.so.1.0" ;;
            onnxrt_ep)   lib="libtidl_onnxrt_EP.so.1.0" ;;
            tidlrt_ep)   lib="libtidlrt_EP.so.1.0" ;;
        esac
        local path="${arm_tidl_src}/${delegate}/out/${OUT_SUBDIR}/${lib}"
        if [[ -f "${path}" ]]; then
            info "  OK: ${delegate}/${lib}"
        else
            warn "  MISSING: ${path}"
            ok=0
        fi
    done

    [[ "${ok}" -eq 1 ]] || error "Build verification failed — see ${SCRIPT_DIR}/build-from-source.log"
}

# ---------------------------------------------------------------------------
# Step 4: Stage outputs
#
# Mirrors do_install in ti-tidl.bb
# ---------------------------------------------------------------------------
stage_outputs() {
    info "=== Staging outputs ==="
    local arm_tidl_src="${SRC_DIR}/arm-tidl"
    local staging="${SCRIPT_DIR}/staging"

    rm -rf "${staging}"
    mkdir -p "${staging}/lib"
    mkdir -p "${staging}/include"
    mkdir -p "${staging}/opt/tidl_test"

    # Shared libraries + unversioned .so symlinks
    for entry in \
        "rt/libvx_tidl_rt.so.1.0" \
        "tfl_delegate/libtidl_tfl_delegate.so.1.0" \
        "onnxrt_ep/libtidl_onnxrt_EP.so.1.0" \
        "tidlrt_ep/libtidlrt_EP.so.1.0"; do

        local delegate="${entry%%/*}"
        local filename="${entry##*/}"
        local soname="${filename%.so.1.0}.so"
        local src="${arm_tidl_src}/${delegate}/out/${OUT_SUBDIR}/${filename}"

        cp "${src}" "${staging}/lib/${filename}"
        ln -sf "${filename}" "${staging}/lib/${soname}"
        info "  ${filename}"
    done

    # Public headers (from arm-tidl/rt/inc/)
    for hdr in itidl_rt.h itidl_io.h itvm_rt.h; do
        cp "${arm_tidl_src}/rt/inc/${hdr}" "${staging}/include/"
        info "  ${hdr}"
    done

    # Test binary
    local test_bin="${arm_tidl_src}/rt/out/${OUT_SUBDIR}/TI_DEVICE_armv8_test_dl_algo_host_rt.out"
    if [[ -f "${test_bin}" ]]; then
        cp "${test_bin}" "${staging}/opt/tidl_test/"
        info "  TI_DEVICE_armv8_test_dl_algo_host_rt.out"
    else
        warn "  Test binary not found (not fatal): ${test_bin}"
    fi

    info "Staged outputs:"
    find "${staging}" \( -name "*.so*" -o -name "*.h" -o -name "*.out" \) | sort
}

# ---------------------------------------------------------------------------
# Step 5: Package into .deb
# ---------------------------------------------------------------------------
package_debs() {
    info "=== Packaging .deb files ==="
    cd "${SCRIPT_DIR}"

    local current_ver
    current_ver=$(dpkg-parsechangelog -l "${SCRIPT_DIR}/debian/changelog" \
                  --show-field Version 2>/dev/null || echo "")
    info "  Package version: ${current_ver}"

    dpkg-buildpackage \
        --build=binary \
        --no-sign \
        --host-arch=arm64 \
        -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    info "=== Packages built ==="
    ls -lh "${SCRIPT_DIR}/../"ti-tidl*.deb 2>/dev/null || \
        info "  .deb files are in the parent directory"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Building ti-tidl arm-tidl delegates ${PKG_VERSION}"
    info ""

    validate_inputs
    soc_to_output_components

    if [[ "${SKIP_FETCH}" -eq 0 ]]; then
        obtain_sources
    else
        info "Skipping source fetch (--skip-fetch)"
        for repo in arm-tidl concerto onnxruntime tensorflow protobuf; do
            [[ -d "${SRC_DIR}/${repo}/.git" ]] || \
                error "Source directory missing: ${SRC_DIR}/${repo} (remove --skip-fetch to clone)"
        done
    fi

    if [[ "${SKIP_BUILD}" -eq 0 ]]; then
        build_arm_tidl
    else
        info "Skipping build (--skip-build)"
    fi

    verify_outputs
    stage_outputs
    package_debs
}

main "$@"
