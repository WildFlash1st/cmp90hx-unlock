#!/usr/bin/env python3
"""Extract ucodes from GSP firmware (610.x / 595.x flat .fwimage format).

The GA10x GSP firmware is an ELF with a large .fwimage section containing
multiple ucodes in a flat binary format. This tool:

1. Parses the outer ELF to locate .fwimage
2. Scans for ucode headers (magic patterns)
3. Extracts each ucode as a separate binary for analysis

Usage:
    python extract_ucode.py firmware/gsp_ga10x.bin -o firmware/ucodes/
"""

import argparse
import struct
import sys
from pathlib import Path

try:
    from elftools.elf.elffile import ELFFile
except ImportError:
    print("ERROR: pyelftools not installed. Run: pip install pyelftools")
    sys.exit(1)

try:
    from rich.console import Console
    from rich.table import Table
    console = Console()
except ImportError:
    console = None
    Table = None


# Known ucode signatures in 610.x firmware
# Based on STATUS.md: ucode09 is FWSEC (the target for exploitation)
UCODE_MAGIC = {
    # Header patterns observed in GA10x firmware dumps
    0x00010001: "FWSEC_HEADER",
    0x00020001: "FWSEC_HEADER_V2",
    0x01000100: "FALCON_UCODE",
    0x00000001: "GENERIC_UCODE",
}


def find_elf_section(data: bytes, section_name: str) -> tuple[int, int] | None:
    """Find a section in ELF by name, return (offset, size)."""
    if len(data) < 64:
        return None

    # Parse ELF header
    e_ident = data[:16]
    if e_ident[:4] != b'\x7fELF':
        return None

    is_64bit = e_ident[4] == 2

    if is_64bit:
        e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
        e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
        e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
        e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]
    else:
        e_shoff = struct.unpack_from("<I", data, 0x20)[0]
        e_shentsize = struct.unpack_from("<H", data, 0x2E)[0]
        e_shnum = struct.unpack_from("<H", data, 0x30)[0]
        e_shstrndx = struct.unpack_from("<H", data, 0x32)[0]

    if e_shoff == 0 or e_shnum == 0:
        return None

    # Get section header string table
    if is_64bit:
        strtab_hdr = e_shoff + e_shstrndx * e_shentsize
        strtab_off = struct.unpack_from("<Q", data, strtab_hdr + 0x18)[0]
        strtab_sz = struct.unpack_from("<Q", data, strtab_hdr + 0x20)[0]
    else:
        strtab_hdr = e_shoff + e_shstrndx * e_shentsize
        strtab_off = struct.unpack_from("<I", data, strtab_hdr + 0x10)[0]
        strtab_sz = struct.unpack_from("<I", data, strtab_hdr + 0x14)[0]

    strtab = data[strtab_off:strtab_off + strtab_sz]

    # Search for section by name
    for i in range(e_shnum):
        hdr_off = e_shoff + i * e_shentsize
        name_idx = struct.unpack_from("<I", data, hdr_off)[0]

        # Get section name
        end = strtab.find(b'\x00', name_idx)
        name = strtab[name_idx:end].decode(errors='replace')

        if name == section_name:
            if is_64bit:
                sh_offset = struct.unpack_from("<Q", data, hdr_off + 0x18)[0]
                sh_size = struct.unpack_from("<Q", data, hdr_off + 0x20)[0]
            else:
                sh_offset = struct.unpack_from("<I", data, hdr_off + 0x10)[0]
                sh_size = struct.unpack_from("<I", data, hdr_off + 0x14)[0]
            return (sh_offset, sh_size)

    return None


def scan_for_ucodes(fwimage: bytes) -> list[dict]:
    """Scan .fwimage for potential ucode boundaries.

    Ucodes in flat binary format have structured headers. We look for:
    - 4-byte aligned boundaries
    - Magic values that indicate ucode headers
    - Size fields that point to valid offsets
    """
    ucodes = []
    offset = 0

    while offset < len(fwimage) - 32:
        # Read potential header words
        word0 = struct.unpack_from("<I", fwimage, offset)[0]
        word1 = struct.unpack_from("<I", fwimage, offset + 4)[0]
        word2 = struct.unpack_from("<I", fwimage, offset + 8)[0]
        word3 = struct.unpack_from("<I", fwimage, offset + 12)[0]

        # Heuristic: look for structured headers
        # FWSEC/ucode headers often have small values in first words
        # followed by size/offset fields

        # Pattern 1: Version/type followed by size
        if word0 < 0x100 and 0x1000 < word1 < 0x100000:
            # Potential ucode header
            ucodes.append({
                'offset': offset,
                'type': 'POTENTIAL_HEADER',
                'word0': word0,
                'word1': word1,
                'word2': word2,
                'word3': word3,
            })

        # Pattern 2: Known magic values
        if word0 in UCODE_MAGIC:
            ucodes.append({
                'offset': offset,
                'type': UCODE_MAGIC[word0],
                'magic': word0,
                'word1': word1,
            })

        offset += 4

    return ucodes


