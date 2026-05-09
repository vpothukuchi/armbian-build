# Ubuntu vs Yocto Install Path Gaps — TI EdgeAI Packages

**Purpose:** Reference for TI team discussion on making `edgeai-dl-inferer`,
`edgeai-tiovx-kernels`, and the robotics SDK cmake files work with both Yocto
and standard Ubuntu (Armbian) installs without breaking either.

**Armbian build context:** `armbian-build` repo, `ti-main` branch.
TI PSDK version: 11.02.
Ubuntu Noble (24.04) target.

---

## Background

The cmake `common.cmake` files in `edgeai-dl-inferer` and `edgeai-tiovx-kernels`
use a `TARGET_FS` cmake variable to locate dependencies:

```cmake
# Set in Yocto via EXTRA_OECMAKE:
#   -DTARGET_FS=${WORKDIR}/recipe-sysroot
# On Ubuntu native build on-target: TARGET_FS="" (empty)

set(TENSORFLOW_INSTALL_DIR ${TARGET_FS}/usr/include/tensorflow)
set(ONNXRT_INSTALL_DIR     ${TARGET_FS}/usr/include/onnxruntime)
set(TFLITE_INSTALL_DIR     ${TARGET_FS}/usr/lib/tflite_2.12)
set(TVMRT_INSTALL_DIR      ${TARGET_FS}/usr/include/tvm)
```

In Yocto, `TARGET_FS` points to the recipe-specific sysroot which is
populated by `do_populate_sysroot` from each upstream recipe's `do_install`.
On Ubuntu, `TARGET_FS=""` so all paths resolve to `/usr/...` — the standard
FHS location where our Debian packages install.

The gaps documented below are places where the Ubuntu-installed layout differs
from what the Yocto recipe-sysroot provides.

> **Note on root cause:** The TFLite subdirectory structure is not a deliberate
> TI design choice. It is an artifact of how cmake's `FetchContent` names its
> build output directories (`ruy-build`, `flatbuffers-build`, etc.). When Yocto
> packages the prebuilt tarball it preserves this cmake build artifact structure.
> A source build on Ubuntu produces the same cmake output names but they are
> staged differently.

---

## Gap 1 — TFLite Static Library Subdirectory Structure

### What Yocto provides

`ti-tidl-osrt.bb` installs from the prebuilt TI CDN tarball
`tflite_2.12_aragoj7.tar.gz`, which preserves the cmake `FetchContent` build
output structure:

```
/usr/lib/tflite_2.12/
├── ruy-build/
│   ├── libruy_allocator.a
│   ├── libruy_context.a
│   └── ... (~25 ruy libs)
├── flatbuffers-build/
│   └── libflatbuffers.a
├── xnnpack-build/
│   └── libXNNPACK.a
├── pthreadpool/
│   └── libpthreadpool.a
├── fft2d-build/
│   ├── libfft2d_fftsg.a
│   └── libfft2d_fftsg2d.a
├── cpuinfo-build/
│   └── libcpuinfo.a
├── abseil-cpp-build/
│   └── libabsl_*.a  (~35 abseil libs)
└── farmhash-build/
    └── libfarmhash.a
```

### What Ubuntu source build produces

Our `build-from-source.sh` builds TFLite from source via cmake. All 79 `.a`
files are staged **flat** into a single directory (no subdirs):

```
/usr/lib/tflite_2.12/
├── libruy_allocator.a
├── libruy_context.a
├── libflatbuffers.a
├── libXNNPACK.a
├── libpthreadpool.a
├── libfft2d_fftsg.a
├── libabsl_base.a
└── ... (79 files flat)
```

### Consumer cmake expectation (`edgeai-dl-inferer/cmake/common.cmake`)

```cmake
link_directories(${TFLITE_INSTALL_DIR}/ruy-build       # /usr/lib/tflite_2.12/ruy-build
                 ${TFLITE_INSTALL_DIR}/xnnpack-build    # /usr/lib/tflite_2.12/xnnpack-build
                 ${TFLITE_INSTALL_DIR}/pthreadpool      # /usr/lib/tflite_2.12/pthreadpool
                 ${TFLITE_INSTALL_DIR}/fft2d-build      # /usr/lib/tflite_2.12/fft2d-build
                 ${TFLITE_INSTALL_DIR}/cpuinfo-build    # /usr/lib/tflite_2.12/cpuinfo-build
                 ${TFLITE_INSTALL_DIR}/flatbuffers-build# /usr/lib/tflite_2.12/flatbuffers-build
                 ${TFLITE_INSTALL_DIR}/abseil-cpp-build # /usr/lib/tflite_2.12/abseil-cpp-build
                 ${TFLITE_INSTALL_DIR}/farmhash-build)  # /usr/lib/tflite_2.12/farmhash-build
```

