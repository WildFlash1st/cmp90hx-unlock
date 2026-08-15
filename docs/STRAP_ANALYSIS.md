# STRAP Analysis — Manli CMP 90HX (GA102, PG132 SKU 100)

**Date:** 2026-08-15
**Status:** measurements taken; DEVID_SEL mapping pending (empirical flip test)

## Measured strap state (Manli CMP 90HX, device 0x220D)

Each strap is a 2-pad resistor site (pull-up to 1V8 / pull-down to GND). Populated
resistor determines the logic level. Measured with multimeter (continuity to GND /
1V8 rail):

| Strap | Pads | Populated | Pull | Level | Bit |
|-------|------|-----------|------|-------|-----|
| STRAP0 | R5225 / R5226 | R5226 | GND | L | 0 |
| STRAP1 | R5227 / R5228 | R5227 | 1V8 | H | 1 |
| STRAP2 | R5229 / R5230 | R5230 | GND | L | 0 |
| STRAP3 | R5236 / R5237 | R5236 | 1V8 | H | 1 |
| STRAP4 | R5240 / R5241 | R5241 | GND | L | 0 |
| STRAP5 | R5244 / R5245 | R5245 | GND | L | 0 |

Current mask (S0..S5): `0 1 0 1 0 0` → device **0x220D (CMP 90HX)**.

## GA102 device ID table (authoritative, from g_nv_name_released.h)

| Device ID | Name |
|-----------|------|
| 0x2203 | GeForce RTX 3090 Ti |
| 0x2204 | GeForce RTX 3090 |
| 0x2206 | GeForce RTX 3080 |
| 0x2207 | GeForce RTX 3070 Ti |
| 0x2208 | GeForce RTX 3080 Ti |
| 0x220A | GeForce RTX 3080 |
| 0x220D | CMP 90HX |

Targets for the experiment: **0x2206** or **0x220A** (full consumer RTX 3080).

## Experiment: find DEVID_SEL bits (empirical, one flip at a time)

The strap→ID mapping is NOT a direct binary of the low nibble (current mask 010100 →
0x0A/0x14, neither = 0x0D), so the mapping must be discovered empirically:

1. Move ONE resistor to the opposite pad (e.g., R5226 → R5225 flips STRAP0)
2. Boot WITHOUT the unlock service active (device ID ≠ 220D → bootstrap won't fire —
   card boots stock, fine for reading the ID)
3. Read: `lspci -s 01:00.0 -nn` (device ID) and `lspci -s 01:00.0 -vvv | grep LnkCap2`
   (**the PCIe cap is the second thing to watch** — if DEVID also feeds the PHY
   config, the link capability may change)
4. Record the ID per flipped bit; restore the strap
5. Once DEVID bits are known, set the combination for 0x2206/0x220A

## Coupling with the compute unlock (IMPORTANT)

`kgspCmp90hxApplyComputeOverrides` gates on `PCIDeviceID==0x220D && PCISubDeviceID==0x1555`.
After a strap change that alters the device ID, the unlock will NOT apply at boot.
Fix: add the new device ID to `_kgspCmp90hxEnabled` in the bootstrap source
(`/home/it/bendy2-cmp90hx/work/cmp90hx-persistent-build/.../kernel_gsp.c`), rebuild,
reinstall — SS0/SS1 are plain register writes and work under any ID once PLM opens.

## Risks / notes

- Operation is reversible (move the resistor back); no VBIOS or fuse is touched
- The link cap (`LnkCap2: 2.5GT/s`) may be fed by the same strap block — this is the
  main hypothesis to test; if 2206/220A changes LnkCap2 → PCIe Gen3+ becomes real
- Habr teardown of other CMP boards found the gen limit deeper than the lanes; the
  strap experiment is the definitive test for THIS board
