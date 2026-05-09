# TI EdgeAI + Armbian Build Architecture

## Overview

This document describes the complete build flow for TI EdgeAI packages on
Armbian/Ubuntu Noble for the j784s4-evm board family. It explains what
Yocto does natively, how our Debian-based build mimics the same sysroot
population model, and why there is no fundamentally simpler approach outside
of a dedicated build framework like Yocto.

---

## 1. Package Dependency Graph

The build-time dependency between packages drives the phase ordering.

```plantuml
@startuml package-deps
skinparam rectangle {
    BackgroundColor #DDEEFF
    BorderColor #336699
}
skinparam arrow {
    Color #336699
}

rectangle "libti-rpmsg-char0\nlibti-rpmsg-char-dev" as rpmsg #AADDAA
rectangle "ti-tidl-osrt\nti-tidl-osrt-dev" as osrt #AADDAA
rectangle "libtivision-apps11.2.0\nlibtivision-apps-dev\nti-vision-apps-data" as vapps #AADDFF
rectangle "ti-tidl\nti-tidl-dev" as tidl #FFD9AA
rectangle "ti-adas-firmware" as fw #EEEEAA
rectangle "edgeai-apps-utils\nedgeai-apps-utils-dev" as eutils #FFCCDD
rectangle "edgeai-tiovx-kernels\nedgeai-tiovx-kernels-dev" as etkern #FFCCDD
rectangle "edgeai-dl-inferer\nedgeai-dl-inferer-dev" as edli #FFCCDD

rpmsg --> vapps  : headers + libs\nat build time
rpmsg --> tidl   : headers + libs\nat build time
vapps --> tidl   : headers + libs\nat build time
vapps --> eutils : headers + libs\nat build time
osrt  --> edli   : headers + libs\nat build time
eutils --> etkern : headers + libs\nat build time
eutils --> edli   : headers + libs\nat build time

note right of rpmsg  : Phase A1
note right of osrt   : Phase A1
note right of vapps  : Phase A2
note right of tidl   : Phase A3
note right of fw     : Phase FW (independent)
note right of eutils : Phase E1
note right of etkern : Phase E2
note right of edli   : Phase E2
@enduml
```

`ti-tidl-osrt` and `ti-adas-firmware` have no build-time dependency on the
other packages. `ti-adas-firmware` is entirely independent (pre-built blobs).
Both A1 packages (`ti-rpmsg-char`, `ti-tidl-osrt`) can build in parallel.

---

## 2. How Yocto Manages This

Yocto (BitBake) resolves the dependency graph automatically through its
**recipe sysroot** mechanism.

```plantuml
@startuml yocto-flow
skinparam sequenceMessageAlign center
skinparam backgroundColor #FAFAFA

participant "BitBake\nScheduler" as bb
participant "ti-rpmsg-char\n.bb recipe" as rpmsg
participant "ti-vision-apps\n.bb recipe" as vapps
participant "ti-tidl\n.bb recipe" as tidl
participant "edgeai-apps-utils\n.bb recipe" as eutils
participant "Shared\nSTAGING_DIR_TARGET\n(sysroot)" as sysroot

bb -> rpmsg : schedule (no DEPENDS on our packages)
activate rpmsg
rpmsg -> rpmsg : do_fetch / do_unpack\ndo_configure / do_compile
rpmsg -> sysroot : do_populate_sysroot\ncopies headers + .so stubs
deactivate rpmsg

bb -> vapps : schedule\n(DEPENDS = "ti-rpmsg-char virtual/egl freetype ...")
activate vapps
note right of vapps
  BitBake auto-populates
  ${WORKDIR}/recipe-sysroot
  from all DEPENDS before
  do_configure runs.
end note
vapps -> sysroot : reads ti_rpmsg_char.h, EGL/GLES headers
vapps -> vapps : do_compile\n(SDK builder yocto_build target)
vapps -> sysroot : do_populate_sysroot\ncopies libtivision_apps.so + headers
deactivate vapps

bb -> tidl : schedule\n(DEPENDS += "ti-vision-apps")
activate tidl
tidl -> sysroot : reads processor_sdk/ headers\nlibtivision_apps.so, libti_rpmsg_char.so
tidl -> tidl : do_compile\n(arm-tidl delegates)
tidl -> sysroot : do_populate_sysroot
deactivate tidl

bb -> eutils : schedule\n(DEPENDS += "ti-vision-apps")
activate eutils
eutils -> sysroot : reads vision_apps headers
eutils -> eutils : do_compile\n(NEON utility lib)
eutils -> sysroot : do_populate_sysroot
deactivate eutils
@enduml
```

