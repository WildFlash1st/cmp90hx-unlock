# CMP 90HX — Graphics (PGRAPH2) Unlock Analysis (2026-08-16)

## Status: ❌ Blocked — Hardware eFuse, No Override

Graphics unlock on CMP 90HX is **significantly harder** than compute unlock was.
The fundamental difference: compute throttle had override registers (SS0/SS1),
graphics disable does not.

## Comparison: Compute vs Graphics

| Parameter | Compute (SOLVED ✅) | Graphics (BLOCKED ❌) |
|-----------|---------------------|----------------------|
| Disable mechanism | SM issue-rate throttle | PGRAPH init skip |
| Control register | SS0 @ 0x82381C, SS1 @ 0x823820 | FEAT_READOUT_0 @ 0x823814 |
| Override register | ✅ FEAT_OVR_SM_SPD exists | ❌ NO override exists |
| Register type | Writable via FEAT_OVR (PLM open) | eFuse (hardware R/O) |
| CMP 90HX value | 0x05050505 (throttled) | 0x00000033 (bit8=0) |
| RTX 3090 value | 0x88888888 (full speed) | 0x00000233 (bit8=1) |
| Unlock method | V67 → PLM open → write SS0/SS1 | None known |

## Technical Details

### FEAT_READOUT_0 Register (0x00823814)

```
Offset: BAR0 0x00823814
Type:   R--4R (Read-only 4-byte)
Source: NV_FUSE_FEATURE_READOUT in dev_fuse.h

Bit layout (documented):
  bit16: ECC_DRAM (0=disabled, 1=enabled)

Bit layout (undocumented, from RE):
  bit8:  Graphics functional (0=disabled, 1=enabled)

Values:
  CMP 90HX:  0x00000033 (bit8=0 → graphics disabled)
  RTX 3090:  0x00000233 (bit8=1 → graphics enabled)
```

### GSP-RM Behavior

GSP-RM firmware reads FEAT_READOUT_0 during boot:
- If bit8=0: skips PGRAPH initialization entirely
- Result: 7177 PGRAPH2 registers return 0xBADFxxxx (power-gated)
- Result: 4680 FIFO/CE registers stay at 0 (never initialized)

The skip logic is in **closed-source GSP firmware**, not open kernel modules.

### Why No Override Works

Unlike SS0/SS1 which have explicit FEAT_OVR registers:
```
SS0:  0x0082381C (FEAT_OVR_SM_SPD)   — writable after PLM open
SS1:  0x00823820 (FEAT_OVR_SM_SPD_1) — writable after PLM open
```

FEAT_READOUT_0 is a **direct eFuse read** with no corresponding override:
```
FEAT_READOUT_0: 0x00823814 — no FEAT_OVR_READOUT exists
```

The V67 exploit can write to the FEAT_OVR block (0x823800+), but 0x823814
is not part of the override mechanism — it's a raw fuse register.

### Related Registers Probed

| Offset | Name | Status |
|--------|------|--------|
| 0x823804 | FEAT_OVR_PLM | ✅ Writable (used for compute unlock) |
| 0x823808 | Unknown | ✅ Writable (0x00100282→0x03900bbb), function unknown |
| 0x82380C | SS0 mirror? | Read-only |
| 0x823814 | FEAT_READOUT_0 | ❌ Read-only eFuse |
| 0x823818 | Unknown | Zero |
| 0x82381C | FEAT_OVR_SM_SPD (SS0) | ✅ Writable (used for compute unlock) |
| 0x823820 | FEAT_OVR_SM_SPD_1 (SS1) | ✅ Writable (used for compute unlock) |

## Nouveau Analysis

Nouveau is **NOT a viable alternative** for graphics unlock.

### Why Nouveau Won't Help

1. **GSP-RM firmware is REQUIRED** for all Ampere GPUs (GA10x)
   - Without it, driver cannot initialize Ampere hardware at all
   - Required files: `gsp_ga10x.bin`, `booter_load_ga10x.bin`, `booter_unload_ga10x.bin`

2. **Nouveau defers GR to GSP-RM**:
   ```c
   // tu102.c, ga102.c
   if (nvkm_gsp_rm(device->gsp))
       return -ENODEV;  // Let GSP handle graphics
   ```

