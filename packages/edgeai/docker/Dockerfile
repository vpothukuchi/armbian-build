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
           /opt/cross-oe/bin/aarch64-oe-linux-cc

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

# 2. OE compat shim
RUN printf 'int main(void){return 0;}\n' | \
        /opt/cross-oe/bin/aarch64-oe-linux-gcc -x c - -o /tmp/test-oe && \
    echo "aarch64-oe-linux-gcc shim OK" && \
    rm /tmp/test-oe

# 3. debhelper available
RUN dh --version | head -1

# 4. Python cross-compile headers present
RUN test -f /usr/include/aarch64-linux-gnu/python3.12/pyconfig.h && \
    echo "aarch64 Python3.12 cross-compile headers OK" && \
    python3 -c "import pybind11; print('pybind11 OK:', pybind11.get_include())" && \
    python3 -c "import numpy; print('numpy OK:', numpy.get_include())"

WORKDIR /workspace

CMD ["/bin/bash"]