**Key Yocto mechanisms:**
- Every recipe declares `DEPENDS` listing its build-time prerequisites.
- Before `do_configure` runs, BitBake automatically runs `do_populate_sysroot`
  for all `DEPENDS`, placing headers and `.so` stubs into
  `${WORKDIR}/recipe-sysroot`.
- There is one shared `STAGING_DIR_TARGET` that accumulates all target
  libraries and headers as recipes are built.
- **No manual sysroot management** is needed — the build framework handles it.

---

## 3. Our Debian Build Flow

We replicate the same dependency ordering outside of Yocto using Docker
containers and `.deb` overlay steps between phases.

### 3.1 Build sequence

```
B1  Armbian base image   — kernel, u-boot, firmware (no EdgeAI)
A1  ti-rpmsg-char        — autotools cross-compile
    ti-tidl-osrt         — TFLite + ONNX RT cross-compiled from source
A2  ti-vision-apps       — SDK builder source build (overlays A1 debs first)
A3  ti-tidl              — arm-tidl delegates (overlays A1+A2 debs first)
FW  ti-adas-firmware     — R5F MCU + C7x DSP RTOS firmware blobs (independent)
E1  edgeai-apps-utils    — NEON utility lib (overlays A2 dev headers first)
E2  edgeai-tiovx-kernels — OpenVX kernels (overlays A2+E1 dev headers first)
    edgeai-dl-inferer    — DL inference abstraction (overlays A1+E1 dev headers)
B2  Final Armbian image  — installs all EdgeAI .deb packages
```

B1 and A/FW/E phases have no dependency on each other, so B1 runs first (it
is the longest step) and A/E phases run afterward. B2 requires both B1 and
all A/E phases to be complete.

### 3.2 Docker mode (default, tested)