def extract_known_structure(fwimage: bytes) -> list[dict]:
    """Extract ucodes using known 610.x firmware structure.

    Based on driver analysis (kernel_gsp_falcon_ga102.c), the firmware
    contains multiple Falcon ucodes:

    - ucode08: SEC2 booter (loads other ucodes)
    - ucode09: FWSEC (firmware security, runs in HS mode)
    - ucode10: GSP-RM (main runtime)

    The structure appears to be:
    - Header table at the start of .fwimage
    - Each entry contains: offset, size, type, flags
    """
    ucodes = []

    # Try to parse as header table
    # First 4 words might be: magic, version, num_entries, reserved
    if len(fwimage) < 32:
        return ucodes

    header = struct.unpack_from("<8I", fwimage, 0)

    # Dump first 256 bytes for analysis
    print("\n=== First 256 bytes of .fwimage ===")
    for i in range(0, min(256, len(fwimage)), 16):
        hex_str = ' '.join(f'{b:02x}' for b in fwimage[i:i+16])
        ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in fwimage[i:i+16])
        print(f"{i:08x}: {hex_str}  {ascii_str}")

    # Look for RISC-V instruction patterns (entry points)
    # RISC-V instructions are 4-byte aligned, little-endian
    # Common patterns: JAL (0x6f), AUIPC (0x17), LUI (0x37)

    print("\n=== Scanning for RISC-V entry points ===")
    rv_entries = []
    for i in range(0, min(0x20000, len(fwimage)), 4):
        insn = struct.unpack_from("<I", fwimage, i)[0]
        opcode = insn & 0x7f

        # Look for function prologues: ADDI sp, sp, -N (common prologue)
        # Or: JAL x1, offset (function call)
        # Or: AUIPC (position-independent code)
        if opcode == 0x13:  # ADDI
            funct3 = (insn >> 12) & 0x7
            rd = (insn >> 7) & 0x1f
            rs1 = (insn >> 15) & 0x1f
            imm = (insn >> 20) & 0xfff
            if funct3 == 0 and rd == 2 and rs1 == 2:  # ADDI sp, sp, imm
                if (imm & 0x800):  # Negative immediate (stack allocation)
                    rv_entries.append({
                        'offset': i,
                        'type': 'FUNCTION_PROLOGUE',
                        'insn': insn,
                    })
                    if len(rv_entries) < 20:
                        print(f"  0x{i:08x}: ADDI sp, sp, -{0x1000 - imm}")

    return ucodes


def analyze_firmware(path: Path, output_dir: Path | None = None):
    """Main analysis function."""
    print(f"Analyzing: {path}")
    print(f"File size: {path.stat().st_size:,} bytes")

    with open(path, 'rb') as f:
        data = f.read()

    # Find .fwimage section
    result = find_elf_section(data, '.fwimage')
    if not result:
        print("ERROR: .fwimage section not found")
        return

    fwimage_off, fwimage_size = result
    print(f"\n.fwimage section:")
    print(f"  Offset: 0x{fwimage_off:x}")
    print(f"  Size:   0x{fwimage_size:x} ({fwimage_size:,} bytes)")

    fwimage = data[fwimage_off:fwimage_off + fwimage_size]

    # Also find signature sections
    print("\n=== Signature sections ===")
    for i in range(16):
        for suffix in ['ga102', 'ga10x', f'ga10x_{i}']:
            name = f'.fwsignature_{suffix}'
            result = find_elf_section(data, name)
            if result:
                sig_off, sig_size = result
                print(f"  {name}: offset=0x{sig_off:x}, size={sig_size} bytes")

    # Find .fwversion
    result = find_elf_section(data, '.fwversion')
    if result:
        ver_off, ver_size = result
        version = data[ver_off:ver_off + ver_size].decode(errors='replace').strip('\x00')
        print(f"\nFirmware version: {version}")

    # Extract and analyze
    print("\n=== Analyzing .fwimage structure ===")
    extract_known_structure(fwimage)

    # Save .fwimage for further analysis
    if output_dir:
        output_dir.mkdir(parents=True, exist_ok=True)
        fwimage_path = output_dir / "fwimage.bin"
        with open(fwimage_path, 'wb') as f:
            f.write(fwimage)
        print(f"\nSaved .fwimage to: {fwimage_path}")

        # Also extract signatures
        for name in ['.fwsignature_ga10x', '.fwsignature_ga102']:
            result = find_elf_section(data, name)
            if result:
                sig_off, sig_size = result
                sig_path = output_dir / f"{name[1:]}.bin"
                with open(sig_path, 'wb') as f:
                    f.write(data[sig_off:sig_off + sig_size])
                print(f"Saved {name} to: {sig_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Extract ucodes from GSP firmware"
    )
    parser.add_argument("firmware", type=Path,
                        help="Path to gsp_ga10x.bin or gsp_tu10x.bin")
    parser.add_argument("-o", "--output", type=Path, default=None,
                        help="Output directory for extracted ucodes")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Verbose output")

    args = parser.parse_args()

    if not args.firmware.exists():
        print(f"ERROR: File not found: {args.firmware}")
        sys.exit(1)

    analyze_firmware(args.firmware, args.output)


if __name__ == "__main__":
    main()
