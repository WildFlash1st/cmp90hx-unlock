# GA102 XVE — PCIe Config-Space Mirror (host-writable)

**Date:** 2026-08-16
**Status:** confirmed on CMP 90HX (GA102, 0x220D) — architecture knowledge,
independent of the PCIe Gen2 unlock outcome.

## Discovery

BAR0 register scan (via bootstrap `GPU_REG_RD32`) of the XVE block revealed
that **XVE base `0x00088000` is a byte-exact mirror of the PCIe config-space
capability block** (`0x78..0xFF`). Mapping: `BAR0 0x88000 + config_offset`.

| BAR0 | Config | Register | Value (CMP 90HX) |
|------|--------|----------|------------------|
| 0x88078 | 0x78 | Cap ID / next | 0x0002b410 |
| 0x8807c | 0x7C | DevCap | 0x112c8de1 |
| 0x88080 | 0x80 | DevCtl | 0x0000213f |
| 0x88084 | 0x84 | DevSta | 0x00453d01 |
| 0x88088 | 0x88 | **LnkCap** | 0x11010140 |
| 0x8808c | 0x8C | LnkCtl | 0x00000000 |
| 0x88090 | 0x90 | LnkSta | 0x00000000 |
| 0x88094 | 0x94 | DevCap2 | badf (unreadable) |
| 0x88098 | 0x98 | LnkCap2 | badf (unreadable) |
| 0x8809c | 0x9C | LnkCtl2 | 0x00070813 |
| 0x880a0 | 0xA0 | LnkSta2 | 0x00000400 |
| 0x880a4 | 0xA4 | (ext) | 0x00000002 |
| 0x880a8 | 0xA8 | (ext) | 0x00000001 |

## Key property: host-writable

With the FEAT_OVR PLM open, `GPU_REG_WR32(0x88088, ...)` **changes the raw
config-space LnkCap** as read by the kernel (od/setpci/sysfs):

```text
LNKCAP_MIRROR 0x88088 old=0x11010140 new=0x11010143 rb=0x11010143
→ raw config 0x88 = 0x11010143 (MaxLinkSpeed = Gen3)
```

- The write goes through the normal driver path (no SEC2/CSB needed).
- It survives across service restarts (register keeps its value until reset).
- `LnkCap2` mirror (0x88098) and `DevCap2` (0x88094) return `badf5040` on read
  (not implemented / protected) and ignore writes.

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
