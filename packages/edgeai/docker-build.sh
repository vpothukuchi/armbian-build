#!/bin/bash
# docker-build.sh — Build TI EdgeAI .deb packages inside a Docker container.
#
# Isolates the build environment so the host system is not polluted with
# cross-compilation tools, Debian packaging utilities, or build artifacts.
# The only host requirements are Docker and the optional input paths below.
#
# Usage: ./docker-build.sh [OPTIONS] <PACKAGE|all>
#
# Packages:
#   ti-rpmsg-char    Build libti-rpmsg-char0 + dev from source (autotools)
#   ti-tidl-osrt     Cross-compile TFLite + ONNX RT from source; tvm/tidlruntime from CDN
#   ti-tidl          Build arm-tidl delegate .so libraries from source
#   ti-vision-apps   Build libtivision_apps.so from SDK source repos
#   all              Build all of the above (skips ti-vision-apps and ti-tidl
#                    if their required options are not provided)
#
# Options:
#   --mirror   <path>   Host path to a bare-clone git mirror directory.
#                       Mounted read-only at /mirrors inside the container.
#                       ti-rpmsg-char looks for:
#                         /mirrors/git.ti.com.git.rpmsg.ti-rpmsg-char.git
#                       ti-tidl looks for 5 additional mirror repos (see
#                       ti-tidl/build-from-source.sh --help for names).
#   --sysroot  <path>   Host path to an aarch64 target sysroot.
#                       Mounted read-only at /sysroot inside the container.
#                       ti-rpmsg-char: optional (improves libc compat)
#                       ti-tidl: REQUIRED — must contain ti-vision-apps dev
#                         headers (/usr/include/processor_sdk/...) and shared
#                         libs (libtivision_apps.so, libti_rpmsg_char.so).
#                         Quick option: use the ti-vision-apps staging sysroot:
#                           --sysroot /path/to/edgeai/ti-vision-apps/staging-src/rootfs
#                       ti-vision-apps source build: required target rootfs
#   --sdk-path <path>   Host path for the SDK source tree.
#                       Mounted read-write at /sdk inside the container.
#                       On first run the SDK repos are cloned here automatically
#                       via repo sync (vision_apps_yocto.xml manifest).
#                       On subsequent runs the existing checkout is reused.
#                       Required for ti-vision-apps source build.
#   --ipk-dir  <path>   Host path to directory containing prebuilt .ipk files.
#                       Mounted read-only at /ipk inside the container.
#                       Used when --prebuilt is specified for ti-vision-apps.
#   --prebuilt          For ti-vision-apps: use build-deb.sh (prebuilt IPK)
#                       instead of build-from-source.sh.
#                       Requires --ipk-dir.
#   --no-cache          Force rebuild of the Docker image without cache.
#   --shell             Drop into a bash shell inside the build container.
#                       All volume mounts are applied. Useful for debugging.
#   --image-tag <tag>   Override Docker image tag (default: noble).
#
# Examples:
#
#   # ti-rpmsg-char — fully self-contained (clones from git.ti.com):
#   ./docker-build.sh ti-rpmsg-char
#
#   # ti-rpmsg-char — use local git mirror for faster/offline build:
#   ./docker-build.sh \
#     --mirror /path/to/yocto/downloads/git2 \
#     ti-rpmsg-char
#
#   # ti-tidl-osrt — cross-compile TFLite + ONNX RT from source (tvm/tidlruntime from CDN):
#   ./docker-build.sh ti-tidl-osrt
#
#   # ti-tidl-osrt with local git mirror (faster, offline-capable):
#   ./docker-build.sh \
#     --mirror /path/to/yocto/downloads/git2 \
#     ti-tidl-osrt
#
#   # ti-tidl-osrt — use prebuilt CDN wheels (--prebuilt-osrt fallback):
#   ./docker-build.sh --prebuilt ti-tidl-osrt
#
#   # ti-tidl — source build (needs mirrors + ti-vision-apps sysroot):
#   ./docker-build.sh \
#     --mirror  /path/to/yocto/downloads/git2 \
#     --sysroot /path/to/edgeai/ti-vision-apps/staging-src/rootfs \
#     ti-tidl
#
#   # ti-vision-apps — source build (SDK repos cloned automatically on first run):
#   ./docker-build.sh \
#     --sdk-path /path/to/sdk-dir \
#     --sysroot  /path/to/armbian/output/j784s4-rootfs \
#     ti-vision-apps
#
#   # ti-vision-apps — prebuilt IPK repackaging:
#   ./docker-build.sh \
#     --prebuilt \
#     --ipk-dir /path/to/ipk/aarch64 \
#     ti-vision-apps
#
#   # Build all packages (ti-vision-apps and ti-tidl skipped if deps not given):
#   ./docker-build.sh \
#     --mirror  /path/to/yocto/downloads/git2 \
#     --sysroot /path/to/edgeai/ti-vision-apps/staging-src/rootfs \
#     all
#
#   # Interactive shell in build container:
#   ./docker-build.sh --sysroot /path/to/sysroot --shell

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
IMAGE_NAME="ti-edgeai-build"
IMAGE_TAG="noble"

