#!/bin/bash
# build-from-source.sh — Build ti-vision-apps from source and package as .deb
#
# This script builds libtivision_apps.so from the TI SDK source repositories
# using the Arago cross-compiler and Yocto target sysroot.
#
# Prerequisites (all available in a PSDK Analytics Yocto build):
#   - Arago aarch64-oe-linux cross-compiler
#   - j784s4-evm target sysroot (libc, GLES, EGL, etc.)
#   - SDK source repos (cloned via `repo` from PSDK manifest)
#
# Source repos required (from vision_apps_yocto.xml manifest):
#   sdk_builder, tiovx, vision_apps, app_utils, imaging, video_io,
#   ti-perception-toolkit, psdk_include, concerto
#
# Usage: ./build-from-source.sh [OPTIONS]
#   --sdk-path       <path>  Root of cloned SDK repos (contains sdk_builder/)
#   --sysroot        <path>  Target sysroot for linking
#   --toolchain-bin  <path>  Directory containing aarch64-oe-linux-* tools
#   --soc            <soc>   Target SoC: j784s4|j722s|j721e|j721s2|am62a (default: j784s4)
#   --jobs           <N>     Parallel make jobs (default: $(nproc))
#   --skip-build             Skip compilation, use pre-existing build outputs
#
# Example:
#   ./build-from-source.sh \
#     --sdk-path      /path/to/psdk-analytics/repo \
#     --sysroot       /path/to/sysroots/j784s4-evm \
#     --toolchain-bin /path/to/sysroots/x86_64/usr/bin/aarch64-oe-linux

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SDK_PATH=""
SYSROOT=""
TOOLCHAIN_BIN=""
SOC="j784s4"
JOBS="$(nproc)"
SKIP_BUILD=0

PKG_VERSION="11.02.03"
DEB_REVISION="1"
SOVERSION="11.2.0"
PSDK_VERSION="11.2.0"

