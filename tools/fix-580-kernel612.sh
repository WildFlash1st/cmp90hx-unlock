#!/bin/bash
# Kernel compat fixes for NVIDIA Open 580.159.03.
# Usage: fix-580-kernel612.sh /path/to/open-gpu-kernel-modules-<version> [kernel_version]
#
# Idempotent. Apply AFTER a conftest pass and re-apply after each `make` (the
# driver build regenerates kernel-open/conftest, which can re-break these).
#
# Always-applied (kernel >= 6.1): vm_fault_t/mmap_lock, proc_ops, DMA includes,
# of_dma_configure 3-arg, backlight rename, hv_get_isolation_type guard.
# Kernel >= 6.12 only: timespec64/MHP_NONE, follow_pfn, __assign_str 1-arg,
# class_create/devnode const, ioremap_*_hardened, dma_is_direct,
# set_memory_array_uc/wb, handle_mm_fault pt_regs, MODULE_IMPORT_NS.
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 /path/to/open-gpu-kernel-modules-<version> [kernel_version]" >&2
    exit 1
fi
SRC="${1}"
KVER="${2:-$(uname -r)}"
KMAJ="${KVER%%.*}"
KMIN="${KVER#*.}"; KMIN="${KMIN%%.*}"
if [ "${KMAJ}" -gt 6 ] || { [ "${KMAJ}" -eq 6 ] && [ "${KMIN}" -ge 12 ]; }; then
    GE_612=1
else
    GE_612=0
fi
echo "Target kernel: ${KVER} (6.12+ fixes: $([ ${GE_612} -eq 1 ] && echo YES || echo NO))"

# 1. nv-mm.h: remove vm_fault_t typedef + mmap_sem -> mmap_lock (kernel >= 5.12)
MM="${SRC}/kernel-open/common/inc/nv-mm.h"
if [ -f "$MM" ]; then
    python3 - "$MM" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
old = '''#if !defined(NV_VM_FAULT_T_IS_PRESENT)
typedef int vm_fault_t;
#endif'''
new = '''/* vm_fault_t: provided by kernel since 5.17; removed fallback typedef */
#if !defined(NV_VM_FAULT_T_IS_PRESENT) && !defined(__VM_FAULT_T_DEFINED__)
/* intentionally empty */
#endif'''
if old in t:
    t = t.replace(old, new)
    print('nv-mm.h: removed vm_fault_t typedef')
else:
    print('nv-mm.h: vm_fault_t pattern not found')
t = t.replace('down_read(&mm->mmap_sem)', 'mmap_read_lock(mm)')
t = t.replace('up_read(&mm->mmap_sem)', 'mmap_read_unlock(mm)')
t = t.replace('down_write(&mm->mmap_sem)', 'mmap_write_lock(mm)')
t = t.replace('up_write(&mm->mmap_sem)', 'mmap_write_unlock(mm)')
t = t.replace('rwsem_is_locked(&mm->mmap_sem)', 'rwsem_is_locked(&mm->mmap_lock)')
t = t.replace('return &mm->mmap_sem;', 'return &mm->mmap_lock;')
p.write_text(t)
print('nv-mm.h: patched mmap_lock')
PY
fi

# 2. nv-backlight.c: backlight API rename
BL="${SRC}/kernel-open/nvidia/nv-backlight.c"
[ -f "$BL" ] && sed -i 's/get_backlight_device_by_name/backlight_device_get_by_name/g' "$BL" && echo "nv-backlight.c fixed"

# 3. nv-platform.c: of_dma_configure always 3 args (kernel >= 6.1)
PL="${SRC}/kernel-open/nvidia/nv-platform.c"
if [ -f "$PL" ]; then
    python3 - "$PL" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
old = '''rc = of_dma_configure(
        &niso_plat_dev->dev,
        niso_np
#if NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT > 2
        , true
#endif
    );'''
new = '''rc = of_dma_configure(
        &niso_plat_dev->dev,
        niso_np,
        true
    );'''