### Breakage on Ubuntu

All eight subdirectory paths do not exist. The linker cannot find
`libruy_allocator.a`, `libflatbuffers.a`, etc.

### Proposed fix (additive, does not break Yocto)

Add `${TFLITE_INSTALL_DIR}` itself as a search path alongside the existing
subdirectory paths. cmake `link_directories` is order-independent per-library;
the linker finds each `.a` in the first directory that contains it:

```cmake
link_directories(${TFLITE_INSTALL_DIR}              # ← ADD: flat Ubuntu layout
                 ${TFLITE_INSTALL_DIR}/ruy-build
                 ${TFLITE_INSTALL_DIR}/xnnpack-build
                 ${TFLITE_INSTALL_DIR}/pthreadpool
                 ${TFLITE_INSTALL_DIR}/fft2d-build
                 ${TFLITE_INSTALL_DIR}/cpuinfo-build
                 ${TFLITE_INSTALL_DIR}/flatbuffers-build
                 ${TFLITE_INSTALL_DIR}/abseil-cpp-build
                 ${TFLITE_INSTALL_DIR}/farmhash-build)
```

This is a **one-line addition** to `edgeai-dl-inferer/cmake/common.cmake`.

---

## Gap 2 — TFLite / Flatbuffers Headers

### What Yocto provides

`ti-tidl-osrt.bb` installs the prebuilt tarball's full TensorFlow source tree
skeleton, including the cmake `FetchContent` download cache:

```
/usr/include/tensorflow/
└── tensorflow/lite/tools/make/downloads/flatbuffers/include/
    └── flatbuffers/flatbuffers.h          ← cmake FetchContent artifact
/usr/include/tensorflow/
└── tensorflow/lite/tools/pip_package/gen/tflite_pip/python3/cmake_build/
    └── flatbuffers/include/flatbuffers/   ← pip_package cmake artifact
/usr/include/tensorflow/lite/
└── ...                                    ← standard lite/ headers
```

### What Ubuntu source build produces

Headers copied from the TF source tree — only `*.h` and `*.fbs` files under
`tensorflow/lite/`, excluding cmake build artifact directories:

```
/usr/include/tensorflow/
└── lite/
    ├── core/
    ├── kernels/
    ├── schema/
    └── ...    (standard lite headers only — no tools/make/downloads/)
```

### Consumer cmake expectation

```cmake
include_directories(
    SYSTEM ${TENSORFLOW_INSTALL_DIR}/lite/tools/make/downloads/flatbuffers/include
    SYSTEM ${TENSORFLOW_INSTALL_DIR}/lite/tools/pip_package/gen/tflite_pip/python3/cmake_build/flatbuffers/include
    SYSTEM ${TENSORFLOW_INSTALL_DIR}/tensorflow/lite/tools/make/downloads/flatbuffers/include
    SYSTEM ${TENSORFLOW_INSTALL_DIR}/tensorflow/lite/tools/pip_package/gen/tflite_pip/python3/cmake_build/flatbuffers/include
)
```

### Breakage on Ubuntu

All four flatbuffers include paths resolve to non-existent paths. Any code
that `#include`s flatbuffers headers (`flatbuffers/flatbuffers.h`) fails to
compile.

### Proposed fix (additive, does not break Yocto)

Option A (preferred): Add the system `libflatbuffers-dev` apt package path:

```cmake
include_directories(
    SYSTEM /usr/include     # ← ADD: system flatbuffers-dev (Ubuntu: /usr/include/flatbuffers/)
    SYSTEM ${TENSORFLOW_INSTALL_DIR}/lite/tools/make/downloads/flatbuffers/include
    SYSTEM ${TENSORFLOW_INSTALL_DIR}/lite/tools/pip_package/gen/tflite_pip/python3/cmake_build/flatbuffers/include
    SYSTEM ${TENSORFLOW_INSTALL_DIR}/tensorflow/lite/tools/make/downloads/flatbuffers/include
    SYSTEM ${TENSORFLOW_INSTALL_DIR}/tensorflow/lite/tools/pip_package/gen/tflite_pip/python3/cmake_build/flatbuffers/include
)
```

