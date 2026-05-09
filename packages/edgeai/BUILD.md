# EdgeAI Package Build Guide

This document covers how to build the TI EdgeAI `.deb` packages and integrate
them into an Armbian image for the j784s4-evm (and compatible) boards.

## Build sequence

```
B1  Armbian base image   — compile.sh (kernel, u-boot, firmware only)
A1  ti-rpmsg-char        — autotools source build          ─┐
    ti-tidl-osrt         — TFLite + ONNX RT source build    │
A2  ti-vision-apps       — SDK source build (needs A1)      │ TI base packages
A3  ti-tidl              — arm-tidl delegates (A1+A2)       │ (no dependency
FW  ti-adas-firmware     — R5F MCU + C7x DSP firmware blobs │  on B1)
E1  edgeai-apps-utils    — NEON utility library (A2)        │
E2  edgeai-tiovx-kernels — OpenVX kernels (A2+E1)          ─┘
B2  Final Armbian image  — compile.sh + ENABLE_EXTENSIONS=ti-debpkgs
```

B1 and A/E phases have no dependency on each other. B1 runs first because it
is the longest step (~60 min). A1→A2→A3→E1→E2 must be sequential (each phase
overlays the previous phase's `.deb` files into the build sysroot before
compiling). B2 consumes all outputs: the B1 kernel/u-boot and all EdgeAI `.deb`
files.

> **Note:** `edgeai-dl-inferer` is **not** built as a Debian package by
> default. The `edgeai-robotics-sdk` always fetches and builds it from source
> via CMake CPM (`CPMAddPackage`) at build time, so a pre-installed package
> provides no benefit. The `build-from-source.sh` and `docker-build.sh` support
> it as an explicit optional target if needed for other consumers.
>
> **Note:** E3 (edgeai-tiovx-modules, edgeai-tiovx-apps) and E4
> (edgeai-gst-plugins, edgeai-gst-apps) build scripts exist under
> `packages/edgeai/` but are **not** built by default. They are not required
> for the edgeai-robotics-sdk target (which uses GStreamer from Ubuntu repos
> and fetches edgeai-gst-apps via CPM at build time).

The top-level orchestration script is `packages/edgeai/build_armbian.sh`
(inside this repository). It self-derives the armbian-build root from its own
path and can be invoked from any working directory.

---

## Produced packages

| Package | Phase | Description |
|---------|-------|-------------|
| `libti-rpmsg-char0_0.6.10-1_arm64.deb` | A1 | RPMsg char runtime library |
| `libti-rpmsg-char-dev_0.6.10-1_arm64.deb` | A1 | RPMsg char headers + link stubs |
| `ti-tidl-osrt_11.02.04.00-1_arm64.deb` | A1 | TFLite 2.12, ONNX RT 1.15, TVM 0.18, TIDL RT |
| `ti-tidl-osrt-dev_11.02.04.00-1_arm64.deb` | A1 | OSRT headers + static libs |
| `libtivision-apps11.2.0_11.02.03-1_arm64.deb` | A2 | vision_apps shared library |
| `libtivision-apps-dev_11.02.03-1_arm64.deb` | A2 | vision_apps headers |
| `ti-vision-apps-data_11.02.03-1_arm64.deb` | A2 | Demo binaries + data files |
| `ti-tidl_1.0.0-1_arm64.deb` | A3 | TIDL delegate .so libraries |
| `ti-tidl-dev_1.0.0-1_arm64.deb` | A3 | TIDL delegate headers |
| `ti-adas-firmware_1.0.0-1_all.deb` | FW | R5F MCU + C7x DSP RTOS firmware for vision_apps |
| `edgeai-apps-utils_1.0.0-1_arm64.deb` | E1 | NEON utility lib + `/opt/edgeai-apps-utils/` |
| `edgeai-apps-utils-dev_1.0.0-1_arm64.deb` | E1 | edgeai-apps-utils headers + link stubs |
| `edgeai-tiovx-kernels_1.0.0-1_arm64.deb` | E2 | OpenVX custom kernels |
| `edgeai-tiovx-kernels-dev_1.0.0-1_arm64.deb` | E2 | OpenVX kernels headers |
| `edgeai-dl-inferer_1.0.0-1_arm64.deb` | *(optional)* | DL inference abstraction library — fetched via CPM by edgeai-robotics-sdk; no image install needed |
| `edgeai-dl-inferer-dev_1.0.0-1_arm64.deb` | *(optional)* | DL inferer headers |
| `edgeai-tiovx-modules_1.0.0-1_arm64.deb` | E3 *(optional)* | OpenVX pipeline modules |
| `edgeai-tiovx-modules-dev_1.0.0-1_arm64.deb` | E3 *(optional)* | OpenVX modules headers |
| `edgeai-tiovx-apps_1.0.0-1_arm64.deb` | E3 *(optional)* | OpenVX demo apps + `/opt/edgeai-tiovx-apps/` |
| `edgeai-gst-plugins_1.0.0-1_arm64.deb` | E4 *(optional)* | GStreamer HW-offload plugins |
| `edgeai-gst-apps_1.0.0-1_arm64.deb` | E4 *(optional)* | GStreamer demos + `/opt/edgeai-gst-apps/` |

