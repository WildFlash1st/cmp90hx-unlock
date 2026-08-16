# NVIDIA PSTRAPS Documentation (from envytools)

Source: https://envytools.readthedocs.io/en/latest/hw/io/pstraps.html
GitHub: https://github.com/envytools/envytools/blob/master/docs/hw/io/pstraps.rst

## Overview

Configuration straps are a set of resistors used to configure various functions of the 
card that need to be up before the card is POSTed. On the first few cycles after reset,
the memory bus pins are sampled. Since nothing else is driving them at that point, their
logic state is decided by pull-up or pull-down resistors placed by the board manufacturer.

## MMIO Locations

- **NV1**: `0x608000-0x608fff` in BAR0
- **NV3+**: `0x101000-0x101fff` in BAR0 (also known as PEXTDEV by nvidia)

## Strap Evolution by Generation

| Generation | Strap Bits |
|------------|------------|
| NV1        | 5 bits     |
| NV3        | 10 bits    |
| NV4        | 16 bits (with runtime override capability) |
| NV11       | 22 bits    |
| NV20       | 31 bits    |
| NV18+      | Dual sets of 31-bit values (primary/secondary with selection mask) |
| GF119+     | Three strap sets introduced |

## Register Layout (NV3+)

| Offset | Register           | Variants            |
|--------|--------------------|---------------------|
| 0x0    | STRAPS0_PRIMARY    | All                 |
| 0x4    | STRAPS0_SELECT     | NV18:NV20, NV25:GK104 |
| 0x8    | STRAPS0_SECONDARY  | NV18:NV20, NV25:GK104 |
| 0xc    | STRAPS1_PRIMARY    | NV18+               |
| 0x10   | STRAPS1_SELECT     | NV18:NV20, NV25:GK104 |
| 0x14   | STRAPS1_SECONDARY  | NV18:NV20, NV25:GK104 |
| 0x34   | STRAPS2_PRIMARY    | GF119+              |
| 0x38   | STRAPS2_SELECT     | GF119:GK104         |
| 0x3c   | STRAPS2_SECONDARY  | GF119:GK104         |

## Override Mechanism

Bit 31 of PRIMARY registers (NV4+): When set to 1, enables override mode allowing 
driver to modify straps at runtime. When cleared, restores original boot-time values.

SELECT registers control which bits source from PRIMARY (1) versus SECONDARY (0) values.

**Important**: Changing effective straps values takes effect immediately on the card.

## Strap Bit Definitions

### NV3 Family (Bits 0-9)

| Bit | Meaning |
|-----|---------|
| 0   | PCI 66MHz support |
| 1   | ROM presence (0=motherboard/ROMless, 1=card/has ROM) |
| 5   | Host bus (0=PCI, 1=AGP) |
| 6   | Crystal (0=13.5MHz, 1=14.31818MHz) |
| 7-8 | TV mode (0=none, 1=NTSC, 2=PAL) |

### NV4-NV40 (Bits 0-30)

| Bit(s) | Meaning |
|--------|---------|
| 1      | ROM presence indicator |
| 2-5    | RAM configuration |
| 6      | Crystal type bit 0 |
| 7-8    | TV mode |
| 9      | AGP x4 disable flag |
| 10     | AGP side band disable |
| 11     | AGP fast writes disable |
| 12-13  | Device ID bits 0-1 |
| 14     | Bus type (0=PCI, 1=AGP) |
| 15     | Panel width (0=12-bit, 1=24-bit) |
| 16-19  | Flat panel configuration |
| 20-21  | Device ID bits 2-3 (NV17:NV20, NV25+) |
| 23-24  | BAR1 size (64MB/128MB/256MB/512MB) |
| 29-30  | BIOS ROM type |

### G80+ (Set 0 - STRAPS0)

| Bit(s) | Meaning |
|--------|---------|
| 1      | ROM presence |
| 2-5    | RAM config |
| 6      | Crystal (0=27MHz, 1=25MHz) |
| 10-13  | Device ID bits 0-3 |
| 22-23  | BIOS ROM type (0=parallel, 1=serial/SPI) |
| 24-27  | Flat panel mode table index |

### G80+ (Set 1 - STRAPS1)

| Bit(s) | Meaning |
|--------|---------|
| 4      | PCI device class (0=3D controller, 1=VGA) |
| 16     | BAR5 enable |
| 17-19  | BAR0 size encoding |
| 20-22  | BAR1 size extension |

## Device ID Modification

The last few bits [0-6 depending on GPU] of PCI device id are changeable through straps.
This allows a single GPU silicon to present as different PCI devices based on strap
configuration, useful for product differentiation.

## Notes for Ampere (GA102) and Later

**WARNING**: The envytools documentation ends at the G80:GF100 era with incomplete 
coverage. It has a "Todo: finish file" note for GF100+ architectures. No official
documentation exists for Ampere (GA102) PSTRAPS bit definitions.

However, the general mechanism (memory bus pin sampling with pull-up/down resistors)
and register structure (STRAPS0/1/2 with PRIMARY/SELECT/SECONDARY organization)
likely remains consistent in modern architectures.

## PCIe-Specific Straps (Historical)

For older generations, PCIe/bus configuration straps included:
- Host bus type (PCI vs AGP vs PCIe)
- PCI 66MHz mode support
- AGP x4/sideband/fast-writes disable flags
- BAR size configuration

For modern GPUs like GA102, PCIe lane width configuration is likely controlled 
by different mechanisms (possibly through GPIO pins or dedicated configuration 
registers rather than traditional memory-bus straps).