```plantuml
@startuml docker-flow
skinparam backgroundColor #FAFAFA
skinparam sequenceMessageAlign left

actor Developer as dev
participant "build_armbian.sh\n(packages/edgeai/)" as script
participant "ti-edgeai-build\nDocker container\n(/opt/arm64-sysroot)" as docker
participant "compile.sh\n(Armbian)" as armbian
participant "output/debs/extra/" as debs

== B1 — Armbian base image (kernel + u-boot) ==
dev -> script : bash packages/edgeai/build_armbian.sh\n--sdk-path /opt/sdk
script -> armbian : compile.sh BOARD=j784s4-evm\n(no ENABLE_EXTENSIONS)
armbian --> script : Armbian-..._minimal.img\n(no EdgeAI packages)

== A1 — ti-rpmsg-char + ti-tidl-osrt ==
script -> docker : docker-build.sh ti-rpmsg-char
docker -> docker : autotools cross-compile\naarch64-linux-gnu-gcc
docker --> script : libti-rpmsg-char0.deb\nlibti-rpmsg-char-dev.deb

script -> docker : docker-build.sh ti-tidl-osrt
docker -> docker : cross-compile TFLite + ONNX RT\ndownload TVM + tidlruntime from CDN
docker --> script : ti-tidl-osrt.deb\nti-tidl-osrt-dev.deb

== A2 — ti-vision-apps ==
script -> docker : docker-build.sh --sdk-path /sdk ti-vision-apps

note over docker
  pre_cmd (inside container, before build):
    dpkg-deb -x libti-rpmsg-char0.deb /opt/arm64-sysroot
    dpkg-deb -x libti-rpmsg-char-dev.deb /opt/arm64-sysroot
  Equivalent to Yocto's do_populate_sysroot for ti-rpmsg-char.
end note

docker -> docker : repo sync SDK (first run only)\nSDK builder yocto_build target\naarch64-oe-linux-gcc --sysroot
docker --> script : libtivision-apps11.2.0.deb\nlibtivision-apps-dev.deb\nti-vision-apps-data.deb

== A3 — ti-tidl ==
script -> docker : docker-build.sh ti-tidl

note over docker
  pre_cmd (inside container, before build):
    dpkg-deb -x libti-rpmsg-char{0,-dev}.deb /opt/arm64-sysroot
    dpkg-deb -x libtivision-apps{11.2.0,-dev}.deb /opt/arm64-sysroot
  Equivalent to Yocto's do_populate_sysroot for rpmsg + vision-apps.
end note

docker -> docker : make arm-tidl delegates\naarch64-oe-linux-gcc --sysroot
docker --> script : ti-tidl.deb\nti-tidl-dev.deb

== FW — ti-adas-firmware (independent, no sysroot needed) ==
script -> docker : docker-build.sh ti-adas-firmware
docker --> script : ti-adas-firmware.deb

== E1 — edgeai-apps-utils ==
script -> docker : docker-build.sh edgeai-apps-utils

note over docker
  pre_cmd (inside container, before build):
    dpkg-deb -x libtivision-apps-dev.deb /opt/arm64-sysroot
  Overlays A2 dev headers so edgeai-apps-utils CMake can find vision_apps.
end note

docker --> script : edgeai-apps-utils.deb\nedgeai-apps-utils-dev.deb

== E2 — edgeai-tiovx-kernels + edgeai-dl-inferer ==
script -> docker : docker-build.sh edgeai-tiovx-kernels

note over docker
  pre_cmd (inside container, before build):
    dpkg-deb -x libtivision-apps-dev.deb /opt/arm64-sysroot
    dpkg-deb -x edgeai-apps-utils-dev.deb /opt/arm64-sysroot
  Overlays A2+E1 dev headers (mimics do_populate_sysroot for both).
end note

docker --> script : edgeai-tiovx-kernels.deb\nedgeai-tiovx-kernels-dev.deb

script -> docker : docker-build.sh edgeai-dl-inferer
docker --> script : edgeai-dl-inferer.deb\nedgeai-dl-inferer-dev.deb

== B2 — Final Armbian image ==
script -> debs : cp packages/edgeai/*.deb output/debs/extra/
script -> armbian : compile.sh BOARD=j784s4-evm\nENABLE_EXTENSIONS=ti-debpkgs

note over armbian
  ti-debpkgs extension:
  apt-get install all .deb files
  into the arm64 chroot in one pass
  (resolves cross-package deps)
end note

armbian --> dev : Armbian-..._minimal.img\n(all EdgeAI packages installed)
@enduml
```

### 3.3 No-Docker mode (not tested end-to-end)

Each package's `build-from-source.sh` is called directly on the host.
The `.deb` overlay step runs on a host-side writable sysroot instead of
inside a container. See prerequisites in `packages/edgeai/build_armbian.sh`.