3. **No CMP-specific handling**: Nouveau uses nv172_chipset for GA102
   identically to RTX 3090 — no code to detect or bypass CMP limitations

4. **Same root cause**: The graphics disable decision happens in GSP-RM
   firmware (reads FEAT_READOUT_0 bit8), not in the open-source kernel driver

5. **TOP enumeration is downstream**: Nouveau gets engine list from GSP-RM
   device info table — if GSP says no GR engine, Nouveau cannot override

### Nouveau Code Path

```
ga102_gr_new() / tu102_gr_new()
    └── if (nvkm_gsp_rm(device->gsp)) return -ENODEV
    └── (native path never reached on Ampere)

nvkm_rm_gr_new()  ← GSP-RM path
    └── Gets GR info from GSP RPC
    └── If GSP reports no GR → no graphics
```

## Possible Attack Vectors (All High Difficulty)

### 1. GSP-RM Firmware Patching
- RE the RISC-V GSP firmware to find FEAT_READOUT_0 check
- Patch to ignore bit8 or force device ID != 0x220D
- **Blocker**: PKC signature verification (RSA-3K), enforced by BootROM

### 2. Undocumented Override Register
- 0x823808 is writable but function unknown
- Try writing patterns that include bit8 (0x100, 0x133, 0x233)
- **Likelihood**: Low — no evidence of graphics override in FEAT_OVR block

### 3. Force PGRAPH Power-On
- After compute unlock, write 0x1000 to NV_PMC_ENABLE (0x200) bit12
- Check if PGRAPH registers transition from 0xBADFxxxx
- Then manually write 7177+ PGRAPH2 registers from RTX 3090 BAR0 dump
- **Likelihood**: Very low — sequencing is critical, likely GPU hang

### 4. CSB Write to Fuse Register
- V67 chain can address 0x823800+lowbyte via CSB
- Try writing 0x233 to 0x823814 directly
- **Likelihood**: Very low — eFuse is OTP (one-time programmable)

## Conclusion

Graphics unlock on CMP 90HX requires one of:
1. **GSP-RM firmware modification** (blocked by PKC signatures)
2. **Undiscovered override register** (not found in probing)
3. **Manual PGRAPH init** (7177+ registers, impractical)

Unlike compute which had the FEAT_OVR_SM_SPD mechanism, graphics disable
is a direct eFuse read with no software override path.

**bendy2's analysis confirms**: "不是 fuse/硬件阉割，是固件层面的 init 跳过"
(Not fuse/hardware castration, but firmware-level init skip). This means
the hardware exists and works — it's just not initialized. However, the
initialization is controlled by signed GSP firmware reading an eFuse bit.

## Files Referenced

### NVIDIA Open Driver (610.43.03)
- `src/nvidia/src/kernel/gpu/gr/kernel_graphics.c` — GR init
- `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` — GSP-RM interface
- `src/nvidia/src/kernel/gpu/subdevice/subdevice_ctrl_gpu_kernel.c` — CMP SKU check
- `src/common/inc/swref/published/ampere/ga100/dev_fuse.h` — FEAT_READOUT definition

### Nouveau (Linux kernel)
- `drivers/gpu/drm/nouveau/nvkm/engine/gr/ga102.c` — GA102 GR
- `drivers/gpu/drm/nouveau/nvkm/subdev/gsp/` — GSP interface
- `drivers/gpu/drm/nouveau/nvkm/subdev/fuse/gm107.c` — Fuse reading

## GSP Firmware Analysis Results (2026-08-16)

### Critical Discovery: Device ID Table Exclusion

**FEAT_READOUT_0 (0x823814) is NOT read by GSP firmware directly!**

Exhaustive search of 84MB RISC-V GSP firmware found:
- NO LUI 0x823 instructions
- NO direct 0x823814 literal
- NO AUIPC patterns reaching 0x823814

Instead, graphics disable happens via **Device ID table exclusion**:

```
Firmware offset 0xe037b0 - Supported Device IDs:
  0x2203, 0x2204, 0x2205, 0x2206, 0x2207, 0x2208, 0x2209, 0x220A, 0x220C
  
  NOTE: 0x220D (CMP 90HX) is ABSENT!
```

