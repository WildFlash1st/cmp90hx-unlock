#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/VERSION")
DEFAULT_VERSION="${SUPPORTED_VERSIONS[0]:-}"
VERSION="${CMPUNLOCKER_DRIVER_VERSION:-${DEFAULT_VERSION}}"
PATCH_DIR="${SCRIPT_DIR}/patches"
BUILD_ROOT="${CMPUNLOCKER_BUILD_DIR:-${SCRIPT_DIR}/.build}"
SRC_NAME="open-gpu-kernel-modules-${VERSION}"
SRC_DIR="${BUILD_ROOT}/${SRC_NAME}"
TARBALL="${BUILD_ROOT}/${SRC_NAME}.tar.gz"
TARBALL_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${VERSION}.tar.gz"
KVER="${CMPUNLOCKER_KVER:-$(uname -r)}"
KSRC="/lib/modules/${KVER}/build"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

version_supported() {
    local v="$1"
    local s
    for s in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "${v}" == "${s}" ]] && return 0
    done
    return 1
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ${SCRIPT_DIR}/build.sh"
[[ -n "${VERSION}" ]] || die "No driver version set (driver/VERSION empty and CMPUNLOCKER_DRIVER_VERSION unset)"
version_supported "${VERSION}" || die "Unsupported driver version '${VERSION}' (supported: ${SUPPORTED_VERSIONS[*]})"
[[ -d "${PATCH_DIR}" ]] || die "Missing patches directory: ${PATCH_DIR}"
[[ -d "${KSRC}" ]] || die "Kernel headers not found at ${KSRC}. Install linux-headers-${KVER} (or kernel-devel)."
command -v python3 &>/dev/null || die "python3 is required to apply the card memory profile"
info "Building against open-gpu-kernel-modules ${VERSION}"

mkdir -p "${BUILD_ROOT}"

if [[ ! -f "${TARBALL}" ]]; then
    info "Downloading open-gpu-kernel-modules ${VERSION}..."
    curl -L --fail -o "${TARBALL}.partial" "${TARBALL_URL}"
    mv "${TARBALL}.partial" "${TARBALL}"
    ok "Downloaded ${TARBALL}"
else
    ok "Using cached tarball ${TARBALL}"
fi

info "Extracting clean stock sources..."
rm -rf "${SRC_DIR}"
tar -xzf "${TARBALL}" -C "${BUILD_ROOT}"
if [[ ! -d "${SRC_DIR}" ]]; then
    extracted="$(find "${BUILD_ROOT}" -maxdepth 1 -type d -name "${SRC_NAME}*" | head -1)"
    [[ -n "${extracted}" ]] || die "Extracted source tree not found"
    mv "${extracted}" "${SRC_DIR}"
fi
ok "Sources ready: ${SRC_DIR}"

PROFILE="${CMPUNLOCKER_CARD_PROFILE:-8gb}"
GSP_C="${SRC_DIR}/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"

info "Applying unlock patches..."
cd "${SRC_DIR}"
shopt -s nullglob

if [[ "${PROFILE}" == "cmp90" ]]; then
    PROFILE_PATCH_DIR="${PATCH_DIR}/cmp90"
else
    PROFILE_PATCH_DIR="${PATCH_DIR}/cmp170hx"
fi

