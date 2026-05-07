#!/usr/bin/env bash
# Copyright 2021 The TensorFlow Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Adapted for TI EdgeAI cross-compilation from x86_64 to aarch64.
# Key changes vs upstream:
#   - aarch64 case: use ARMCC_PREFIX env to select cross-compiler.
#   - aarch64 case: if ARMCC_PREFIX set, use arm64 multiarch Python headers
#     (/usr/include/aarch64-linux-gnu/python3.12) for cross-compile.
# ==============================================================================
set -ex

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${CI_BUILD_PYTHON:-python3}"
VERSION_SUFFIX=${VERSION_SUFFIX:-}
export TENSORFLOW_DIR="${SCRIPT_DIR}/../../../.."
TENSORFLOW_LITE_DIR="${TENSORFLOW_DIR}/tensorflow/lite"
TENSORFLOW_VERSION=$(grep "_VERSION = " "${TENSORFLOW_DIR}/tensorflow/tools/pip_package/setup.py" | cut -d= -f2 | sed "s/[ '-]//g")
export PACKAGE_VERSION="${TENSORFLOW_VERSION}${VERSION_SUFFIX}"
export PROJECT_NAME=${WHEEL_PROJECT_NAME:-tflite_runtime}
BUILD_DIR="${SCRIPT_DIR}/gen/tflite_pip/${PYTHON}"
TENSORFLOW_TARGET=${TENSORFLOW_TARGET:-$1}
if [ "${TENSORFLOW_TARGET}" = "rpi" ]; then
  export TENSORFLOW_TARGET="armhf"
fi
PYTHON_INCLUDE=$(${PYTHON} -c "from sysconfig import get_paths as gp; print(gp()['include'])")
PYBIND11_INCLUDE=$(${PYTHON} -c "import pybind11; print (pybind11.get_include())")
NUMPY_INCLUDE=$(${PYTHON} -c "import numpy; print (numpy.get_include())")
export CROSSTOOL_PYTHON_INCLUDE_PATH=${PYTHON_INCLUDE}

# Build source tree.
rm -rf "${BUILD_DIR}" && mkdir -p "${BUILD_DIR}/tflite_runtime"
cp -r "${TENSORFLOW_LITE_DIR}/tools/pip_package/debian" \
      "${TENSORFLOW_LITE_DIR}/tools/pip_package/MANIFEST.in" \
      "${TENSORFLOW_LITE_DIR}/python/interpreter_wrapper" \
      "${BUILD_DIR}"
cp  "${TENSORFLOW_LITE_DIR}/tools/pip_package/setup_with_binary.py" "${BUILD_DIR}/setup.py"
cp "${TENSORFLOW_LITE_DIR}/python/interpreter.py" \
   "${TENSORFLOW_LITE_DIR}/python/metrics/metrics_interface.py" \
   "${TENSORFLOW_LITE_DIR}/python/metrics/metrics_portable.py" \
   "${BUILD_DIR}/tflite_runtime"
echo "__version__ = '${PACKAGE_VERSION}'" >> "${BUILD_DIR}/tflite_runtime/__init__.py"
echo "__git_version__ = '$(git -C "${TENSORFLOW_DIR}" describe --always --tags 2>/dev/null || echo unknown)'" >> "${BUILD_DIR}/tflite_runtime/__init__.py"

# Build python interpreter_wrapper.
mkdir -p "${BUILD_DIR}/cmake_build"
cd "${BUILD_DIR}/cmake_build"