This requires `libflatbuffers-dev` in `PACKAGE_LIST_ADDITIONAL` for the
Armbian image.

Option B: Stage flatbuffers headers from the cmake `FetchContent` dir
(`build/_deps/flatbuffers-src/include/`) into a fixed location under
`/usr/lib/tflite_2.12/flatbuffers-include/` and add that path.

---

## Gap 3 — ONNX Runtime TIDL Execution Provider

### What Yocto provides

The prebuilt CDN binary `onnx_1.15.0_aragoj7.tar.gz` from TI contains
`libonnxruntime.so.1.15.0` compiled **with TIDL EP enabled**. It exports:

```
OrtSessionOptionsAppendExecutionProvider_Tidl
OrtSessionsOptionsSetDefault_Tidl
OrtSessionGetTIBenchmarkData_Tidl
```

### What Ubuntu source build produced (before fix)

Our `build-from-source.sh` called `python3 tools/ci_build/build.py` without
any TIDL EP cmake flag. `libonnxruntime.so` was built without the TIDL
provider — those three symbols were absent.

### Breakage on Ubuntu

Any consumer that calls `OrtSessionOptionsAppendExecutionProvider_Tidl` (e.g.
`edgeai-dl-inferer`, robotics SDK inference code) gets a link-time or
runtime undefined symbol error:

```
undefined reference to `OrtSessionOptionsAppendExecutionProvider_Tidl'
undefined reference to `OrtSessionsOptionsSetDefault_Tidl'
```

### Fix applied (this build cycle)

Added `"onnxruntime_USE_TIDL=ON"` to `cmake_extra_defines` in
`build_onnxrt()` in `ti-tidl-osrt/build-from-source.sh`:

```bash
python3 tools/ci_build/build.py \
    ...
    --cmake_extra_defines \
        "CMAKE_TOOLCHAIN_FILE=${src}/cmake/tool.cmake" \
        "onnxruntime_USE_TIDL=ON" \          ← ADDED
    ...
```

The TIDL EP source in
`onnxruntime/core/providers/tidl/tidl_provider_factory.cc` uses `dlopen()`
to load `libtidl_onnxrt_EP.so` at **runtime** only, so no link-time
dependency on TIDL libraries is introduced during the cross-compile.

---

## Gap 4 — TVM C++ Headers

### What Yocto provides (`ti-tidl-osrt.bb`)

```bash
install -d ${D}${includedir}/tvm/tvm
cd ${D}${PYTHON_SITEPACKAGES_DIR}/tvm/
cp --parents $(find . -name "*.h*") ${D}${includedir}/tvm/tvm
```

Result: `/usr/include/tvm/tvm/` populated with all TVM C++ headers from the
Python wheel's source tree.

### What Ubuntu install provides

TVM is installed as a Python-only wheel. No C++ headers are placed under
`/usr/include/`. Headers live inside the Python package:

```
/usr/lib/python3/dist-packages/tvm/
├── libtvm.so
├── libtvm_runtime.so
└── include/
    └── tvm/...    ← headers here, NOT under /usr/include/
```

### Consumer cmake expectation (`edgeai-dl-inferer/cmake/common.cmake`)

```cmake
set(TVMRT_INSTALL_DIR ${TARGET_FS}/usr/include/tvm)

include_directories(
    SYSTEM ${TVMRT_INSTALL_DIR}/tvm/include           # /usr/include/tvm/tvm/include
    SYSTEM ${TVMRT_INSTALL_DIR}/tvm/3rdparty/dmlc-core/include
    SYSTEM ${TVMRT_INSTALL_DIR}/tvm/3rdparty/dlpack/include
)
```

### Breakage on Ubuntu

`/usr/include/tvm/tvm/include` does not exist. Any source file that includes
TVM C++ headers fails to compile.

### Fix applied (this build cycle)

Option (a) implemented: `ti-tidl-osrt/debian/rules` now copies all C++
headers from the TVM Python wheel into `/usr/include/tvm/tvm/`, mirroring
the Yocto recipe exactly:

