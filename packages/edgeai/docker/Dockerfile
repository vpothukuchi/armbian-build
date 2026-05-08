# Dockerfile — TI EdgeAI Debian Package Build Environment
#
# Base: ghcr.io/armbian/docker-armbian-build:armbian-ubuntu-noble-latest
#   Ubuntu 24.04 Noble, already contains:
#     - gcc-aarch64-linux-gnu + libc6-dev-arm64-cross  (cross-compiler)
#     - autoconf, automake, libtool  (for ti-rpmsg-char autotools build)
#     - python3, zstd, binutils (ar)  (for ti-tidl-osrt wheel unpacking)
#   We add on top:
#     - debhelper, devscripts, dpkg-dev, fakeroot  (Debian packaging)
#     - cmake, ninja-build, meson, pkg-config  (downstream edgeai builds)
#     - /opt/cross-oe/bin/ compat shim  (aarch64-oe-linux-* → aarch64-linux-gnu-*)
#     - repo tool  (SDK source checkout for ti-vision-apps)
#
# Build:
#   docker build -t ti-edgeai-build:noble docker/
#
# Run (via docker-build.sh — preferred):
#   ./docker-build.sh ti-rpmsg-char
#   ./docker-build.sh --sdk-path /path/to/sdk --sysroot /path/to/rootfs ti-vision-apps

FROM ghcr.io/armbian/docker-armbian-build:armbian-ubuntu-noble-latest

LABEL org.opencontainers.image.title="TI EdgeAI Build"
LABEL org.opencontainers.image.description="Cross-compilation environment for TI EdgeAI Debian packages (aarch64)"

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Add missing tools on top of the Armbian base image
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    \
    # Debian packaging tools (not in Armbian base)
    debhelper \
    devscripts \
    dpkg-dev \
    fakeroot \
    \
    # libtool-bin provides /usr/bin/libtool (separate from the 'libtool' package
    # which only provides libtoolize; both are needed for autotools builds)
    libtool-bin \
    \
    # Build tools for downstream edgeai CMake packages
    cmake \
    ninja-build \
    meson \
    pkg-config \
    \
    # Optional host-side dev libs needed when cross-compiling downstream
    # edgeai packages against a target sysroot (Phases 3–9)
    libglm-dev \
    libfreetype6-dev \
    libpam0g-dev \
    libyaml-cpp-dev \
    libglib2.0-dev \
    \
    # Architecture-independent (arch:all) headers needed by vision_apps SRV GPU kernel.
    # These are copied into the arm64 sysroot further below.
    libstb-dev \
    nlohmann-json3-dev \
    \
    # Misc
    ca-certificates \
    file \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Python cross-compilation prerequisites for ti-tidl-osrt source build
#
# TFLite and ONNX Runtime are cross-compiled from x86_64 → aarch64.
# Their Python extension .so files (_pywrap_tensorflow_interpreter_wrapper.so
# and onnxruntime_pybind11_state.so) need aarch64 Python headers.
#
# python3-dev:arm64 installs pyconfig.h to the multiarch path:
#   /usr/include/aarch64-linux-gnu/python3.12/pyconfig.h
# which our patches/tflite/build_pip_package_with_cmake.sh and
# patches/onnxruntime/tool.cmake reference directly.
# ---------------------------------------------------------------------------
RUN dpkg --add-architecture arm64 && \
    # archive.ubuntu.com only serves amd64/i386; arm64 packages are on ports.ubuntu.com.
    # Restrict the existing ubuntu.sources stanzas to amd64, then add arm64-specific
    # stanzas pointing to ports.ubuntu.com so apt can resolve arm64 packages.
    sed -i '/^Signed-By:.*ubuntu-archive-keyring/a Architectures: amd64' \
        /etc/apt/sources.list.d/ubuntu.sources && \
    printf 'Types: deb\nURIs: http://ports.ubuntu.com/ubuntu-ports\nSuites: noble noble-updates noble-security\nComponents: main restricted universe multiverse\nArchitectures: arm64\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
        > /etc/apt/sources.list.d/ubuntu-ports-arm64.sources && \
    apt-get update && apt-get install -y --no-install-recommends \
    \
    # Host-side Python dev: needed by TFLite build_pip_package_with_cmake.sh
    # to call `python3 -c "import pybind11; print(pybind11.get_include())"` etc.
    python3-dev \
    python3-pybind11 \
    python3-numpy \
    \
    # arm64 Python headers for cross-compiling Python C extensions.
    # libpython3.12-dev:arm64 is Multi-Arch:same — installs cleanly alongside
    # python3-dev:amd64 and provides:
    #   /usr/include/aarch64-linux-gnu/python3.12/pyconfig.h
    libpython3.12-dev:arm64 \
    \
    # Python packaging tools for wheel creation
    python3-pip \
    python3-setuptools \
    \
    && pip3 install --no-cache-dir --break-system-packages \
        wheel flatbuffers \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Arm64 cross-compile sysroot — /opt/arm64-sysroot