```plantuml
@startuml nodock-flow
skinparam backgroundColor #FAFAFA
skinparam sequenceMessageAlign left

actor Developer as dev
participant "build_armbian.sh\n(host)" as script
participant "Host cross-tools\n/opt/cross-oe/bin\naarch64-linux-gnu-*" as tools
participant "Host sysroot\n/opt/arm64-sysroot\n(writable)" as sysroot

== B1 — Armbian base image ==
script -> script : compile.sh (uses its own Docker)

== A1 ==
script -> tools : ti-rpmsg-char/build-from-source.sh
script -> tools : ti-tidl-osrt/build-from-source.sh

== A2 ==
script -> sysroot : dpkg-deb -x libti-rpmsg-char*.deb\n(host-side overlay — mimics do_populate_sysroot)
script -> tools : ti-vision-apps/build-from-source.sh\n--toolchain-bin /opt/cross-oe/bin\n--sysroot /opt/arm64-sysroot

== A3 ==
script -> sysroot : dpkg-deb -x libti-rpmsg-char*.deb\ndpkg-deb -x libtivision-apps*.deb
script -> tools : ti-tidl/build-from-source.sh\n--sysroot /opt/arm64-sysroot

== E1 ==
script -> sysroot : dpkg-deb -x libtivision-apps-dev*.deb
script -> tools : edgeai-apps-utils/build-from-source.sh\n--sysroot /opt/arm64-sysroot

== E2 ==
script -> sysroot : dpkg-deb -x libtivision-apps-dev*.deb\ndpkg-deb -x edgeai-apps-utils-dev*.deb
script -> tools : edgeai-tiovx-kernels/build-from-source.sh
script -> tools : edgeai-dl-inferer/build-from-source.sh

== B2 ==
script -> script : stage debs → compile.sh ENABLE_EXTENSIONS=ti-debpkgs
@enduml
```

---

## 4. Yocto vs. Debian Build System Comparison

```plantuml
@startuml comparison
skinparam backgroundColor #FAFAFA

package "Yocto / BitBake" {
    [DEPENDS declaration\nin .bb recipe] as dep
    [do_populate_sysroot\n(automatic task)] as pop
    [STAGING_DIR_TARGET\n(shared, grows over time)] as staging

    dep --> pop : triggers automatically
    pop --> staging : writes headers + .so stubs
}

package "Our Debian/Docker Build" {
    [Phase ordering\nin build_armbian.sh] as phases
    [pre_cmd / overlay_deb\ndpkg-deb -x *.deb /sysroot] as overlay
    [/opt/arm64-sysroot\n(Docker-internal, grows over time)] as docker_sr

    phases --> overlay : explicit shell steps
    overlay --> docker_sr : writes headers + .so
}

note bottom of pop
  Automatic — no shell script needed.
end note

note bottom of overlay
  Manual — functionally identical outcome.
end note
@enduml
```

| Aspect | Yocto | Our Debian/Docker Build |
|---|---|---|
| Dependency declaration | `DEPENDS = "pkg"` in `.bb` recipe | Phase ordering in `build_armbian.sh` |
| Sysroot population | Automatic via `do_populate_sysroot` | Manual `dpkg-deb -x` overlay between phases |
| Sysroot location | `${STAGING_DIR_TARGET}` (shared) | `/opt/arm64-sysroot` in Docker container |
| Cross-compiler | OE toolchain (`aarch64-oe-linux-`) | Ubuntu `aarch64-linux-gnu-` + OE compat shim |
| Package format | `.ipk` / `.rpm` | `.deb` |
| Build isolation | Separate `WORKDIR` per recipe | Docker container per package group |
| Incremental build | BitBake task hash tracking | `--skip-*` flags in `build_armbian.sh` |
| Host requirements | Yocto host tools + large initial download | Docker only (or cross-tools for no-Docker) |

---

## 5. Does Debian Have a More Efficient Flow?

Short answer: **No.**

Debian's packaging system (`dpkg`/`apt`) is designed for installing packages
on a running target, not for managing cross-compilation build trees. Its
multi-arch support (`dpkg --add-architecture arm64`) allows co-installing
arm64 and amd64 packages on an x86_64 host, but this:

- Requires `sudo` and modifies the host system permanently.
- Does not isolate builds between packages — a bad install can break all
  subsequent builds.
- Has no equivalent of Yocto's per-recipe `recipe-sysroot` snapshot.