### New Model of Graphics Disable

```
Old assumption:
  GSP reads FEAT_READOUT_0 → bit8=0 → skip PGRAPH

Actual mechanism:
  1. GSP reads device ID from hardware
  2. Lookup in whitelist table @ 0xe037b0
  3. 0x220D not in table → skip PGRAPH init
  4. FEAT_READOUT_0 bit8=0 is EFFECT, not CAUSE
```

### Registry Keys Found in Firmware

| Offset | Key | Potential Use |
|--------|-----|---------------|
| 0x1015ee8 | `RMSkipGrResetForInstSys` | Skip GR reset |
| 0x1024e00 | `DisableGrAuto` | Auto-disable mechanism |
| 0x1015ed0 | `RMForceGrUcodeLoad` | Force GR microcode load |
| 0x1015fd0 | `GrCtxSwMode` | GR context switch mode |

### New Attack Vectors

1. **Device ID Spoofing** — make GSP see 0x2206 instead of 0x220D
   - PCI config space device ID? (likely in eFuse)
   - GSP reads from where? (needs more RE)

2. **Registry Key Override** — set `RMForceGrUcodeLoad=1` via RM
   - Need to find how to pass regkeys to GSP-RM

3. **Table Patching** — add 0x220D to table @ 0xe037b0
   - Blocked by PKC signature verification

---

## Why There's Still Hope

**Key fact from bendy2**: "不是 fuse/硬件阉割，是固件层面的 init 跳过"
(Not fuse/hardware castration, but firmware-level init skip)

This means:
- **PGRAPH hardware physically EXISTS and works** on CMP 90HX
- The silicon is identical to RTX 3090
- Only the initialization is skipped by GSP-RM firmware
- If we can force initialization, graphics should work

The difference from compute unlock: we found SS0/SS1 override registers.
For graphics, we haven't found the equivalent yet — but it may exist.

## Concrete Experiments (NOT YET DONE)

### 1. Systematic 0x823808 Probe
This register is writable but function unknown. Test all relevant patterns:

```bash
# After compute unlock (PLM open), try:
./rm_reg write 0x823808 0x00000100  # bit8 set
./rm_reg write 0x823808 0x00000233  # RTX 3090 FEAT_READOUT value
./rm_reg write 0x823808 0xFFFFFFFF  # all bits
# After each write, check:
./rm_reg read 0x400000  # PGRAPH base - should NOT be 0xBADF if working
```

### 2. PMC_ENABLE bit12 (Force GR Power-On)
NV_PMC_ENABLE @ 0x200, bit12 = GR engine enable:

```bash
# Read current PMC_ENABLE
./rm_reg read 0x200
# Set bit12 (GR enable)
./rm_reg write 0x200 0x????1???  # OR current value with 0x1000
# Check PGRAPH registers
./rm_reg read 0x400000
./rm_reg read 0x409604  # GPC count
```

### 3. V67 Payload Modification
Current V67 writes SS0/SS1 after PLM open. Could extend to:
- Write to 0x823808 with graphics-enable pattern
- Write to PMC_ENABLE bit12
- Probe GSP data segment for cached FEAT_READOUT result

### 4. GSP-RM Firmware Analysis
```bash
# Extract and compare firmware
binwalk /lib/firmware/nvidia/610.43.03/gsp_ga10x.bin
# Disassemble RISC-V code, search for:
# - 0x823814 reference (FEAT_READOUT read)
# - 0x220D reference (device ID check)
# - Conditional branch after fuse read
```

### 5. Runtime Memory Patching
If GSP caches FEAT_READOUT result in DMEM/IMEM:
- Find the cached value location via V67 memory scan
- Patch it to 0x233 (bit8=1) before PGRAPH init decision
- This would require understanding GSP boot sequence timing

## Summary

| Path | Difficulty | Tested? |
|------|------------|---------|
| 0x823808 systematic probe | Low | ❌ No |
| PMC_ENABLE bit12 | Low | ❌ No |
| V67 payload extension | Medium | ❌ No |
| GSP firmware RE | High | ❌ No |
| GSP memory patching | Very High | ❌ No |

**The "blocked" status means: no KNOWN path works, not that it's impossible.**
Several low-difficulty experiments remain untested.
