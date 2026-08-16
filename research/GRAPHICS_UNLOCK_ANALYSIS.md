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

## Next Steps (If Pursuing)

1. **Probe 0x823808** — write various patterns, check effects on PGRAPH
2. **PMC_ENABLE bit12** — try forcing GR power-on after compute unlock
3. **Dump GSP-RM firmware** — compare CMP vs RTX systems
4. **RE GSP RISC-V code** — find SKU/FEAT_READOUT check location
5. **Community outreach** — check if anyone has achieved this
