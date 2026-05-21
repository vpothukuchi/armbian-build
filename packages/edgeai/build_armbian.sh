#!/bin/bash
# build_armbian.sh — Full build sequence for TI EdgeAI + Armbian on j784s4-evm
#
# This script lives at packages/edgeai/build_armbian.sh inside the armbian-build
# repository.  It can be invoked from any working directory; it derives the repo
# root from its own path automatically (see "Self-locate" block below).
#
#   # From the repo root (most common):
#   bash packages/edgeai/build_armbian.sh [OPTIONS]
#
#   # From anywhere using an absolute path:
#   bash /mnt/DATA/UBUNTU/armbian-build/packages/edgeai/build_armbian.sh [OPTIONS]
#
# Build sequence:
#   B1) Armbian base image  — kernel, u-boot, firmware (no EdgeAI packages)
#   G1) ti-img-rogue-driver — pvrsrvkm.ko out-of-tree module; needs B1 kernel worktree
#   G2) ti-img-rogue-umlibs — pre-built arm64 userspace libs (GLES, Vulkan, OpenCL)
#   G3) ti-img-pvr-mesa-wsi — Mesa PowerVR WSI + lavapipe, cross-compiled from source
#   A1) ti-rpmsg-char       — autotools source build
#       ti-tidl-osrt        — TFLite + ONNX RT cross-compiled from source
#   A2) ti-vision-apps      — SDK source build; needs A1 rpmsg-char in sysroot
#   A3) ti-tidl             — arm-tidl delegates; needs A1+A2 in sysroot
#   B2) Final Armbian image — compile.sh with ENABLE_EXTENSIONS=ti-debpkgs
#
# Rationale for this ordering:
#   B1 has no dependency on any EdgeAI package — it only builds kernel/u-boot.
#   G1 needs the kernel worktree produced by B1; G2/G3 are independent.
#   A1/A2/A3 have no dependency on B1 or GPU packages.
#   B1 is the slowest step (~60 min) so it runs first while nothing else blocks it.
#   A1 feeds into A2 (rpmsg-char headers overlaid into sysroot before vision-apps).
#   A2 feeds into A3 (vision-apps headers overlaid into sysroot before ti-tidl).
#   B2 consumes all outputs: B1 kernel/uboot + all EdgeAI + GPU .deb files.
#
# All EdgeAI and GPU .deb files are staged into output/debs/extra/ before B2.
#
# ============================================================================
# Build modes (--docker / --no-docker)
# ============================================================================
#
# --docker (default when Docker is available)
#   A1/A2/A3 are built inside the ti-edgeai-build Docker container.
#   The container carries a pre-built arm64 sysroot at /opt/arm64-sysroot.
#   Before A2, A1 .deb files are overlaid into the container sysroot.
#   Before A3, A1+A2 .deb files are overlaid into the container sysroot.
#   Host requirements: docker, git
#
# --no-docker   *** NOT TESTED end-to-end. Use --docker for production builds. ***
#   A1/A2/A3 are built directly on the host.
#   The host must have cross-compilation tools installed (see prerequisites below).
#   Built .deb files are overlaid into the host sysroot between phases.
#
# No-Docker host prerequisites:
#   sudo apt install \
#       gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
#       libc6-dev-arm64-cross \
#       debhelper devscripts dpkg-dev fakeroot \
#       automake autoconf libtool libtool-bin \
#       cmake ninja-build meson pkg-config \
#       python3-dev python3-pybind11 python3-numpy python3-pip \
#       make git curl ca-certificates
#   sudo dpkg --add-architecture arm64
#   sudo apt install libpython3.12-dev:arm64
#   pip3 install --user wheel flatbuffers
#
#   OE compat shim (required for A2 and A3):
#     sudo mkdir -p /opt/cross-oe/bin/aarch64-oe-linux
#     for t in gcc g++ cpp ar as ld nm ranlib strip objcopy objdump readelf \
#               addr2line size strings; do
#         sudo ln -sf /usr/bin/aarch64-linux-gnu-$t /opt/cross-oe/bin/aarch64-oe-linux-$t
#         sudo ln -sf /usr/bin/aarch64-linux-gnu-$t \
#             /opt/cross-oe/bin/aarch64-oe-linux/aarch64-oe-linux-$t
#     done
#     sudo ln -sf /opt/cross-oe/bin/aarch64-oe-linux-gcc \
#         /opt/cross-oe/bin/aarch64-oe-linux-cc
#     export PATH="/opt/cross-oe/bin:$PATH"
#
#   Arm64 sysroot for A2/A3 (create once, reuse across builds):
#     sudo mkdir -p /opt/arm64-sysroot/usr/{lib,include}
#     sudo cp -a /usr/lib/aarch64-linux-gnu    /opt/arm64-sysroot/usr/lib
#     sudo cp -a /usr/include/aarch64-linux-gnu /opt/arm64-sysroot/usr/include
#     sudo ln -sf usr/lib /opt/arm64-sysroot/lib
#     cd /tmp
#     sudo apt-get download \
#         libfreetype6:arm64 libfreetype-dev:arm64 \
#         libpam0g:arm64 libpam0g-dev:arm64 \
#         libglvnd0:arm64 libegl1:arm64 libegl-dev:arm64 \
#         libgles2:arm64 libgles-dev:arm64 libgl-dev:arm64 \
#         libgbm1:arm64 libgbm-dev:arm64 libdrm2:arm64 libdrm-dev:arm64 \
#         libglfw3:arm64 libglfw3-dev:arm64 libglew2.2:arm64 libglew-dev:arm64 \
#         libc6:arm64 libc6-dev:arm64 libstdc++6:arm64 libstdc++-13-dev:arm64
#     for f in /tmp/*.deb; do sudo dpkg-deb -x "$f" /opt/arm64-sysroot; rm "$f"; done
#     sudo chmod -R a+rwX /opt/arm64-sysroot
#     curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
#         | sudo tee /usr/local/bin/repo > /dev/null && sudo chmod +x /usr/local/bin/repo
#
# Usage examples:
#
#   *** FULL BUILD — single command (runs all phases): ***
#   # --sdk-path is a local workspace dir; repos are cloned there automatically on first run.
#   bash packages/edgeai/build_armbian.sh \
#       --sdk-path /mnt/DATA/UBUNTU/sdk_repos
#
#   # Skip B1 (kernel already built), rebuild EdgeAI packages + final image:
#   bash packages/edgeai/build_armbian.sh --skip-kernel --sdk-path /opt/ti-vision-apps-sdk
#
#   # Skip everything except final image (all debs already built):
#   bash packages/edgeai/build_armbian.sh --skip-kernel --skip-edgeai
#
#   # Clean all build artifacts (keeps ti-tidl-osrt downloads cache):
#   bash packages/edgeai/build_armbian.sh --clean
#
#   # Clean including the large ti-tidl-osrt download cache:
#   bash packages/edgeai/build_armbian.sh --clean --clean-downloads
#
#   # Full clean including Armbian rootfs + apt cache (forces complete image rebuild):
#   bash packages/edgeai/build_armbian.sh --clean --clean-downloads --clean-cache
#
#   # No-Docker build (UNTESTED):
#   bash packages/edgeai/build_armbian.sh --no-docker \
#                         --sysroot /opt/arm64-sysroot \
#                         --sdk-path /opt/ti-vision-apps-sdk
#
# Options:
#   --docker                Use Docker for EdgeAI builds (default if docker present)
#   --no-docker             Build EdgeAI packages directly on host (see prerequisites above)
#   --clean                 Remove all generated build artifacts, then exit
#   --clean-downloads       (with --clean) also delete ti-tidl-osrt download cache
#   --clean-cache           (with --clean) also delete Armbian rootfs + apt cache
#                           (forces full image rebuild; preserves cache/sources kernel tree)
#   --skip-kernel           Skip Armbian base image build (kernel + u-boot)
#   --skip-gpu              Skip all GPU package builds (G1/G2/G3)
#   --skip-edgeai           Skip all EdgeAI package builds (base-pkgs + vision-apps + tidl + fw)
#   --skip-base-pkgs        Skip ti-rpmsg-char + ti-tidl-osrt only
#   --skip-vision-apps      Skip ti-vision-apps only
#   --skip-tidl             Skip ti-tidl only
#   --skip-fw               Skip ti-adas-firmware only
#   --skip-image            Skip final Armbian image build
#   --mirror <path>         Local bare-clone git mirror directory
#   --no-cache              Force rebuild of the EdgeAI Docker image (Docker mode only)
#   --sdk-path <path>       Where to store the ti-vision-apps SDK source workspace.
#                           DO NOT clone anything manually — the build system does it:
#                             First run : repo init + repo sync into <path> (~15 min, ~2 GB).
#                             Later runs: <path>/sdk_builder/ already exists → sync skipped.
#                           Provide an empty directory (created automatically if absent),
#                           or an existing workspace from a previous build run.
#   --fw-dir <path>         Prebuilt firmware directory containing *.out / *.out.signed files
#                           for ti-adas-firmware.  The *.out.signed files are NOT in psdk_fw.git
#                           (they are generated by Yocto secure-binary-image.sh).  Pass the
#                           Yocto staging dir, e.g.:
#                             .../ti-adas-firmware/1.0.0/package/usr/lib/firmware/vision_apps_evm
#   --sysroot <path>        Arm64 target sysroot override.
#                           Docker mode: optional (uses /opt/arm64-sysroot internally).
#                           No-Docker mode: required for vision-apps and tidl; must be WRITABLE.