MIRROR_PATH=""
SYSROOT_PATH=""
SDK_PATH=""
IPK_DIR=""
NO_CACHE=""
DROP_SHELL=0
PREBUILT=0
TARGET=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mirror)    MIRROR_PATH="$2";  shift 2 ;;
        --sysroot)   SYSROOT_PATH="$2"; shift 2 ;;
        --sdk-path)  SDK_PATH="$2";     shift 2 ;;
        --ipk-dir)   IPK_DIR="$2";      shift 2 ;;
        --prebuilt)  PREBUILT=1;        shift ;;
        --no-cache)  NO_CACHE="--no-cache"; shift ;;
        --shell)     DROP_SHELL=1;      shift ;;
        --image-tag) IMAGE_TAG="$2";    shift 2 ;;
        ti-rpmsg-char|ti-tidl-osrt|ti-tidl|ti-vision-apps|all)
            TARGET="$1"; shift ;;
        --help)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${TARGET}" && "${DROP_SHELL}" -eq 0 ]]; then
    echo "Usage: $0 [OPTIONS] <ti-rpmsg-char|ti-tidl-osrt|ti-tidl|ti-vision-apps|all>" >&2
    echo "       $0 --help" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Build (or verify) the Docker image
# ---------------------------------------------------------------------------
build_image() {
    local dockerfile="${SCRIPT_DIR}/docker/Dockerfile"
    [[ -f "${dockerfile}" ]] || error "Dockerfile not found: ${dockerfile}"

    local existing
    existing=$(docker images -q "${IMAGE_NAME}:${IMAGE_TAG}" 2>/dev/null || true)

    if [[ -z "${existing}" || -n "${NO_CACHE}" ]]; then
        info "Building Docker image ${IMAGE_NAME}:${IMAGE_TAG}..."
        # Build context is the docker/ subdirectory (Dockerfile only — no large files).
        docker build ${NO_CACHE} \
            -t "${IMAGE_NAME}:${IMAGE_TAG}" \
            -f "${dockerfile}" \
            "${SCRIPT_DIR}/docker"
        info "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"
    else
        info "Using existing Docker image ${IMAGE_NAME}:${IMAGE_TAG}"
        info "  (use --no-cache to force rebuild)"
    fi
}

