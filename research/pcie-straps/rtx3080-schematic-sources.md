# RTX 3080 PG132/PG133 Schematic Sources

## Board Designations

- **PG132**: Reference PCB design adopted by AIB partners
- **PG133**: Founders Edition exclusive PCB design

## Available Schematic Documents

### BadCaps Forum (requires premium membership)
URL: https://www.badcaps.net/forum/document-software-archive/schematics-and-boardviews/3474188-nvidia-geforce-rtx-3080-rtx-3090-schematic-board-view

**PG132 Documents:**
- `Gigabyte_GV-N3080AORUS_X-10GD_PG132-A02_Rev_1.0_.pdf` (1.61 MB)
- `Gigabyte_GV-N3080AORUSX_W-10GD_PG132-A02_Rev_1.0_.pdf` (1.91 MB)
- `600-1G132-0030-300_PG132-A02_Rev_C_.pdf` (RTX 3090)

**PG133 Documents (Founders Edition):**
- `3080 Founders Edition 600-1G133-0030-900_PG133-A03_Rev_A.pdf` (2.09 MB)
- `GeForce_RTX_3080_GA102_GF_PG133-A03_Rev_A_.pdf` (2.09 MB)

**Access**: Premium supporters get full download access

### RepairLap (requires registration)
URL: https://www.repairlap.com/threads/nvidia-geforce-rtx-3080-rev-c-pg132-b01-600-1g132-0010-400-schematic.12217/

**Document:**
- `NVIDIA GeForce RTX 3080 Rev C - PG132-B01 -600-1G132-0010-400.pdf` (2.2 MB)

**Access**: Requires registration/login

### Additional Sources
URL: https://www.repairlap.com/threads/geforce-rtx-3080-ga102-gf-pg133-a03-rev-a-schematics.11380/

**Document:**
- GeForce RTX 3080 GA102 reference schematic (GF_PG133-A03 Rev A) - 4.3 MB PDF

### Commercial Sources
- RealSchematic.com: Gigabyte GeForce RTX 3080 Eagle OC (79 pages + Boardview)
- Schematic-Expert.com: RTX 3080/Ti 3090/Ti schematics and boardviews

## Strap Resistor Information

Based on general NVIDIA schematic conventions:
- Strap resistors are typically located near the GPU package
- They connect to memory bus pins that are sampled after reset
- Pull-up (to VDD) or pull-down (to GND) determines strap bit value
- Values are typically 0-10K ohms range

## PCIe Configuration Notes

For GA102-based cards:
- PCIe 4.0 x16 interface standard
- Configuration resistors ("straps") determine various hardware settings
- Modern GPUs may use GPIO pins rather than traditional memory-bus straps for PCIe config
- No public documentation exists for GA102-specific strap bit definitions