```makefile
if [ -d staging/python/tvm ]; then \
    install -d debian/ti-tidl-osrt-dev/usr/include/tvm/tvm; \
    cd staging/python/tvm && \
        find . -name "*.h*" | \
        xargs cp --parents -t $(CURDIR)/debian/ti-tidl-osrt-dev/usr/include/tvm/tvm/; \
fi
```

After a package rebuild, `/usr/include/tvm/tvm/include/tvm/...`,
`/usr/include/tvm/tvm/3rdparty/dmlc-core/include/`, and
`/usr/include/tvm/tvm/3rdparty/dlpack/include/` will all exist — exactly
matching what `edgeai-dl-inferer/cmake/common.cmake` expects via
`${TVMRT_INSTALL_DIR}/tvm/include`.

---

## Gap 5 — processor_sdk Headers (vision_apps, tiovx, tidl_j7, ivision)

### What Yocto provides

All `processor_sdk` headers come from `ti-vision-apps` and `ti-tidl` Yocto
recipes, staged into the recipe-sysroot:

```
/usr/include/processor_sdk/
├── vision_apps/       ← from ti-vision-apps
├── tiovx/             ← from ti-vision-apps
├── app_utils/         ← from ti-vision-apps
├── tidl_j7/           ← from ti-tidl (arm-tidl)
│   └── arm-tidl/rt/inc/
├── ivision/           ← from ti-vision-apps
└── vxlib/             ← from ti-vision-apps
```

### What Ubuntu Debian packages provide

Our `libtivision-apps-dev` and `ti-tidl-dev` packages install:

```
/usr/include/processor_sdk/
├── vision_apps/
├── tiovx/
├── app_utils/
├── tidl_j7/
│   └── arm-tidl/rt/inc/
├── ivision/
└── vxlib/
```

### Assessment

This section is **aligned** between Yocto and Ubuntu. The `processor_sdk`
header tree is identical since both install from the same upstream source.
`edgeai-tiovx-kernels/cmake/common.cmake` uses `PSDK_INCLUDE_PATH` which
defaults to `${TARGET_FS}/usr/include/` — resolving correctly to
`/usr/include/` on Ubuntu.

No change needed here.

---

## Gap 6 — GStreamer Dev Headers for `ti_ros_gst_plugins`

### What Yocto provides

GStreamer is built as a Yocto recipe. Headers are automatically present in the
recipe-sysroot for all recipes that `DEPEND` on `gstreamer1.0`.

### What Ubuntu provides

GStreamer dev headers are available via apt but are **not** installed by
default in a `BUILD_MINIMAL=yes` Armbian image.

### Breakage on Ubuntu

On-target native build of `ti_ros_gst_plugins` (robotics SDK):

```
fatal error: gst/gst.h: No such file or directory
```

### Fix applied (this build cycle)

Added to `config/boards/j784s4-evm.conf`:

```bash
PACKAGE_LIST_ADDITIONAL="... \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev"
```

---

## Gap 7 — ROS2 Environment (`ROS_DISTRO` not exported)

### What Yocto provides

Yocto builds ROS2 natively. `ros_environment` is a Yocto recipe that installs
DSV hook files into the colcon package registry. When `setup.bash` is sourced,
the colcon setup chain processes these hooks and exports `ROS_DISTRO=jazzy`.

Additionally, Yocto's `ti-ros*` packages are built as part of the SDK image
and install their colcon metadata (`share/colcon-core/packages/`,
`share/<pkg>/local_setup.{bash,sh,zsh}`) into the rootfs at image build time.

### What Ubuntu provides

On Ubuntu, `ros-jazzy-ros-environment` is an apt package. It installs DSV hook
files, but only registers with the colcon package index via an install script.
If the `ros_environment` package is not listed in `share/colcon-core/packages/`,
its hooks are silently skipped during `setup.bash` sourcing and `ROS_DISTRO`
is never exported.

**Importantly:** The `ti-ros*` packages are NOT pre-built in the Ubuntu image.
The user is expected to `apt install ros-jazzy-*` for the base ROS2 runtime
and then build `ti-ros*` packages on-device using the robotics SDK's
`cross_build.sh`. Any colcon metadata for TI-specific packages in
`/opt/ros/jazzy/share/` is placed there by the on-device build, not the
Armbian image.

### Breakage on Ubuntu

```
source /opt/ros/jazzy/setup.bash
echo $ROS_DISTRO    # → empty
```