STAGING_DIR="${SCRIPT_DIR}/staging-src"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sdk-path)      SDK_PATH="$2";      shift 2 ;;
        --sysroot)       SYSROOT="$2";       shift 2 ;;
        --toolchain-bin) TOOLCHAIN_BIN="$2"; shift 2 ;;
        --soc)           SOC="$2";           shift 2 ;;
        --jobs)          JOBS="$2";          shift 2 ;;
        --skip-build)    SKIP_BUILD=1;       shift ;;
        --help)
            sed -n '/^# Usage:/,/^$/p' "$0"
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -n "${SDK_PATH}" ]]      || { echo "ERROR: --sdk-path is required" >&2; exit 1; }
[[ -n "${SYSROOT}" ]]       || { echo "ERROR: --sysroot is required" >&2; exit 1; }
[[ -n "${TOOLCHAIN_BIN}" ]] || { echo "ERROR: --toolchain-bin is required" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in make dpkg-buildpackage dh ar; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ -x "${TOOLCHAIN_BIN}/aarch64-oe-linux-gcc" ]] || \
        missing+=("aarch64-oe-linux-gcc (expected at ${TOOLCHAIN_BIN}/)")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing tools/components: ${missing[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Validate paths
# ---------------------------------------------------------------------------
validate_paths() {
    info "=== Validating source paths ==="
    [[ -d "${SDK_PATH}/sdk_builder" ]] || \
        error "SDK not found at: ${SDK_PATH}/sdk_builder"
    [[ -d "${SDK_PATH}/vision_apps" ]] || \
        error "vision_apps source not found at: ${SDK_PATH}/vision_apps"
    [[ -d "${SDK_PATH}/tiovx" ]] || \
        error "tiovx source not found at: ${SDK_PATH}/tiovx"
    [[ -d "${SYSROOT}/usr/lib" ]] || \
        error "Target sysroot not found at: ${SYSROOT}"
    [[ -x "${TOOLCHAIN_BIN}/aarch64-oe-linux-gcc" ]] || \
        error "Cross-compiler not found at: ${TOOLCHAIN_BIN}/aarch64-oe-linux-gcc"

    info "  SDK path:      ${SDK_PATH}"
    info "  Sysroot:       ${SYSROOT}"
    info "  Toolchain bin: ${TOOLCHAIN_BIN}"
    info "  SOC:           ${SOC}"
}

# ---------------------------------------------------------------------------
# Step 2: Cross-compile using the SDK builder's yocto_build target
#
# The yocto_build target builds ONLY the A72/Linux components:
#   app_utils, imaging, video_io, tiovx, tidl_tiovx_kernels, ptk,
#   tivision_apps, and vx_app_* binaries
#
# It does NOT build MCU/DSP firmware (which requires TI CGT tools).
# ---------------------------------------------------------------------------
build_from_source() {
    info "=== Building ti-vision-apps from source ==="
    info "  Using SDK builder yocto_build target (Linux A72 components only)"

    local CROSS_COMPILE="${TOOLCHAIN_BIN}/aarch64-oe-linux-"
    local GCC_FLAGS="--sysroot=${SYSROOT}"

    # Determine MPU_CPU based on SOC
    local MPU_CPU="A72"
    if [[ "${SOC}" == "am62a" ]]; then
        MPU_CPU="A53"
    fi

    # The SDK builder Makefile must be run from the sdk_builder directory.
    # PSDK_PATH must point to the parent of sdk_builder (i.e., SDK_PATH).
    cd "${SDK_PATH}/sdk_builder"

    # GCC_LINUX_ARM_ROOT must point to the toolchain parent (contains bin/aarch64-oe-linux/*)
    # CROSS_COMPILE_LINARO is the cross-compiler prefix relative to GCC_LINUX_ARM_ROOT/bin/
    # LINUX_SYSROOT_ARM is the target sysroot (used for --sysroot flag)
    # The SDK builder also looks for $(PSDK_PATH)/targetfs as include search path,
    # so we create a symlink: SDK_PATH/targetfs -> SYSROOT
    local GCC_LINUX_ARM_ROOT="${TOOLCHAIN_BIN%/bin/aarch64-oe-linux}"

    # Create targetfs symlink expected by build system
    ln -snf "${SYSROOT}" "${SDK_PATH}/targetfs"

    # Copy psdk_include to SDK_PATH root (COPYDIR step performed by yocto_build target)
    if [[ -d "${SDK_PATH}/psdk_include" ]]; then
        cp -rn "${SDK_PATH}/psdk_include/"* "${SDK_PATH}/" 2>/dev/null || true
    fi

    info "  GCC root:     ${GCC_LINUX_ARM_ROOT}"
    info "  Running SDK builder yocto_build steps SOC=${SOC}..."

    # Run each build step individually with the correct variables
    # (Matches YOCTO_VARS in makefile_linux_arm.mak — target names are SDK-internal)
    local MAKE_VARS=(
        SOC="${SOC}"
        PSDK_PATH="${SDK_PATH}"
        PROFILE=release
        BUILD_EMULATION_MODE=no
        TARGET_CPU="${MPU_CPU}"
        TARGET_OS=LINUX
        TIDL_PATH="${SDK_PATH}/tidl_j7"
        GCC_LINUX_ARM_ROOT="${GCC_LINUX_ARM_ROOT}"
        LINUX_SYSROOT_ARM="${SYSROOT}"
        TREAT_WARNINGS_AS_ERROR=0
    )

    make -j"${JOBS}" "${MAKE_VARS[@]}" app_utils    2>&1 | tee    "${SCRIPT_DIR}/build-from-source.log"
    make -j"${JOBS}" "${MAKE_VARS[@]}" imaging      2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    make -j"${JOBS}" "${MAKE_VARS[@]}" video_io     2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    make -j"${JOBS}" "${MAKE_VARS[@]}" tiovx        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    make -j"${JOBS}" "${MAKE_VARS[@]}" tidl_tiovx_kernels 2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    make -j"${JOBS}" "${MAKE_VARS[@]}" ptk          2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"
    make -j"${JOBS}" "${MAKE_VARS[@]}" -C "${SDK_PATH}/vision_apps" tivision_apps \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    info "=== Build complete ==="
    cd "${SCRIPT_DIR}"
}

# ---------------------------------------------------------------------------
# Step 3: Run SDK yocto_install target to stage build outputs
# ---------------------------------------------------------------------------
install_from_source() {
    info "=== Staging build outputs ==="

    local MPU_CPU="A72"
    [[ "${SOC}" == "am62a" ]] && MPU_CPU="A53"
    local GCC_LINUX_ARM_ROOT="${TOOLCHAIN_BIN%/bin/aarch64-oe-linux}"

    local STAGE_PATH="${STAGING_DIR}/rootfs"
    rm -rf "${STAGE_PATH}"
    mkdir -p "${STAGE_PATH}"

    cd "${SDK_PATH}/sdk_builder"
    # yocto_install is the SDK-internal target (linux_fs_stage with YOCTO_STAGE=1)
    # Copies libtivision_apps.so and headers to LINUX_FS_STAGE_PATH
    LINUX_FS_STAGE_PATH="${STAGE_PATH}" \
    make yocto_install \
        SOC="${SOC}" \
        PSDK_PATH="${SDK_PATH}" \
        PROFILE=release \
        BUILD_EMULATION_MODE=no \
        TARGET_CPU="${MPU_CPU}" \
        TARGET_OS=LINUX \
        TIDL_PATH="${SDK_PATH}/tidl_j7" \
        GCC_LINUX_ARM_ROOT="${GCC_LINUX_ARM_ROOT}" \
        LINUX_SYSROOT_ARM="${SYSROOT}" \
        TREAT_WARNINGS_AS_ERROR=0 \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    cd "${SCRIPT_DIR}"
    info "Staged output in: ${STAGE_PATH}"
    find "${STAGE_PATH}" -name "*.so*" | sort
}

# ---------------------------------------------------------------------------
# Step 4: Package staged outputs into .deb
# ---------------------------------------------------------------------------
package_debs() {
    info "=== Packaging .deb from source-built artifacts ==="

    local STAGE_PATH="${STAGING_DIR}/rootfs"
    local LIB_SRC="${STAGE_PATH}/usr/lib"
    local INC_SRC="${STAGE_PATH}/usr/include/processor_sdk"
    local OPT_SRC="${STAGE_PATH}/opt"

    [[ -f "${LIB_SRC}/libtivision_apps.so.${SOVERSION}" ]] || \
        error "Build artifact not found: ${LIB_SRC}/libtivision_apps.so.${SOVERSION}"

    # Create staging structure compatible with debian/rules
    rm -rf "${SCRIPT_DIR}/staging"
    mkdir -p "${SCRIPT_DIR}/staging/runtime/usr/lib"
    mkdir -p "${SCRIPT_DIR}/staging/dev/usr/include"

    # Runtime
    cp "${LIB_SRC}/libtivision_apps.so.${SOVERSION}" \
       "${SCRIPT_DIR}/staging/runtime/usr/lib/"

    # opt/ data (imaging, vision_apps binaries)
    if [[ -d "${OPT_SRC}" ]]; then
        cp -a "${OPT_SRC}" "${SCRIPT_DIR}/staging/runtime/"
    fi

    # Dev headers
    if [[ -d "${INC_SRC}" ]]; then
        cp -a "${INC_SRC}" "${SCRIPT_DIR}/staging/dev/usr/include/"
    fi

    ln -snf "${SCRIPT_DIR}/staging" "${SCRIPT_DIR}/staging"

    info "  Running dpkg-buildpackage..."
    dpkg-buildpackage \
        --build=binary \
        --no-sign \
        --host-arch=arm64 \
        -d \
        2>&1 | tee -a "${SCRIPT_DIR}/build-from-source.log"

    info "=== Source-built packages ==="
    ls -lh "${SCRIPT_DIR}/../"*tivision*.deb 2>/dev/null || \
    ls -lh "${SCRIPT_DIR}/../"ti-vision-apps*.deb 2>/dev/null || \
        info "  .deb files in parent directory"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    info "Building ti-vision-apps ${PKG_VERSION} from source"
    info "SOC: ${SOC}"
    info ""

    check_deps
    validate_paths

    if [[ "${SKIP_BUILD}" -eq 0 ]]; then
        build_from_source
    else
        info "Skipping compilation (--skip-build)"
    fi

    # Always run install to populate staging-src/rootfs from build outputs
    if [[ -d "${STAGING_DIR}/rootfs" ]] && [[ "${SKIP_BUILD}" -eq 1 ]]; then
        info "Re-using existing staged outputs at ${STAGING_DIR}/rootfs"
        info "  Delete ${STAGING_DIR}/rootfs to force re-stage"
    else
        install_from_source
    fi

    package_debs
}

main "$@"