set -euo pipefail

# ---------------------------------------------------------------------------
# Self-locate: this script lives at packages/edgeai/build_armbian.sh inside
# the armbian-build repository.  Derive the repo root from the script's own
# path so the caller can invoke it from any working directory without needing
# to cd first.  All subsequent relative paths (./compile.sh, ./packages/edgeai/,
# ./output/) resolve correctly once we cd to ARMBIAN_ROOT.
#
# The layout is: <ARMBIAN_ROOT>/packages/edgeai/build_armbian.sh
# so ARMBIAN_ROOT is exactly two levels above the script.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARMBIAN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ARMBIAN_ROOT}"

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# build_armbian.sh/,/^[^#]/{ /^[^#]/d; s/^# \{0,1\}//; p }' "$0"
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
USE_DOCKER=""
CLEAN=0
CLEAN_DOWNLOADS=0
CLEAN_CACHE=0
SKIP_KERNEL=0
SKIP_GPU=0
SKIP_EDGEAI=0
SKIP_BASE_PKGS=0
SKIP_VISION_APPS=0
SKIP_TIDL=0
SKIP_FW=0
SKIP_EDGEAI_PKGS=0
SKIP_IMAGE=0
MIRROR_DIR=""
NO_CACHE=""
SDK_PATH=""
FW_DIR=""
SYSROOT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)          usage ;;
        --docker)           USE_DOCKER=1;           shift ;;
        --no-docker)        USE_DOCKER=0;           shift ;;
        --clean)            CLEAN=1;                shift ;;
        --clean-downloads)  CLEAN_DOWNLOADS=1;      shift ;;
        --clean-cache)      CLEAN_CACHE=1;          shift ;;
        --skip-kernel)      SKIP_KERNEL=1;          shift ;;
        --skip-gpu)         SKIP_GPU=1;             shift ;;
        --skip-edgeai)      SKIP_EDGEAI=1;          shift ;;
        --skip-base-pkgs)   SKIP_BASE_PKGS=1;       shift ;;
        --skip-vision-apps) SKIP_VISION_APPS=1;     shift ;;
        --skip-tidl)        SKIP_TIDL=1;            shift ;;
        --skip-fw)          SKIP_FW=1;              shift ;;
        --skip-edgeai-pkgs) SKIP_EDGEAI_PKGS=1;     shift ;;
        --skip-image)       SKIP_IMAGE=1;           shift ;;
        --mirror)           MIRROR_DIR="$2";        shift 2 ;;
        --no-cache)         NO_CACHE="--no-cache";  shift ;;
        --sdk-path)         SDK_PATH="$2";          shift 2 ;;
        --fw-dir)           FW_DIR="$2";            shift 2 ;;
        --sysroot)          SYSROOT_OVERRIDE="$2";  shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --skip-edgeai sets all A-phase skips including firmware and E-phase packages