The Debian ecosystem's conventional answer is **sbuild**, **pbuilder**
(chroot-based), or **Docker** — which is exactly what we use. Our Docker
container with `/opt/arm64-sysroot` is the Debian-idiomatic equivalent of
Yocto's `STAGING_DIR_TARGET`. The `.deb` overlay pattern is the closest
Debian equivalent of `do_populate_sysroot`.

---

## 6. Build Script Relationship

```plantuml
@startuml scripts
skinparam backgroundColor #FAFAFA

rectangle "packages/edgeai/build_armbian.sh" as top #AADDFF {
    note as n1
      Top-level orchestrator (TI-specific, not upstream).
      Sequence: B1 → A1 → A2 → A3 → FW → E1 → E2 → B2.
      --docker (default) / --no-docker.
      Self-derives repo root from BASH_SOURCE[0].
    end note
}

rectangle "packages/edgeai/docker-build.sh" as dbs #CCDDFF {
    note as n2
      Manages ti-edgeai-build Docker image.
      Handles pre_cmd .deb overlays before each phase.
    end note
}

rectangle "ti-rpmsg-char/build-from-source.sh" as rpmsg_bs #DDEEDD
rectangle "ti-tidl-osrt/build-from-source.sh" as osrt_bs #DDEEDD
rectangle "ti-vision-apps/build-from-source.sh" as va_bs #DDEEDD
rectangle "ti-tidl/build-from-source.sh" as tidl_bs #DDEEDD
rectangle "ti-adas-firmware/build-from-source.sh" as fw_bs #DDEEDD
rectangle "edgeai-apps-utils/build-from-source.sh" as eu_bs #FFCCDD
rectangle "edgeai-tiovx-kernels/build-from-source.sh" as etk_bs #FFCCDD
rectangle "edgeai-dl-inferer/build-from-source.sh" as edli_bs #FFCCDD

rectangle "compile.sh (Armbian)" as compile #FFEEDD {
    note as n3
      B1: base image (no EdgeAI)
      B2: + ENABLE_EXTENSIONS=ti-debpkgs
    end note
}

rectangle "extensions/ti-debpkgs.sh" as ext #FFE8BB

top --> dbs       : Docker mode A1/A2/A3/FW/E1/E2
top --> rpmsg_bs  : no-Docker A1
top --> osrt_bs   : no-Docker A1
top --> va_bs     : no-Docker A2
top --> tidl_bs   : no-Docker A3
top --> fw_bs     : no-Docker FW
top --> eu_bs     : no-Docker E1
top --> etk_bs    : no-Docker E2
top --> edli_bs   : no-Docker E2
top --> compile   : B1 and B2

dbs --> rpmsg_bs  : inside container
dbs --> osrt_bs   : inside container
dbs --> va_bs     : inside container
dbs --> tidl_bs   : inside container
dbs --> fw_bs     : inside container
dbs --> eu_bs     : inside container
dbs --> etk_bs    : inside container
dbs --> edli_bs   : inside container

compile --> ext   : B2 only
@enduml
```

---

## 7. Quick Reference

```bash
# Full build (B1 → A1 → A2 → A3 → FW → E1 → E2 → B2):
bash packages/edgeai/build_armbian.sh \
    --mirror   /mnt/DATA/YOCTO/yocto-build/downloads/git2 \
    --sdk-path /opt/ti-vision-apps-sdk

# Kernel already built — EdgeAI packages + final image only:
bash packages/edgeai/build_armbian.sh --skip-kernel \
    --sdk-path /opt/ti-vision-apps-sdk

# All debs already built — regenerate final image only:
bash packages/edgeai/build_armbian.sh --skip-kernel --skip-edgeai

# EdgeAI packages only (no Armbian image builds):
bash packages/edgeai/build_armbian.sh --skip-kernel --skip-image \
    --sdk-path /opt/ti-vision-apps-sdk

# E1+E2 only (A1-A3 and FW already built):
bash packages/edgeai/build_armbian.sh \
    --skip-kernel --skip-base-pkgs --skip-vision-apps --skip-tidl --skip-fw \
    --skip-image
```
