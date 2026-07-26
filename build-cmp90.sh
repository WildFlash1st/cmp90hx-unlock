#!/bin/bash
set -euo pipefail

TARBALL_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/610.43.03.tar.gz"
TARBALL="/build/nv-build/open-gpu-kernel-modules-610.43.03.tar.gz"
SRC_DIR="/build/nv-build/open-gpu-kernel-modules-610.43.03"

mkdir -p /build/nv-build
test -f "$TARBALL" || wget -q "$TARBALL_URL" -O "$TARBALL"
rm -rf "$SRC_DIR"
tar -xzf "$TARBALL" -C /build/nv-build
cd "$SRC_DIR"

patch -p1 < /build/cmpunlocker/driver/patches/cmp90/0007-cmp90-compute-unlock.patch

cat > kernel-open/common/inc/nv_stdarg.h << 'NVSTDARG'
#ifndef _NV_STDARG_H_
#define _NV_STDARG_H_
#if defined(NV_KERNEL_INTERFACE_LAYER) && defined(NV_LINUX)
  #include <linux/stdarg.h>
#else
  #include <stdarg.h>
#endif
#endif
NVSTDARG

python3 << 'PYFIX'
import pathlib

# Fix nv-mm.h
p = pathlib.Path("kernel-open/common/inc/nv-mm.h")
t = p.read_text()
t = t.replace('#include "nv-kernel61-compat.h"\n', '')
t = t.replace('#include "conftest.h"\n', '#include "conftest.h"\n#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,1,0)\n  #undef NV_MM_HAS_MMAP_LOCK\n  #define NV_MM_HAS_MMAP_LOCK 1\n  #undef NV_VM_FAULT_T_IS_PRESENT\n  #define NV_VM_FAULT_T_IS_PRESENT 1\n  #undef NV_VM_FLAGS_SET_PRESENT\n#endif\n')
p.write_text(t)

# Fix nv-linux.h
p = pathlib.Path("kernel-open/common/inc/nv-linux.h")
t = p.read_text()
t = t.replace('#include "nv-kernel61-compat.h"\n', '')
t = t.replace('#include <linux/dma-mapping.h>\n', '#include <linux/dma-mapping.h>\n#include <linux/dma-map-ops.h>\n#include <linux/dma-direct.h>\n')
p.write_text(t)

# Fix backlight
p = pathlib.Path("kernel-open/nvidia/nv-backlight.c")
t = p.read_text()
t = t.replace("get_backlight_device_by_name(", "backlight_device_get_by_name(")
p.write_text(t)

# Fix of_dma_configure
p = pathlib.Path("kernel-open/nvidia/nv-platform.c")
t = p.read_text()
t = t.replace("rc = of_dma_configure(\n        &niso_plat_dev->dev,\n        niso_np",
              "rc = of_dma_configure(\n        &niso_plat_dev->dev,\n        niso_np,\n        false")
p.write_text(t)
PYFIX

# Build pass 1: generate conftest
make -j1 modules SYSSRC=/lib/modules/6.1.0-50-amd64/build 2>/dev/null || true

# Fix conftest and CRITICALLY replace conftest.sh with a no-op to prevent regeneration
C=kernel-open/conftest
sed -i 's/^#undef NV_MM_HAS_MMAP_LOCK$/#define NV_MM_HAS_MMAP_LOCK/' "$C/types.h" 2>/dev/null || true
sed -i 's/^#undef NV_VM_FAULT_T_IS_PRESENT$/#define NV_VM_FAULT_T_IS_PRESENT/' "$C/types.h" "$C/generic.h" 2>/dev/null || true
sed -i 's/^#undef NV_OF_PROPERTY_FOR_EACH_U32_HAS_INTERNAL_ARGS$/#define NV_OF_PROPERTY_FOR_EACH_U32_HAS_INTERNAL_ARGS/' "$C/types.h" 2>/dev/null || true
sed -i 's/^#undef NV_LINUX_OF_GPIO_H_PRESENT$/#define NV_LINUX_OF_GPIO_H_PRESENT/' "$C/headers.h" 2>/dev/null || true
sed -i 's/^#define NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT 2$/#define NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT 3/' "$C/functions.h" 2>/dev/null || true
sed -i 's/^#define NV_VM_FLAGS_SET_PRESENT$/\/\/#define NV_VM_FLAGS_SET_PRESENT/' "$C/functions.h" 2>/dev/null || true
grep -q 'NV_MM_HAS_MMAP_LOCK' "$C/types.h" || echo '#define NV_MM_HAS_MMAP_LOCK' >> "$C/types.h"
grep -q 'NV_VM_FAULT_T_IS_PRESENT' "$C/types.h" || echo '#define NV_VM_FAULT_T_IS_PRESENT' >> "$C/types.h"
grep -q 'NV_OF_PROPERTY_FOR_EACH_U32_HAS_INTERNAL_ARGS' "$C/types.h" || echo '#define NV_OF_PROPERTY_FOR_EACH_U32_HAS_INTERNAL_ARGS' >> "$C/types.h"
grep -q 'NV_LINUX_OF_GPIO_H_PRESENT' "$C/headers.h" || echo '#define NV_LINUX_OF_GPIO_H_PRESENT' >> "$C/headers.h"

# Add compat overrides to conftest/types.h (this is what conftest.h includes)
cat >> "$C/types.h" << 'CONFTYPES'
/* Kernel 6.1 compatibility overrides */
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,1,0)
  #undef NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID
  #define NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID 1
#endif
CONFTYPES

touch "$C"/*.h kernel-open/conftest.sh

echo "=== Conftest frozen ==="

# Build pass 2
make -j$(nproc) modules SYSSRC=/lib/modules/6.1.0-50-amd64/build
echo "=== Build complete ==="