patches=("${PROFILE_PATCH_DIR}"/*.patch)
[[ ${#patches[@]} -gt 0 ]] || die "No patches found in ${PROFILE_PATCH_DIR} for profile ${PROFILE}"
for p in "${patches[@]}"; do
    info "  $(basename "${p}")"
    patch -p1 < "${p}"
done
ok "All patches applied (profile: ${PROFILE})"

# ── CMP90/HX PCI-ID adapter (post-patch) ──
# The CMP90 patch is hardcoded for 0x20B0. For CMP 90HX (0x220D), replace.
if [[ "${PROFILE}" == "cmp90" ]]; then
    info "Patching PCI ID: 0x20B0 → 0x220D for CMP 90HX support..."
    ADAPT_FILES=(
        "src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
        "src/nvidia/src/kernel/gpu/bus/arch/maxwell/kern_bus_gm107.c"
        "src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c"
        "src/nvidia/src/kernel/gpu/mem_mgr/arch/turing/mem_mgr_tu102.c"
        "src/nvidia/src/kernel/gpu/mem_mgr/mem_mgr.c"
        "src/nvidia/src/kernel/gpu/mem_mgr/mem_scrub.c"
        "kernel-open/nvidia/nv.c"
    )
    for af in "${ADAPT_FILES[@]}"; do
        if [[ -f "${SRC_DIR}/${af}" ]]; then
            sed -i 's/0x20B0/0x220D/g; s/0x20b0/0x220d/g' "${SRC_DIR}/${af}"
            ok "  PCI ID adapted: ${af}"
        else
            warn "  Missing: ${af}"
        fi
    done
fi

# Fix conftest bug: linux/stdarg.h exists but conftest fails to detect it
# because -nostdinc strips GCC built-in paths. Force kernel interface layer
# to always use <linux/stdarg.h> which is self-contained.
NV_STDARG="${SRC_DIR}/kernel-open/common/inc/nv_stdarg.h"
if [[ -f "${NV_STDARG}" ]]; then
    sed -i 's|#if defined(NV_KERNEL_INTERFACE_LAYER) && defined(NV_LINUX)\n  #include "conftest.h"\n  #if defined(NV_LINUX_STDARG_H_PRESENT)\n    #include <linux/stdarg.h>\n  #else\n    #include <stdarg.h>\n  #endif|#if defined(NV_KERNEL_INTERFACE_LAYER) \&\& defined(NV_LINUX)\n  #include <linux/stdarg.h>|' "${NV_STDARG}" 2>/dev/null || true
    python3 -c "
import pathlib
p = pathlib.Path('${NV_STDARG}')
t = p.read_text()
old = '''#if defined(NV_KERNEL_INTERFACE_LAYER) && defined(NV_LINUX)
  #include \"conftest.h\"
  #if defined(NV_LINUX_STDARG_H_PRESENT)
    #include <linux/stdarg.h>
  #else
    #include <stdarg.h>
  #endif   '''
new = '''#if defined(NV_KERNEL_INTERFACE_LAYER) && defined(NV_LINUX)
  #include <linux/stdarg.h>'''
if old in t:
    t = t.replace(old, new)
    p.write_text(t)
    print('nv_stdarg.h fixed')
else:
    print('nv_stdarg.h already fixed or not found')
"
fi

# Fix nv-linux.h: add missing includes for kernel 6.1+
# phys_to_dma() is in linux/dma-direct.h, get_dma_ops() is in linux/dma-map-ops.h
# These MUST be included before any code that uses them (before line ~530)
NV_LINUX_H="${SRC_DIR}/kernel-open/common/inc/nv-linux.h"
if [[ -f "${NV_LINUX_H}" ]]; then
    python3 -c "
import pathlib
p = pathlib.Path('${NV_LINUX_H}')
t = p.read_text()
changed = False

# Add both DMA headers after '#include <linux/kernel.h>' (line ~72) which is
# early enough for all subsequent code
kernel_inc = '#include <linux/kernel.h>'
dma_block = '''#include <linux/kernel.h>
#include <linux/dma-map-ops.h>
#include <linux/dma-direct.h>'''
if '#include <linux/dma-direct.h>' not in t:
    if kernel_inc in t:
        t = t.replace(kernel_inc, dma_block, 1)
        changed = True
    else:
        # Fallback: add after first #include
        import re
        m = re.search(r'#include\s*[<\"]linux/\w+\.h[>\"]', t)
        if m:
            pos = t.index('\n', m.end())
            t = t[:pos+1] + '#include <linux/dma-map-ops.h>\n#include <linux/dma-direct.h>\n' + t[pos+1:]
            changed = True

if changed:
    p.write_text(t)
    print('nv-linux.h: added DMA includes after kernel.h')
else:
    print('nv-linux.h: DMA includes already present')
"
fi

# Fix nv-procfs-utils.h: force proc_ops for kernel >= 5.6
# Conftest misdetects this due to -Wno-implicit-function-declaration
NV_PROCFSG="${SRC_DIR}/kernel-open/common/inc/nv-procfs-utils.h"
if [[ -f "${NV_PROCFSG}" ]]; then
    sed -i 's/#if defined(NV_PROC_OPS_PRESENT)/#if 1 \/\* force proc_ops \*\//' "${NV_PROCFSG}"
    info "Fixed nv-procfs-utils.h: forced proc_ops"
fi

[[ -f "${GSP_C}" ]] || die "Missing ${GSP_C} after patching"

case "${PROFILE}" in
    8gb|8GB)
        PROFILE="8gb"
        CFG1="0x02779000"
        LMR="0x0000020B"
        FB_BYTES="0x0000001000000000"
        UNLOCK_LABEL="64GB"
        ;;
    10gb|10GB)
        PROFILE="10gb"
        CFG1="0x02669000"
        LMR="0x0000028A"
        FB_BYTES="0x0000000A00000000"
        UNLOCK_LABEL="40GB"
        ;;
    cmp90)
        PROFILE="cmp90"
        UNLOCK_LABEL="CMP90-COMPUTE"
        CFG1=""
        LMR=""
        FB_BYTES=""
        ;;
    *)
        die "Unknown CMPUNLOCKER_CARD_PROFILE='${PROFILE}' (use 8gb, 10gb, or cmp90)"
        ;;
esac

if [[ "${PROFILE}" == "cmp90" ]]; then
    info "CMP 90 profile: compute unlock only (SS0=0x88888888 SS1=0x00000008)"
    info "Memory geometry rewrite skipped — GDDR6X not expandable"
else
    info "Applying memory profile ${PROFILE} (${UNLOCK_LABEL} geometry)..."

    python3 - "${GSP_C}" "${CFG1}" "${LMR}" "${FB_BYTES}" "${UNLOCK_LABEL}" <<'PY'
import pathlib, re, sys
path, cfg1, lmr, fb, label = sys.argv[1:6]
text = pathlib.Path(path).read_text()

# Dual-device path: both geometries are already baked into the patch.
if (
    "SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID" in text
    and "SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID" in text
    and "0x02779000U" in text
    and "0x02669000U" in text
    and "0x0000001000000000ULL" in text
    and "0x0000000A00000000ULL" in text
):
    print(f"runtime device-id geometry (profile metadata={label})")
    raise SystemExit(0)

text2, n1 = re.subn(
    r"(NvU32 cfg1Value = )0x[0-9A-Fa-f]+(U;)",
    rf"\g<1>{cfg1}\g<2>",
    text,
    count=1,
)
text2, n2 = re.subn(
    r"(NvU32 lmrValue\s*=\s*)0x[0-9A-Fa-f]+(U;)",
    rf"\g<1>{lmr}\g<2>",
    text2,
    count=1,
)
text2, n3 = re.subn(
    r"(NvU64 targetFbBytes = )0x[0-9A-Fa-f]+ULL;\s*/\*[^*]*\*/",
    rf"\g<1>{fb}ULL;  /* {label} */",
    text2,
    count=1,
)
if n1 != 1 or n2 != 1 or n3 != 1:
    raise SystemExit(
        f"geometry rewrite failed (cfg1={n1} lmr={n2} fb={n3}); check kernel_gsp.c markers"
    )