# ---------------------------------------------------------------------------
# docker run helper
#
# Assembles the common run arguments and appends caller-supplied extra ones.
# Always:
#   - Removes the container on exit (--rm)
#   - Runs with the host UID/GID so output files are owned by the caller
#   - Mounts packages/edgeai/ as /workspace (read-write)
#   - Sets HOME=/tmp (tools like dpkg-buildpackage expect a writable home)
# Optional mounts are added when the corresponding option is set.
# ---------------------------------------------------------------------------
docker_run() {
    local -a cmd=("$@")
    local -a run_args=(
        --rm
        --user "$(id -u):$(id -g)"
        -e HOME=/tmp
        # The entire packages/edgeai/ tree is the workspace.
        # Build scripts find their debian/ dirs and write .deb files here.
        -v "${SCRIPT_DIR}:/workspace"
        -w /workspace
    )

    [[ -n "${MIRROR_PATH}" ]] && \
        run_args+=(-v "${MIRROR_PATH}:/mirrors:ro")
    [[ -n "${SYSROOT_PATH}" ]] && \
        run_args+=(-v "${SYSROOT_PATH}:/sysroot:ro")
    [[ -n "${SDK_PATH}" ]] && \
        run_args+=(-v "${SDK_PATH}:/sdk")
    [[ -n "${IPK_DIR}" ]] && \
        run_args+=(-v "${IPK_DIR}:/ipk:ro")

    docker run "${run_args[@]}" "${IMAGE_NAME}:${IMAGE_TAG}" "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# Per-package build functions
# ---------------------------------------------------------------------------

build_ti_rpmsg_char() {
    info "=== Building ti-rpmsg-char ==="

    local -a args=()

    if [[ -n "${MIRROR_PATH}" ]]; then
        # The standard mirror basename produced by Yocto/bitbake git fetcher
        args+=(--git-mirror \
            /mirrors/git.ti.com.git.rpmsg.ti-rpmsg-char.git)
    fi

    if [[ -n "${SYSROOT_PATH}" ]]; then
        args+=(--sysroot /sysroot)
    fi

    local build_cmd="./build-from-source.sh"
    [[ ${#args[@]} -gt 0 ]] && build_cmd+=" $(printf '%q ' "${args[@]}")"
    docker_run bash -c "cd /workspace/ti-rpmsg-char && ${build_cmd}"
}

build_ti_tidl_osrt() {
    info "=== Building ti-tidl-osrt ==="
    # TFLite and ONNX Runtime are cross-compiled from source.
    # TVM and TIDL Runtime wheels are downloaded from TI CDN.
    # Requires outbound internet access (HTTPS to software-dl.ti.com and github.com),
    # or a local git mirror passed via --mirror.

    local -a args=()

    if [[ -n "${MIRROR_PATH}" ]]; then
        # git2/ subdir of the Yocto downloads is mounted at /mirrors
        args+=(--mirror-dir /mirrors)
    fi

    if [[ "${PREBUILT}" -eq 1 ]]; then
        # Fall back to all-CDN mode (same outcome as the old build-deb.sh)
        args+=(--prebuilt-osrt)
    fi

    local build_cmd="./build-from-source.sh"
    [[ ${#args[@]} -gt 0 ]] && build_cmd+=" $(printf '%q ' "${args[@]}")"
    docker_run bash -c "cd /workspace/ti-tidl-osrt && ${build_cmd}"
}

build_ti_tidl() {
    info "=== Building ti-tidl ==="

    # ti-tidl needs an aarch64 sysroot containing:
    #   - ti-vision-apps dev headers (/usr/include/processor_sdk/...)
    #   - libti-rpmsg-char dev headers and .so stubs
    #
    # If no --sysroot is provided, the Docker-internal sysroot at
    # /opt/arm64-sysroot is used. The dev .deb files produced in A1/A2
    # (sitting in /workspace/) are overlaid into it inside the container.
    local sysroot_container
    if [[ -n "${SYSROOT_PATH}" ]]; then
        sysroot_container="/sysroot"
    else
        sysroot_container="/opt/arm64-sysroot"
    fi

    local -a args=(
        --sysroot "${sysroot_container}"
    )

    if [[ -n "${MIRROR_PATH}" ]]; then
        args+=(--mirror /mirrors)
    fi

    # When using the Docker-internal sysroot, overlay both runtime and dev .deb
    # files (built in earlier phases, present at /workspace/) into the sysroot
    # so headers are found at compile time and .so stubs resolve at link time.
    # Runtime packages (.so.N) must come before dev packages (.so stubs that
    # symlink to the .so.N) to avoid dangling symlinks during the link step.
    local pre_cmd=""
    if [[ "${sysroot_container}" == "/opt/arm64-sysroot" ]]; then
        pre_cmd='for deb in \
    /workspace/libti-rpmsg-char0_*.deb \
    /workspace/libti-rpmsg-char-dev_*.deb \
    /workspace/libtivision-apps11.2.0_*.deb \
    /workspace/libtivision-apps-dev_*.deb \
    /workspace/ti-vision-apps-dev_*.deb; do
    [ -f "${deb}" ] && dpkg-deb -x "${deb}" /opt/arm64-sysroot || true
done
'
    fi

    docker_run bash -c \
        "${pre_cmd}cd /workspace/ti-tidl && ./build-from-source.sh $(printf '%q ' "${args[@]}")"
}

build_ti_vision_apps() {
    info "=== Building ti-vision-apps ==="

    if [[ "${PREBUILT}" -eq 1 ]]; then
        # Prebuilt IPK repackaging flow
        [[ -n "${IPK_DIR}" ]] || \
            error "ti-vision-apps --prebuilt requires --ipk-dir <path>"

        docker_run bash -c \
            "cd /workspace/ti-vision-apps && ./build-deb.sh --prebuilt-dir /ipk"
        return
    fi

    # Source build flow
    [[ -n "${SDK_PATH}" ]] || \
        error "ti-vision-apps source build requires --sdk-path <path>.
  Provide an empty directory and the SDK repos will be cloned automatically:
    --sdk-path /some/dir      (repo sync runs on first use; reused on subsequent runs)
  Or use --prebuilt --ipk-dir <path> for the prebuilt IPK flow."

    local -a args=(
        --sdk-path /sdk
        # The OE compat shim in /opt/cross-oe/bin provides aarch64-oe-linux-*
        # tools that the TI SDK builder expects.  This path is baked into the
        # Docker image — no need for the user to pass it.
        --toolchain-bin /opt/cross-oe/bin
    )

    local sysroot_container
    local pre_cmd=""
    if [[ -n "${SYSROOT_PATH}" ]]; then
        sysroot_container="/sysroot"
    else
        # No external sysroot provided; use the Docker-internal arm64 sysroot.
        # Overlay libti-rpmsg-char-dev so app_utils/ipc can find ti_rpmsg_char.h.
        sysroot_container="/opt/arm64-sysroot"
        pre_cmd='for deb in /workspace/libti-rpmsg-char0_*.deb /workspace/libti-rpmsg-char-dev_*.deb; do
    [ -f "${deb}" ] && dpkg-deb -x "${deb}" /opt/arm64-sysroot || true
done
'
    fi
    args+=(--sysroot "${sysroot_container}")

    docker_run bash -c \
        "${pre_cmd}cd /workspace/ti-vision-apps && ./build-from-source.sh $(printf '%q ' "${args[@]}")"
}

drop_shell() {
    info "Dropping into build container shell..."
    info "  /workspace  → ${SCRIPT_DIR}"
    [[ -n "${MIRROR_PATH}" ]]  && info "  /mirrors    → ${MIRROR_PATH}"
    [[ -n "${SYSROOT_PATH}" ]] && info "  /sysroot    → ${SYSROOT_PATH}"
    [[ -n "${SDK_PATH}" ]]     && info "  /sdk        → ${SDK_PATH}"
    [[ -n "${IPK_DIR}" ]]      && info "  /ipk        → ${IPK_DIR}"
    info ""
    info "Useful commands once inside:"
    info "  cd /workspace/ti-rpmsg-char  && ./build-from-source.sh"
    info "  cd /workspace/ti-tidl-osrt   && ./build-from-source.sh [--mirror-dir /mirrors]"
    info "  cd /workspace/ti-tidl        && ./build-from-source.sh --sysroot /sysroot"
    info "  cd /workspace/ti-vision-apps && ./build-from-source.sh --sdk-path /sdk"

    # -it for interactive terminal
    local -a run_args=(
        --rm -it
        --user "$(id -u):$(id -g)"
        -e HOME=/tmp
        -v "${SCRIPT_DIR}:/workspace"
        -w /workspace
    )
    [[ -n "${MIRROR_PATH}" ]]  && run_args+=(-v "${MIRROR_PATH}:/mirrors:ro")
    [[ -n "${SYSROOT_PATH}" ]] && run_args+=(-v "${SYSROOT_PATH}:/sysroot:ro")
    [[ -n "${SDK_PATH}" ]]     && run_args+=(-v "${SDK_PATH}:/sdk")
    [[ -n "${IPK_DIR}" ]]      && run_args+=(-v "${IPK_DIR}:/ipk:ro")

    docker run "${run_args[@]}" "${IMAGE_NAME}:${IMAGE_TAG}" /bin/bash
}

# ---------------------------------------------------------------------------
# Summary of produced packages
# ---------------------------------------------------------------------------
show_output() {
    echo ""
    info "=== Built packages in $(realpath "${SCRIPT_DIR}") ==="
    local found=0
    while IFS= read -r deb; do
        echo "  $(ls -lh "${deb}" | awk '{print $5, $9}')"
        found=1
    done < <(find "${SCRIPT_DIR}" -maxdepth 1 -name "*.deb" | sort)
    [[ "${found}" -eq 1 ]] || info "  (no .deb files found)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
build_image

if [[ "${DROP_SHELL}" -eq 1 ]]; then
    drop_shell
    exit 0
fi

case "${TARGET}" in
    ti-rpmsg-char)
        build_ti_rpmsg_char
        ;;
    ti-tidl-osrt)
        build_ti_tidl_osrt
        ;;
    ti-tidl)
        build_ti_tidl
        ;;
    ti-vision-apps)
        build_ti_vision_apps
        ;;
    all)
        build_ti_rpmsg_char
        build_ti_tidl_osrt
        if [[ -n "${SDK_PATH}" || "${PREBUILT}" -eq 1 ]]; then
            # Build vision-apps first (ti-tidl needs its dev headers)
            build_ti_vision_apps
            build_ti_tidl
        else
            warn "Skipping ti-vision-apps and ti-tidl (no --sdk-path provided)."
            warn "  Run with --sdk-path <path> or --prebuilt --ipk-dir <path> to include them."
        fi
        ;;
esac

show_output
