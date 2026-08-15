# CMP 90HX Unlock — Research Status

> Started: 2026-07-26 | GPU: CMP 90HX (GA102, PCI ID `10de:220d`) | Kernel: 6.12.95

## Current State — ✅ COMPUTE UNLOCKED (2026-08-15)

**Compute unlock achieved via bendy2's V67 exploit on stock NVIDIA Open `580.159.03`.**
PLM opens (attempt 0), SS0=0x88888888 / SS1=0x00000008 written at every boot by
`cmp90hx-persistent.service` (bootstrap module → bus resets → stock driver handoff).

```
check.sh: PASS DP=full FFMA=full FMLA16=full FMLA32=full IMLA0..4=full   (9/9 fields)
dmesg   : CMP90HX: V67 attempt=0 status=0x65 PLM=0xffffffff
          CMP90HX: compute selectors enabled PLM=0xffffffff SS0=0x88888888 SS1=0x00000008
```

**Benchmark (gemma-4-12B-it-QAT-Q4_0, pp512):**
| Metric | Throttled (610.43.03) | Unlocked (580.159.03) |
|--------|----------------------|----------------------|
| pp512  | 224.10 t/s           | **1824.15 t/s (+713%)** |
| tg16   | —                    | 55.96 t/s |
| PPL    | 202.67               | 53.05 (local corpus) |

PCIe stays **Gen1 x16** — hardware link cap of the card (LnkCap2: 2.5GT/s only),
not a driver issue. Clocks normal: SM 2100 MHz, mem 9501 MHz.

**Stack:** stock 580.159.03 open modules built for kernel 6.12.95 (compat fixes in
`/home/it/build/nv-580/fix-580-kernel612.sh`) + bendy2/cmp90hx service (installed
from `/home/it/bendy2-cmp90hx`). Rollback: `/root/backup-nvidia-610.43.03-modules/`.

