# tool.cmake — CMake cross-compile toolchain for ONNX Runtime 1.15
# Cross-compiles from x86_64 host to aarch64 target.
#
# Compiler resolution order:
#   1. If CROSS_CC / CROSS_CXX env vars are set, use those.
#   2. Look for aarch64-linux-gnu-gcc/g++ in PATH (Ubuntu cross package).
#
# Python extension (onnxruntime_pybind11_state.so) uses aarch64 Python headers
# from the python3.12-dev:arm64 multiarch package:
#   sudo dpkg --add-architecture arm64
#   sudo apt install python3-dev:arm64

SET(CMAKE_SYSTEM_NAME Linux)
SET(CMAKE_SYSTEM_PROCESSOR aarch64)
SET(CMAKE_SYSTEM_VERSION 1)

# --- Locate cross-compiler ---
if(DEFINED ENV{CROSS_CC})
  SET(CMAKE_C_COMPILER "$ENV{CROSS_CC}")
else()
  find_program(_cross_gcc NAMES aarch64-linux-gnu-gcc REQUIRED)
  SET(CMAKE_C_COMPILER "${_cross_gcc}")
endif()

if(DEFINED ENV{CROSS_CXX})
  SET(CMAKE_CXX_COMPILER "$ENV{CROSS_CXX}")
else()
  find_program(_cross_gxx NAMES aarch64-linux-gnu-g++ REQUIRED)
  SET(CMAKE_CXX_COMPILER "${_cross_gxx}")
endif()

# --- Locate aarch64 Python headers ---
# Target Python version: TI PSDK 11.02 devices run Python 3.12.
set(_py_ver "3.12")

if(EXISTS "/usr/include/aarch64-linux-gnu/python${_py_ver}/pyconfig.h")
  set(_py_inc_dir "/usr/include/python${_py_ver}")
else()
  message(FATAL_ERROR
    "aarch64 Python ${_py_ver} headers not found.\n"
    "Install with:\n"
    "  sudo dpkg --add-architecture arm64\n"
    "  sudo apt install python3-dev:arm64")
endif()

# Force cmake's FindPython3 to use the cross-target include directory.
# Without CACHE FORCE, cmake detects Python from the host interpreter
# (/usr/bin/python3) and picks up the host Python headers, which then
# trigger -Werror=poison-system-directories in the cross-compiler.
set(Python3_INCLUDE_DIR   "${_py_inc_dir}"
    CACHE PATH "aarch64 Python ${_py_ver} include directory" FORCE)
set(Python3_INCLUDE_DIRS  "${_py_inc_dir}"
    CACHE PATH "aarch64 Python ${_py_ver} include directories" FORCE)

SET(Python3_EXECUTABLE /usr/bin/python3)

# --- GCC 13 compatibility flags ---
# ONNX Runtime 1.15 was developed against GCC 11.  GCC 13 promotes several
# additional warnings to errors.  Demote them back to warnings so the build
# succeeds without requiring per-file source patches.
#   -Wno-error=array-bounds        : false positive on vector::back() in templates
#   -Wno-error=range-loop-construct: copy vs ref for gsl::not_null<T*> in range-for
#   -Wno-error=restrict            : false positive in GCC 13 with -O2 + memset
#   -Wno-error=stringop-overflow   : template-instantiation false positive
# GCC's header search order: -I dirs first, then -isystem dirs.
# By prepending the aarch64 Python include path with -I here, it takes
# precedence over cmake's "-isystem /usr/include/python3.x" (injected by
# FindPython3's IMPORTED target using the host interpreter).
SET(CMAKE_C_FLAGS_INIT
    "-I${_py_inc_dir} -Wno-error=array-bounds -Wno-error=restrict -Wno-error=stringop-overflow -Wno-poison-system-directories")
SET(CMAKE_CXX_FLAGS_INIT
    "-I${_py_inc_dir} -Wno-error=array-bounds -Wno-error=range-loop-construct -Wno-error=restrict -Wno-error=stringop-overflow -Wno-error=dangling-reference -Wno-poison-system-directories")

# Prevent CMake from using host (x86_64) programs/libraries for the target.
SET(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
SET(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
SET(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
SET(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
