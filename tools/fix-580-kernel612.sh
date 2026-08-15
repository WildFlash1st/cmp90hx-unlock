#!/bin/bash
# Kernel 6.12 compat fixes for stock 580.159.03 (patterns from cmpunlocker driver/build.sh)
set -euo pipefail
SRC=/home/it/bendy2-cmp90hx/work/cmp90hx-persistent-build

# 1. nv-mm.h: remove vm_fault_t typedef + mmap_sem -> mmap_lock
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

# 2. nv-backlight.c
BL="${SRC}/kernel-open/nvidia/nv-backlight.c"
[ -f "$BL" ] && sed -i 's/get_backlight_device_by_name/backlight_device_get_by_name/g' "$BL" && echo "nv-backlight.c fixed"

# 3. nv-platform.c: of_dma_configure 3 args
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

# 4. os-interface.c: timespec64 + MHP_NONE
OI="${SRC}/kernel-open/nvidia/os-interface.c"
if [ -f "$OI" ]; then
    sed -i 's/struct timespec ts;/struct timespec64 ts;/' "$OI"
    sed -i 's/jiffies_to_timespec(jiffies, &ts)/jiffies_to_timespec64(jiffies, \&ts)/' "$OI"
    sed -i 's/timespec_to_ns(&ts)/timespec64_to_ns(\&ts)/' "$OI"
    sed -i 's|ret = add_memory_driver_managed(node, segment_base, segment_size, "System RAM (NVIDIA)");|ret = add_memory_driver_managed(node, segment_base, segment_size, "System RAM (NVIDIA)", MHP_NONE);|' "$OI"
    echo "os-interface.c fixed"
fi

# 5. os-mlock.c: follow_pfn removal
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
    print('os-mlock.c: follow_pfn patched')
else:
    print('os-mlock.c: pattern not found')
p.write_text(t)
PY
fi

# 6. nv-tracepoint.h + nvswitch_event.h: __assign_str 1-arg
for TP in "${SRC}/kernel-open/nvidia/nv-tracepoint.h" "${SRC}/kernel-open/nvidia/nvswitch_event.h"; do
    [ -f "$TP" ] && sed -i 's|#if NV_ASSIGN_STR_ARGUMENT_COUNT == 1|#if 1 /* force 1-arg __assign_str */|' "$TP" && echo "$(basename $TP) fixed"
done

# 7. nv-caps-imex.c: class_create/devnode
NC="${SRC}/kernel-open/nvidia/nv-caps-imex.c"
if [ -f "$NC" ]; then
    sed -i 's|#if defined(NV_CLASS_CREATE_HAS_NO_OWNER_ARG)|#if 1 /* force no-owner class_create */|' "$NC"
    sed -i 's|#if defined(NV_CLASS_DEVNODE_HAS_CONST_ARG)|#if 1 /* force const devnode */|' "$NC"
    echo "nv-caps-imex.c fixed"
fi

# 8. uvm_linux.h: sg_dma_page_iter + handle_mm_fault
UV="${SRC}/kernel-open/nvidia-uvm/uvm_linux.h"
if [ -f "$UV" ]; then
    sed -i 's|#if !defined(NV_SG_DMA_PAGE_ITER_PRESENT)|#if 0 /* sg_dma_page_iter in kernel 6.12+ */|' "$UV"
    sed -i 's|#if defined(NV_HANDLE_MM_FAULT_HAS_PT_REGS_ARG)|#if 1 /* force pt_regs arg */|' "$UV"
    echo "uvm_linux.h fixed"
fi

# 9. nv.c: MODULE_IMPORT_NS
NV="${SRC}/kernel-open/nvidia/nv.c"
if [ -f "$NV" ]; then
    sed -i 's|#if defined(MODULE_IMPORT_NS)|#if 1 /* force MODULE_IMPORT_NS */|' "$NV"
    sed -i 's|#if defined(NV_MODULE_IMPORT_NS_TAKES_CONSTANT)|#if 1 /* force constant */|' "$NV"
    echo "nv.c fixed"
fi

# 10. conftest overrides (post-run fixes, idempotent)
C="${SRC}/kernel-open/conftest"
if [ -d "$C" ]; then
    sed -i 's/^#undef NV_MM_HAS_MMAP_LOCK$/#define NV_MM_HAS_MMAP_LOCK/' "$C/types.h" 2>/dev/null || true
    sed -i 's/^#undef NV_VM_FAULT_T_IS_PRESENT$/#define NV_VM_FAULT_T_IS_PRESENT/' "$C/types.h" 2>/dev/null || true
    sed -i 's/^#undef NV_VM_FAULT_T_IS_PRESENT$/#define NV_VM_FAULT_T_IS_PRESENT/' "$C/generic.h" 2>/dev/null || true
    sed -i 's/^#define NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT 2$/#define NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT 3/' "$C/functions.h" 2>/dev/null || true
    sed -i 's/^#define NV_FOLLOW_PFN_PRESENT$/#undef NV_FOLLOW_PFN_PRESENT/' "$C/functions.h" 2>/dev/null || true
    sed -i 's/^#define NV_JIFFIES_TO_TIMESPEC_PRESENT$/#undef NV_JIFFIES_TO_TIMESPEC_PRESENT/' "$C/functions.h" 2>/dev/null || true
    sed -i 's/^#define NV_ASSIGN_STR_ARGUMENT_COUNT 2$/#define NV_ASSIGN_STR_ARGUMENT_COUNT 1/' "$C/functions.h" 2>/dev/null || true
    sed -i 's/^#define NV_HV_GET_ISOLATION_TYPE$/#undef NV_HV_GET_ISOLATION_TYPE/' "$C/functions.h" 2>/dev/null || true
    sed -i 's/^#define NV_DRM_GEM_OBJECT_PUT_UNLOCK_PRESENT$/#undef NV_DRM_GEM_OBJECT_PUT_UNLOCK_PRESENT/' "$C/functions.h" 2>/dev/null || true
    sed -i 's/^#define NV_PCIE_IS_CXL_PRESENT$/#undef NV_PCIE_IS_CXL_PRESENT/' "$C/functions.h" 2>/dev/null || true
    sed -i 's/^#define NV_SET_MEMORY_ARRAY_UC_PRESENT$/#undef NV_SET_MEMORY_ARRAY_UC_PRESENT/' "$C/functions.h" 2>/dev/null || true
    touch "$C"/*.h 2>/dev/null || true
    echo "conftest overrides applied"
fi
echo "ALL FIXES APPLIED"