echo "Building for ${TENSORFLOW_TARGET}"
case "${TENSORFLOW_TARGET}" in
  armhf)
    eval $(${TENSORFLOW_LITE_DIR}/tools/cmake/download_toolchains.sh "${TENSORFLOW_TARGET}")
    ARMCC_FLAGS="${ARMCC_FLAGS} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"
    cmake \
      -DCMAKE_C_COMPILER=${ARMCC_PREFIX}gcc \
      -DCMAKE_CXX_COMPILER=${ARMCC_PREFIX}g++ \
      -DCMAKE_C_FLAGS="${ARMCC_FLAGS}" \
      -DCMAKE_CXX_FLAGS="${ARMCC_FLAGS}" \
      -DCMAKE_SYSTEM_NAME=Linux \
      -DCMAKE_SYSTEM_PROCESSOR=armv7 \
      -DTFLITE_ENABLE_XNNPACK=OFF \
      "${TENSORFLOW_LITE_DIR}"
    ;;
  aarch64)
    # When ARMCC_PREFIX is set (cross-compile from x86_64), locate arm64 Python
    # headers.  When empty (native aarch64 build), use host sysconfig paths.
    if [[ -n "${ARMCC_PREFIX:-}" ]]; then
      # Target Python version: TI PSDK 11.02 devices run Python 3.12.
      _cross_py_ver="3.12"
      if [[ -f "/usr/include/aarch64-linux-gnu/python${_cross_py_ver}/pyconfig.h" ]]; then
        # Ubuntu multiarch (python3-dev:arm64 installed)
        CROSS_PY_INCLUDE="-I/usr/include/python${_cross_py_ver} -I/usr/include/aarch64-linux-gnu/python${_cross_py_ver}"
      else
        echo "ERROR: aarch64 Python ${_cross_py_ver} headers not found." >&2
        echo "  Install with:" >&2
        echo "    sudo dpkg --add-architecture arm64" >&2
        echo "    sudo apt install python3-dev:arm64" >&2
        exit 1
      fi
    else
      CROSS_PY_INCLUDE="-I${PYTHON_INCLUDE}"
    fi
    # -D_GNU_SOURCE: must be defined before any header to enable mremap/MREMAP_MAYMOVE.
    # -include stdint.h: GCC 13 requires explicit include for uint32_t in older code.
    # Both flags are needed and order matters: _GNU_SOURCE (-D flag) is evaluated by
    # the preprocessor before forced includes (-include), so features.h sees it first.
    ARMCC_FLAGS="${ARMCC_FLAGS:-} -funsafe-math-optimizations -D_GNU_SOURCE -include stdint.h ${CROSS_PY_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"
    cmake \
      -DCMAKE_C_COMPILER=${ARMCC_PREFIX:-}gcc \
      -DCMAKE_CXX_COMPILER=${ARMCC_PREFIX:-}g++ \
      -DCMAKE_C_FLAGS="${ARMCC_FLAGS}" \
      -DCMAKE_CXX_FLAGS="${ARMCC_FLAGS}" \
      -DCMAKE_SYSTEM_NAME=Linux \
      -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
      "${TENSORFLOW_LITE_DIR}"
    ;;
  native)
    BUILD_FLAGS=${BUILD_FLAGS:-"-march=native -I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}
    cmake \
      -DCMAKE_C_FLAGS="${BUILD_FLAGS}" \
      -DCMAKE_CXX_FLAGS="${BUILD_FLAGS}" \
      "${TENSORFLOW_LITE_DIR}"
    ;;
  *)
    BUILD_FLAGS=${BUILD_FLAGS:-"-I${PYTHON_INCLUDE} -I${PYBIND11_INCLUDE} -I${NUMPY_INCLUDE}"}
    cmake \
      -DCMAKE_C_FLAGS="${BUILD_FLAGS}" \
      -DCMAKE_CXX_FLAGS="${BUILD_FLAGS}" \
      "${TENSORFLOW_LITE_DIR}"
    ;;
esac

cmake --build . --verbose -j ${BUILD_NUM_JOBS:-$(nproc)} -t _pywrap_tensorflow_interpreter_wrapper
cd "${BUILD_DIR}"

cp "${BUILD_DIR}/cmake_build/_pywrap_tensorflow_interpreter_wrapper.so" \
   "${BUILD_DIR}/tflite_runtime"
chmod u+w "${BUILD_DIR}/tflite_runtime/_pywrap_tensorflow_interpreter_wrapper.so"

# Build python wheel.
cd "${BUILD_DIR}"
case "${TENSORFLOW_TARGET}" in
  armhf)
    WHEEL_PLATFORM_NAME="${WHEEL_PLATFORM_NAME:-linux-armv7l}"
    ${PYTHON} setup.py bdist --plat-name=${WHEEL_PLATFORM_NAME} \
                       bdist_wheel --plat-name=${WHEEL_PLATFORM_NAME}
    ;;
  aarch64)
    WHEEL_PLATFORM_NAME="${WHEEL_PLATFORM_NAME:-linux-aarch64}"
    ${PYTHON} setup.py bdist --plat-name=${WHEEL_PLATFORM_NAME} \
                       bdist_wheel --plat-name=${WHEEL_PLATFORM_NAME}
    ;;
  *)
    if [[ -n "${WHEEL_PLATFORM_NAME:-}" ]]; then
      ${PYTHON} setup.py bdist --plat-name=${WHEEL_PLATFORM_NAME} \
                         bdist_wheel --plat-name=${WHEEL_PLATFORM_NAME}
    else
      ${PYTHON} setup.py bdist bdist_wheel
    fi
    ;;
esac

echo "Output can be found here:"
find "${BUILD_DIR}/dist"