if [[ "${SKIP_EDGEAI}" -eq 1 ]]; then
    SKIP_BASE_PKGS=1; SKIP_VISION_APPS=1; SKIP_TIDL=1; SKIP_FW=1; SKIP_EDGEAI_PKGS=1
fi

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
do_clean() {
    phase "=== Cleaning build artifacts ==="
    local pkg_dir="./packages/edgeai"

    echo "  ti-rpmsg-char ..."
    rm -rf  "${pkg_dir}/ti-rpmsg-char/src" \
            "${pkg_dir}/ti-rpmsg-char/staging" \
            "${pkg_dir}/ti-rpmsg-char/staging-src" \
            "${pkg_dir}/ti-rpmsg-char/build-from-source.log"

    echo "  ti-tidl-osrt ..."
    rm -rf  "${pkg_dir}/ti-tidl-osrt/build" \
            "${pkg_dir}/ti-tidl-osrt/staging" \
            "${pkg_dir}/ti-tidl-osrt/build.log"
    if [[ "${CLEAN_DOWNLOADS}" -eq 1 ]]; then
        echo "  ti-tidl-osrt/downloads (--clean-downloads) ..."
        rm -rf "${pkg_dir}/ti-tidl-osrt/downloads"
    fi

    echo "  ti-vision-apps ..."
    rm -rf  "${pkg_dir}/ti-vision-apps/staging" \
            "${pkg_dir}/ti-vision-apps/staging-src" \
            "${pkg_dir}/ti-vision-apps/build-from-source.log"
    # Note: dev and runtime are committed symlinks (→ staging/dev, staging/runtime);
    # they are not deleted — removing staging/ above already clears their targets.

    echo "  ti-tidl ..."
    rm -rf  "${pkg_dir}/ti-tidl/src" \
            "${pkg_dir}/ti-tidl/staging" \
            "${pkg_dir}/ti-tidl/build-from-source.log"

    echo "  ti-adas-firmware ..."
    rm -rf  "${pkg_dir}/ti-adas-firmware/src" \
            "${pkg_dir}/ti-adas-firmware/staging" \
            "${pkg_dir}/ti-adas-firmware/build-from-source.log"

    echo "  edgeai-apps-utils ..."
    rm -rf  "${pkg_dir}/edgeai-apps-utils/src" \
            "${pkg_dir}/edgeai-apps-utils/staging" \
            "${pkg_dir}/edgeai-apps-utils/build-from-source.log"

    echo "  edgeai-tiovx-kernels ..."
    rm -rf  "${pkg_dir}/edgeai-tiovx-kernels/src" \
            "${pkg_dir}/edgeai-tiovx-kernels/staging" \
            "${pkg_dir}/edgeai-tiovx-kernels/build-from-source.log"

    echo "  edgeai-dl-inferer ..."
    rm -rf  "${pkg_dir}/edgeai-dl-inferer/src" \
            "${pkg_dir}/edgeai-dl-inferer/staging" \
            "${pkg_dir}/edgeai-dl-inferer/build-from-source.log"

    echo "  EdgeAI .deb files ..."
    rm -f "${pkg_dir}"/*.deb

    echo "  GPU packages ..."
    rm -rf  "./packages/gpu/ti-img-rogue-driver/src" \
            "./packages/gpu/ti-img-rogue-driver/build-from-source.log"
    rm -f   "./packages/gpu/ti-img-rogue-driver"/*.deb
    rm -f   "./packages/gpu/ti-img-rogue-umlibs"/*.deb
    rm -rf  "./packages/gpu/mesa-pvr/build" \
            "./packages/gpu/mesa-pvr/staging"
    rm -f   "./packages/gpu/mesa-pvr"/*.deb

    echo "  Armbian output artifacts ..."
    rm -rf  ./output/debs/extra \
            ./output/images \
            ./output/logs

    if [[ "${CLEAN_CACHE}" -eq 1 ]]; then
        echo "  Armbian rootfs + apt cache (--clean-cache) ..."
        # These subdirs are created inside Docker containers and are root-owned;
        # sudo is required.  If sudo is unavailable (e.g. non-interactive CI),
        # print a warning and continue — the user can clear them manually with:
        #   sudo rm -rf cache/rootfs cache/aptcache cache/ccache cache/memoize
        if sudo rm -rf ./cache/rootfs \
                        ./cache/aptcache \
                        ./cache/ccache \
                        ./cache/memoize; then
            echo "  Armbian rootfs + apt cache removed."
        else
            echo "  WARNING: sudo rm failed; cache/rootfs etc. may still exist." \
                 "Run manually: sudo rm -rf cache/rootfs cache/aptcache cache/ccache cache/memoize" >&2
        fi
    fi

    phase "=== Clean complete ==="
}

if [[ "${CLEAN}" -eq 1 ]]; then
    do_clean
    exit 0
fi

# ---------------------------------------------------------------------------
# Auto-detect Docker
# ---------------------------------------------------------------------------
if [[ -z "${USE_DOCKER}" ]]; then
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        USE_DOCKER=1
    else
        USE_DOCKER=0
    fi
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ -x "./compile.sh" ]] || {
    echo "ERROR: armbian-build root not found (expected compile.sh in ${ARMBIAN_ROOT})" >&2; exit 1
}

DOCKER_BUILD="./packages/edgeai/docker-build.sh"
[[ "${USE_DOCKER}" -eq 0 || -x "${DOCKER_BUILD}" ]] || {
    echo "ERROR: not found or not executable: ${DOCKER_BUILD}" >&2; exit 1
}

# vision-apps requires --sdk-path
if [[ "${SKIP_VISION_APPS}" -eq 0 && -z "${SDK_PATH}" ]]; then
    echo "[WARN] --sdk-path not provided — skipping A2 (ti-vision-apps) and A3 (ti-tidl)."
    SKIP_VISION_APPS=1; SKIP_TIDL=1
fi

# Ensure SDK_PATH exists and is writable BEFORE Docker bind-mounts it.
# If Docker creates the directory it does so as root, causing "Permission denied" inside the container.
if [[ -n "${SDK_PATH}" && "${SKIP_VISION_APPS}" -eq 0 ]]; then
    mkdir -p "${SDK_PATH}"
    if [[ ! -w "${SDK_PATH}" ]]; then
        echo "ERROR: --sdk-path ${SDK_PATH} is not writable by $(whoami)." >&2
        echo "       Fix with: sudo chown $(whoami):$(whoami) ${SDK_PATH}" >&2
        exit 1
    fi
fi

# ti-tidl depends on vision-apps
if [[ "${SKIP_TIDL}" -eq 0 && "${SKIP_VISION_APPS}" -eq 1 ]]; then
    echo "[WARN] A2 is skipped — automatically skipping A3 (ti-tidl)."
    SKIP_TIDL=1
fi

# No-Docker: validate sysroot and tools
if [[ "${USE_DOCKER}" -eq 0 ]]; then
    echo "[WARN] *** No-Docker mode has NOT been tested end-to-end. ***"
    missing=()
    for cmd in aarch64-linux-gnu-gcc dh dpkg-buildpackage fakeroot cmake; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if [[ "${SKIP_VISION_APPS}" -eq 0 || "${SKIP_TIDL}" -eq 0 ]]; then
        [[ -x /opt/cross-oe/bin/aarch64-oe-linux-gcc ]] || \
            missing+=("/opt/cross-oe/bin/aarch64-oe-linux-gcc (OE compat shim)")
        [[ -n "${SYSROOT_OVERRIDE}" ]] || {
            echo "ERROR: --sysroot is required in --no-docker mode for A2/A3." >&2; exit 1
        }
        [[ -d "${SYSROOT_OVERRIDE}" && -w "${SYSROOT_OVERRIDE}" ]] || {
            echo "ERROR: sysroot must exist and be writable: ${SYSROOT_OVERRIDE}" >&2; exit 1
        }
    fi
    [[ ${#missing[@]} -eq 0 ]] || {
        echo "ERROR: Missing host tools: ${missing[*]}" >&2; exit 1
    }
fi

SYSROOT="${SYSROOT_OVERRIDE:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
base_docker_args() {
    local -a args=()
    [[ -n "${MIRROR_DIR}" ]] && args+=(--mirror "${MIRROR_DIR}")
    [[ -n "${NO_CACHE}" ]]   && args+=("${NO_CACHE}")
    [[ -n "${FW_DIR}" ]]     && args+=(--fw-dir "${FW_DIR}")
    [[ ${#args[@]} -gt 0 ]] && printf '%s\n' "${args[@]}"
}

stage_debs() {
    echo ""
    echo "--- Staging EdgeAI + GPU .deb files for Armbian ---"
    mkdir -p ./output/debs/extra
    find ./packages/edgeai -maxdepth 1 -name "*.deb" -exec cp -v {} ./output/debs/extra/ \;
    find ./packages/gpu    -maxdepth 2 -name "*.deb" -exec cp -v {} ./output/debs/extra/ \;
    echo "Staged packages:"
    ls -lh ./output/debs/extra/*.deb 2>/dev/null || echo "  (none found)"
}

overlay_deb_into_sysroot() {
    local glob="$1" sysroot="$2"
    local deb_file
    deb_file=$(ls packages/edgeai/${glob} 2>/dev/null | sort -V | tail -1)
    if [[ -z "${deb_file}" ]]; then
        echo "[WARN] No deb found matching: packages/edgeai/${glob}" >&2
        return 1
    fi
    echo "[INFO] Overlaying $(basename "${deb_file}") into ${sysroot}"
    dpkg-deb -x "${deb_file}" "${sysroot}"
}

compile_armbian() {
    ./compile.sh build \
        BOARD=j784s4-evm \
        BRANCH=vendor \
        BUILD_MINIMAL=yes \
        KERNEL_CONFIGURE=no \
        RELEASE=noble \
        GIT_SKIP_SUBMODULES=yes \
        SKIP_ARMBIAN_REPO=yes \
        SHARE_LOG=yes \
        "$@"
}

# ---------------------------------------------------------------------------
# Phase marker — always includes a timestamp for parse_build_log.py
# ---------------------------------------------------------------------------
phase() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# Print planned sequence
# ---------------------------------------------------------------------------
echo ""
phase "=== Build sequence ==="
echo "  Mode: $([ "${USE_DOCKER}" -eq 1 ] && echo 'Docker' || echo 'No-Docker (UNTESTED)')"
[[ "${SKIP_KERNEL}" -eq 0 ]]        && echo "  B1) Armbian base image (kernel + u-boot)"
[[ "${SKIP_GPU}" -eq 0 ]]          && echo "  G1) ti-img-rogue-driver (pvrsrvkm.ko)"
[[ "${SKIP_GPU}" -eq 0 ]]          && echo "  G2) ti-img-rogue-umlibs (GLES/Vulkan/OpenCL)"
[[ "${SKIP_GPU}" -eq 0 ]]          && echo "  G3) ti-img-pvr-mesa-wsi (Mesa WSI + lavapipe)"
[[ "${SKIP_BASE_PKGS}" -eq 0 ]]    && echo "  A1) ti-rpmsg-char + ti-tidl-osrt"
[[ "${SKIP_VISION_APPS}" -eq 0 ]]  && echo "  A2) ti-vision-apps"
[[ "${SKIP_TIDL}" -eq 0 ]]         && echo "  A3) ti-tidl"
[[ "${SKIP_FW}" -eq 0 ]]           && echo "  FW) ti-adas-firmware"
[[ "${SKIP_EDGEAI_PKGS}" -eq 0 ]]  && echo "  E1) edgeai-apps-utils"
[[ "${SKIP_EDGEAI_PKGS}" -eq 0 ]]  && echo "  E2) edgeai-tiovx-kernels"
[[ "${SKIP_IMAGE}" -eq 0 ]]        && echo "  B2) Final Armbian image (all EdgeAI + GPU debs)"
[[ -n "${MIRROR_DIR}" ]]    && echo "  Mirror:      ${MIRROR_DIR}"
[[ -n "${SDK_PATH}" ]]      && echo "  SDK:         ${SDK_PATH}"
[[ -n "${FW_DIR}" ]]        && echo "  FW dir:      ${FW_DIR}"
[[ -n "${SYSROOT}" ]]       && echo "  Sysroot:     ${SYSROOT}"
echo ""

# ---------------------------------------------------------------------------
# B1 — Armbian base image (kernel + u-boot; no EdgeAI packages)
# ---------------------------------------------------------------------------
if [[ "${SKIP_KERNEL}" -eq 0 ]]; then
    echo ""
    phase "=== B1: Armbian base image ==="
    compile_armbian
fi

# ---------------------------------------------------------------------------
# G1 — ti-img-rogue-driver (pvrsrvkm.ko)
# G2 — ti-img-rogue-umlibs (pre-built arm64 userspace libs)
# G3 — ti-img-pvr-mesa-wsi (Mesa PowerVR WSI + lavapipe, cross-compiled from source)
#
# G1 requires the kernel worktree produced by B1. G2 and G3 are independent.
# All three require Docker (no host cross-compile path for GPU packages).
# ---------------------------------------------------------------------------
if [[ "${SKIP_GPU}" -eq 0 ]]; then
    if [[ "${USE_DOCKER}" -eq 0 ]]; then
        echo "[WARN] GPU package builds require Docker — skipping G1/G2/G3 in no-docker mode."
    else
        echo ""
        phase "=== G1: ti-img-rogue-driver ==="
        KERNEL_WORKTREE=$(ls -d \
            "${ARMBIAN_ROOT}/cache/sources/linux-kernel-worktree/"*__k3__arm64 \
            2>/dev/null | head -1 || true)
        if [[ -z "${KERNEL_WORKTREE}" ]]; then
            echo "[WARN] Kernel worktree not found under cache/sources/linux-kernel-worktree/"
            echo "       Run B1 first (remove --skip-kernel) to produce the worktree."
            echo "       Skipping G1 (ti-img-rogue-driver)."
        else
            echo "[INFO] Using kernel worktree: ${KERNEL_WORKTREE}"
            docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
                -v "${ARMBIAN_ROOT}/packages/gpu/ti-img-rogue-driver:/workspace" \
                -v "${KERNEL_WORKTREE}:/kernel:ro" \
                ti-edgeai-build:noble \
                bash -c "cd /workspace && ./build-from-source.sh --kernel-dir /kernel"
        fi

        echo ""
        phase "=== G2: ti-img-rogue-umlibs ==="
        docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
            -v "${ARMBIAN_ROOT}/packages/gpu/ti-img-rogue-umlibs:/workspace" \
            ti-edgeai-build:noble \
            bash -c "cd /workspace && ./build-from-source.sh"

        echo ""
        phase "=== G3: ti-img-pvr-mesa-wsi ==="
        docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
            -v "${ARMBIAN_ROOT}/packages/gpu/mesa-pvr:/workspace" \
            ti-edgeai-build:noble \
            bash -c "cd /workspace && ./build-from-source.sh"
    fi
fi

# ---------------------------------------------------------------------------
# A1 — ti-rpmsg-char + ti-tidl-osrt
# ---------------------------------------------------------------------------
if [[ "${SKIP_BASE_PKGS}" -eq 0 ]]; then
    echo ""
    phase "=== A1: ti-rpmsg-char + ti-tidl-osrt ==="

    if [[ "${USE_DOCKER}" -eq 1 ]]; then
        DOCKER_ARGS=()
        readarray -t DOCKER_ARGS < <(base_docker_args)
        bash "${DOCKER_BUILD}" "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}" ti-rpmsg-char
        bash "${DOCKER_BUILD}" "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}" ti-tidl-osrt
    else
        rpmsg_args=()
        [[ -n "${MIRROR_DIR}" ]] && \
            rpmsg_args+=(--git-mirror "${MIRROR_DIR}/git.ti.com.git.rpmsg.ti-rpmsg-char.git")
        (cd packages/edgeai/ti-rpmsg-char && ./build-from-source.sh "${rpmsg_args[@]+"${rpmsg_args[@]}"}")

        osrt_args=()
        [[ -n "${MIRROR_DIR}" ]] && osrt_args+=(--mirror-dir "${MIRROR_DIR}")
        (cd packages/edgeai/ti-tidl-osrt && ./build-from-source.sh "${osrt_args[@]+"${osrt_args[@]}"}")
    fi
fi

# ---------------------------------------------------------------------------
# A2 — ti-vision-apps
# ---------------------------------------------------------------------------
if [[ "${SKIP_VISION_APPS}" -eq 0 ]]; then
    echo ""
    phase "=== A2: ti-vision-apps ==="

    if [[ "${USE_DOCKER}" -eq 1 ]]; then
        DOCKER_ARGS=()
        readarray -t DOCKER_ARGS < <(base_docker_args)
        [[ -n "${SYSROOT}" ]] && DOCKER_ARGS+=(--sysroot "${SYSROOT}")

        bash "${DOCKER_BUILD}" "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}" \
            --sdk-path "${SDK_PATH}" ti-vision-apps
    else
        echo "--- Overlaying A1 packages into sysroot ---"
        overlay_deb_into_sysroot "libti-rpmsg-char0_*.deb"    "${SYSROOT}"
        overlay_deb_into_sysroot "libti-rpmsg-char-dev_*.deb" "${SYSROOT}"

        va_args=(
            --sdk-path      "${SDK_PATH}"
            --toolchain-bin /opt/cross-oe/bin
            --sysroot       "${SYSROOT}"
        )
        [[ -n "${MIRROR_DIR}" ]] && va_args+=(--mirror "${MIRROR_DIR}")
        (cd packages/edgeai/ti-vision-apps && ./build-from-source.sh "${va_args[@]}")
    fi
fi

# ---------------------------------------------------------------------------
# A3 — ti-tidl (arm-tidl delegates)
# ---------------------------------------------------------------------------
if [[ "${SKIP_TIDL}" -eq 0 ]]; then
    echo ""
    phase "=== A3: ti-tidl ==="

    if [[ "${USE_DOCKER}" -eq 1 ]]; then
        DOCKER_ARGS=()
        readarray -t DOCKER_ARGS < <(base_docker_args)
        [[ -n "${SYSROOT}" ]] && DOCKER_ARGS+=(--sysroot "${SYSROOT}")
        bash "${DOCKER_BUILD}" "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}" ti-tidl
    else
        echo "--- Overlaying A1+A2 packages into sysroot ---"
        overlay_deb_into_sysroot "libti-rpmsg-char0_*.deb"      "${SYSROOT}"
        overlay_deb_into_sysroot "libti-rpmsg-char-dev_*.deb"   "${SYSROOT}"
        overlay_deb_into_sysroot "libtivision-apps11.2.0_*.deb" "${SYSROOT}"
        overlay_deb_into_sysroot "libtivision-apps-dev_*.deb"   "${SYSROOT}" || \
        overlay_deb_into_sysroot "ti-vision-apps-dev_*.deb"     "${SYSROOT}"

        tidl_args=(--sysroot "${SYSROOT}")
        [[ -n "${MIRROR_DIR}" ]] && tidl_args+=(--mirror "${MIRROR_DIR}")
        (cd packages/edgeai/ti-tidl && ./build-from-source.sh "${tidl_args[@]}")
    fi
fi

# ---------------------------------------------------------------------------
# FW — ti-adas-firmware (R5F MCU + C7x DSP RTOS firmware blobs)
# Independent of A1/A2/A3; no cross-compilation needed.
# ---------------------------------------------------------------------------
if [[ "${SKIP_FW}" -eq 0 ]]; then
    echo ""
    phase "=== FW: ti-adas-firmware ==="

    if [[ "${USE_DOCKER}" -eq 1 ]]; then
        DOCKER_ARGS=()
        readarray -t DOCKER_ARGS < <(base_docker_args)
        bash "${DOCKER_BUILD}" "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}" ti-adas-firmware
    else
        fw_args=()
        [[ -n "${FW_DIR}" ]] && fw_args+=(--prebuilt-fw-dir "${FW_DIR}")
        [[ -n "${MIRROR_DIR}" ]] && fw_args+=(--mirror "${MIRROR_DIR}")
        (cd packages/edgeai/ti-adas-firmware && ./build-from-source.sh "${fw_args[@]+"${fw_args[@]}"}")
    fi
fi

# ---------------------------------------------------------------------------
# E1 — edgeai-apps-utils
# E2 — edgeai-tiovx-kernels (depends on E1)
# Note: edgeai-dl-inferer is NOT built here; edgeai-robotics-sdk fetches and
# builds it from source via CPM at build time, so a pre-installed package
# provides no benefit.
# ---------------------------------------------------------------------------
if [[ "${SKIP_EDGEAI_PKGS}" -eq 0 ]]; then
    echo ""
    phase "=== E1: edgeai-apps-utils ==="

    if [[ "${USE_DOCKER}" -eq 1 ]]; then
        DOCKER_ARGS=()
        readarray -t DOCKER_ARGS < <(base_docker_args)
        bash "${DOCKER_BUILD}" "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}" edgeai-apps-utils
    else
        e1_args=(--sysroot "${SYSROOT:-/opt/arm64-sysroot}")
        [[ -n "${MIRROR_DIR}" ]] && e1_args+=(--mirror "${MIRROR_DIR}")
        (cd packages/edgeai/edgeai-apps-utils && ./build-from-source.sh "${e1_args[@]}")
    fi

    echo ""
    phase "=== E2: edgeai-tiovx-kernels ==="

    if [[ "${USE_DOCKER}" -eq 1 ]]; then
        DOCKER_ARGS=()
        readarray -t DOCKER_ARGS < <(base_docker_args)
        bash "${DOCKER_BUILD}" "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}" edgeai-tiovx-kernels
    else
        e2_args=(--sysroot "${SYSROOT:-/opt/arm64-sysroot}")
        [[ -n "${MIRROR_DIR}" ]] && e2_args+=(--mirror "${MIRROR_DIR}")

        echo "--- Overlaying E1 packages into sysroot ---"
        overlay_deb_into_sysroot "edgeai-apps-utils_*.deb"     "${SYSROOT:-/opt/arm64-sysroot}"
        overlay_deb_into_sysroot "edgeai-apps-utils-dev_*.deb" "${SYSROOT:-/opt/arm64-sysroot}"

        (cd packages/edgeai/edgeai-tiovx-kernels && ./build-from-source.sh "${e2_args[@]}")
    fi
fi

# ---------------------------------------------------------------------------
# B2 — Final Armbian image with all EdgeAI packages installed
# ---------------------------------------------------------------------------
if [[ "${SKIP_IMAGE}" -eq 0 ]]; then
    echo ""
    phase "=== B2: Final Armbian image (all EdgeAI debs) ==="
    stage_debs
    compile_armbian ENABLE_EXTENSIONS=ti-debpkgs
fi

echo ""
phase "=== Build complete ==="
echo "Output image : $(ls -t output/images/*.img 2>/dev/null | head -1 || echo '(none)')"
echo "Output debs  :"
ls -lh output/debs/extra/*.deb 2>/dev/null || echo "  (none)"
