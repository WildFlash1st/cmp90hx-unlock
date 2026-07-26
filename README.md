# cmpunlocker — CMP 90HX Unlock Research

[![Status](https://img.shields.io/badge/status-research%20in%20progress-orange)](STATUS.md)
[![Kernel](https://img.shields.io/badge/kernel-6.12.95-blue)](https://kernel.org)
[![GPU](https://img.shields.io/badge/GPU-CMP%2090HX%20(GA102)-76B900)](https://www.nvidia.com)

Unlock tool for the NVIDIA CMP 90HX (GA102, PCI ID `10de:220d`). Aims to restore full SM compute throughput and unlock PCIe Gen3 that are restricted in firmware/OTP configuration.

> **We need help!** The hardware unlock infrastructure is ready (kernel modules build and load on 6.12), but **ROP gadget addresses for the 610.x Falcon booter** are unknown. If you have RISC-V reverse engineering, Falcon emulation, or NVIDIA GPU security experience — please help! See [STATUS.md](STATUS.md) for full technical details.

---

## Background

The CMP 90HX is a physically complete GA102 die (same silicon as RTX 3080) with compute and PCIe speed artificially limited. This project ports the [original cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) (designed for CMP 170HX/GA100) to the CMP 90HX.

### What Works

| Feature | Status |
|---------|--------|
| Kernel 6.12.95 port | ✅ Complete |
| PCI ID `10de:220d` support | ✅ Complete |
| `nvidia.ko` + `nvidia-uvm.ko` build & load | ✅ Stable |
| GPU initialization (safe-mode) | ✅ 10240 MiB, 53°C |
| CMP 90HX exploit chain | ⚠️ Activates, but PLM fails |
| Full SM compute unlock | ❌ Needs ROP gadgets |
| PCIe Gen3 unlock | ❌ Needs ROP gadgets |

### The Problem

The exploit uses a **ROP chain** executed on the Falcon RISC-V coprocessor. The chain uses `mpopaddret` (HS-mode instruction `0x3b`) and **gadget addresses** — specific locations in the booter code that perform BAR0 writes. These addresses are known for the 580.x firmware (GA100, TU10x GSP), but the 610.x firmware (GA10x GSP) uses a **completely different flat binary format** with different gadget locations.

A working [Python Falcon emulator](https://github.com/d3dx9/cmpunlocker) exists for the 580.x firmware but needs adaptation for the 610.x flat binary format.

### What We Know

- **12 GSP Falcon registers** identified from NVIDIA's own `dev_gsp.h` (MAILBOX0 at BAR0+0x110040, etc.)
- **Signature format** reverse-engineered: 20-byte header + 2248-byte signature
- **PLM values** mapped: FEAT=0xffffff8f, FBPA=0xffffff0f, PCIE_FUSE=0x002aaaaa
- **Target registers**: SS0→0x88888888, SS1→0x00000008, PCIE_FUSE→0x00000000
- **Hardware**: CMP 90HX on test bench with PCIe x16 mod (soldered components)

---

## Requirements

- Linux (x86-64) with root access
- NVIDIA CMP 90HX (GA102, PCI ID `10de:220d`) — *also supports `10de:20b0`*
- **nvidia-open 610.43.0x firmware** already installed
- Kernel headers matching running kernel
- Secure Boot disabled
- Kernel 6.1+ (tested on 6.12.95)

---

## Install (Safe Mode)

GPU boots stock — stable for testing, but no unlock:

```bash
cd cmpunlocker
sudo ./install.sh --profile=cmp90
# COLD REBOOT required
```

### Verify

```bash
nvidia-smi
# Expected: CMP 90HX, 10240 MiB, working normally
```

### Uninstall

```bash
sudo ./remove.sh --yes
```

---

## Development

### Exploit Mode

Requires a valid `dmem.bin` (63KB ROP payload) at `/lib/firmware/nvidia/ga102/gsp/dmem.bin`. When present, safe-mode is automatically disabled.

```bash
mkdir -p /lib/firmware/nvidia/ga102/gsp/
# Place valid dmem.bin here
sudo ./install.sh --profile=cmp90
```

### Key Files

| File | Purpose |
|------|---------|
| `driver/build.sh` | Build script with all 6.12 kernel fixes |
| `driver/patches/cmp90/0007-*.patch` | CMP90 compute unlock kernel patch |
| `common/constants.yaml` | Register values, PLM table |
| `STATUS.md` | Full technical status & research notes |

---

## How You Can Help

We need:

1. **Falcon emulator adaptation** — port `d3dx9/cmpunlocker/tools/booter_emu.py` for 610.x flat `.fwimage` format
2. **ROP gadget discovery** — find BAR0-write gadgets in the 610.x Falcon booter
3. **RISC-V reverse engineering** — disassemble SEC2 booter to understand instruction set

If you have experience with any of these, please open an issue or PR!

---

## Credits

- **Jon Pry** ([@jonpry](https://zenodo.org/records/20916112)) — Original discoverer of the Falcon vulnerability
- **d3dx9** ([d3dx9/cmpunlocker](https://github.com/d3dx9/cmpunlocker)) — Python Falcon emulator & ROP chain
- **amoghmunikote** — Original cmpunlocker for CMP 170HX (GA100)

---

## License

[Same as original cmpunlocker](LICENSE)