Scripts that rely on `ROS_DISTRO` being set after sourcing `setup.bash` fail.

### Fix applied (this build cycle)

Added a fallback export in `edgeai-robotics-sdk/scripts/lib/build_common.sh`:

```bash
source_ros2() {
    set +u
    source /opt/ros/jazzy/setup.bash
    # Ensure ROS_DISTRO is set even if the colcon setup chain did not export it.
    export ROS_DISTRO="${ROS_DISTRO:-jazzy}"
    set -u
}
```

### Long-term fix

The `ros_environment` apt package should ensure it registers itself in
`share/colcon-core/packages/` via a post-install script, or the package
maintainers should fix `setup.bash` generation to always export `ROS_DISTRO`.
This is an upstream Ubuntu ROS2 packaging issue, not a TI issue.

---

## Summary Table

| # | Component | Yocto path | Ubuntu path | Gap type | Fix |
|---|-----------|-----------|-------------|----------|-----|
| 1 | TFLite static libs | `tflite_2.12/{ruy-build,...}/lib*.a` | `tflite_2.12/lib*.a` (flat) | cmake `link_directories` subdirs missing | Add `${TFLITE_INSTALL_DIR}` as flat fallback in consumer cmake |
| 2 | TFLite flatbuffers headers | `tensorflow/lite/tools/make/downloads/flatbuffers/include/` | Not installed (cmake build artifact) | Missing include path | Add `libflatbuffers-dev` apt package + include path fallback in consumer cmake |
| 3 | ONNX RT TIDL EP | Prebuilt `.so` has TIDL EP compiled in | Source build missing `onnxruntime_USE_TIDL=ON` | Missing cmake flag | **Fixed**: added flag to `build_onnxrt()` |
| 4 | TVM C++ headers | `/usr/include/tvm/tvm/include/` (copied from wheel) | Not installed under `/usr/include/` | Missing install step | **Fixed**: added `cp --parents` from TVM wheel to `/usr/include/tvm/tvm/` in `ti-tidl-osrt/debian/rules` |
| 5 | processor_sdk headers | `/usr/include/processor_sdk/...` | `/usr/include/processor_sdk/...` | **Aligned** ✓ | None needed |
| 6 | GStreamer dev headers | In Yocto sysroot automatically | Not in minimal image | Missing apt package | **Fixed**: added `libgstreamer1.0-dev` to board config |
| 7 | ROS_DISTRO env var | Exported by Yocto's `ros_environment` | Not reliably exported on Ubuntu | Upstream Ubuntu ROS2 packaging issue | **Fixed (workaround)**: fallback export in `source_ros2()` |

---

## Recommended Actions for TI Teams

### edgeai-dl-inferer / edgeai-tiovx-kernels

Changes to `cmake/common.cmake` — all **additive** (Yocto build unchanged):

1. **Gap 1**: Add `${TFLITE_INSTALL_DIR}` to `link_directories()` as a flat fallback.
2. **Gap 2**: Add a system flatbuffers include path fallback (conditioned on
   `TARGET_FS` being empty or the path not existing).
3. **Gap 4**: Add Python sitepackages TVM include paths as fallback when
   `/usr/include/tvm/tvm/` is absent.

Suggested cmake pattern:

```cmake
# Ubuntu/native-build fallback: add the flat tflite_2.12 dir
# (Yocto builds find libs in the named subdirs; Ubuntu finds them flat)
if(NOT EXISTS "${TFLITE_INSTALL_DIR}/ruy-build")
    link_directories(${TFLITE_INSTALL_DIR})
endif()
```

### ti-tidl-osrt Debian package

1. **Gap 4**: ✓ **Done** — `debian/rules` now copies TVM C++ headers from the
   Python wheel to `/usr/include/tvm/tvm/`, mirroring the Yocto recipe.
   Requires a package rebuild to produce an updated `ti-tidl-osrt-dev.deb`.

### edgeai-robotics-sdk

No cmake changes needed for the gaps above (the robotics SDK links against
installed Debian packages, not rebuilt `edgeai-dl-inferer`). However:

1. The `source_ros2()` fallback for `ROS_DISTRO` should remain until the
   upstream Ubuntu ROS2 packaging issue is resolved.
2. Build scripts should not assume any `share/colcon-core/packages/` entries
   for TI-specific packages exist before the first on-device build.