---

## Full orchestrated build (recommended)

Use `packages/edgeai/build_armbian.sh` to run the full sequence. The script
self-derives the armbian-build root from its own path, so it can be invoked
from any working directory. It handles proxy setup and deb staging automatically.

```bash
# Full build with local git mirror and SDK path:
bash packages/edgeai/build_armbian.sh \
    --mirror   /mnt/DATA/YOCTO/yocto-build/downloads/git2 \
    --sdk-path /opt/ti-vision-apps-sdk

# Skip B1 (kernel already built), rebuild EdgeAI packages + final image:
bash packages/edgeai/build_armbian.sh --skip-kernel \
    --mirror   /mnt/DATA/YOCTO/yocto-build/downloads/git2 \
    --sdk-path /opt/ti-vision-apps-sdk

# All debs already built — just regenerate the final image:
bash packages/edgeai/build_armbian.sh --skip-kernel --skip-edgeai

# EdgeAI packages only (no Armbian builds at all):
bash packages/edgeai/build_armbian.sh --skip-kernel --skip-image \
    --sdk-path /opt/ti-vision-apps-sdk
```

### build_armbian.sh options

| Option | Effect |
|--------|--------|
| `--skip-kernel` | Skip Armbian base image build (B1) |
| `--skip-edgeai` | Skip all EdgeAI package builds (A1+A2+A3+FW+E1+E2) |
| `--skip-base-pkgs` | Skip ti-rpmsg-char + ti-tidl-osrt (A1) only |
| `--skip-vision-apps` | Skip ti-vision-apps (A2) only |
| `--skip-tidl` | Skip ti-tidl (A3) only |
| `--skip-fw` | Skip firmware package (ti-adas-firmware) |
| `--skip-edgeai-pkgs` | Skip E1+E2 packages (edgeai-apps-utils, edgeai-tiovx-kernels) |
| `--skip-image` | Skip final Armbian image build (B2) |
| `--skip-proxy` | Skip TI proxy setup (outside TI network) |
| `--mirror <path>` | Local Yocto git2/ mirror (faster, offline-capable) |
| `--sdk-path <path>` | Local workspace dir for the ti-vision-apps SDK source repos. **Do not clone anything manually** — the build system runs `repo init` + `repo sync` into this directory on the first run (~15 min, ~2 GB). On subsequent runs the existing workspace is reused. Provide an empty directory, or the path from a previous build. |
| `--ipk-dir <path>` | Prebuilt Yocto IPK dir for ti-vision-apps (Docker only) |
| `--clean` | Remove all generated build artifacts, then exit |
| `--clean-downloads` | (with `--clean`) also delete the ti-tidl-osrt download cache |
| `--no-cache` | Force rebuild of the EdgeAI Docker image |

---

## Building individual packages with docker-build.sh

`docker-build.sh` is the lower-level script that builds one package at a time
inside the `ti-edgeai-build` Docker container. The Docker image is built
automatically on first run.

```bash
cd packages/edgeai

# A1 — no extra inputs needed (fetches from git.ti.com / GitHub / TI CDN)
./docker-build.sh ti-rpmsg-char
./docker-build.sh ti-tidl-osrt

# A1 with local git mirror (faster, offline-capable)
./docker-build.sh --mirror /path/to/git-mirrors ti-rpmsg-char
./docker-build.sh --mirror /path/to/git-mirrors ti-tidl-osrt

# A2 — provide an empty dir; build system runs repo init+sync there on first run
#       (~15 min, ~2 GB); on subsequent runs the existing workspace is reused.
#       Do NOT clone repos manually.
./docker-build.sh --sdk-path /opt/ti-vision-apps-sdk ti-vision-apps

# A2 using prebuilt Yocto IPKs instead of source build
./docker-build.sh --prebuilt --ipk-dir /path/to/ipk ti-vision-apps

# A3 — uses Docker-internal /opt/arm64-sysroot; overlays A1+A2 debs automatically
./docker-build.sh ti-tidl

# Firmware — pre-built RTOS blobs, no sysroot needed
./docker-build.sh ti-adas-firmware

# E1 — overlays A2 dev headers into sysroot
./docker-build.sh edgeai-apps-utils

# E2 — overlays E1 debs in addition to A1+A2
./docker-build.sh edgeai-tiovx-kernels

# edgeai-dl-inferer (optional — edgeai-robotics-sdk fetches it via CPM)
./docker-build.sh edgeai-dl-inferer

# E3/E4 (optional — not needed for edgeai-robotics-sdk target):
./docker-build.sh edgeai-tiovx-modules
./docker-build.sh edgeai-tiovx-apps
./docker-build.sh edgeai-gst-plugins
./docker-build.sh edgeai-gst-apps

# Build all in one shot (A1 → A2 → A3 → FW → E1 → E2)
./docker-build.sh --sdk-path /opt/ti-vision-apps-sdk all

# Force Docker image rebuild
./docker-build.sh --no-cache ti-rpmsg-char
```