**History note:** the same exploit family failed on 610.x (PLM stays locked — Falcon
rejects the payload); the 610.57.04 port (PR #2) is unnecessary. The HFMA2 Tier 3a
software bypass (llama.cpp fork) is superseded.

---

## Prior Research Summary

## What Works

- [x] Kernel 6.12 port (13 iterations, all API incompatibilities fixed)
- [x] PCI ID `10de:220d` support added (`install.sh`, `constants.yaml`, patches)
- [x] DRM/modeset/peermem excluded (not needed for compute)
- [x] `nvidia.ko` + `nvidia-uvm.ko` build and load stably
- [x] Safe-mode: GPU boots stock, all registers readable

## What We Know

### GSP Falcon Registers (GA102)
From NVIDIA's own `dev_gsp.h`:

| Register | BAR0 Offset | Description |
|----------|-------------|-------------|
| MAILBOX0 | `0x110040` | Falcon internal mailbox 0 |
| MAILBOX1 | `0x110044` | Falcon internal mailbox 1 |
| ENGINE | `0x1103c0` | Falcon engine reset |
| HOST_MBOX(0) | `0x110804` | Host-to-Falcon mailbox |

### GSP Firmware Structure (610.x)
- Outer ELF: `gsp_ga10x.bin` (84 MB)
- Section `.fwimage` at offset `0x40` — flat RISC-V binary (no inner ELF)
- Section `.fwsignature_ga10x` at offset `0x505e06e` (4096 bytes)
- Section `.fwversion` at offset `0x5053064`
- 12 `.fwsignature_*` sections, each 4KB

### Signature Format
```
Header (20 bytes): 01 00 02 00 c8 08 00 00 0c 00 00 00 01 01 00 00 00 02 00 00
  sigSize = 0x08c8 = 2248 bytes (matches sec2/sig.bin)
  offset  = 0x0c = 12 (start of signature data)
```

### PLM State (stock)
```
FEAT:       0xffffff8f (locked, some bits open)
FBPA:       0xffffff0f (locked, more bits open)
WPR:        0x0004cb8f
WPR_CFG:    0x0004cb8f
PCIE_FUSE:  0x002aaaaa
```

### Unlock Target Values
```
SS0:        0x16122002 → 0x88888888
SS1:        0x00000006 → 0x00000008
PCIE_FUSE:  0x002aaaaa → 0x00000000
```

## What We Tried

| Approach | Result | Why Failed |
|----------|--------|------------|
| Kernel module PLM via Falcon (610.x) | `status=0xffff` | ROP shellcode offsets are GA100-specific |
| d3dx9 ROP via dm.bin (610.x) | `status=0xffff` | ROP gadgets point to 580.x booter code |
| d3dx9 ROP + 580.x firmware (610.x driver) | Driver crash | Firmware format incompatible with 610.x parser |
| Direct BAR0 writes from host | Writes ignored | PLM protection active |
| GPU reset + BAR0 writes | Writes ignored | Falcon re-locks PLM during init |

## Key Repositories

| Repo | Description |
|------|-------------|
| `bendy2/cmp90hx` | **The working V67 exploit** for stock 580.159.03 + persistent service (our current unlock stack) |
| `loss-and-quick` (PR #2) | 610.x port, gadget analysis, tools, English translations |
| `Rhonstin/llama-cpp-cmp90hx` | llama.cpp patches — CMP 90HX decode +66% |
| `jonpry` (Zenodo) | Original paper "A Canary in the Crypto Mine" |
| `d3dx9/cmpunlocker` | Python implementation — Falcon emulator + ROP chain |
| `amoghmunikote/cmpunlocker` | Upstream fork — kernel module approach (610.x port) |
| `WildFlash1st/cmp90hx-unlock` | This repository — full research history (GSP audit, 25 driver iterations, issue-rate characterization, kernel 6.12 port) |

## Credits

- **bendy2** — V67 exploit + direct-compute patch for 580.159.03 (`github.com/bendy2/cmp90hx`), the key that finally opened PLM
- **loss-and-quick** — 610.57.04 port, ROP gadget analysis, `lw_catalog_610.py` / `compare_op32.py` / `extract_ucode.py`, documentation and English translations (merged PR #2)
- **Rhonstin** — llama.cpp CMP 90HX patches (decode +66%) and prefill findings
- **jonpry** — "A Canary in the Crypto Mine" (original debug-booter overflow disclosure)
- **d3dx9** — Python Falcon emulator
- **WildFlash1st** — this project: GSP Falcon attack surface audit (v3–v28), SM issue-rate characterization (V2/V1 comparison), kernel 6.12.95 driver port, HFMA2 Tier 3a research, 580.159.03 kernel-compat fixes for 6.12.95

## Remaining Work / Roadmap

### 1. PCIe Gen3 unlock — CONCLUSIVE: Gen1 is HARDWARE-LOCKED (2026-08-15)
The card's PCIe link is **Gen1 x16** (`LnkCap2: 2.5GT/s only`, `LnkSta: 2.5GT/s x16`).
The root port (Xeon E3-1200 v3, 00:01.0) is Gen3 (8GT/s) capable — the bottleneck is
the card itself. Four independent tests prove the Gen1 cap cannot be changed by any
software/firmware path:

| Test | Result |
|------|--------|
| `PCIE_FUSE_OVR` (0x00823810)=0 with **PLM open** | rejected — readback stays 0x002aaaaa |
| `LINK_CONTROL` (0x0008c000)=3 with PLM open | rejected — readback stays 0x2 |
| **RTX 3080 VBIOS flashed** (Manli, device-ID swap works) | `LnkCap2` STILL 2.5GT/s; GSP hangs at memory training (BCT incompatible) |
| Capability registers in **compute-unlocked state** (PLM open, SS0/SS1 written) | `LnkCap/LnkCap2` STILL 2.5GT/s only |
| **FEAT_OVR block probe** (0x08/0x0C/0x18 = 0xFFFFFFFF, PLM open) | 0x0C = SS0 mirror (RO), 0x18 = 0, **0x08 writable** (0x00100282→0x03900bbb, function unknown) — LnkCap2 STILL 2.5GT/s |

Community data (Habr "Тёмные лошадки ИИ", CMP 90HX teardown): the ×4→×16 lane mod
(24 missing AC-coupling caps 0402) works on some CMP PCBs, **but the link stays
PCIe 1.1** even after the mod — Gen1 is baked deeper than the lanes. Device ID
(220D) is also strap-set (unchanged by the 3080 VBIOS). The `PCIE_CFG` strap on
GA102 PG132 is documented as LOW/HIGH POWER selection, not a link-gen selector.

**Conclusion:** PCIe Gen1 is a hardware (strap/fuse/PHY) characteristic of the CMP
90HX. The only remaining avenue is physical strap/PCB analysis (photos of the bare
PCB around the GA102 package + PCIe connector, compared against PG132 schematics),
with no community evidence that it yields Gen3. The unlock (pp512 224→1824 t/s) is
not PCIe-bound and remains fully effective at Gen1.


### 2. Memory upgrade: 10 GB → 20 GB VRAM (open question)
CMP 90HX ships 10 GB GDDR6X (320-bit bus, 8 Gbit modules). Proposal:
- **Hardware:** reball/replace the 10× 8 Gbit modules with **16 Gbit (2 GB) GDDR6X**
  modules → 20 GB on the same 320-bit bus (same chip count, no PCB change in theory)
- **Software:** unlock the 20 GB geometry in driver/VBIOS via FBPA/CFG1/LMR-style
  overrides (the same mechanism the CMP 170HX 8→64 GB path uses), plus training-table
  verification for the new density
- Open questions: 16 Gbit GDDR6X availability/board layout, thermal design, VBIOS
  training tables, memory controller support for the density (needs investigation)

### 3. Graphics (PGRAPH2) remain disabled
Compute is fully unlocked, but 3D/graphics stay gated (GSP-RM skips graphics init;
`FEAT_READOUT_0 bit8 = 0`). Separate problem — likely requires GSP-RM firmware work.

## Critical Missing Piece

**ROP gadget addresses for 610.x Falcon booter.** 

The d3dx9 emulator (`tools/booter_emu.py`) works on 580.x firmware but NOT on 610.x (different ELF format). The emulator is a pure-Python RV32I interpreter with Falcon CSR semantics.

For the exploit to work we need:
1. Adapt the emulator to parse 610.x `.fwimage` (flat binary format)
2. Run it to find BAR0-write gadget addresses in the 610.x booter
3. Build a ROP chain with those addresses
4. Place it in `dm.bin`

Or: get the gadget addresses from Jon Pry (`jonpry@gmail.com`).

## Build System

### Safe-mode (GPU works)
```bash
# Builds automatically in safe mode (exploit disabled)
cd /home/it/cmpunlocker-master && ./install.sh --profile=cmp90
```

### Exploit mode
```bash
# Create dmem.bin first, then build (dmem.bin presence disables safe-mode)
mkdir -p /lib/firmware/nvidia/ga102/gsp/
# Create 63KB ROP payload
python3 d3dx9/build_payload.py > /lib/firmware/nvidia/ga102/gsp/dmem.bin
./install.sh --profile=cmp90
```

### After ANY module change
```bash
# Cold reboot required (Falcon hangs otherwise)
shutdown -h now   # then power on manually
```

## Quick Recovery

After a failed exploit attempt (GPU shows `No devices were found`):
```bash
rm -f /lib/firmware/nvidia/ga102/gsp/dmem.bin
cd /home/it/cmpunlocker-master && ./install.sh --profile=cmp90
# COLD REBOOT
```

## File Locations

| File | Purpose |
|------|---------|
| `/home/it/cmpunlocker-master/` | Main project |
| `/home/it/cmpunlocker-master/driver/build.sh` | Build script with all 6.12 fixes |
| `/home/it/cmpunlocker-master/driver/patches/cmp90/0007-*.patch` | CMP90 kernel patch |
| `/home/it/GA102.rom` | GPU VBIOS dump (976 KB) |
| `/home/it/rtx3000/` | Memory channel disabler + BIOSes |
| `/lib/firmware/nvidia/610.43.03/gsp_ga10x.bin` | Active GSP firmware |
| `/lib/firmware/nvidia/ga102/gsp/dmem.bin` | ROP payload (when present) |
| `/lib/modules/*/updates/cmpunlocker/` | Installed patched modules |
| `/tmp/d3dx9-cmpunlocker/` | d3dx9 Python exploit tool |
| `/tmp/nvidia-580.run` | 580.105.08 driver installer |
| `/tmp/nv580_extract/` | Extracted 580.x driver |

## VBIOS Cross-Flash Experiment

See [docs/VBIOS_EXPERIMENT.md](docs/VBIOS_EXPERIMENT.md) — RTX 3080 VBIOS flashed, Device ID substitution works, GSP hangs at memory training.

## Rhonstin's Critical Findings (2026-07-29)

Forked at [Rhonstin/cmp90hx-unlock](https://github.com/Rhonstin/cmp90hx-unlock). Key results:

- ❌ ROP via BooterLoad/ucode09/GSP: all DEAD (0 indirect calls, no copy loops, PLM hardcoded)
- ✅ NEW VECTOR: meta_knob — driver hooks for WPR meta swap before FWSEC
- ✅ NEW VECTOR: other ucodes (not 0x09) — may have indirect calls
- ✅ Correct mailbox: PGSP (0x110040)

## Next Steps

1. Analyze other Falcon ucodes for exploitable characteristics
2. Collaborate with Rhonstin — merge tools + hardware test capability
3. Frankenstein VBIOS — transplant CMP memory timings into RTX 3080 VBIOS

## Log Files

- `/home/it/cmpunlocker-master/logs/install_*.log`

**PCIe Gen2 breakthrough direction (2026-08-15 evening):** the CMP 170HX (GA100)
recipe (abobasixseven/unlock-cmp-170hx) shows Gen2 IS reachable via a combined
PLM+override sequence, NOT straps/VBIOS. Fingerprint on GA102 confirmed the SAME
register addresses work (XVE base 0x88000 matches): OPT_GEN23=0x1 (Gen2/3 disable
set), CYA_0 bit2=1 (DIS_G2), LINK_CONFIG_0 MAX_RATE=Gen1, all PLMs closed.
Driver writes (GPU_REG_WR32 with PLM open): CYA_0 bit2 cleared ✓, PRIV_MISC_1
bits 11,13 set ✓, but OPT_GEN23/LINK_CTRL_2/VSEC rejected — they need the SEC2
Booter CSB write path (extend the V67 ROP payload in the signature area, like
the GA100 recipe's combined 22-register sequence).

**Gen2 booter-path test (2026-08-15 late):** parameterized the V67 payload
(value/regaddr fields) and ran a second kgspExecuteBooterLoad writing
OPT_GEN23=0 via the SEC2 booter (CSB path). Result: booter executed
(status=0x65) but OPT_GEN23 stayed 0x1 — matches the GA100 doc's
"OPT_GEN23/VSEC permanently locked at SEC2 level" symptom (other registers
CYA0/PRIV_MISC_1 write fine). Ambiguity: payload parameterization may have
broken the ROP chain — distinguishing test = write a known-writable register
(SS0) via the same booter path. If SS0 changes, OPT_GEN23 is SEC2-locked and
Gen2 is impossible in software (like the affected CMP 170HX revisions).
