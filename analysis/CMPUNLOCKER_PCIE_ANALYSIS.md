# cmpunlocker-rs Binary Analysis: PCIe Gen3 Claim Investigation

**Date:** 2026-08-17  
**Target:** pearlfortune/cmpunlocker v0.1.28 (cmpunlocker-rs binary)  
**Method:** Ghidra headless + rizin static analysis  
**Issue:** [#4 — PCIe Gen3 claim needs verification](https://github.com/minicx/cmpunlocker/issues/4)

---

## Executive Summary

**cmpunlocker DOES NOT unlock PCIe Gen3.**

The binary contains V67 compute unlock code (SS0/SS1 writes) but **NO code for PCIe speed modification**. The `NVreg_EnablePCIeGen3` strings found in the binary are part of embedded NVIDIA driver code, not a separate unlock mechanism.

---

## Analysis Results

### 1. Compute Unlock Code — FOUND ✅

V67 exploit code located at `0x079f5160`:

```asm
0x079f5160  mov qword [rsp], 0x82381c    ; SS0 address
0x079f51dd  mov eax, dword [rax+0x823804] ; Read FEAT_OVR_PLM
```

Registers accessed:
| Address | Name | Found | Count |
|---------|------|-------|-------|
| 0x82381c | SS0 (FEAT_OVR_SM_SPD) | ✅ | 13 locations |
| 0x823820 | SS1 (FEAT_OVR_SM_SPD_1) | ✅ | 16 locations |
| 0x823804 | FEAT_OVR_PLM | ✅ | Referenced in unlock code |

### 2. PCIe Gen3 Unlock Code — NOT FOUND ❌

Critical PCIe registers searched:
| Address | Name | Found | Implication |
|---------|------|-------|-------------|
| 0x823810 | PCIE_FUSE | ❌ | No PCIe fuse modification |
| 0x82057c | OPT_GEN23 | ❌ | No Gen2/3 strap modification |

Other PCIe-related values found (but NOT for unlock):
| Address | Name | Found | Context |
|---------|------|-------|---------|
| 0x88088 | XVE_LnkCap | ✅ | Read-only in driver code |
| 0x8c000 | LINK_CONTROL | ✅ | Read-only in driver code |
| 0x8c040 | LINK_SPEED | ✅ | Read-only in driver code |

### 3. NVreg_EnablePCIeGen3 Strings — Part of Embedded Driver

Found at multiple offsets:
```
0x3f5c0e  NVreg_EnablePCIeGen3
0xb0bd60  EnablePCIeGen3  
0xc1c211  EnablePCIeGen3
```

These are standard NVIDIA driver module parameters embedded in the binary. **No xrefs found** — meaning the binary doesn't use these strings programmatically for any unlock.

`NVreg_EnablePCIeGen3=1` modprobe parameter only works if hardware LnkCap allows Gen3. On CMP 90HX, LnkCap is **fuse-locked to Gen1** (OPT_GEN23 eFuse), so the parameter has **no effect**.

### 4. stockflow Patches Analysis

All PCIe mentions in patches are for **FLR (Function Level Reset)** — part of V67 compute unlock:

```c
"CMP90_STOCKFLOW_REJOIN12: armed official PCIe FLR on init-failure cleanup"
```

No patches modify PCIe speed capability.

---

## Why Issue #4 Claims Are Incorrect

@vnadein's claim of "+50% performance from PCIe Gen3" is likely:

1. **Confusion with compute unlock** — V67 unlock gives +700% prefill, user may attribute it to PCIe
2. **Placebo effect** — measuring after compute unlock enabled
3. **Misunderstanding** — `NVreg_EnablePCIeGen3=1` presence ≠ actual Gen3 speed

Evidence requested from user:
- `lspci -vv | grep -A20 "LnkCap\|LnkSta"` showing actual link speed
- Before/after compute unlock benchmarks
- PCIe bandwidth measurement (not just inference throughput)

---

## Technical Deep-Dive

### Why Hardware PCIe Unlock Is Impossible

The PCIe Gen1 lock on CMP 90HX is enforced by:

```
OPT_GEN23 @ 0x82057c — eFuse-backed, hardware read-only
  bit0: Gen2 disable
  bit1: Gen3 disable
  CMP 90HX: 0x3 (both disabled)
```

Unlike compute throttle (SS0/SS1) which has FEAT_OVR override registers, PCIe strap has **no software override mechanism**:

| Feature | Override Register | Unlock Possible |
|---------|------------------|-----------------|
| Compute (SM speed) | FEAT_OVR_SM_SPD (SS0/SS1) | ✅ Yes |
| PCIe Gen2/3 | None | ❌ No |

### XVE Registers Are Read-Only

The XVE (PCIe controller) registers found in binary:
- `0x88088` (LnkCap) — mirrors fused capability, read-only
- `0x8c000` (LINK_CONTROL) — can force retrain, but **cannot exceed LnkCap**
- `0x8c040` (LINK_SPEED) — reports current speed, read-only

Writing to LINK_CONTROL can trigger re-negotiation, but the link will re-train to the **maximum allowed by LnkCap** (Gen1 for CMP 90HX).

---

## Conclusion

**pearlfortune/cmpunlocker does NOT unlock PCIe Gen3.**

The binary performs:
1. ✅ V67 compute unlock (SS0/SS1 full speed selectors)
2. ✅ PCIe FLR (reset after unlock)
3. ❌ PCIe Gen3 unlock (impossible — eFuse-locked)

The "+50% performance" claim in issue #4 is unsubstantiated and likely conflates compute unlock gains with PCIe improvement.

---

## Files Analyzed

- `cmpunlocker-v0.1.28-linux-x64-90hx-stockflow/cmpunlocker-rs` (128 MB ELF binary)
- `stockflow/610.43.03/patches/*.patch` (rejoin11-14 patches)
- Ghidra scripts: `AnalyzePCIe.java`, `DecompilePCIe.java`
