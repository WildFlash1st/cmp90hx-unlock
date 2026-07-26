# CMP 90HX Unlock — Research Status

> Started: 2026-07-26 | GPU: CMP 90HX (GA102, PCI ID `10de:220d`) | Kernel: 6.12.95

## Current State

**GPU works in safe-mode** — 10240 MiB GDDR6X, PCIe x16 Gen1, stable.
Exploit chain activates but PLM doesn't open — Falcon rejects payload.

```
nvidia-smi → NVIDIA CMP 90HX, 10240 MiB, 53°C, 79W/250W
dmesg | grep CMP90_DIRECT → SS0=0x16122002 (stock, PLM locked)
```

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
| `jonpry` (Zenodo) | Original paper "A Canary in the Crypto Mine" |
| `d3dx9/cmpunlocker` | Python implementation — Falcon emulator + ROP chain |
| `amoghmunikote/cmpunlocker` | Our fork — kernel module approach (610.x port) |

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

## Next Steps

1. **Wait for Jon Pry's response** — gadget addresses or emulator help
2. **Adapt d3dx9 emulator for 610.x** — parse flat `.fwimage`, find booter sections
3. **Try 580.x driver build** — port 580.x kernel-open to 6.12 (similar to 610.x port)

## Log Files

- `/home/it/cmpunlocker-master/logs/install_*.log`
