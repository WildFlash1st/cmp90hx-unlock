# GA102 XVE — PCIe Config-Space Mirror (host-writable)

**Date:** 2026-08-16
**Status:** confirmed on CMP 90HX (GA102, 0x220D) — architecture knowledge,
independent of the PCIe Gen2 unlock outcome.

## Discovery

BAR0 register scan (via bootstrap `GPU_REG_RD32`) of the XVE block revealed
that **XVE base `0x00088000` is a byte-exact mirror of the PCIe config-space
capability block** (`0x78..0xFF`). Mapping: `BAR0 0x88000 + config_offset`.

> **CORRECTION (2026-08-22):** the table below previously shifted every label
> by one dword (LnkCap was listed at 0x88088, LnkCtl2 at 0x8809c). The correct
> PCIe-cap layout for cap @0x78 is: LnkCap=0x84, LnkCtl/LnkSta=0x88,
> LnkCap2=0xA4, LnkCtl2/LnkSta2=0xA8. The original Aug-16 "advertise Gen3"
> experiment therefore wrote **Link Control**, not Link Capabilities; the
> conclusion was re-verified against the true addresses on 2026-08-22 (see
> `docs/GEN3ADV_XP3G_RESEARCH.md`): with FEAT PLM open, 0x88084 (LnkCap),
> 0x880a4 and 0x880a8 are hardware-RO for both host and SEC2-falcon writes;
> only 0x88088 (LnkCtl) accepts host writes.

| BAR0 | Config | Register | Value (CMP 90HX) |
|------|--------|----------|------------------|
| 0x88078 | 0x78 | Cap ID / next | 0x0002b410 |
| 0x8807c | 0x7C | DevCap | 0x112c8de1 |
| 0x88080 | 0x80 | DevCtl/Sta | 0x0000213f |
| 0x88084 | 0x84 | **LnkCap** | 0x00453d01 (Max Link Speed = 1 → 2.5GT/s, W x16) |
| 0x88088 | 0x88 | LnkCtl/Sta | 0x11010140 (LnkSta: Speed=1, Width=x16) |
| 0x880a4 | 0xA4 | LnkCap2 area | 0x00000002 |
| 0x880a8 | 0xA8 | **LnkCtl2/Sta2** | TLS = 1 (target 2.5GT/s) |

## Key property: partially host-writable

With the FEAT_OVR PLM open, `GPU_REG_WR32(0x88088, ...)` **changes the raw
config-space Link Control** as read by the kernel (od/setpci/sysfs):

```text
LNKCTL_MIRROR 0x88088 old=0x11010140 new=0x11010141 rb=0x11010141
(ASPM L0s bit toggled; restored afterwards)
```

- The write goes through the normal driver path (no SEC2/CSB needed).
- It survives across service restarts (register keeps its value until reset).
- The capability registers themselves — **LnkCap (0x88084), LnkCap2 area
  (0x880a4), LnkCtl2 (0x880a8)** — silently drop host writes even with PLM
  open (verified 2026-08-22 via rm_reg toggle tests; NVIDIA's own
  `dev_nv_pcfg_xve_regmap.h` WR bitmap marks them writable, but that map does
  not reflect the live per-register RO policy seen from the host).

## Why it matters (independent of PCIe Gen2 outcome)

1. **First known way to alter the OS-visible PCIe capability advertisement on
   GA102 from software** — the config block serves the *emulated* values to the
   OS, and this mirror exposes the same registers to BAR0 writes.
2. **Architecture knowledge:** the XVE block implements/aliases the PCIe
   capability registers; offsets are byte-aligned with config space.
3. Could be reused for capability masking experiments on other GA10x parts,
   debug, or future unlock work that touches config-space semantics.

## Caveats

- Changing the advertisement does **not** change PHY training (verified: link
  stays Gen1). PHY training follows internal state (OPT_GEN23 etc.), not the
  config-space copy.
- `lspci -vvv` reads a different (emulated/synthesized) view and did not reflect
  the change; kernel raw reads (od/setpci/max_link_speed) did.
- Read-only scan data for the full XVE block (0x88000-0x88fff) plus OPTB and
  PCIe-cfg blocks: `/root/pcie_full_map.txt`.

## Access tools

- `research/rm_reg` — live BAR0 read/write via RM ioctl (NV2080_CTRL_GPU_REG_OPS):
  `./rm_reg read 0x88088` / `./rm_reg write 0x88088 0x11010143`
- Bootstrap `GPU_REG_RD32`/`GPU_REG_WR32` (kernel module path).
