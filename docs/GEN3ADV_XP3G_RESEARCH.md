# GEN3ADV — PCIe Gen2+ Research on CMP 90HX (GA102)

**Date:** 2026-08-22
**Status:** software front exhaustively closed. Root gate identified:
the **XP3G privilege domain (PLM @ BAR0 `0x8E1B0`)** is locked against every
software-accessible level (host ± FEAT PLM, SEC2 falcon ROP).
Machine state after the campaign: compute unlock fully active, normal
rejoin15 module restored.

## Background

The working hypothesis "we only tried Gen2, never Gen3/4" was disproven first,
then replaced by a stronger research program after the user pointed at
[xrip/cmp50hx-unlock](https://github.com/xrip/cmp50hx-unlock) — a complete,
working PCIe Gen2 unlock for CMP 50HX (**TU102**, same NVIDIA open stack
610.43.03).

### The real mechanism (per xrip, TU102)

Advertisement registers (LnkCap/LnkCap2) are **not** the lever. The lever is
the link-policy register set that stock RM itself programs via
`pcie_apply_link_speed_policy` (IDA: TU102 `0x4CB25B8`):

| Register | Role | Gen2 target |
|----------|------|-------------|
| `0x880A8` | LnkCtl2 mirror / TLS | 2 (Gen2); alternates 3/4 |
| `0x8841C` | private misc Gen2 enable | — |
| `0x88610` | VSEC hierarchy | — |
| `0x8C2C0` | CYA, bit 2 must be clear | bit2=0 |
| `0x8C040` | link policy field [19:18] | 2 |
| `0x8C1C0` | link rate field | 0x40000 |
| `0x8872C` | LTSSM control kick | 6 |

Plus a host-side retrain (`LNKCTL2 TLS` on GPU + bridge, `LNKCTL RL`, poll
`LNKSTA`). Their GSP-side policy writer requires **XP3G PLM = 0xFFFFFFFF**
first; on TU102 that PLM is opened by an *added* synthetic-signature write
(`0x8E110/8E11C/8E12C/8E1B0`) — i.e., from the booter/falcon context.

## What was verified on GA102 (CMP 90HX, 220d/1555)

### Register map correction

`docs/XVE_CONFIG_MIRROR.md` had all labels shifted by one dword. Correct:
LnkCap=`0x88084` (=0x00453d01, MaxSpeed 2.5GT/s), LnkCtl/Sta=`0x88088`,
LnkCap2 area=`0x880a4`, LnkCtl2=`0x880a8`. Cross-checked against raw config
space and lspci decode.

### Host writes (FEAT PLM 0x823804 open via V67)

| Target | Result |
|--------|--------|
| LnkCap `0x88084` → Gen3 | rejected (readback unchanged) |
| LnkCap2 area `0x880a4` → vector 0x7 | rejected |
| LnkCtl2 `0x880a8` → TLS 3 | rejected |
| OPT_GEN23 `0x82057c` → 0 | rejected |
| LnkCtl `0x88088` toggle (control) | **STUCK** — write path itself is fine |
| CYA `0x8C2C0` bit2 clear | **STUCK** |
| Link policy `0x8C040`, rate `0x8C1C0` | rejected — gated by XP3G PLM |
| **XP3G PLM `0x8E1B0`** = 0xffffffff | rejected (reads 0xffffff8f) |

### Falcon (SEC2) writes via the rejoin15 signature-swap pipeline

Five instrumented builds (`GEN3ADV-V1…V5`; payload slots value@0xf948 /
addr@0xf960, single-write chain, terminator 0x81ee; parameterization proven by
the earlier SS0=5 test):

| Build | Chain target | Result |
|-------|--------------|--------|
| V1 | LnkCap=Gen3 @0x88084 | chain ran, but FLR wiped evidence + double-poison bug broke init |
| V2 | same + one-shot gate + pre-FLR readback | **READBACK 0x453d01 → REJECTED** (clean measurement) |
| V3-control | LnkCtlSta=+ASPM @0x88088 (known-writable control) | inconclusive run (GFW_BOOT hang on cold boots), later superseded |
| V5 | **XP3G PLM @0x8E1B0 = 0xffffffff** | **READBACK 0xffffff8f → REJECTED** (pre-FLR, chain confirmed executed via telemetry) |

Warm trigger technique (no cold-boot lottery): unload driver → clear
SS0/SS1 via raw mmap while FEAT PLM persists open → modprobe; the Replace
hook then sees empty selectors and takes the poison path. Never clear SS
registers with the driver loaded and GSP alive (RmInitAdapter 4/4 failure).

## Final verdict

On this GA102 CMP sample the entire xrip-style mechanism is unreachable:

```
feature domain 0x823xxx   : falcon-writable  ✓ (this is why compute unlock works)
advertisement LnkCap/Cap2 : RO for host AND falcon
link policy 0x8C040/1C0   : locked behind XP3G PLM
XP3G PLM 0x8E1B0          : locked for host AND falcon
OPT_GEN23                 : locked for host AND falcon
```

The XP3G lock and the 2.5GT/s-only speed vector are fuse-derived on this SKU
and enforced below every software privilege we can reach. On TU102-based
CMP 50HX the same signature mechanism opens XP3G — the difference is in the
die fuses, not in the method. Any further progress requires different
hardware (another 90HX sample: test `0x8E1B0` readback first) or physical
fuse work.

## Artifacts

- Batch register sweeper (single-ioctl EXEC_REG_OPS array): `research/xve_sweep.c`
- Official writability bitmap parse: `/root/xve_writable.txt`,
  header `dev_nv_pcfg_xve_regmap.h` (ga102, tag 610.43.03)
- Test scripts/logs: `/root/test-gen3adv-v*.sh`, `/root/gen3adv-v*-result.log`
- Build logs: `/root/build-gen3adv-v{1,2,5}.log`, `/root/build-final-restore.log`
