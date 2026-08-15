# Analysis of bendy2/cmp90hx — Working Unlock for 580.159.03

**Source:** https://github.com/bendy2/cmp90hx  
**Author:** [bendy2](https://github.com/bendy2)  
**License:** See original repository  
**Status:** ✅ Working compute unlock for CMP 90HX on driver 580.159.03

> **Important:** All work on finding ROP gadgets and creating the V67 payload was done by bendy2. This document is an analysis of their solution for adaptation to other driver versions.

## Key Discovery

bendy2 found a **working V67 payload** (ROP chain) for opening PLM and writing SS0/SS1 on driver **580.159.03**!

## Technical Details

### Driver Version
- **580.159.03** — NOT 610.x!
- Open GPU Kernel Modules
- PCI ID: `10de:220d` / `10de:1555`

### ROP Payload (V67)
Payload size **0xFA00 (64000)** bytes, filled with `0x0000019C`:

```c
// Key offsets and values in ROP-chain:
offset 0x1100: 0x00000007   // Init instruction
offset 0xf948: 0xffffffff   // PLM open value
offset 0xf950: 0x00000d44   // ROP gadget address
offset 0xf960: 0x00823804   // FEAT_OVR_PLM register
offset 0xf968: 0x00001fce   // ROP gadget address
offset 0xf974: 0x00000000   // 
offset 0xf97c: 0x00001101   // 
offset 0xf980: 0x000084c8   // ROP gadget address
offset 0xf984: 0x00008e18   // ROP gadget address
offset 0xf98c: 0x000084c8   // 
offset 0xf990: 0x00000000   // 
offset 0xf998: 0x00001fce   // 
offset 0xf9a4: 0x0000ffbc   // 
offset 0xf9ac: 0x00005789   // 
offset 0xf9bc: 0x00000d44   // 
offset 0xf9cc: 0x00000003   // 
offset 0xf9d4: 0x00001fce   // 
offset 0xf9e8: 0x00000d52   // 
offset 0xf9ec: 0x000081ee   // 
```

### Discovered ROP Gadgets (580.x firmware)
- `0x00000d44` — ?
- `0x00001fce` — ?
- `0x000084c8` — ?
- `0x00008e18` — ?
- `0x0000ffbc` — ?
- `0x00005789` — ?
- `0x00000d52` — ?
- `0x000081ee` — ?

### Target Registers
```c
CMP90HX_FEAT_OVR_PLM     = 0x00823804  // PLM override
CMP90HX_FEAT_OVR_SM_SPD  = 0x0082381C  // SS0 (SM speed 0)
CMP90HX_FEAT_OVR_SM_SPD_1= 0x00823820  // SS1 (SM speed 1)
```

### Unlock Values
```c
PLM:  0xFFFFFFFF  // Open all PLMs
SS0:  0x88888888  // All SMs enabled
SS1:  0x00000008  // FP32/FP64 unlock
```

## Unlock Process (V67)

1. Save WPR2 (lo/hi)
2. Fill signature memdesc with ROP payload
3. Execute `kgspExecuteBooterLoad_HAL()` — V67 invocation
4. Check `FEAT_OVR_PLM == 0xFFFFFFFF`
5. If not opened — retry (max 2 attempts)
6. Restore WPR2
7. Write `SS1 = 0x00000008`, then `SS0 = 0x88888888`
8. Restore stock signature
9. Execute bus reset via systemd

## Adaptation to 610.x

**Problem:** ROP gadgets `0x00000d44`, `0x00001fce` etc. are addresses in **580.x** firmware. In **610.x**, firmware has a different format (.fwimage flat binary) and different addresses.

**Tasks:**
1. Find equivalent gadgets in 610.x firmware
2. Recalculate payload offsets
3. Possibly change payload format (580.x vs 610.x signature format)

## Graphics Analysis

From `分析报告-90HX图形阉割定位.md` (bendy2's graphics analysis):

- **PGRAPH2** (3D engine) — 7177 registers return `0xBADFxxxx` (gate-off)
- **FIFO/CE** — 5538 registers = 0 (not initialized)
- Root cause: GSP-RM firmware skips graphics initialization
- `FEAT_READOUT_0 @ 0x00823814`: bit8 = 0 (no graphics)

**This is a separate problem** — even after compute unlock, graphics don't work!

## Files from bendy2

| File | Description |
|------|-------------|
| `patches/0001-58015903-cmp90hx-direct-compute.patch` | Main patch |
| `分析报告-90HX图形阉割定位.md` | Graphics analysis |
| `others/compare.py` | BAR0 dump comparison script |