if old in t:
    t = t.replace(old, new)
    print('nv-platform.c: fixed of_dma_configure args')
else:
    print('nv-platform.c: pattern not found (may already be 3-arg)')
p.write_text(t)
PY
fi

# 4. nv-linux.h: DMA includes (always) + ioremap/dma_is_direct (6.12+)
NL="${SRC}/kernel-open/common/inc/nv-linux.h"
if [ -f "$NL" ]; then
    python3 - "$NL" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
kernel_inc = '#include <linux/kernel.h>'
dma_block = '''#include <linux/kernel.h>
#include <linux/dma-map-ops.h>
#include <linux/dma-direct.h>'''
if '#include <linux/dma-direct.h>' not in t:
    if kernel_inc in t:
        t = t.replace(kernel_inc, dma_block, 1)
        print('nv-linux.h: added DMA includes')
    else:
        print('nv-linux.h: kernel.h include not found')
p.write_text(t)
PY
    if [ "${GE_612}" -eq 1 ]; then
        sed -i 's|#if IS_ENABLED(CONFIG_INTEL_TDX_GUEST) \&\& defined(NV_IOREMAP_DRIVER_HARDENED_PRESENT)|#if 0 /* ioremap_driver_hardened removed in 6.12 */|' "$NL"
        sed -i 's|#if IS_ENABLED(CONFIG_INTEL_TDX_GUEST) \&\& defined(NV_IOREMAP_CACHE_SHARED_PRESENT)|#if 0 /* ioremap_cache_shared removed in 6.12 */|' "$NL"
        sed -i 's|#if IS_ENABLED(CONFIG_INTEL_TDX_GUEST) \&\& defined(NV_IOREMAP_DRIVER_HARDENED_WC_PRESENT)|#if 0 /* ioremap_driver_hardened_wc removed in 6.12 */|' "$NL"
        sed -i 's|#if defined(NV_DMA_IS_DIRECT_PRESENT)|#if 0 /* dma_is_direct removed in 6.12 */|' "$NL"
        echo "nv-linux.h: ioremap/dma_is_direct disabled (6.12+)"
    fi
fi

# 5. nv-procfs-utils.h: force proc_ops (kernel >= 5.6)
NP="${SRC}/kernel-open/common/inc/nv-procfs-utils.h"
[ -f "$NP" ] && sed -i 's|#if defined(NV_PROC_OPS_PRESENT)|#if 1 /* force proc_ops (kernel 5.6+) */|' "$NP" && echo "nv-procfs-utils.h: forced proc_ops"

# 6. nv-vm.c: set_memory_array_uc/wb removed (6.12+)
if [ "${GE_612}" -eq 1 ]; then
    NV_VM="${SRC}/kernel-open/nvidia/nv-vm.c"
    [ -f "$NV_VM" ] && sed -i 's|#if defined(NV_SET_MEMORY_ARRAY_UC_PRESENT)|#if 0 /* set_memory_array_uc/wb removed in 6.12 */|' "$NV_VM" && echo "nv-vm.c: set_memory_array disabled (6.12+)"
fi

# 7. uvm_populate_pageable.c: handle_mm_fault pt_regs arg (6.12+)
if [ "${GE_612}" -eq 1 ]; then
    UVP="${SRC}/kernel-open/nvidia-uvm/uvm_populate_pageable.c"
    [ -f "$UVP" ] && sed -i 's|#if defined(NV_HANDLE_MM_FAULT_HAS_PT_REGS_ARG)|#if 1 /* force pt_regs arg (6.12) */|' "$UVP" && echo "uvm_populate_pageable.c: pt_regs forced (6.12+)"
fi

