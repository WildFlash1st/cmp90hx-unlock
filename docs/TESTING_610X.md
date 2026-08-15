# CMP 90HX 610.x Testing Guide

> **WARNING: EXPERIMENTAL** - This patch has NOT been verified on hardware.
> GPU lockups and system instability are possible. Test at your own risk!

## Prerequisites

- CMP 90HX GPU (PCI ID: `10de:220d`)
- Linux with kernel 6.1+ (tested on 6.12)
- NVIDIA driver source 610.57.04
- Build tools: gcc, make, kernel headers

## Quick Start

```bash
# Clone repository
git clone https://github.com/your-repo/cmp90hx-unlock.git
cd cmp90hx-unlock

# Build patched driver
sudo ./build-cmp90-610.sh

# Install modules (creates backup automatically)
cd /tmp/cmp90-build/open-gpu-kernel-modules-610.57.04
sudo cp kernel-open/*.ko /lib/modules/$(uname -r)/updates/
sudo depmod -a

# COLD reboot required (not warm reboot!)
sudo shutdown -h now
# Power on manually
```

## What the Patch Does

The patch exploits a vulnerability in NVIDIA's Falcon microcontroller signature verification to:

1. **Open PLM (Privilege Level Masks)** - Unlocks access to restricted registers
2. **Write SM Speed selectors** - Enables full compute throughput
3. *(Optional)* **PCIe Gen3 unlock** - Restores full PCIe bandwidth

### ROP Chain Gadgets (610.x) — VERIFIED 2026-08-08

All instructions are **byte-identical** to 580.x, shifted by -0x1a (26 bytes).

| Address | Raw Value | Instruction | Purpose |
|---------|-----------|-------------|---------|
| 0x0d2a | 0xe806a903 | LW x18, -384(x13) | Entry point (load from sigbuf) |
| 0x0d36 | 0x4120093b | SUBW x18, x0, x18 | mpopaddret gadget |
| 0x0d38 | 0x4c814120 | (offset) | Offset from LOAD |
| 0x209c | 0xffffe797 | AUIPC | Address calculation |

### Target Registers

| Register | Address | Unlock Value | Purpose |
|----------|---------|--------------|---------|
| FEAT_OVR_PLM | 0x00823804 | 0xFFFFFFFF | Open all PLMs |
| SS0 | 0x0082381C | 0x88888888 | SM speed selector 0 |
| SS1 | 0x00823820 | 0x00000008 | SM speed selector 1 |

## Verification

After reboot, check these:

```bash
# Check driver loaded
lsmod | grep nvidia

# Check GPU visible
nvidia-smi

# Check dmesg for CMP90 messages
dmesg | grep -i cmp90

# Check PLM state (should be 0xffffffff if unlocked)
# Requires custom tool or driver debug output
```

### Expected Outcomes

**Success:**
```
CMP90_DEBUG: PLM opened = 0xffffffff
CMP90_DEBUG: SS0 = 0x88888888, SS1 = 0x00000008
nvidia-smi shows full compute capability
```

**Partial Success (PLM open, but registers not written):**
```
CMP90_DEBUG: PLM opened = 0xffffffff
CMP90_DEBUG: SS0 = 0x16122002, SS1 = 0x00000006  # Stock values
```

**Failure:**
```
NVRM: GPU at PCI:xxxx fallen off the bus
# Or
nvidia-smi: No devices were found
```

## Recovery from Failed Unlock

If GPU hangs or disappears:

```bash
# 1. Remove patched modules
sudo rm /lib/modules/$(uname -r)/updates/nvidia*.ko
sudo depmod -a

# 2. Install stock NVIDIA driver
# Either reinstall from .run file or package manager

# 3. COLD reboot (power off completely)
sudo shutdown -h now
```

## Debugging

Enable verbose debug output:

```bash
# Check kernel log
sudo dmesg -w | grep -E "(CMP90|nvidia|NVRM)"

# Monitor GPU state
watch -n 1 nvidia-smi

# Check BAR0 registers (requires root)
sudo setpci -s <GPU_BDF> COMMAND
```

## Known Issues

1. **DMEM addresses not verified** - Scratch space addresses (0x84c8, 0x8e18, etc.) 
   are kept from 580.x and may differ in 610.x firmware layout.

2. **PCIe unlock not implemented** - Requires additional ROP chain or different approach.

3. **Graphics remain disabled** - This unlock only restores compute; graphics (PGRAPH2)
   requires different approach (GSP-RM firmware modification).

## Files

| File | Purpose |
|------|---------|
| `build-cmp90-610.sh` | Build script for 610.57.04 |
| `driver/patches/cmp90/0007-*.patch` | Base CMP90 unlock patch |
| `driver/patches/cmp90/0009-*.patch` | 610.x gadget address updates |
| `tools/generate_610_payload.py` | Generate V67 payload for testing |
| `tools/gadget_mapper.py` | Address translation utility |

## Credits

- **bendy2** (https://github.com/bendy2/cmp90hx) - Original V67 exploit for 580.x
- **jonpry** - "A Canary in the Crypto Mine" research
- **d3dx9** - Python Falcon emulator
- Analysis tools generated with Claude Opus/Fable

## Related Documentation

- [STATUS.md](../STATUS.md) - Current research status
- [BENDY2_ANALYSIS.md](BENDY2_ANALYSIS.md) - Analysis of bendy2's solution
- [GADGET_ANALYSIS.md](GADGET_ANALYSIS.md) - 580.x vs 610.x gadget comparison
