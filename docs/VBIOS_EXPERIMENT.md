# VBIOS Cross-Flash Experiment — CMP 90HX ← RTX 3080

**Date:** 2026-07-27  
**Status:** ❌ GSP hang at progress 0x1 — memory training incompatible  
**Verdict:** Device ID substitution WORKS. Memory timings are the blocker.

## What We Did

Flashed an RTX 3080 VBIOS (Manli, `94.02.26.48.52`) onto a CMP 90HX (native `94.02.74.00.01`) using [nvflashk](https://github.com/notfromstatefarm/nvflashk) — a patched nvflash that bypasses PCI Subsystem ID, Board ID, and Device ID mismatch checks.

```
nvflashk.exe --index 0 -6 Manli.RTX3080.10240.201012.rom
```

## Results

| Component | Before | After |
|-----------|--------|-------|
| VBIOS version | 94.02.74.00.01 | **94.02.26.48.52** ✅ |
| Device ID | 10DE:220D | **10DE:2206** (RTX 3080) |
| Subsystem ID | 10DE:1555 | **10DE:1612** |
| Board ID | 0314 | **023F** |
| GSP boot | progress 0x0 → OK | **progress 0x1 → HANG** ❌ |

## Key Finding

```
dmesg:
NVRM: GPU0 gpuWaitForGfwBootComplete_TU102: 
  failed to wait for GFW_BOOT: (progress 0x1)
  VBIOS version 94.02.26.48.52
NVRM: GPU0 kgspWaitForGfwBootOk_TU102: 
  failed to wait for GFW boot complete: 0x55
  (the GPU may be in a bad state and may need to be reset)
```

**Progress 0x1 = GSP started, entered memory training, FAILED.**

This PROVES:
1. ✅ BootROM accepts Device ID substitution — GSP firmware loads
2. ✅ GSP begins executing — reaches initialization code
3. ❌ Memory training (BCT/straps) incompatible between JPG132 (CMP) and PG132 (RTX 3080)

## Why This Matters

The experiment demonstrates that **Device ID gating IS software-enforced**, not purely hardware. The GSP reads the VBIOS, sees RTX 3080 identifiers, and attempts to configure the GPU accordingly. The failure is at the memory controller level — not at the authentication/ID check level.

## Next: Frankenstein VBIOS

If CMP 90HX memory timings (BCT/Power tables) are transplanted into an RTX 3080 VBIOS, the GSP should:
1. See RTX 3080 IDs → load "unrestricted" init path
2. Read CMP memory timings → successfully train GDDR6X
3. Potentially unlock PCIe Gen3 and compute

Tools needed: [Ampere BIOS Editor](https://github.com/bmgjet/Ampere-Bios-Editor) (Windows, C#)

## Files

| File | Description |
|------|-------------|
| `/home/it/GA102.rom` | Original CMP 90HX VBIOS |
| `/home/it/factory_backup3080.rom` | Working RTX 3080 VBIOS (ASUS) |
| `/home/it/Manli.RTX3080.10240.201012.rom` | Manli RTX 3080 VBIOS (flashed) |
| `/home/it/Manli.RTX3080.10240.210305.rom` | Manli RTX 3080 VBIOS (newer, untested) |
| `/tmp/cmp90hx_backup_original.rom` | Backup before flash |

## References

- [nvflashk](https://github.com/notfromstatefarm/nvflashk) — Patched nvflash with ID bypass
- [Ampere BIOS Editor](https://github.com/bmgjet/Ampere-Bios-Editor) — For BCT table transplant
- [Rhonstin's fork](https://github.com/Rhonstin/cmp90hx-unlock) — Deep Falcon/GSP analysis
