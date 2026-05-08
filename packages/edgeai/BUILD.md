# EdgeAI Package Build Guide

This document covers how to build the TI EdgeAI `.deb` packages and integrate
them into an Armbian image for the j784s4-evm (and compatible) boards.

## Build sequence

```
B1  Armbian base image   — compile.sh (kernel, u-boot, firmware only)
A1  ti-rpmsg-char        — autotools source build         ─┐
    ti-tidl-osrt         — TFLite + ONNX RT source build   │ EdgeAI packages
A2  ti-vision-apps       — SDK source build (needs A1)     │ (no dependency
A3  ti-tidl              — arm-tidl delegates (needs A1+A2)─┘  on B1)
B2  Final Armbian image  — compile.sh + ENABLE_EXTENSIONS=ti-debpkgs
```

B1 and A1/A2/A3 have no dependency on each other. B1 runs first because it
is the longest step (~60 min). A1→A2→A3 must be sequential (each overlays
the previous phase's `.deb` files into the build sysroot before compiling).
B2 consumes all outputs: the B1 kernel/u-boot and all nine EdgeAI `.deb` files.

The top-level orchestration script is `/mnt/DATA/UBUNTU/build_armbian.sh`.

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

---

## Full orchestrated build (recommended)

Use `build_armbian.sh` from the `armbian-build` directory. It handles the
full sequence, proxy setup, and staging automatically.

```bash
cd /mnt/DATA/UBUNTU/armbian-build

# Full build with local git mirror and SDK path:
bash /mnt/DATA/UBUNTU/build_armbian.sh \
    --mirror   /mnt/DATA/YOCTO/yocto-build/downloads/git2 \
    --sdk-path /opt/ti-vision-apps-sdk

# Skip B1 (kernel already built), rebuild EdgeAI packages + final image:
bash /mnt/DATA/UBUNTU/build_armbian.sh --skip-kernel \
    --mirror   /mnt/DATA/YOCTO/yocto-build/downloads/git2 \
    --sdk-path /opt/ti-vision-apps-sdk

# All debs already built — just regenerate the final image:
bash /mnt/DATA/UBUNTU/build_armbian.sh --skip-kernel --skip-edgeai

# EdgeAI packages only (no Armbian builds at all):
bash /mnt/DATA/UBUNTU/build_armbian.sh --skip-kernel --skip-image \
    --sdk-path /opt/ti-vision-apps-sdk
```

### build_armbian.sh options

| Option | Effect |
|--------|--------|
| `--skip-kernel` | Skip Armbian base image build |
| `--skip-edgeai` | Skip all EdgeAI package builds (A1+A2+A3) |
| `--skip-base-pkgs` | Skip ti-rpmsg-char + ti-tidl-osrt only |
| `--skip-vision-apps` | Skip ti-vision-apps only |
| `--skip-tidl` | Skip ti-tidl only |
| `--skip-image` | Skip final Armbian image build |
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

# Build all in one shot (A1 → A2 → A3)
./docker-build.sh --sdk-path /opt/ti-vision-apps-sdk all

# Force Docker image rebuild
./docker-build.sh --no-cache ti-rpmsg-char
```

### What docker-build.sh does between phases

Before A2 runs inside the container, `docker-build.sh` automatically extracts
the A1 `.deb` files into the container's `/opt/arm64-sysroot` so that
`ti_rpmsg_char.h` is visible to the vision_apps build system. Before A3, it
similarly extracts all A1+A2 `.deb` files. This is our equivalent of Yocto's
`do_populate_sysroot` mechanism.

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

The `ti-debpkgs` extension (`extensions/ti-debpkgs.sh`) installs all nine
`.deb` files into the arm64 chroot via `apt-get install` during rootfs
creation, which resolves cross-package dependencies automatically.

---

## Incremental builds

The B and A pipelines are independent until B2. Only rebuild what changed:

| What changed | What to rebuild |
|---|---|
| Kernel config, u-boot, board patches | B1 only (then B2) |
| ti-rpmsg-char source | `--skip-kernel --skip-vision-apps --skip-tidl` then B2 |
| ti-tidl-osrt source or patches | `--skip-kernel --skip-vision-apps --skip-tidl` then B2 |
| ti-vision-apps source | `--skip-kernel --skip-base-pkgs` (A2+A3+B2) |
| ti-tidl source | `--skip-kernel --skip-base-pkgs --skip-vision-apps` (A3+B2) |
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

See the prerequisites section at the top of `build_armbian.sh` for the
complete list of host packages, OE compat shim setup, and arm64 sysroot
creation steps. Once prerequisites are met, invoke:

```bash
bash /mnt/DATA/UBUNTU/build_armbian.sh --no-docker \
    --sysroot /opt/arm64-sysroot \
    --sdk-path /opt/ti-vision-apps-sdk
```
