# EdgeAI Package Build Guide

This document covers how to build the TI EdgeAI `.deb` packages and integrate
them into an Armbian image for the j784s4-evm (and compatible) boards.

There are two independent pipelines:

```
Pipeline A: EdgeAI packages
  packages/edgeai/ → .deb files

Pipeline B: Armbian base image
  compile.sh → rootfs / SD card image

Integration: copy .deb files into output/debs/extra/ before running compile.sh
```

---

## Pipeline A: Build EdgeAI Packages

### Docker (preferred — no host dependencies beyond Docker)

```bash
cd packages/edgeai

# Build one package:
./docker-build.sh ti-tidl-osrt      # TFLite 2.12 + ONNX RT 1.15 (source build)
./docker-build.sh ti-rpmsg-char     # RPMsg char userspace library

# Build all (skips ti-tidl and ti-vision-apps if their deps are not provided):
./docker-build.sh all
```

The Docker image is built automatically on first run from `docker/Dockerfile`.
To force a rebuild of the image:

```bash
./docker-build.sh --no-cache ti-tidl-osrt
```

Output `.deb` files land in `packages/edgeai/`:

```
packages/edgeai/
├── ti-tidl-osrt_11.02.04.00-1_arm64.deb
├── ti-tidl-osrt-dev_11.02.04.00-1_arm64.deb
├── libti-rpmsg-char0_0.6.10-1_arm64.deb
└── libti-rpmsg-char-dev_0.6.10-1_arm64.deb
```

#### Packages that need extra inputs

| Package | Extra inputs | Flag |
|---------|-------------|------|
| `ti-tidl-osrt` | None — sources from GitHub, tvm/tidlruntime from TI CDN | — |
| `ti-rpmsg-char` | None — sources from git.ti.com | — |
| `ti-tidl` | aarch64 sysroot with ti-vision-apps headers | `--sysroot <path>` |
| `ti-vision-apps` | SDK source tree (via `repo sync`) | `--sdk-path <path>` |
| `ti-vision-apps` (prebuilt) | Yocto-built IPK files | `--prebuilt --ipk-dir <path>` |

#### Offline / faster builds with a local git mirror

If you have a local git mirror directory (e.g. from a Yocto downloads cache):

```bash
./docker-build.sh --mirror /path/to/git-mirrors ti-tidl-osrt
```

The mirror directory should contain bare repos named:
- `github.com.TexasInstruments.tensorflow`
- `github.com.TexasInstruments.onnxruntime`

---

### Native (without Docker)

Only use this if Docker is not available.

#### One-time host setup

```bash
sudo dpkg --add-architecture arm64
sudo apt install \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  cmake ninja-build wget unzip git \
  python3-dev python3-dev:arm64 \
  python3-pybind11 python3-numpy python3-pip \
  debhelper devscripts

pip3 install --user wheel setuptools flatbuffers
```

#### Build

```bash
cd packages/edgeai/ti-tidl-osrt
./build-from-source.sh
```

---

## Pipeline B: Build Armbian Base Image

```bash
cd <armbian-build>
./compile.sh \
  BOARD=j784s4-evm \
  BRANCH=vendor \
  RELEASE=noble \
  BUILD_MINIMAL=no
```

This produces a rootfs and SD card image in `output/images/`.

---

## Integration: Getting EdgeAI Packages into the Image

Copy the built `.deb` files into Armbian's extra debs directory before
running `compile.sh`. Armbian automatically installs all `.deb` files found
there during rootfs creation:

```bash
mkdir -p output/debs/extra
cp packages/edgeai/*.deb output/debs/extra/

./compile.sh BOARD=j784s4-evm BRANCH=vendor RELEASE=noble BUILD_MINIMAL=no
```

---

## Incremental Builds

The two pipelines are independent. Only rebuild what changed:

| What changed | What to rebuild |
|---|---|
| TFLite / ONNX RT source or patches | `./docker-build.sh ti-tidl-osrt` only |
| Board config, kernel, or Armbian patches | `./compile.sh ...` only |
| EdgeAI packages AND Armbian config | Both, in either order |
| Only packaging / debian metadata | `./docker-build.sh ti-tidl-osrt` only |

Within `build-from-source.sh`, two flags allow partial rebuilds:

```bash
# Skip source compilation; re-stage and repackage only:
./build-from-source.sh --skip-source-build

# Skip CDN downloads; use existing downloads/:
./build-from-source.sh --skip-download

# Both — fastest repackage cycle:
./build-from-source.sh --skip-source-build --skip-download
```

Armbian's `compile.sh` also has its own incremental caching — it reuses a
cached rootfs if nothing affecting it has changed.