### What docker-build.sh does between phases

Before each phase, `docker-build.sh` automatically extracts the previous
phase's `.deb` files into the container's `/opt/arm64-sysroot` so that headers
and shared libraries from earlier phases are visible to the next phase's build
system. For example, before E2, it overlays A2 + E1 dev headers so that
`edgeai-tiovx-kernels` can find `edgeai-apps-utils` headers. This is our
equivalent of Yocto's `do_populate_sysroot` mechanism.

### Git mirror directory

Pass `--mirror` to speed up builds or enable offline operation. The directory
should contain Yocto-style bare-clone repos:

| Package | Mirror basename |
|---------|----------------|
| ti-rpmsg-char | `git.ti.com.git.rpmsg.ti-rpmsg-char.git` |
| ti-tidl-osrt | `github.com.TexasInstruments.tensorflow` |
| ti-tidl-osrt | `github.com.TexasInstruments.onnxruntime` |
| ti-tidl | `git.ti.com.git.processor-sdk-vision.arm-tidl.git` |
| ti-tidl | `git.ti.com.git.processor-sdk.concerto.git` |
| ti-tidl | `github.com.TexasInstruments.onnxruntime` |
| ti-tidl | `github.com.TexasInstruments.tensorflow` |
| ti-tidl | `github.com.protocolbuffers.protobuf.git` |

---

## Building the Armbian image (compile.sh)

### B1 — Base image (kernel + u-boot, no EdgeAI packages)

```bash
cd /mnt/DATA/UBUNTU/armbian-build
./compile.sh build \
    BOARD=j784s4-evm \
    BRANCH=vendor \
    BUILD_MINIMAL=yes \
    KERNEL_CONFIGURE=no \
    RELEASE=noble \
    GIT_SKIP_SUBMODULES=yes \
    SKIP_ARMBIAN_REPO=yes \
    SHARE_LOG=yes
```

### B2 — Final image with all EdgeAI packages installed

Stage the built `.deb` files first, then add `ENABLE_EXTENSIONS=ti-debpkgs`:

```bash
mkdir -p output/debs/extra
cp packages/edgeai/*.deb output/debs/extra/

./compile.sh build \
    BOARD=j784s4-evm \
    BRANCH=vendor \
    BUILD_MINIMAL=yes \
    KERNEL_CONFIGURE=no \
    RELEASE=noble \
    GIT_SKIP_SUBMODULES=yes \
    SKIP_ARMBIAN_REPO=yes \
    SHARE_LOG=yes \
    ENABLE_EXTENSIONS=ti-debpkgs
```

The `ti-debpkgs` extension (`extensions/ti-debpkgs.sh`) installs all
`.deb` files found in `output/debs/extra/` into the arm64 chroot via
`apt-get install` during rootfs creation, which resolves cross-package
dependencies automatically.

---

## Incremental builds

The B and A pipelines are independent until B2. Only rebuild what changed:

| What changed | What to rebuild |
|---|---|
| Kernel config, u-boot, board patches | B1 only (then B2) |
| ti-rpmsg-char source | `--skip-kernel --skip-vision-apps --skip-tidl --skip-edgeai-pkgs` then B2 |
| ti-tidl-osrt source or patches | `--skip-kernel --skip-vision-apps --skip-tidl --skip-edgeai-pkgs` then B2 |
| ti-vision-apps source | `--skip-kernel --skip-base-pkgs` (A2+A3+E1+E2+B2) |
| ti-tidl source | `--skip-kernel --skip-base-pkgs --skip-vision-apps` (A3+E1+E2+B2) |
| edgeai-apps-utils source | `--skip-kernel --skip-base-pkgs --skip-vision-apps --skip-tidl --skip-fw` (E1+E2+B2) |
| edgeai-tiovx-kernels source | `--skip-kernel --skip-base-pkgs --skip-vision-apps --skip-tidl` then B2 |
| edgeai-dl-inferer source | Not applicable — not packaged; rebuilt by edgeai-robotics-sdk via CPM |
| Only Debian packaging metadata | Rebuild the affected package only, then B2 |
| Everything | Full build (no skip flags) |

Within each `build-from-source.sh`, use `--skip-build` to repackage without
recompiling (e.g. after changing `debian/control` or install rules):

```bash
cd packages/edgeai/ti-tidl-osrt
./build-from-source.sh --skip-source-build --skip-download
```

---

## Native build (without Docker)

> **Not tested end-to-end. Use Docker for production builds.**

See the prerequisites section at the top of `packages/edgeai/build_armbian.sh`
for the complete list of host packages, OE compat shim setup, and arm64 sysroot
creation steps. Once prerequisites are met, invoke:

```bash
bash packages/edgeai/build_armbian.sh --no-docker \
    --sysroot /opt/arm64-sysroot \
    --sdk-path /opt/ti-vision-apps-sdk
```
