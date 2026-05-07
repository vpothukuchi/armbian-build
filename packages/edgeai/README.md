# EdgeAI Ubuntu Packages

Ubuntu/Debian packaging for TI EdgeAI components sourced from the
[meta-edgeai](https://git.ti.com/git/edgeai/meta-edgeai.git) layer,
SDK baseline: **PSDK Analytics 11.02.04.00**.

---

## Supported Machines

All packages target **aarch64** and are compatible with:

| Machine | SoC | CPU |
|---------|-----|-----|
| `j721e` | TDA4VM / AM752x | A72 |
| `j721s2` | TDA4AL / AM68A | A72 |
| `j784s4` | TDA4VH / AM69A | A72 |
| `j722s` | AM67A | A53 |
| `j742s2` | TDA4VH-Q1 | A72 |
| `am62axx` | AM62A | A53 |

---

## Package Status

| Package | Directory | Flow 1: Pre-built | Flow 2: Source |
|---------|-----------|-------------------|----------------|
| `libti-rpmsg-char0` + `-dev` | `ti-rpmsg-char/` | **Done ✓** | **Done ✓** (autotools) |
| `ti-tidl-osrt` + `-dev` | `ti-tidl-osrt/` | **Done ✓** | **Done ✓** (TFLite 2.12 + ONNX RT 1.15 cross-compiled) |
| `ti-tidl` (arm-tidl delegates) | `ti-tidl-osrt/` | — | **Planned** (see below) |
| `libtivision-apps11.2.0` | `ti-vision-apps/` | **Done ✓** | **Done ✓** |
| `libtivision-apps-dev` | `ti-vision-apps/` | **Done ✓** | **Done ✓** |
| `ti-vision-apps-data` | `ti-vision-apps/` | **Done ✓** | **Done ✓** |
| `edgeai-apps-utils` | `edgeai-apps-utils/` | Planned | Needs vision-apps sysroot |
| `edgeai-tiovx-kernels` | `edgeai-tiovx-kernels/` | Planned | Needs vision-apps sysroot |
| `edgeai-tiovx-modules` | `edgeai-tiovx-modules/` | Planned | Needs vision-apps sysroot |
| `edgeai-dl-inferer` | `edgeai-dl-inferer/` | Planned | Needs vision-apps + OSRT |
| `edgeai-gst-plugins` | `edgeai-gst-plugins/` | Planned | Needs full stack |
| `edgeai-gst-apps` | `edgeai-gst-apps/` | Planned | Needs full stack |
| `edgeai-tiovx-apps` | `edgeai-tiovx-apps/` | Planned | Needs kernels sysroot |
| `ti-edgeai-firmware` | `ti-edgeai-firmware/` | Planned (prebuilt blobs) | N/A (R5F/C7x, needs CGT) |
| `ti-gpio-cpp` | `ti-gpio-cpp/` | Planned | Standalone CMake |
| `ti-gpio-py` | `ti-gpio-py/` | Planned | Standalone setuptools |

---

## Build Instructions

See **[BUILD.md](BUILD.md)** for the complete build guide covering:
- Docker-based builds (preferred — no host dependencies beyond Docker)
- Native builds (without Docker)
- Armbian image integration (`compile.sh` + `output/debs/extra/`)
- Incremental rebuild scenarios

### Quick start

```bash
cd packages/edgeai
./docker-build.sh ti-tidl-osrt    # builds + packages in one step
```

The Docker image (`docker/Dockerfile`) is based on the Armbian Noble build image
(`ghcr.io/armbian/docker-armbian-build:armbian-ubuntu-noble-latest`), which already
contains `gcc-aarch64-linux-gnu` and `libc6-dev-arm64-cross`. The image adds:
- `debhelper`, `devscripts`, `libtool-bin` — Debian packaging
- `cmake`, `ninja-build`, `meson` — downstream component builds
- `python3-dev:arm64` — aarch64 Python 3.12 headers for cross-compiling Python extensions
- `/opt/cross-oe/bin/` — `aarch64-oe-linux-*` symlinks pointing to
  `aarch64-linux-gnu-*`, satisfying the TI SDK builder's
  `CROSS_COMPILE_LINARO=aarch64-oe-linux-` convention without modification
- `repo` — SDK source checkout

---

## Dev Flow Overview

There are two distinct ways to produce Ubuntu `.deb` packages for EdgeAI components.
Both are supported by the Docker wrapper and the per-package scripts.

### Flow 1: Pre-built IPK → .deb

**When to use:** You have a completed build (Yocto or otherwise) and the
`deploy/ipk/aarch64/` directory contains the built binaries as IPK packages.
Fastest path — no cross-compilation needed.

**Mechanism:** Extract the IPK data archive, repack as a Debian `.deb` using a
minimal `debian/` control directory and `dpkg-buildpackage`.

```
deploy/ipk/aarch64/
├── libtivision-apps11.2.0_*.ipk     ← ar archive with data.tar.zst
├── libtivision-apps-dev_*.ipk
└── ti-vision-apps-data_*.ipk

             ↓  build-deb.sh

packages/edgeai/
├── libtivision-apps11.2.0_11.02.03-1_arm64.deb   (4.1M)
├── libtivision-apps-dev_11.02.03-1_arm64.deb      (12M)
└── ti-vision-apps-data_11.02.03-1_arm64.deb       (257K)
```

**Steps:**
```bash
cd packages/edgeai/ti-vision-apps

./build-deb.sh --prebuilt-dir /path/to/ipk/aarch64

# Produces:
ls ../libtivision-apps*.deb ../ti-vision-apps-data*.deb
```

**IPK format note:** TI IPKs are `ar` archives containing:
- `debian-binary`
- `control.tar.zst`
- `data.tar.zst`

`build-deb.sh` uses `ar x` + `zstdcat | tar` to extract and repack as `.deb`.

---

### Flow 2: Source → Cross-compile → Stage → .deb

**When to use:** No pre-built IPK available (typical Ubuntu-first development
scenario). Requires:
- The TI PSDK Analytics source repos (obtained via `repo sync`)
- `aarch64-linux-gnu-gcc` (Ubuntu) or `aarch64-oe-linux-gcc` (Arago) — equivalent
- A target sysroot (libc, GLES, EGL, RPMsg headers) — the Armbian-built j784s4
  rootfs serves as this sysroot; no separate Yocto build needed

**Cross-compiler note:** The TI SDK builder uses `CROSS_COMPILE_LINARO=aarch64-oe-linux-`
as the compiler prefix. Ubuntu's `aarch64-linux-gnu-gcc` is the same GCC build with
a different prefix. The Docker image provides a `/opt/cross-oe/bin/` shim that
maps `aarch64-oe-linux-*` → `aarch64-linux-gnu-*`, so the SDK builds without
modification.

```
SDK source repos (vision_apps_yocto.xml manifest)
├── sdk_builder/       ← Makefile with yocto_build / yocto_install targets
├── tiovx/             ← OpenVX framework
├── vision_apps/       ← libtivision_apps.so source
├── app_utils/         ← A72 utility library
├── imaging/           ← sensor DCC .bin files
├── video_io/
├── ti-perception-toolkit/
└── psdk_include/      ← arm-tidl headers + ivision + vxlib

             ↓  build-from-source.sh

staging-src/rootfs/
├── usr/lib/libtivision_apps.so.11.2.0   (45 MB ARM aarch64)
├── usr/include/processor_sdk/           (tiovx, vision_apps, app_utils, ...)
└── opt/
    ├── vision_apps/                     (vision_apps_init.sh, scripts)
    └── imaging/                         (imx390, ar0820, ar0233, imx219, ...)

             ↓  dpkg-buildpackage

packages/edgeai/
├── libtivision-apps11.2.0_11.02.03-1_arm64.deb   (4.1M  — source-built)
├── libtivision-apps-dev_11.02.03-1_arm64.deb      (12M   — headers)
└── ti-vision-apps-data_11.02.03-1_arm64.deb       (226K  — imaging DCC + scripts)
```

**Steps:**
```bash
cd packages/edgeai/ti-vision-apps

# First build (full compile, ~30 min on 32-core host):
./build-from-source.sh \
  --sdk-path /path/to/vision_apps_yocto.xml/repo \
  --sysroot  /path/to/sysroots/j784s4-evm \
  --toolchain-bin /opt/cross-oe/bin \   # or Arago toolchain bin dir
  --soc j784s4

# Subsequent runs (skip compile, re-stage + repackage):
./build-from-source.sh --skip-build
```

**Build sequence (what `build-from-source.sh` does internally):**
```bash
# From sdk_builder/, with SOC=j784s4 PROFILE=release TARGET_CPU=A72 TARGET_OS=LINUX
make app_utils              # A72 utility library
make imaging                # sensor drivers + DCC bins
make video_io               # video I/O
make tiovx                  # OpenVX framework
make tidl_tiovx_kernels     # TIDL OpenVX kernels
make ptk                    # perception toolkit
make -C vision_apps tivision_apps  # → libtivision_apps.so.11.2.0

# Stage outputs (yocto_install SDK-internal target name, cannot be renamed):
LINUX_FS_STAGE_PATH=staging-src/rootfs make yocto_install
```

**Key make variables:**
```makefile
SOC               = j784s4
PSDK_PATH         = $(SDK_PATH)
PROFILE           = release
BUILD_EMULATION_MODE = no
TARGET_CPU        = A72
TARGET_OS         = LINUX
TIDL_PATH         = $(SDK_PATH)/tidl_j7
GCC_LINUX_ARM_ROOT = $(toolchain_parent)  # parent of bin/aarch64-oe-linux/
LINUX_SYSROOT_ARM = $(SYSROOT)
TREAT_WARNINGS_AS_ERROR = 0
```

---

## ti-tidl: Two Separate Recipes {#ti-tidl-two-recipes}

The TIDL/OSRT stack in Yocto is split across **two recipes** in `meta-edgeai`.
Understanding this split is essential for knowing what "source build" means here.

### `ti-tidl-osrt.bb` — prebuilt downloads only

Downloads these prebuilt binaries directly from TI CDN. **Zero source build.**

| Artifact | Type | Built by |
|----------|------|----------|
| `tflite_runtime-2.12.0-*.whl` | Python wheel | TI (closed) |
| `onnxruntime_tidl-1.15.0-*.whl` | Python wheel | TI (closed) |
| `tvm-0.18.0-*.whl` | Python wheel | TI (closed) |
| `tidlruntime-0.1.0-*.whl` | Python wheel | TI (closed) |
| `tflite_2.12_aragoj7.tar.gz` | C++ static lib + headers | TI (closed) |
| `onnx_1.15.0_aragoj7.tar.gz` | C++ shared lib + headers | TI (closed) |

Our `ti-tidl-osrt/build-deb.sh` and `build-from-source.sh` (without `--sdk-path`)
replicate this exactly.  The Python wheels contain the compiled runtimes for
TFLite, ONNX Runtime, TVM, and TIDL Runtime.

### `ti-tidl.bb` — source build of arm-tidl delegates

Separately clones and builds the four **C++ delegate libraries** that bridge
the above runtimes to TI's TIDL inference engine:

```
Sources cloned by ti-tidl.bb:
  arm-tidl.git        SRCREV 81fefa6   git.ti.com/processor-sdk-vision/arm-tidl
  concerto.git        SRCREV f5541b8   git.ti.com/processor-sdk/concerto
  tensorflow (TI fork) SRCREV 422156a  github.com/TexasInstruments/tensorflow  (branch tidl-j7-2.12)
  onnxruntime (TI fork) SRCREV 5816cc  github.com/TexasInstruments/onnxruntime (branch tidl-1.15)
  protobuf             SRCREV f0dc78d  github.com/protocolbuffers/protobuf

Build command (from arm-tidl/ Makefile directly — NOT the SDK builder):
  CROSS_COMPILE_LINARO=aarch64-oe-linux-   ← our OE shim satisfies this
  GCC_LINUX_ARM_ROOT=                      ← empty; compiler found via PATH
  LINUX_SYSROOT_ARM=<target-sysroot>
  TARGET_SOC=J784S4

Outputs:
  arm-tidl/rt/out/J784S4/A72/LINUX/release/libvx_tidl_rt.so.1.0
  arm-tidl/tfl_delegate/out/J784S4/A72/LINUX/release/libtidl_tfl_delegate.so.1.0
  arm-tidl/onnxrt_ep/out/J784S4/A72/LINUX/release/libtidl_onnxrt_EP.so.1.0
  arm-tidl/tidlrt_ep/out/J784S4/A72/LINUX/release/libtidlrt_EP.so.1.0

Depends on:  ti-vision-apps  (links against tiovx + vision_apps headers)
```

**Note on tensorflow/onnxruntime repos:** These are checked out for **headers only**,
not compiled. The actual runtimes are the prebuilt archives from `ti-tidl-osrt.bb`
(`tflite_2.12_aragoj7.tar.gz` and `onnx_1.15.0_aragoj7.tar.gz`). The arm-tidl
delegates link against these prebuilt libs.

### Current status and plan

Our current `ti-tidl-osrt/build-from-source.sh` handles the `ti-tidl-osrt.bb`
case (prebuilt downloads) and has a stub for `--sdk-path` (arm-tidl via SDK builder).
The correct arm-tidl source build should match `ti-tidl.bb` — building directly
from the arm-tidl Makefile, not via the SDK builder. This is **planned** and requires:

1. `ti-vision-apps` already built (provides tiovx/vision_apps headers in sysroot)
2. Clone `arm-tidl` at SRCREV `81fefa6` + `concerto` at `f5541b8`
3. Clone TI tensorflow fork (headers only, branch `tidl-j7-2.12`)
4. Clone TI onnxruntime fork (headers only, branch `tidl-1.15`)
5. Run `make` from `arm-tidl/` with the variables above
6. Package the four `.so.1.0` files alongside the prebuilt Python wheels

---

## Getting Source Repos (without a pre-existing build)

The SDK source repos for `ti-vision-apps` are obtained via the `repo` tool:

```bash
# Install repo (also included in the Docker image)
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    > ~/bin/repo && chmod +x ~/bin/repo

# Initialize and sync
mkdir -p ~/psdk-analytics && cd ~/psdk-analytics
repo init -u https://git.ti.com/git/processor-sdk/psdk_repo_manifests.git \
     -b REL.PSDK.ANALYTICS.11.02.00.06 \
     -m vision_apps_yocto.xml
repo sync -j8

# Result: ~/psdk-analytics/ contains sdk_builder/, tiovx/, vision_apps/,
# tidl_j7/arm-tidl/, etc.
```

The sysroot (needed for `--sysroot`) can be the **Armbian-built j784s4 rootfs**
(`output/cache/rootfs/` after an Armbian build), or any other target rootfs
that contains libc, GLES/EGL, and TI BSP libraries. No separate Yocto build
and no PSDK SDK installer is required — the PSDK SDK installer is the *output*
of a build, not an input.

---

## Where `ti-vision-apps` Lives

**`ti-vision-apps` is defined in `meta-edgeai`, NOT `meta-tisdk`.**

- Recipe: `meta-edgeai/recipes-tisdk/ti-psdk-rtos/ti-vision-apps.bb`
- `meta-tisdk` contains BSP/multimedia/graphics packages but has no vision_apps
  or edgeai component recipes.
- The TI debian package repository (`TexasInstruments/ti-debpkgs`) does **not**
  contain vision_apps or any edgeai package — it covers kernel, GPU drivers,
  rpmsg, etc. only.

---

## Package Dependency Graph

```
ti-vision-apps          ← repo manifest REL.PSDK.ANALYTICS.11.02.00.06
│                         10 repos: sdk_builder, tiovx, vision_apps, app_utils,
│                         imaging, video_io, ti-perception-toolkit, psdk_include,
│                         arm-tidl, concerto
│                         Build: sdk_builder/Makefile → yocto_build / yocto_install
│
├── ti-tidl-osrt         ← TFLite 2.12 + ONNX RT 1.15 cross-compiled from source  ✓ DONE
│   │  Python wheels: tflite_runtime 2.12, onnxruntime 1.15, tvm 0.18, tidlruntime 0.1
│   │  tvm + tidlruntime: prebuilt wheels from TI CDN (no public source available)
│   │  C++ libs: libonnxruntime.so.1.15.0, libtensorflow-lite.a (source-built)
│   │
│   └── ti-tidl          ← SOURCE BUILD of arm-tidl delegates  (PLANNED)
│          arm-tidl @ 81fefa6  (git.ti.com/processor-sdk-vision/arm-tidl)
│          concerto  @ f5541b8  (git.ti.com/processor-sdk/concerto)
│          tensorflow TI fork @ 422156a  (headers only, branch tidl-j7-2.12)
│          onnxruntime TI fork @ 5816cc  (headers only, branch tidl-1.15)
│          Outputs: libvx_tidl_rt.so.1.0, libtidl_tfl_delegate.so.1.0,
│                   libtidl_onnxrt_EP.so.1.0, libtidlrt_EP.so.1.0
│
├── edgeai-apps-utils    ← git.ti.com/edgeai/edgeai-apps-utils  0d003eb
│   ├── edgeai-tiovx-kernels  ← git.ti.com/edgeai/edgeai-tiovx-kernels  f81cdbc
│   │   └── edgeai-tiovx-modules ← git.ti.com/edgeai/edgeai-tiovx-modules  11399cf
│   │       └── edgeai-gst-plugins ← TexasInstruments/edgeai-gst-plugins  ad59325
│   │
│   └── edgeai-dl-inferer ← git.ti.com/edgeai/edgeai-dl-inferer  d06b07d
│       └── edgeai-gst-apps  ← TexasInstruments/edgeai-gst-apps  464f70b
│
├── edgeai-tiovx-apps    ← TexasInstruments/edgeai-tiovx-apps  cb123fd
│
ti-edgeai-firmware       ← psdk_fw.git 579af7d  (PREBUILT R5F/C7x .out blobs)
ti-gpio-cpp              ← TexasInstruments/ti-gpio-cpp  c0ac0c2  (libgpiod)
ti-gpio-py               ← TexasInstruments/ti-gpio-py  62f12a3  (gpiozero)
edgeai-gui-app           ← apps/edgeai-gui-app  b2220ea
edgeai-studio-agent      ← TexasInstruments/edgeai-studio-agent  653632e
edgeai-init              ← local scripts
edgeai-test-data / edgeai-tidl-models ← TexasInstruments/edgeai-gst-apps  464f70b
```

---

## Armbian Build Integration

### Entry Point

```bash
cd <armbian-build>
./compile.sh BOARD=j784s4-evm BRANCH=vendor RELEASE=noble BUILD_MINIMAL=no
```

> Note: the script is `compile.sh`, not `build.sh`.

### How Custom Packages Are Integrated

**1. Extensions** (`userpatches/extensions/<name>.sh`) — preferred:
- Hook into `pre_customize_image`, `post_customize_image`, etc.
- Can install `.deb` files, add apt repos, enable systemd services.
- The existing `extensions/ti-debpkgs.sh` adds the official `TexasInstruments/ti-debpkgs`
  apt repo (GPU, kernel, rpmsg — NOT edgeai).
- A new `extensions/ti-edgeai-pkgs.sh` (to be written) will install the edgeai debs.

**2. `userpatches/customize-image.sh`** — simpler, runs inside chroot:
- `/tmp/overlay/` is bind-mounted from `userpatches/overlay/` on the host.
- Drop built `.deb` files there and call `dpkg -i` from the script.

**3. `output/debs/extra/`** — armbian auto-installs all `.deb` files found here
   during rootfs creation (requires matching architecture/release).

---

## Host Build Dependencies

See [BUILD.md](BUILD.md) for host prerequisites when building without Docker.

---

## Downstream Package Build Plans (Phases 3+)

### Phase 3: `edgeai-apps-utils`

**SRCREV:** `0d003eb05afb89d4b6248ce9a33b6599b9629e1d`
**Build system:** CMake
**Requires:** ti-vision-apps sysroot (headers + `libtivision_apps.so`)
**Key CMake variables:**
```
-DTARGET_FS=<sysroot>
-DCMAKE_SKIP_RPATH=TRUE
-DCMAKE_OUTPUT_DIR=<out>
SOC=j784s4  (env var)
```

### Phase 4: `edgeai-tiovx-kernels`

**SRCREV:** `f81cdbcd12c15894165a348ea4844060b3c2499b`
**Build system:** CMake, same pattern as edgeai-apps-utils
**Requires:** ti-vision-apps + edgeai-apps-utils sysroot

### Phase 5: `edgeai-tiovx-modules`

**SRCREV:** `11399cffa14dfb0bff65bf35dcbe04b701391eb8`
**Build system:** CMake, adds `-DINSTALL_SRC=on`
**Requires:** ti-vision-apps + edgeai-tiovx-kernels sysroot

### Phase 6: `edgeai-dl-inferer`

**SRCREV:** `d06b07d3058b1859df0e32c3ca545b70b8cf3ec9`
**Build system:** CMake + Python3
**Requires:** edgeai-apps-utils + ti-tidl-osrt + yaml-cpp + opencv + ti-vision-apps
**Ubuntu build deps:** `libyaml-cpp-dev libopencv-dev python3-dev`

### Phase 7: `edgeai-gst-plugins`

**SRCREV:** `ad59325325ef96cb132600b77f753cd88740501e`
**Build system:** Meson
**Requires:** edgeai-tiovx-modules + edgeai-apps-utils + edgeai-dl-inferer + ti-tidl-osrt + gstreamer1.0
**Ubuntu build deps:** `libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev meson ninja-build`
**Installs:** `/usr/lib/aarch64-linux-gnu/gstreamer-1.0/`

### Phase 8: `edgeai-gst-apps`

**SRCREV:** `464f70b2e780bbaed8ab048b4b548f54b75b1661`
**Build system:** CMake
**Requires:** ti-vision-apps + edgeai-dl-inferer + yaml-cpp + gstreamer1.0 + opencv

### Phase 9: `edgeai-tiovx-apps`

**SRCREV:** `cb123fd90869a94a13a9a34a6972a2907b41e8b2`
**Build system:** CMake
**Requires:** edgeai-tiovx-kernels + yaml-cpp + glib-2.0 + ffmpeg + libdrm
**Ubuntu build deps:** `libglib2.0-dev libdrm-dev libavcodec-dev libavformat-dev`

### Phase 10: `ti-edgeai-firmware` — PREBUILT

**SRCREV:** `579af7d6c4b0172d4824faf16972adbdcd13902b`
**Repo:** `psdk_fw.git` — prebuilt R5F/C7x `.out` blobs, signed via `ti-secdev`
**Installs to:** `/lib/firmware/vision_apps_eaik/`
**Machines:** j721e, j721s2, j784s4, j722s, j742s2 (not am62axx)

### Phase 11: Extras (no ti-vision-apps dependency)

| Package | SRCREV | Notes |
|---------|--------|-------|
| `ti-gpio-cpp` | `c0ac0c2` | CMake, dep: `libgpiod-dev` |
| `ti-gpio-py` | `62f12a3` | setuptools, dep: gpiozero |
| `edgeai-studio-agent` | `653632e` | Python FastAPI server |
| `edgeai-init` | local | systemd service + scripts |
| `edgeai-test-data` | `464f70b` | test images/videos |
| `edgeai-tidl-models` | `464f70b` | pre-trained models |