# 8. nv.c: hv_get_isolation_type guard (conftest false positive) + MODULE_IMPORT_NS (6.12+)
NV_C="${SRC}/kernel-open/nvidia/nv.c"
if [ -f "$NV_C" ]; then
    sed -i 's|#if defined(NV_HV_GET_ISOLATION_TYPE)|#if 0 /* hv_get_isolation_type not in this kernel */|' "$NV_C"
    if [ "${GE_612}" -eq 1 ]; then
        sed -i 's|#if defined(MODULE_IMPORT_NS)|#if 1 /* force MODULE_IMPORT_NS */|' "$NV_C"
        sed -i 's|#if defined(NV_MODULE_IMPORT_NS_TAKES_CONSTANT)|#if 1 /* force constant */|' "$NV_C"
    fi
    echo "nv.c fixed"
fi

# 9. os-interface.c: timespec64 + MHP_NONE (6.12+)
if [ "${GE_612}" -eq 1 ]; then
    OI="${SRC}/kernel-open/nvidia/os-interface.c"
    if [ -f "$OI" ]; then
        sed -i 's/struct timespec ts;/struct timespec64 ts;/' "$OI"
        sed -i 's/jiffies_to_timespec(jiffies, &ts)/jiffies_to_timespec64(jiffies, \&ts)/' "$OI"
        sed -i 's/timespec_to_ns(&ts)/timespec64_to_ns(\&ts)/' "$OI"
        sed -i 's|ret = add_memory_driver_managed(node, segment_base, segment_size, "System RAM (NVIDIA)");|ret = add_memory_driver_managed(node, segment_base, segment_size, "System RAM (NVIDIA)", MHP_NONE);|' "$OI"
        echo "os-interface.c fixed (6.12+)"
    fi
fi

# 10. os-mlock.c: follow_pfn removal (6.12+)
if [ "${GE_612}" -eq 1 ]; then
    ML="${SRC}/kernel-open/nvidia/os-mlock.c"
    if [ -f "$ML" ]; then
        python3 - "$ML" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
old = '''#if defined(NV_FOLLOW_PFN_PRESENT)
    return follow_pfn(vma, address, pfn);
#else
    return nv_follow_flavors(vma, address, pfn);
#endif'''
new = '''return nv_follow_flavors(vma, address, pfn);'''
if old in t:
    t = t.replace(old, new)
    print('os-mlock.c: follow_pfn patched (6.12+)')
else:
    print('os-mlock.c: pattern not found')
p.write_text(t)
PY
    fi
fi

# 11. nv-tracepoint.h + nvswitch_event.h: __assign_str 1-arg (6.12+)
if [ "${GE_612}" -eq 1 ]; then
    for TP in "${SRC}/kernel-open/nvidia/nv-tracepoint.h" "${SRC}/kernel-open/nvidia/nvswitch_event.h"; do
        [ -f "$TP" ] && sed -i 's|#if NV_ASSIGN_STR_ARGUMENT_COUNT == 1|#if 1 /* force 1-arg __assign_str */|' "$TP"
    done
    echo "nv-tracepoint/nvswitch_event: __assign_str forced (6.12+)"
fi

# 12. nv-caps-imex.c: class_create/devnode API (6.12+)
if [ "${GE_612}" -eq 1 ]; then
    NC="${SRC}/kernel-open/nvidia/nv-caps-imex.c"
    if [ -f "$NC" ]; then
        sed -i 's|#if defined(NV_CLASS_CREATE_HAS_NO_OWNER_ARG)|#if 1 /* force no-owner class_create */|' "$NC"
        sed -i 's|#if defined(NV_CLASS_DEVNODE_HAS_CONST_ARG)|#if 1 /* force const devnode */|' "$NC"
        echo "nv-caps-imex.c fixed (6.12+)"
    fi
fi

# 13. uvm_linux.h: sg_dma_page_iter + handle_mm_fault (6.12+)
if [ "${GE_612}" -eq 1 ]; then
    UV="${SRC}/kernel-open/nvidia-uvm/uvm_linux.h"
    if [ -f "$UV" ]; then
        sed -i 's|#if !defined(NV_SG_DMA_PAGE_ITER_PRESENT)|#if 0 /* sg_dma_page_iter in kernel 6.12+ */|' "$UV"
        sed -i 's|#if defined(NV_HANDLE_MM_FAULT_HAS_PT_REGS_ARG)|#if 1 /* force pt_regs arg */|' "$UV"
        echo "uvm_linux.h fixed (6.12+)"
    fi
