# Dockerfile — TI EdgeAI Debian Package Build Environment
# Proxy support: pass --build-arg http_proxy=... at build time if needed.
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

# Proxy build args — passed via --build-arg at docker build time.
# Docker BuildKit pre-defines http_proxy/https_proxy but declaring them
# here makes them available as ENV for all subsequent RUN steps.
ARG http_proxy
ARG https_proxy
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG no_proxy
ARG NO_PROXY
ENV http_proxy=${http_proxy} \
    https_proxy=${https_proxy} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    no_proxy=${no_proxy} \
    NO_PROXY=${NO_PROXY}

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
    \
    # Architecture-independent (arch:all) headers needed by vision_apps SRV GPU kernel.
    # These are copied into the arm64 sysroot further below.
    libstb-dev \
    nlohmann-json3-dev \
    \
    # Mesa PVR WSI build: Python template processing + SPIR-V tools + Vulkan headers
    python3-mako \
    glslang-tools \
    libvulkan-dev \
    libwayland-bin \
    libwayland-dev \
    bison \
    flex \
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
        \
        # yaml-cpp arm64 — needed for edgeai-dl-inferer / edgeai-tiovx-apps.
        # Include runtime package so the unversioned .so symlink is not dangling.
        # Ubuntu Noble (24.04): yaml-cpp 0.8.x → libyaml-cpp0.8.
        libyaml-cpp0.8:arm64 \
        libyaml-cpp-dev:arm64 \
        \
        # ffmpeg arm64 — edgeai-tiovx-apps links avcodec/avformat/avutil unconditionally.
        # Include both -dev (headers + unversioned .so symlink) AND the runtime packages
        # (versioned .so.60 / .so.58 files) so the unversioned symlinks are not dangling.
        # Ubuntu Noble (24.04) ffmpeg 6.1.x: avcodec 60, avformat 60, avutil 58.
        libavcodec60:arm64 \
        libavcodec-dev:arm64 \
        libavformat60:arm64 \
        libavformat-dev:arm64 \
        libavutil58:arm64 \
        libavutil-dev:arm64 \
        \
        # zlib arm64 — libelf.pc (Requires.private chain for gstreamer-1.0) needs
        # zlib.pc in the sysroot.  apt-get download unconditionally fetches the .deb
        # regardless of whether the package is already installed on the host, unlike
        # apt-get install -d which skips packages already at the newest version.
        zlib1g:arm64 \
        zlib1g-dev:arm64 \
        \
        # expat arm64 — Mesa pvr WSI xmlconfig needs libexpat.
        libexpat1:arm64 \
        libexpat1-dev:arm64 \
        \
        # Vulkan + Wayland arm64 — Mesa pvr WSI Vulkan ICD integration.
        libvulkan1:arm64 \
        libvulkan-dev:arm64 \
        libwayland-dev:arm64 \
        libwayland-client0:arm64 \
        libwayland-egl-backend-dev:arm64 \
        \
        # GLVND vendor ABI headers — required for mesa -Dglvnd=true.
        # libglvnd-core-dev provides glvnd/libeglabi.h and libglvnd.pc
        # so meson's dependency('libglvnd') resolves correctly.
        libglvnd-core-dev:arm64 \
        \
        # libtinfo6 arm64 — libtinfo6:arm64 is pre-installed in this Docker image
        # (pulled in by the aarch64 cross-compile toolchain), so apt-get install -d
        # silently skips it.  apt-get download forces the download so we can extract
        # the versioned libtinfo.so.6 into the sysroot.  Without it, the
        # libtinfo.so -> libtinfo.so.6 symlink installed by libtinfo-dev:arm64 is
        # a dangling symlink and -ltinfo fails to link.
        libtinfo6:arm64 \
        \
    && for f in /tmp/*.deb; do \
           dpkg-deb -x "${f}" /opt/arm64-sysroot/; \
           rm "${f}"; \
       done \
    # GStreamer arm64 — use apt-get install -d (not apt-get download) to resolve
    # the full transitive dependency tree: libpcre2-8 (glib-2.0 Requires.private),
    # libdw (gstreamer-1.0 Requires.private), libffi (gobject-2.0), liborc, etc.
    # Downloads go to /var/cache/apt/archives/; extract only *_arm64.deb files.
    # Ubuntu Noble: libglib2.0-0t64 (64-bit time_t variant replaces libglib2.0-0).
    && apt-get install -d -y --no-install-recommends \
        libglib2.0-0t64:arm64 \
        libglib2.0-dev:arm64 \
        libgstreamer1.0-0:arm64 \
        libgstreamer1.0-dev:arm64 \
        libgstreamer-plugins-base1.0-0:arm64 \
        libgstreamer-plugins-base1.0-dev:arm64 \
        \
        # OpenCV arm64 — edgeai-gst-apps links opencv_core and opencv_imgproc.
        # Headers install to /usr/include/opencv4/ (Ubuntu Noble 4.0.6t64).
        libopencv-core406t64:arm64 \
        libopencv-core-dev:arm64 \
        libopencv-imgproc406t64:arm64 \
        libopencv-imgproc-dev:arm64 \
        \
        # ncurses/tinfo arm64 — edgeai-gst-apps links -lncurses and -ltinfo.
        libncurses6:arm64 \
        libncurses-dev:arm64 \
        libtinfo-dev:arm64 \
        \
        # BLAS/LAPACK arm64 — Ubuntu Noble libopencv-core406t64:arm64 has DT_NEEDED
        # on liblapack.so.3 and libblas.so.3 (Yocto OpenCV does not).  The cross-
        # linker must be able to resolve these transitive references; without them,
        # undefined-reference errors on cblas_dgemm, dgeqrf_, etc. abort the link.
        # libgfortran5:arm64 is a runtime dep of liblapack3:arm64.
        libblas3:arm64 \
        liblapack3:arm64 \
        libgfortran5:arm64 \
    && for f in /var/cache/apt/archives/*_arm64.deb; do \
           [ -f "${f}" ] || continue; \
           dpkg-deb -x "${f}" /opt/arm64-sysroot/ || true; \
           rm "${f}"; \
       done \
    && rm -rf /var/cache/apt/archives/partial \
    && rm -rf /var/lib/apt/lists/* \
    # Create SONAME symlinks for BLAS and LAPACK.
    # Ubuntu Noble installs libblas.so.3.x.y in blas/ and liblapack.so.3.x.y in
    # lapack/ subdirectories.  The SONAME symlinks (e.g. libblas.so.3) are normally
    # created by ldconfig at install time, not by the package itself.  Since ldconfig
    # is not run on the cross-compile sysroot, create them manually so the linker
    # can resolve DT_NEEDED entries from libopencv_core.so.
    && for f in \
           /opt/arm64-sysroot/usr/lib/aarch64-linux-gnu/blas/lib*.so.3.* \
           /opt/arm64-sysroot/usr/lib/aarch64-linux-gnu/lapack/lib*.so.3.*; do \
           [ -f "${f}" ] || continue; \
           subdir="$(basename "$(dirname "${f}")")"; \
           name="$(basename "${f}")"; \
           soname="${name%.*}"; soname="${soname%.*}"; \
           dest="/opt/arm64-sysroot/usr/lib/aarch64-linux-gnu/${soname}"; \
           [ -e "${dest}" ] || ln -sf "${subdir}/${name}" "${dest}"; \
       done \
    # Re-establish /lib → usr/lib symlink.  dpkg-deb -x of libc6:arm64 replaces the
    # symlink (created above) with an empty directory.  Glibc linker scripts
    # (libm.so, libpthread.so, librt.so) contain GROUP entries that reference
    # /lib/aarch64-linux-gnu/... paths; the cross-linker prepends the sysroot
    # to those absolute paths, so they must resolve via this symlink.
    && rm -rf /opt/arm64-sysroot/lib \
    && ln -sf usr/lib /opt/arm64-sysroot/lib \
    # cmake/common.cmake in edgeai-tiovx-apps sets
    # CMAKE_FIND_LIBRARY_SUFFIXES ".a" ".lib" ".so", so CMake prefers static
    # archives over shared libraries.  Static C++ libs (yaml-cpp, avcodec, …)
    # drag in C++ runtime symbols (__cxa_*, vtable, operator new/delete) that
    # are absent when a C executable is linked without -lstdc++.
    # Remove ALL static archives except the glibc non-shared stubs that the
    # C runtime linker scripts require, forcing the linker to use .so instead.
    && find /opt/arm64-sysroot/usr/lib -name "lib*.a" \
            ! -name "libc_nonshared.a" \
            ! -name "libpthread_nonshared.a" \
            -delete \
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