#
# Vision-apps and ti-tidl cross-compile against an aarch64 target sysroot.
# We build one here from Ubuntu Noble arm64 packages so Docker builds need
# no external sysroot (no losetup / no sudo / no Armbian image mount).
#
# Strategy: apt-get download arm64 .deb files, then dpkg-deb -x each into
# /opt/arm64-sysroot/.  This avoids package-manager conflicts between the
# host amd64 dev packages and their arm64 counterparts.
#
# We also copy the arm64 files already installed in the container
# (libc6:arm64 and friends pulled in via libpython3.12-dev:arm64) so the
# sysroot has a complete C/C++ runtime.
#
# Packages needed (from vision-apps DEPENDS):
#   virtual/egl  → libegl-dev:arm64
#   freetype     → libfreetype6-dev:arm64
#   libpam       → libpam0g-dev:arm64
#   glm          → libglm-dev (header-only — amd64 headers are arch-neutral)
# ---------------------------------------------------------------------------
RUN mkdir -p /opt/arm64-sysroot/usr && \
    \
    # Copy arm64 C/C++ libraries already present in the container
    # (libc6:arm64, libstdc++6:arm64 etc. installed as multiarch deps)
    cp -a /usr/lib/aarch64-linux-gnu  /opt/arm64-sysroot/usr/lib && \
    cp -a /usr/include/aarch64-linux-gnu /opt/arm64-sysroot/usr/include 2>/dev/null || true && \
    # /lib → usr/lib alias (some linker scripts reference /lib/aarch64-linux-gnu/)
    ln -sf usr/lib /opt/arm64-sysroot/lib && \
    \
    # Download and extract arm64 dev packages (no package DB touch)
    cd /tmp && apt-get update && \
    apt-get download \
        libfreetype6:arm64 \
        libfreetype-dev:arm64 \
        libpam0g:arm64 \
        libpam0g-dev:arm64 \
        libglvnd0:arm64 \
        libegl1:arm64 \
        libegl-dev:arm64 \
        libgles2:arm64 \
        libgles-dev:arm64 \
        libgl-dev:arm64 \
        libgbm1:arm64 \
        libgbm-dev:arm64 \
        libdrm2:arm64 \
        libdrm-dev:arm64 \
        libglfw3:arm64 \
        libglfw3-dev:arm64 \
        libglew2.2:arm64 \
        libglew-dev:arm64 \
        libc6:arm64 \
        libc6-dev:arm64 \
        libstdc++6:arm64 \
        libstdc++-13-dev:arm64 \
    && for f in /tmp/*.deb; do \
           dpkg-deb -x "${f}" /opt/arm64-sysroot/; \
           rm "${f}"; \
       done \
    && rm -rf /var/lib/apt/lists/* \
    # Ubuntu's libdrm-dev installs headers to /usr/include/libdrm/*.h
    # Yocto/OE sysroots expose them directly as /usr/include/drm.h etc.
    # Create flat symlinks so #include <drm.h> and #include <drm_fourcc.h> work.
    && for h in /opt/arm64-sysroot/usr/include/libdrm/*.h; do \
           ln -sf "libdrm/$(basename "${h}")" \
                  "/opt/arm64-sysroot/usr/include/$(basename "${h}")"; \
       done \
    # Copy architecture-neutral (arch:all) headers installed on the host into
    # the arm64 sysroot so the cross-compiler finds them via --sysroot.
    # GLM: vision_apps 3dsrv GPU kernel includes <glm/glm.hpp> etc.
    && cp -a /usr/include/glm       /opt/arm64-sysroot/usr/include/ \
    # nlohmann/json: vision_apps 3dsrv GPU kernel includes <nlohmann/json.hpp>
    && cp -a /usr/include/nlohmann  /opt/arm64-sysroot/usr/include/ \
    # stb: vision_apps includes <stb_image.h> (without the stb/ prefix)
    && cp    /usr/include/stb/*.h   /opt/arm64-sysroot/usr/include/ \
    # Allow non-root container users (e.g. --user $(id -u)) to overlay
    # additional .deb packages (libti-rpmsg-char-dev, libtivision-apps-dev)
    # into the sysroot at build time via dpkg-deb -x.
    && chmod -R a+rwX /opt/arm64-sysroot

# ---------------------------------------------------------------------------
# repo tool (Google Android repo, used for TI SDK source manifest checkout)
# ---------------------------------------------------------------------------
RUN curl -fsSL -o /usr/local/bin/repo \
        https://storage.googleapis.com/git-repo-downloads/repo \
    && chmod +x /usr/local/bin/repo

# ---------------------------------------------------------------------------
# OE cross-compiler compatibility shim
#
# TI's SDK builder uses CROSS_COMPILE_LINARO=aarch64-oe-linux- and
# constructs compiler paths as:
#   $(GCC_LINUX_ARM_ROOT)/bin/aarch64-oe-linux-gcc
#
# Ubuntu packages the same GCC under the aarch64-linux-gnu- prefix.
# Create /opt/cross-oe/bin/ with aarch64-oe-linux-* symlinks pointing to
# the Ubuntu tools so both naming conventions resolve without modifying
# any TI build scripts.
# ---------------------------------------------------------------------------
RUN mkdir -p /opt/cross-oe/bin && \
    for tool in \
        gcc g++ cpp ar as ld nm ranlib strip \
        objcopy objdump readelf addr2line size strings; \
    do \
        if [ -x "/usr/bin/aarch64-linux-gnu-${tool}" ]; then \
            ln -sf "/usr/bin/aarch64-linux-gnu-${tool}" \
                   "/opt/cross-oe/bin/aarch64-oe-linux-${tool}"; \
        fi; \
    done && \
    ln -sf /opt/cross-oe/bin/aarch64-oe-linux-gcc \
           /opt/cross-oe/bin/aarch64-oe-linux-cc && \
    \
    # TI SDK builder's tools_path.mak sets CROSS_COMPILE_LINARO to the nested form:
    #   aarch64-oe-linux/aarch64-oe-linux-
    # so concerto.mak resolves the compiler at:
    #   $(GCC_LINUX_ARM_ROOT)/bin/aarch64-oe-linux/aarch64-oe-linux-gcc
    # Create the nested subdirectory so both the flat naming convention used by
    # the smoke test and the nested one used by the SDK builder are satisfied.
    mkdir -p /opt/cross-oe/bin/aarch64-oe-linux && \
    for tool in \
        gcc g++ cpp ar as ld nm ranlib strip \
        objcopy objdump readelf addr2line size strings; \
    do \
        if [ -x "/usr/bin/aarch64-linux-gnu-${tool}" ]; then \
            ln -sf "/usr/bin/aarch64-linux-gnu-${tool}" \
                   "/opt/cross-oe/bin/aarch64-oe-linux/aarch64-oe-linux-${tool}"; \
        fi; \
    done && \
    ln -sf /opt/cross-oe/bin/aarch64-oe-linux/aarch64-oe-linux-gcc \
           /opt/cross-oe/bin/aarch64-oe-linux/aarch64-oe-linux-cc

ENV PATH="/opt/cross-oe/bin:${PATH}"

# ---------------------------------------------------------------------------
# Smoke-tests
# ---------------------------------------------------------------------------
# 1. Standard Ubuntu cross-compiler
RUN printf 'int main(void){return 0;}\n' | \
        aarch64-linux-gnu-gcc -x c - -o /tmp/test-gnu && \
    file /tmp/test-gnu | grep -q "aarch64" && \
    echo "aarch64-linux-gnu-gcc OK: $(aarch64-linux-gnu-gcc --version | head -1)" && \
    rm /tmp/test-gnu

# 2. OE compat shim — flat (/opt/cross-oe/bin/aarch64-oe-linux-gcc) and
#    nested (/opt/cross-oe/bin/aarch64-oe-linux/aarch64-oe-linux-gcc)
RUN printf 'int main(void){return 0;}\n' | \
        /opt/cross-oe/bin/aarch64-oe-linux-gcc -x c - -o /tmp/test-oe && \
    echo "aarch64-oe-linux-gcc flat shim OK" && \
    rm /tmp/test-oe && \
    printf 'int main(void){return 0;}\n' | \
        /opt/cross-oe/bin/aarch64-oe-linux/aarch64-oe-linux-gcc -x c - -o /tmp/test-oe-nested && \
    echo "aarch64-oe-linux/aarch64-oe-linux-gcc nested shim OK" && \
    rm /tmp/test-oe-nested

# 3. debhelper available
RUN dh --version | head -1

# 4. Python cross-compile headers present
RUN test -f /usr/include/aarch64-linux-gnu/python3.12/pyconfig.h && \
    echo "aarch64 Python3.12 cross-compile headers OK" && \
    python3 -c "import pybind11; print('pybind11 OK:', pybind11.get_include())" && \
    python3 -c "import numpy; print('numpy OK:', numpy.get_include())"

WORKDIR /workspace

CMD ["/bin/bash"]