fi

# 14. conftest overrides (idempotent)
C="${SRC}/kernel-open/conftest"
if [ -d "$C" ]; then
    sed -i 's/^#undef NV_MM_HAS_MMAP_LOCK$/#define NV_MM_HAS_MMAP_LOCK/' "$C/types.h" 2>/dev/null || true
    sed -i 's/^#undef NV_VM_FAULT_T_IS_PRESENT$/#define NV_VM_FAULT_T_IS_PRESENT/' "$C/types.h" 2>/dev/null || true
    sed -i 's/^#undef NV_VM_FAULT_T_IS_PRESENT$/#define NV_VM_FAULT_T_IS_PRESENT/' "$C/generic.h" 2>/dev/null || true
    sed -i 's/^#undef NV_PROC_OPS_PRESENT$/#define NV_PROC_OPS_PRESENT/' "$C/types.h" 2>/dev/null || true
    sed -i 's/^#define NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT 2$/#define NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT 3/' "$C/functions.h" 2>/dev/null || true
    if [ "${GE_612}" -eq 1 ]; then
        sed -i 's/^#define NV_FOLLOW_PFN_PRESENT$/#undef NV_FOLLOW_PFN_PRESENT/' "$C/functions.h" 2>/dev/null || true
        sed -i 's/^#define NV_JIFFIES_TO_TIMESPEC_PRESENT$/#undef NV_JIFFIES_TO_TIMESPEC_PRESENT/' "$C/functions.h" 2>/dev/null || true
        sed -i 's/^#define NV_ASSIGN_STR_ARGUMENT_COUNT 2$/#define NV_ASSIGN_STR_ARGUMENT_COUNT 1/' "$C/functions.h" 2>/dev/null || true
        sed -i 's/^#define NV_SET_MEMORY_ARRAY_UC_PRESENT$/#undef NV_SET_MEMORY_ARRAY_UC_PRESENT/' "$C/functions.h" 2>/dev/null || true
        sed -i 's/^#define NV_DMA_IS_DIRECT_PRESENT$/#undef NV_DMA_IS_DIRECT_PRESENT/' "$C/functions.h" 2>/dev/null || true
        sed -i 's/^#define NV_IOREMAP_DRIVER_HARDENED_PRESENT$/#undef NV_IOREMAP_DRIVER_HARDENED_PRESENT/' "$C/functions.h" 2>/dev/null || true
        sed -i 's/^#define NV_IOREMAP_CACHE_SHARED_PRESENT$/#undef NV_IOREMAP_CACHE_SHARED_PRESENT/' "$C/functions.h" 2>/dev/null || true
        sed -i 's/^#define NV_IOREMAP_DRIVER_HARDENED_WC_PRESENT$/#undef NV_IOREMAP_DRIVER_HARDENED_WC_PRESENT/' "$C/functions.h" 2>/dev/null || true
        sed -i 's/^#undef NV_HANDLE_MM_FAULT_HAS_PT_REGS_ARG$/#define NV_HANDLE_MM_FAULT_HAS_PT_REGS_ARG/' "$C/functions.h" 2>/dev/null || true
    fi
    sed -i 's/^#define NV_HV_GET_ISOLATION_TYPE$/#undef NV_HV_GET_ISOLATION_TYPE/' "$C/functions.h" 2>/dev/null || true
    sed -i 's/^#define NV_DRM_GEM_OBJECT_PUT_UNLOCK_PRESENT$/#undef NV_DRM_GEM_OBJECT_PUT_UNLOCK_PRESENT/' "$C/functions.h" 2>/dev/null || true
    sed -i 's/^#define NV_PCIE_IS_CXL_PRESENT$/#undef NV_PCIE_IS_CXL_PRESENT/' "$C/functions.h" 2>/dev/null || true
    touch "$C"/*.h 2>/dev/null || true
    echo "conftest overrides applied"
fi
echo "ALL FIXES APPLIED"