pathlib.Path(path).write_text(text2)
print(f"cfg1={cfg1} lmr={lmr} fb={fb} ({label})")
PY
    ok "Memory profile ${PROFILE}: CFG1=${CFG1} LMR=${LMR} fb=${FB_BYTES} (${UNLOCK_LABEL})"
fi
mkdir -p "${INSTALL_MOD_DIR}"
printf '%s\n' "${VERSION}" > "${INSTALL_MOD_DIR}/driver_version"
printf '%s\n' "${PROFILE}" > "${INSTALL_MOD_DIR}/card_profile"
printf '%s\n' "${UNLOCK_LABEL}" > "${INSTALL_MOD_DIR}/unlock_geometry"

info "Building modules for kernel ${KVER}..."
cd "${SRC_DIR}"
find . -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
rm -rf src/nvidia/_out src/nvidia-modeset/_out kernel-open/conftest 2>/dev/null || true
make clean 2>/dev/null || true

# ── Kernel compat fix function (called after EVERY make) ──
# Strategy: patch SOURCE files directly so fixes survive conftest regeneration.
fix_kernel_compat() {
    local NV_BACKLIGHT="${SRC_DIR}/kernel-open/nvidia/nv-backlight.c"
    local NV_PLATFORM="${SRC_DIR}/kernel-open/nvidia/nv-platform.c"
    local NV_MM="${SRC_DIR}/kernel-open/common/inc/nv-mm.h"
    local NV_PLATFORM_H="${SRC_DIR}/kernel-open/nvidia/nv-platform.h"

    # ── 1. nv-mm.h: force mmap_lock + fix vm_fault_t ──
    # Conftest misdetects both due to -Wno-implicit-function-declaration.
    # Patch source directly so it works regardless of conftest state.
    if [[ -f "${NV_MM}" ]]; then
        python3 -c "
import pathlib
p = pathlib.Path('${NV_MM}')
t = p.read_text()

# Fix vm_fault_t: just remove the typedef entirely — kernel >= 5.17 provides it
# and conftest can't detect it due to -Wno-implicit-function-declaration bug
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
    print('nv-mm.h: vm_fault_t already patched')

# Fix mmap_sem → mmap_lock: replace all occurrences in nv_mm functions
t = t.replace('down_read(&mm->mmap_sem)', 'mmap_read_lock(mm)')
t = t.replace('up_read(&mm->mmap_sem)', 'mmap_read_unlock(mm)')
t = t.replace('down_write(&mm->mmap_sem)', 'mmap_write_lock(mm)')
t = t.replace('up_write(&mm->mmap_sem)', 'mmap_write_unlock(mm)')
t = t.replace('rwsem_is_locked(&mm->mmap_sem)', 'rwsem_is_locked(&mm->mmap_lock)')
t = t.replace('return &mm->mmap_sem;', 'return &mm->mmap_lock;')

p.write_text(t)
print('nv-mm.h: patched mmap_lock')
"
    fi

    # ── 2. nv-backlight.c: rename function ──
    if [[ -f "${NV_BACKLIGHT}" ]] && grep -q 'get_backlight_device_by_name' "${NV_BACKLIGHT}"; then
        sed -i 's/get_backlight_device_by_name/backlight_device_get_by_name/g' "${NV_BACKLIGHT}"
        info "Fixed nv-backlight.c: backlight API rename"
    fi

    # ── 4. Source guards for conftest false positives ──
    # These functions are detected as present by conftest but don't actually exist
    local NV_C="${SRC_DIR}/kernel-open/nvidia/nv.c"
    if [[ -f "${NV_C}" ]]; then
        sed -i 's/#if defined(NV_HV_GET_ISOLATION_TYPE)/#if 0 \/\* hv_get_isolation_type not in this kernel \*\//' "${NV_C}"
    fi
    local NV_DMA="${SRC_DIR}/kernel-open/nvidia/nv-dma.c"
    if [[ -f "${NV_DMA}" ]]; then
        sed -i 's/#if defined(NV_DRM_GEM_OBJECT_PUT_UNLOCK_PRESENT)/#if 0 \/\* drm_gem_object_put_unlocked removed \*\//' "${NV_DMA}"
    fi
    local NV_PCI="${SRC_DIR}/kernel-open/nvidia/nv-pci.c"
    if [[ -f "${NV_PCI}" ]]; then
        # Uses #ifdef, not #if defined()
        sed -i 's/#ifdef NV_PCIE_IS_CXL_PRESENT/#if 0 \/\* pcie_is_cxl not in this kernel \*\//' "${NV_PCI}"
    fi
    # set_memory_array_uc removed in newer kernels, conftest falsely detects it
    local NV_VM="${SRC_DIR}/kernel-open/nvidia/nv-vm.c"
    if [[ -f "${NV_VM}" ]]; then
        sed -i 's/#if defined(NV_SET_MEMORY_ARRAY_UC_PRESENT)/#if 0 \/\* set_memory_array_uc removed \*\//' "${NV_VM}"
    fi

    # ── 5. nv-platform.c: fix of_dma_configure arg count ──
    # In kernel 6.1+: of_dma_configure(dev, np, force_dma) — 3 args
    if [[ -f "${NV_PLATFORM}" ]]; then
        python3 -c "
import pathlib
p = pathlib.Path('${NV_PLATFORM}')
t = p.read_text()
changed = False

# The stock code uses NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT.
# Force it to always pass 3 args (works on 5.10+).
old = '''#if NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT > 2
        , true
#endif'''
new = '''#if NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT > 2
        , true
#else
        , true
#endif'''
# Actually simpler: just always pass the 3rd arg
old2 = '''rc = of_dma_configure(
        &niso_plat_dev->dev,
        niso_np
#if NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT > 2
        , true
#endif
    );'''
new2 = '''rc = of_dma_configure(
        &niso_plat_dev->dev,
        niso_np,
        true
    );'''
if old2 in t:
    t = t.replace(old2, new2)
    changed = True

if changed:
    p.write_text(t)
    print('nv-platform.c: fixed of_dma_configure args')
else:
    print('nv-platform.c: already fixed or pattern not found')
"
    fi

    # ── 6. Kernel 6.12+ fixes ──
    local NV_OSIF="${SRC_DIR}/kernel-open/nvidia/os-interface.c"
    local NV_MLOCK="${SRC_DIR}/kernel-open/nvidia/os-mlock.c"

    # os-interface.c: timespec → timespec64 (removed in 6.12)
    if [[ -f "${NV_OSIF}" ]]; then
        sed -i 's/struct timespec ts;/struct timespec64 ts;/' "${NV_OSIF}"
        sed -i 's/jiffies_to_timespec(jiffies, &ts)/jiffies_to_timespec64(jiffies, \&ts)/' "${NV_OSIF}"
        sed -i 's/timespec_to_ns(&ts)/timespec64_to_ns(\&ts)/' "${NV_OSIF}"
    fi

    # os-interface.c: add_memory_driver_managed needs mhp_flags in 6.12+
    if [[ -f "${NV_OSIF}" ]]; then
        sed -i 's|ret = add_memory_driver_managed(node, segment_base, segment_size, "System RAM (NVIDIA)");|ret = add_memory_driver_managed(node, segment_base, segment_size, "System RAM (NVIDIA)", MHP_NONE);|' "${NV_OSIF}"
    fi

    # os-mlock.c: nv_follow_pfn — remove the follow_pfn branch (removed in 6.12)
    # Replace the #if branch with a stub that always uses nv_follow_flavors
    if [[ -f "${NV_MLOCK}" ]]; then
        python3 -c "
import pathlib
p = pathlib.Path('${NV_MLOCK}')
t = p.read_text()
old = '''#if defined(NV_FOLLOW_PFN_PRESENT)
    return follow_pfn(vma, address, pfn);
#else
    return nv_follow_flavors(vma, address, pfn);
#endif'''
new = '''return nv_follow_flavors(vma, address, pfn);'''
if old in t:
    t = t.replace(old, new)
    p.write_text(t)
    print('os-mlock.c: nv_follow_pfn patched for 6.12+')
else:
    print('os-mlock.c: nv_follow_pfn pattern not found — may already be patched')
"
    fi

    # nv-tracepoint.h: __assign_str API changed to 1 arg in 6.12
    local NV_TRACEPOINT="${SRC_DIR}/kernel-open/nvidia/nv-tracepoint.h"
    if [[ -f "${NV_TRACEPOINT}" ]]; then
        sed -i 's|#if NV_ASSIGN_STR_ARGUMENT_COUNT == 1|#if 1 /* force 1-arg __assign_str */|' "${NV_TRACEPOINT}"
    fi

    # nv-caps-imex.c: class_create / devnode API changes in 6.12
    local NV_CAPS="${SRC_DIR}/kernel-open/nvidia/nv-caps-imex.c"
    if [[ -f "${NV_CAPS}" ]]; then
        sed -i 's|#if defined(NV_CLASS_CREATE_HAS_NO_OWNER_ARG)|#if 1 /* force no-owner class_create */|' "${NV_CAPS}"
        sed -i 's|#if defined(NV_CLASS_DEVNODE_HAS_CONST_ARG)|#if 1 /* force const devnode */|' "${NV_CAPS}"
    fi

    # nvswitch_event.h: same __assign_str 1-arg fix as nv-tracepoint.h
    local NV_NVSW="${SRC_DIR}/kernel-open/nvidia/nvswitch_event.h"
    if [[ -f "${NV_NVSW}" ]]; then
        sed -i 's|#if NV_ASSIGN_STR_ARGUMENT_COUNT == 1|#if 1 /* force 1-arg */|' "${NV_NVSW}"
    fi

    # uvm_linux.h: sg_dma_page_iter already in kernel 6.12, skip redefinition
    local UVM_LINUX="${SRC_DIR}/kernel-open/nvidia-uvm/uvm_linux.h"
    if [[ -f "${UVM_LINUX}" ]]; then
        sed -i 's|#if !defined(NV_SG_DMA_PAGE_ITER_PRESENT)|#if 0 /* sg_dma_page_iter in kernel 6.12+ */|' "${UVM_LINUX}"
        # handle_mm_fault takes pt_regs arg in 6.12
        sed -i 's|#if defined(NV_HANDLE_MM_FAULT_HAS_PT_REGS_ARG)|#if 1 /* force pt_regs arg */|' "${UVM_LINUX}"
    fi

    # nvidia-drm-helper.h: DRM API changes in 6.12
    local NV_DRM_HELPER="${SRC_DIR}/kernel-open/nvidia-drm/nvidia-drm-helper.h"
    if [[ -f "${NV_DRM_HELPER}" ]]; then
        # drm_prime_pages_to_sg now takes drm_device * arg
        sed -i 's|#if defined(NV_DRM_PRIME_PAGES_TO_SG_HAS_DRM_DEVICE_ARG)|#if 1 /* force drm_device arg */|' "${NV_DRM_HELPER}"
        # drm_mode_connector_* → drm_connector_* (renamed)
        sed -i 's|#if defined(NV_DRM_CONNECTOR_FUNCS_HAVE_MODE_IN_NAME)|#if 0 /* use new drm_connector_* names */|' "${NV_DRM_HELPER}"
    fi

    # nvidia-drm-connector.c: colorspace API now takes 2 args in 6.12
    local NV_DRM_CONN="${SRC_DIR}/kernel-open/nvidia-drm/nvidia-drm-connector.c"
    if [[ -f "${NV_DRM_CONN}" ]]; then
        sed -i 's|drm_mode_create_hdmi_colorspace_property(&nv_connector->base)|drm_mode_create_hdmi_colorspace_property(\&nv_connector->base, 0)|g' "${NV_DRM_CONN}"
        sed -i 's|drm_mode_create_dp_colorspace_property(&nv_connector->base)|drm_mode_create_dp_colorspace_property(\&nv_connector->base, 0)|g' "${NV_DRM_CONN}"
        # drm_helper_probe_single_connector_modes renamed in 6.12
        sed -i 's|drm_helper_probe_single_connector_modes|drm_connector_helper_funcs_probe_single_connector_modes|g' "${NV_DRM_CONN}"
    fi

    # nvidia-drm-crtc.c: add drm_blend.h for drm_plane_create_rotation_property
    local NV_DRM_CRTC="${SRC_DIR}/kernel-open/nvidia-drm/nvidia-drm-crtc.c"
    if [[ -f "${NV_DRM_CRTC}" ]]; then
        if ! grep -q 'drm/drm_blend.h' "${NV_DRM_CRTC}"; then
            sed -i '/#include <drm\/drm_plane.h>/a #include <drm/drm_blend.h>' "${NV_DRM_CRTC}"
        fi
    fi

    # nv.c: force DMA_BUF namespace import for 6.12
    local NV_C="${SRC_DIR}/kernel-open/nvidia/nv.c"
    if [[ -f "${NV_C}" ]]; then
        sed -i 's|#if defined(MODULE_IMPORT_NS)|#if 1 /* force MODULE_IMPORT_NS */|' "${NV_C}"
        sed -i 's|#if defined(NV_MODULE_IMPORT_NS_TAKES_CONSTANT)|#if 1 /* force constant */|' "${NV_C}"
    fi

    # Add Falcon mailbox dump at GSP boot for debugging
    if [[ -f "${GSP_C}" ]]; then
        python3 -c "
import pathlib
p = pathlib.Path('${GSP_C}')
t = p.read_text()
marker = 'NV_CHECK_OK_OR_RETURN(LEVEL_ERROR, kgspPopulateWprMeta_HAL(pGpu, pKernelGsp, pGspFw));'
dump = '''    NV_PRINTF(LEVEL_ERROR, \"GSP_MAILBOX: MBOX0=0x%08x MBOX1=0x%08x ENGINE=0x%08x\\n\",
        GPU_REG_RD32(pGpu, 0x110040), GPU_REG_RD32(pGpu, 0x110044),
        GPU_REG_RD32(pGpu, 0x1103c0));
    '''
if marker in t and 'GSP_MAILBOX' not in t:
    t = t.replace(marker, dump + marker, 1)
    p.write_text(t)
    print('Added GSP mailbox dump')
else:
    print('Mailbox dump already present or pattern not found')
"
    fi

    # ── 4. Conftest: fix critical false negatives AND false positives ──
    # The -Wno-implicit-function-declaration bug causes conftest to detect
    # functions as present when they don't exist. Fix both directions.
    local CONFTEST_DIR="${SRC_DIR}/kernel-open/conftest"
    if [[ -d "${CONFTEST_DIR}" ]]; then
        # False negatives (conftest says absent but present):
        sed -i 's/^#undef NV_MM_HAS_MMAP_LOCK$/#define NV_MM_HAS_MMAP_LOCK/' "${CONFTEST_DIR}/types.h" 2>/dev/null || true
        sed -i 's/^#undef NV_VM_FAULT_T_IS_PRESENT$/#define NV_VM_FAULT_T_IS_PRESENT/' "${CONFTEST_DIR}/types.h" 2>/dev/null || true
        sed -i 's/^#undef NV_VM_FAULT_T_IS_PRESENT$/#define NV_VM_FAULT_T_IS_PRESENT/' "${CONFTEST_DIR}/generic.h" 2>/dev/null || true
        sed -i 's/^#undef NV_PROC_OPS_PRESENT$/#define NV_PROC_OPS_PRESENT/' "${CONFTEST_DIR}/types.h" 2>/dev/null || true
        sed -i 's/^#undef NV_LINUX_OF_GPIO_H_PRESENT$/#define NV_LINUX_OF_GPIO_H_PRESENT/' "${CONFTEST_DIR}/headers.h" 2>/dev/null || true
        sed -i 's/^#undef NV_LINUX_DMA_DIRECT_H_PRESENT$/#define NV_LINUX_DMA_DIRECT_H_PRESENT/' "${CONFTEST_DIR}/headers.h" 2>/dev/null || true
        sed -i 's/^#define NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT 2$/#define NV_OF_DMA_CONFIGURE_ARGUMENT_COUNT 3/' "${CONFTEST_DIR}/functions.h" 2>/dev/null || true
        # False positives (conftest says present but absent):
        # hv_get_isolation_type doesn't exist on non-Hyper-V systems
        sed -i 's/^#define NV_HV_GET_ISOLATION_TYPE$/#undef NV_HV_GET_ISOLATION_TYPE/' "${CONFTEST_DIR}/functions.h" 2>/dev/null || true
        # drm_gem_object_put_unlocked was removed in newer kernels
        sed -i 's/^#define NV_DRM_GEM_OBJECT_PUT_UNLOCK_PRESENT$/#undef NV_DRM_GEM_OBJECT_PUT_UNLOCK_PRESENT/' "${CONFTEST_DIR}/functions.h" 2>/dev/null || true
        # pcie_is_cxl doesn't exist in this kernel
        sed -i 's/^#define NV_PCIE_IS_CXL_PRESENT$/#undef NV_PCIE_IS_CXL_PRESENT/' "${CONFTEST_DIR}/functions.h" 2>/dev/null || true
        # set_memory_array_uc removed in newer kernels
        sed -i 's/^#define NV_SET_MEMORY_ARRAY_UC_PRESENT$/#undef NV_SET_MEMORY_ARRAY_UC_PRESENT/' "${CONFTEST_DIR}/functions.h" 2>/dev/null || true
        # follow_pfn removed in 6.12 (use nv_follow_flavors fallback with follow_pfnmap_start)
        sed -i 's/^#define NV_FOLLOW_PFN_PRESENT$/#undef NV_FOLLOW_PFN_PRESENT/' "${CONFTEST_DIR}/functions.h" 2>/dev/null || true
        # jiffies_to_timespec removed in 6.12
        sed -i 's/^#define NV_JIFFIES_TO_TIMESPEC_PRESENT$/#undef NV_JIFFIES_TO_TIMESPEC_PRESENT/' "${CONFTEST_DIR}/functions.h" 2>/dev/null || true
        # __assign_str changed to 1 arg in 6.12
        sed -i 's/^#define NV_ASSIGN_STR_ARGUMENT_COUNT 2$/#define NV_ASSIGN_STR_ARGUMENT_COUNT 1/' "${CONFTEST_DIR}/functions.h" 2>/dev/null || true
        # class_create no longer takes module owner arg in 6.12
        if ! grep -q 'NV_CLASS_CREATE_HAS_NO_OWNER_ARG' "${CONFTEST_DIR}/functions.h" 2>/dev/null; then
            echo '#define NV_CLASS_CREATE_HAS_NO_OWNER_ARG' >> "${CONFTEST_DIR}/functions.h"
        fi
        # devnode callback takes const struct device * in 6.12
        if ! grep -q 'NV_CLASS_DEVNODE_HAS_CONST_ARG' "${CONFTEST_DIR}/functions.h" 2>/dev/null; then
            echo '#define NV_CLASS_DEVNODE_HAS_CONST_ARG' >> "${CONFTEST_DIR}/functions.h"
        fi
        touch "${CONFTEST_DIR}"/*.h 2>/dev/null || true
    fi
}

# Generate conftest first
info "Generating conftest..."
make -j1 modules SYSSRC="${KSRC}" kernel-open/conftest/headers.h kernel-open/conftest/functions.h kernel-open/conftest/types.h kernel-open/conftest/generic.h 2>/dev/null || true

# Apply ALL kernel compat fixes
fix_kernel_compat
ok "Kernel compat fixes applied"

JOBS="$(nproc)"
NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem" \
    make -j"${JOBS}" modules SYSSRC="${KSRC}" 2>/dev/null || true

# Re-apply fixes after first make pass (conftest regenerated)
fix_kernel_compat
ok "Kernel compat fixes re-applied"

# Second pass — exclude DRM/modeset/peermem (not needed for CMP compute cards)
NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem" \
    make -j"${JOBS}" modules SYSSRC="${KSRC}"
ok "Modules built"

info "Installing modules to ${INSTALL_MOD_DIR}..."
mkdir -p "${INSTALL_MOD_DIR}"

mapfile -t KO_FILES < <(find "${SRC_DIR}" -type f \( \
    -name 'nvidia.ko' -o -name 'nvidia-modeset.ko' -o -name 'nvidia-uvm.ko' \
    -o -name 'nvidia-drm.ko' -o -name 'nvidia-peermem.ko' \) \
    ! -path '*/conftest/*' | sort -u)
[[ ${#KO_FILES[@]} -gt 0 ]] || die "No built nvidia*.ko found"

for ko in "${KO_FILES[@]}"; do
    base="$(basename "${ko}")"
    install -m 0644 "${ko}" "${INSTALL_MOD_DIR}/${base}"
    ok "Installed ${base}"
done

depmod -a "${KVER}"
ok "depmod complete"

rebuild_initramfs() {
    if command -v update-initramfs &>/dev/null; then
        info "Rebuilding initramfs (update-initramfs) so patched modules load at boot..."
        update-initramfs -u -k "${KVER}"
        ok "initramfs rebuilt"
        return 0
    fi
    if command -v dracut &>/dev/null; then
        info "Rebuilding initramfs (dracut) so patched modules load at boot..."
        dracut --force --kver "${KVER}"
        ok "initramfs rebuilt"
        return 0
    fi
    if command -v mkinitcpio &>/dev/null; then
        info "Rebuilding initramfs (mkinitcpio) so patched modules load at boot..."
        mkinitcpio -P
        ok "initramfs rebuilt"
        return 0
    fi
    warn "No initramfs tool found — rebuild manually before rebooting"
    return 1
}

rebuild_initramfs || true

resolved="$(modprobe -n -v nvidia 2>/dev/null | awk '/insmod/ {print $2; exit}' || true)"
if [[ -n "${resolved}" ]]; then
    info "modprobe will load: ${resolved}"
    if [[ "${resolved}" != *"/updates/cmpunlocker/"* ]]; then
        warn "Resolved nvidia.ko is not under updates/cmpunlocker/ — stock may still win"
    fi
fi

info "Attempting to unload existing NVIDIA modules..."
systemctl stop nvidia-persistenced 2>/dev/null || true
systemctl stop nvidia-fabricmanager 2>/dev/null || true

reload_ok=0
if lsmod | grep -q '^nvidia'; then
    for mod in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
        modprobe -r "${mod}" 2>/dev/null || true
    done
    sleep 1
fi

if ! lsmod | grep -q '^nvidia '; then
    if modprobe nvidia && modprobe nvidia-modeset; then
        modprobe nvidia-uvm 2>/dev/null || true
        modprobe nvidia-drm 2>/dev/null || true
        reload_ok=1
        ok "Patched NVIDIA modules loaded"
        running_src="$(cat /sys/module/nvidia/srcversion 2>/dev/null || true)"
        patched_src="$(modinfo -F srcversion "${INSTALL_MOD_DIR}/nvidia.ko" 2>/dev/null || true)"
        if [[ -n "${running_src}" && -n "${patched_src}" && "${running_src}" != "${patched_src}" ]]; then
            warn "Loaded nvidia srcversion (${running_src}) != patched (${patched_src})"
            reload_ok=0
        fi
    else
        warn "modprobe failed after install"
    fi
else
    warn "Could not unload nvidia modules (in use) — cold reboot required"
fi

echo ""
if [[ "${reload_ok}" -eq 1 ]]; then
    ok "Build and install finished. Verify with: nvidia-smi"
    info "If memory still shows stock size, do a cold shutdown (power off), then boot."
else
    warn "Modules installed but the running driver is still stock (or unload failed)."
    info "Perform a cold reboot: shutdown -h now  (then power on)"
    info "After boot, confirm: cat /proc/driver/nvidia/version  (should NOT say dvs-builder)"
    info "And: sudo dmesg | grep SEC2_DEBUG"
fi
echo ""
