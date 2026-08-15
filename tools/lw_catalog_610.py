#!/usr/bin/env python3
"""Catalog ALL load-word (LW/LWU) instructions in 610.x Falcon booter.

This script finds potential ROP gadgets for BAR0 register writes by cataloging
every load instruction that could be used to load controlled values.

RISC-V Load Instructions (opcode 0x03):
  funct3=000: LB   (load byte, sign-extend)
  funct3=001: LH   (load halfword, sign-extend)
  funct3=010: LW   (load word 32-bit) <-- PRIMARY TARGET
  funct3=011: LD   (load doubleword, RV64)
  funct3=100: LBU  (load byte, zero-extend)
  funct3=101: LHU  (load halfword, zero-extend)
  funct3=110: LWU  (load word, zero-extend, RV64) <-- SECONDARY TARGET

RISC-V Compressed Load Instructions (C extension):
  C.LW   (op=00, funct3=010): Load word from memory, rs1' in x8-x15, rd' in x8-x15
  C.LWSP (op=10, funct3=010): Load word from sp-relative address, rd can be any

Context: The 580.x chain used `LW x18, -384(x13)` to load a controlled value
from a stack-relative address. We need to find equivalent patterns in 610.x.

Priority targets:
  - Loads where rs1 is stack pointer (x2) or frame pointer (x8)
  - Loads where rd is argument register (x10-x17) or saved register (x8-x9)
  - Large negative offsets suggesting stack frame access
  - Loads followed by stores or CSR writes

Credits:
  - bendy2 (https://github.com/bendy2/cmp90hx) — original research

Usage:
    python lw_catalog_610.py [firmware_path] [--booter-size SIZE]
"""

import argparse
import struct
import sys
from pathlib import Path
from dataclasses import dataclass
from collections import defaultdict
from typing import Optional

# RISC-V ABI register names
REG_NAMES = {
    0: "zero", 1: "ra", 2: "sp", 3: "gp", 4: "tp",
    5: "t0", 6: "t1", 7: "t2",
    8: "s0/fp", 9: "s1",
    10: "a0", 11: "a1", 12: "a2", 13: "a3",
    14: "a4", 15: "a5", 16: "a6", 17: "a7",
    18: "s2", 19: "s3", 20: "s4", 21: "s5",
    22: "s6", 23: "s7", 24: "s8", 25: "s9",
    26: "s10", 27: "s11",
    28: "t3", 29: "t4", 30: "t5", 31: "t6",
}

# Load instruction funct3 values
LOAD_TYPES = {
    0b000: ("LB", 1, True),   # Load Byte, sign-extend
    0b001: ("LH", 2, True),   # Load Halfword, sign-extend
    0b010: ("LW", 4, True),   # Load Word (32-bit) - PRIMARY
    0b011: ("LD", 8, True),   # Load Doubleword (RV64)
    0b100: ("LBU", 1, False), # Load Byte Unsigned
    0b101: ("LHU", 2, False), # Load Halfword Unsigned
    0b110: ("LWU", 4, False), # Load Word Unsigned (RV64) - SECONDARY
}


def decode_compressed_load(insn: int) -> Optional[tuple]:
    """Decode a compressed load instruction.

    Returns (mnemonic, rd, rs1, imm, size, sign_ext, is_compressed) or None.

    C.LW:   010 uimm[5:3] rs1' uimm[2|6] rd' 00
    C.LWSP: 010 uimm[5] rd uimm[4:2|7:6] 10
    C.LD:   011 uimm[5:3] rs1' uimm[7:6] rd' 00  (RV64/RV128)
    C.LDSP: 011 uimm[5] rd uimm[4:3|8:6] 10  (RV64/RV128)
    """
    op = insn & 0x3
    funct3 = (insn >> 13) & 0x7

    if op == 0b00:  # C.LW, C.LD (from register-relative)
        if funct3 == 0b010:  # C.LW
            # rs1' is in bits [9:7], rd' is in bits [4:2]
            # Both use compressed register encoding (x8-x15)
            rs1_prime = (insn >> 7) & 0x7
            rd_prime = (insn >> 2) & 0x7
            rs1 = 8 + rs1_prime  # x8-x15
            rd = 8 + rd_prime    # x8-x15

            # Immediate: uimm[5:3] in bits [12:10], uimm[2|6] in bits [6:5]
            # Word-aligned, so multiply by 4
            uimm_5_3 = (insn >> 10) & 0x7  # bits 5:3
            uimm_2 = (insn >> 6) & 0x1     # bit 2
            uimm_6 = (insn >> 5) & 0x1     # bit 6
            imm = (uimm_5_3 << 3) | (uimm_6 << 6) | (uimm_2 << 2)

            return ("C.LW", rd, rs1, imm, 4, True, True)

        elif funct3 == 0b011:  # C.LD (RV64)
            rs1_prime = (insn >> 7) & 0x7
            rd_prime = (insn >> 2) & 0x7
            rs1 = 8 + rs1_prime
            rd = 8 + rd_prime

            # Immediate: uimm[5:3] in bits [12:10], uimm[7:6] in bits [6:5]
            uimm_5_3 = (insn >> 10) & 0x7
            uimm_7_6 = (insn >> 5) & 0x3
            imm = (uimm_5_3 << 3) | (uimm_7_6 << 6)

            return ("C.LD", rd, rs1, imm, 8, True, True)

    elif op == 0b10:  # C.LWSP, C.LDSP (stack-relative)
        rd = (insn >> 7) & 0x1f
        if rd == 0:  # Reserved for rd=0
            return None

        if funct3 == 0b010:  # C.LWSP
            # rs1 is implicitly sp (x2)
            rs1 = 2

            # Immediate: uimm[5] in bit 12, uimm[4:2] in bits [6:4], uimm[7:6] in bits [3:2]
            uimm_5 = (insn >> 12) & 0x1
            uimm_4_2 = (insn >> 4) & 0x7
            uimm_7_6 = (insn >> 2) & 0x3
            imm = (uimm_5 << 5) | (uimm_4_2 << 2) | (uimm_7_6 << 6)

            return ("C.LWSP", rd, rs1, imm, 4, True, True)

        elif funct3 == 0b011:  # C.LDSP (RV64)
            rs1 = 2

            # Immediate: uimm[5] in bit 12, uimm[4:3] in bits [6:5], uimm[8:6] in bits [4:2]
            uimm_5 = (insn >> 12) & 0x1
            uimm_4_3 = (insn >> 5) & 0x3
            uimm_8_6 = (insn >> 2) & 0x7
            imm = (uimm_5 << 5) | (uimm_4_3 << 3) | (uimm_8_6 << 6)

            return ("C.LDSP", rd, rs1, imm, 8, True, True)

    return None


@dataclass
class LoadInstruction:
    """Represents a parsed load instruction."""
    offset: int           # File offset
    raw: int              # Raw instruction word
    mnemonic: str         # LW, LWU, C.LW, C.LWSP, etc.
    rd: int               # Destination register
    rs1: int              # Source/base register
    imm: int              # Immediate offset (signed for 32-bit, unsigned for compressed)
    size: int             # Load size in bytes
    sign_extend: bool     # Whether result is sign-extended
    context_before: list  # Instructions before
    context_after: list   # Instructions after
    is_compressed: bool = False  # True for C.LW, C.LWSP, etc.

    @property
    def rd_name(self) -> str:
        return REG_NAMES.get(self.rd, f"x{self.rd}")

    @property
    def rs1_name(self) -> str:
        return REG_NAMES.get(self.rs1, f"x{self.rs1}")

    @property
    def is_stack_relative(self) -> bool:
        """Check if load uses stack or frame pointer."""
        return self.rs1 in (2, 8)  # sp or s0/fp

    @property
    def is_arg_relative(self) -> bool:
        """Check if load uses argument register as base."""
        return 10 <= self.rs1 <= 17  # a0-a7

    @property
    def loads_to_arg_reg(self) -> bool:
        """Check if loading into argument register."""
        return 10 <= self.rd <= 17  # a0-a7

    @property
    def loads_to_saved_reg(self) -> bool:
        """Check if loading into saved register."""
        return 8 <= self.rd <= 9 or 18 <= self.rd <= 27  # s0-s11

    @property
    def priority_score(self) -> int:
        """Score for ROP usefulness (higher = more interesting)."""
        score = 0

        # Loading from stack/frame pointer is very useful
        if self.is_stack_relative:
            score += 100

        # Loading from argument register (controllable input)
        if self.is_arg_relative:
            score += 80

        # Loading into argument register (can pass to functions)
        if self.loads_to_arg_reg:
            score += 50

        # Loading into saved register (persists across calls)
        if self.loads_to_saved_reg:
            score += 40

        # Large negative offset suggests stack frame access
        if self.imm < -128:
            score += 30
        elif self.imm < 0:
            score += 20

        # 32-bit loads are most useful for register writes
        if self.size == 4:
            score += 20

        return score

    def __str__(self) -> str:
        sign = "" if self.imm >= 0 else "-"
        abs_imm = abs(self.imm)
        return f"{self.mnemonic} x{self.rd}, {sign}{abs_imm}(x{self.rs1})"

    def format_detailed(self) -> str:
        """Format with register names and context."""
        sign = "" if self.imm >= 0 else "-"
        abs_imm = abs(self.imm)
        return f"{self.mnemonic} {self.rd_name}, {sign}{abs_imm}({self.rs1_name})"


def sign_extend_12(val: int) -> int:
    """Sign extend a 12-bit immediate to Python int."""
    if val & 0x800:
        return val - 0x1000
    return val


def decode_load_instruction(insn: int) -> Optional[tuple]:
    """Decode a load instruction. Returns (mnemonic, rd, rs1, imm, size, sign_ext) or None."""
    opcode = insn & 0x7f

    if opcode != 0x03:  # Not a load instruction
        return None

    funct3 = (insn >> 12) & 0x7
    rd = (insn >> 7) & 0x1f
    rs1 = (insn >> 15) & 0x1f
    imm = (insn >> 20) & 0xfff
    imm = sign_extend_12(imm)

    if funct3 not in LOAD_TYPES:
        return None

    mnemonic, size, sign_ext = LOAD_TYPES[funct3]
    return (mnemonic, rd, rs1, imm, size, sign_ext)


def disassemble_simple(insn: int) -> str:
    """Simple disassembly for context display."""
    if insn == 0:
        return "NOP (padding)"

    opcode = insn & 0x7f
    rd = (insn >> 7) & 0x1f
    funct3 = (insn >> 12) & 0x7
    rs1 = (insn >> 15) & 0x1f
    rs2 = (insn >> 20) & 0x1f

    # Check for compressed instructions (16-bit)
    if (insn & 0x3) != 0x3:
        return f"C.??? (compressed: {insn:04x})"

    # Common instruction patterns
    if opcode == 0x37:  # LUI
        imm = insn & 0xfffff000
        return f"LUI x{rd}, {imm:#x}"
    elif opcode == 0x17:  # AUIPC
        imm = insn & 0xfffff000
        return f"AUIPC x{rd}, {imm:#x}"
    elif opcode == 0x6f:  # JAL
        return f"JAL x{rd}, ..."
    elif opcode == 0x67:  # JALR
        imm = sign_extend_12((insn >> 20) & 0xfff)
        if rd == 0 and rs1 == 1 and imm == 0:
            return "RET"
        return f"JALR x{rd}, x{rs1}, {imm}"
    elif opcode == 0x63:  # BRANCH
        branch_names = ["BEQ", "BNE", "???", "???", "BLT", "BGE", "BLTU", "BGEU"]
        return f"{branch_names[funct3]} x{rs1}, x{rs2}, ..."
    elif opcode == 0x03:  # LOAD
        decoded = decode_load_instruction(insn)
        if decoded:
            mnemonic, rd, rs1, imm, _, _ = decoded
            return f"{mnemonic} x{rd}, {imm}(x{rs1})"
    elif opcode == 0x23:  # STORE
        imm = ((insn >> 25) << 5) | ((insn >> 7) & 0x1f)
        imm = sign_extend_12(imm)
        store_names = ["SB", "SH", "SW", "SD"]
        if funct3 < 4:
            return f"{store_names[funct3]} x{rs2}, {imm}(x{rs1})"
    elif opcode == 0x13:  # OP-IMM
        imm = sign_extend_12((insn >> 20) & 0xfff)
        op_names = ["ADDI", "SLLI", "SLTI", "SLTIU", "XORI", "SRLI/SRAI", "ORI", "ANDI"]
        return f"{op_names[funct3]} x{rd}, x{rs1}, {imm}"
    elif opcode == 0x33:  # OP
        op_names = ["ADD/SUB", "SLL", "SLT", "SLTU", "XOR", "SRL/SRA", "OR", "AND"]
        return f"{op_names[funct3]} x{rd}, x{rs1}, x{rs2}"
    elif opcode == 0x73:  # SYSTEM
        csr = (insn >> 20) & 0xfff
        if funct3 == 0:
            if insn == 0x00000073:
                return "ECALL"
            elif insn == 0x00100073:
                return "EBREAK"
            elif insn == 0x30200073:
                return "MRET"
            return f"SYSTEM {csr:#x}"
        csr_names = ["???", "CSRRW", "CSRRS", "CSRRC", "???", "CSRRWI", "CSRRSI", "CSRRCI"]
        return f"{csr_names[funct3]} x{rd}, CSR:{csr:#x}, x{rs1}"
    elif opcode == 0x3b:  # RV64 OP-32 or Falcon custom
        return "OP-32/Falcon"
    elif opcode == 0x0f:  # MISC-MEM (fence)
        return "FENCE"

    return f"??? opcode={opcode:#x}"


def find_all_loads(data: bytes, booter_size: int) -> list[LoadInstruction]:
    """Find all load instructions in the booter region."""
    loads = []

    # Limit to booter region
    region = data[:booter_size]

    # We need to handle mixed 16-bit and 32-bit instructions
    # RISC-V uses little-endian, and we can identify instruction size
    # by looking at the low 2 bits:
    #   00, 01, 10 -> 16-bit (compressed)
    #   11 -> 32-bit (or longer, but we ignore 48+ bit)

    offset = 0
    while offset < len(region) - 1:
        # Read 16 bits first
        half = struct.unpack_from("<H", region, offset)[0]

        # Check if this is a compressed instruction
        if (half & 0x3) != 0x3:
            # 16-bit compressed instruction
            decoded = decode_compressed_load(half)
            if decoded is not None:
                mnemonic, rd, rs1, imm, size, sign_ext, is_compressed = decoded

                # Get context
                context_before = get_context_before(region, offset, 4)
                context_after = get_context_after(region, offset + 2, 4)

                load = LoadInstruction(
                    offset=offset,
                    raw=half,
                    mnemonic=mnemonic,
                    rd=rd,
                    rs1=rs1,
                    imm=imm,
                    size=size,
                    sign_extend=sign_ext,
                    context_before=context_before,
                    context_after=context_after,
                    is_compressed=True,
                )
                loads.append(load)

            offset += 2
        else:
            # 32-bit instruction
            if offset + 4 > len(region):
                break

            insn = struct.unpack_from("<I", region, offset)[0]
            decoded = decode_load_instruction(insn)
            if decoded is not None:
                mnemonic, rd, rs1, imm, size, sign_ext = decoded

                context_before = get_context_before(region, offset, 4)
                context_after = get_context_after(region, offset + 4, 4)

                load = LoadInstruction(
                    offset=offset,
                    raw=insn,
                    mnemonic=mnemonic,
                    rd=rd,
                    rs1=rs1,
                    imm=imm,
                    size=size,
                    sign_extend=sign_ext,
                    context_before=context_before,
                    context_after=context_after,
                    is_compressed=False,
                )
                loads.append(load)

            offset += 4

    return loads


def get_context_before(region: bytes, offset: int, count: int) -> list:
    """Get instructions before the given offset."""
    context = []
    # This is approximate since we don't know instruction boundaries
    # We'll try to read 'count' 16-bit units backwards
    for i in range(count, 0, -1):
        ctx_off = offset - (i * 2)
        if ctx_off >= 0:
            # Try to read as 32-bit if aligned
            if ctx_off + 4 <= len(region):
                ctx_insn = struct.unpack_from("<I", region, ctx_off)[0]
            else:
                ctx_insn = struct.unpack_from("<H", region, ctx_off)[0]
            context.append((ctx_off, ctx_insn))
    return context


def get_context_after(region: bytes, offset: int, count: int) -> list:
    """Get instructions after the given offset."""
    context = []
    for i in range(count):
        ctx_off = offset + (i * 2)
        if ctx_off + 4 <= len(region):
            ctx_insn = struct.unpack_from("<I", region, ctx_off)[0]
            context.append((ctx_off, ctx_insn))
        elif ctx_off + 2 <= len(region):
            ctx_insn = struct.unpack_from("<H", region, ctx_off)[0]
            context.append((ctx_off, ctx_insn))
    return context


def check_followed_by_ret(load: LoadInstruction) -> bool:
    """Check if load is followed by a return instruction."""
    for off, insn in load.context_after:
        # JALR x0, x1, 0 = RET
        if insn == 0x00008067:
            return True
        # c.ret (compressed)
        if (insn & 0xffff) == 0x8082:
            return True
    return False


def check_followed_by_store(load: LoadInstruction) -> bool:
    """Check if load is followed by a store instruction."""
    for off, insn in load.context_after:
        opcode = insn & 0x7f
        if opcode == 0x23:  # STORE
            return True
    return False


def check_followed_by_csr(load: LoadInstruction) -> bool:
    """Check if load is followed by CSR instruction."""
    for off, insn in load.context_after:
        opcode = insn & 0x7f
        funct3 = (insn >> 12) & 0x7
        if opcode == 0x73 and funct3 != 0:  # CSR instruction
            return True
    return False


def format_context(context: list, label: str) -> str:
    """Format context instructions for display."""
    if not context:
        return ""

    lines = [f"  {label}:"]
    for off, insn in context:
        disasm = disassemble_simple(insn)
        lines.append(f"    0x{off:05x}: {insn:08x}  {disasm}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Catalog all load-word instructions in 610.x Falcon booter",
        epilog="Credits: bendy2 (https://github.com/bendy2/cmp90hx)"
    )
    parser.add_argument(
        "firmware",
        type=Path,
        nargs="?",
        default=Path("firmware/extracted/fwimage.bin"),
        help="Path to 610.x fwimage.bin"
    )
    parser.add_argument(
        "--booter-size",
        type=lambda x: int(x, 0),
        default=0x10000,
        help="Size of booter region (default: 0x10000 = 64KB)"
    )
    parser.add_argument(
        "--lw-only",
        action="store_true",
        help="Only show LW/LWU (32-bit) loads"
    )
    parser.add_argument(
        "--high-priority",
        action="store_true",
        help="Only show high-priority candidates (score >= 100)"
    )
    parser.add_argument(
        "--context",
        action="store_true",
        help="Show surrounding instruction context"
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Only show summary statistics"
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        help="Output file for results"
    )

    args = parser.parse_args()

    if not args.firmware.exists():
        print(f"ERROR: {args.firmware} not found")
        sys.exit(1)

    with open(args.firmware, 'rb') as f:
        data = f.read()

    print(f"Firmware: {args.firmware} ({len(data):,} bytes)")
    print(f"Booter region: 0x0 - 0x{args.booter_size:x} ({args.booter_size:,} bytes)")
    print()

    # Find all loads
    loads = find_all_loads(data, args.booter_size)

    # Filter if requested
    if args.lw_only:
        loads = [l for l in loads if l.mnemonic in ("LW", "LWU")]

    if args.high_priority:
        loads = [l for l in loads if l.priority_score >= 100]

    # Statistics
    stats = {
        "total": len(loads),
        "by_mnemonic": defaultdict(int),
        "by_rd": defaultdict(int),
        "by_rs1": defaultdict(int),
        "stack_relative": 0,
        "arg_relative": 0,
        "negative_offset": 0,
        "large_negative": 0,
        "followed_by_ret": 0,
        "followed_by_store": 0,
        "followed_by_csr": 0,
    }

    for load in loads:
        stats["by_mnemonic"][load.mnemonic] += 1
        stats["by_rd"][load.rd] += 1
        stats["by_rs1"][load.rs1] += 1

        if load.is_stack_relative:
            stats["stack_relative"] += 1
        if load.is_arg_relative:
            stats["arg_relative"] += 1
        if load.imm < 0:
            stats["negative_offset"] += 1
        if load.imm < -128:
            stats["large_negative"] += 1
        if check_followed_by_ret(load):
            stats["followed_by_ret"] += 1
        if check_followed_by_store(load):
            stats["followed_by_store"] += 1
        if check_followed_by_csr(load):
            stats["followed_by_csr"] += 1

    # Output
    output_lines = []

    def out(line=""):
        output_lines.append(line)
        if not args.output:
            print(line)

    out("=" * 70)
    out("LOAD INSTRUCTION CATALOG - 610.x Falcon Booter")
    out("=" * 70)
    out()

    # Summary statistics
    out("=== SUMMARY STATISTICS ===")
    out(f"Total load instructions found: {stats['total']}")
    out()

    out("By mnemonic:")
    for mnem in sorted(stats["by_mnemonic"].keys()):
        out(f"  {mnem}: {stats['by_mnemonic'][mnem]}")
    out()

    out("By destination register (rd):")
    for rd in sorted(stats["by_rd"].keys()):
        count = stats["by_rd"][rd]
        name = REG_NAMES.get(rd, f"x{rd}")
        out(f"  x{rd:2d} ({name:6s}): {count}")
    out()

    out("By source register (rs1):")
    for rs1 in sorted(stats["by_rs1"].keys()):
        count = stats["by_rs1"][rs1]
        name = REG_NAMES.get(rs1, f"x{rs1}")
        out(f"  x{rs1:2d} ({name:6s}): {count}")
    out()

    out("ROP-relevant patterns:")
    out(f"  Stack/frame pointer relative (sp/s0): {stats['stack_relative']}")
    out(f"  Argument register relative (a0-a7):  {stats['arg_relative']}")
    out(f"  Negative offset:                     {stats['negative_offset']}")
    out(f"  Large negative offset (<-128):       {stats['large_negative']}")
    out(f"  Followed by RET:                     {stats['followed_by_ret']}")
    out(f"  Followed by STORE:                   {stats['followed_by_store']}")
    out(f"  Followed by CSR write:               {stats['followed_by_csr']}")
    out()

    if args.summary:
        if args.output:
            with open(args.output, 'w') as f:
                f.write("\n".join(output_lines))
            print(f"Summary written to {args.output}")
        return

    # Detailed listing
    out("=" * 70)
    out("DETAILED LISTING (sorted by priority score)")
    out("=" * 70)
    out()

    # Sort by priority
    loads_sorted = sorted(loads, key=lambda l: -l.priority_score)

    for i, load in enumerate(loads_sorted):
        flags = []
        if load.is_stack_relative:
            flags.append("STACK")
        if load.is_arg_relative:
            flags.append("ARG-BASE")
        if load.loads_to_arg_reg:
            flags.append("ARG-DST")
        if load.loads_to_saved_reg:
            flags.append("SAVED-DST")
        if check_followed_by_ret(load):
            flags.append("->RET")
        if check_followed_by_store(load):
            flags.append("->STORE")
        if check_followed_by_csr(load):
            flags.append("->CSR")

        flag_str = " [" + ", ".join(flags) + "]" if flags else ""

        out(f"[{i+1:4d}] 0x{load.offset:05x}: {load.raw:08x}  {load.format_detailed()}")
        out(f"       Score: {load.priority_score:3d}{flag_str}")

        if args.context:
            if load.context_before:
                out(format_context(load.context_before, "Before"))
            if load.context_after:
                out(format_context(load.context_after, "After"))

        out()

    out("=" * 70)
    out("HIGH-PRIORITY CANDIDATES FOR ROP")
    out("(Stack-relative LW instructions, similar to 580.x 'LW x18, -384(x13)')")
    out("=" * 70)
    out()

    # Filter for high-priority ROP candidates
    high_priority = [l for l in loads if l.priority_score >= 100 and l.mnemonic in ("LW", "LWU")]
    high_priority.sort(key=lambda l: l.imm)  # Sort by offset

    if high_priority:
        out(f"Found {len(high_priority)} high-priority candidates:")
        out()

        for load in high_priority:
            out(f"  0x{load.offset:05x}: {load.format_detailed():<30s} (offset={load.imm:+5d})")

            # Show what happens after this load
            if check_followed_by_ret(load):
                out(f"           ^ Followed by RET - good gadget endpoint!")
            if check_followed_by_store(load):
                for off, insn in load.context_after:
                    if (insn & 0x7f) == 0x23:
                        out(f"           ^ Followed by STORE at 0x{off:05x}: {disassemble_simple(insn)}")
                        break
    else:
        out("  No high-priority candidates found.")
        out("  Consider relaxing criteria or checking for alternative patterns.")

    out()

    # Special section: Look for patterns similar to 580.x
    out("=" * 70)
    out("SEARCHING FOR 580.x-LIKE PATTERNS")
    out("Original pattern: LW x18, -384(x13)  ->  load from a3-relative with large offset")
    out("=" * 70)
    out()

    # The 580.x gadget loaded from x13 (a3) with offset -384
    # Look for similar patterns
    similar = [l for l in loads if l.rs1 == 13 and l.imm < 0 and l.mnemonic == "LW"]
    if similar:
        out(f"Loads from x13 (a3) with negative offset:")
        for load in similar:
            out(f"  0x{load.offset:05x}: {load.format_detailed()}")
    else:
        out("  No exact matches for x13-relative loads with negative offset.")

    out()

    # Look for any load from a0-a7 with large negative offset
    arg_loads = [l for l in loads if 10 <= l.rs1 <= 17 and l.imm < -128 and l.mnemonic == "LW"]
    if arg_loads:
        out(f"LW from argument registers (a0-a7) with large negative offset (<-128):")
        for load in arg_loads:
            out(f"  0x{load.offset:05x}: {load.format_detailed()}")
    else:
        out("  No LW from argument registers with large negative offset found.")

    out()

    # Stack-based loads that could be useful
    stack_lw = [l for l in loads if l.rs1 == 2 and l.mnemonic == "LW"]
    if stack_lw:
        out(f"LW from stack pointer (sp) - total {len(stack_lw)}:")
        # Group by offset
        by_offset = defaultdict(list)
        for load in stack_lw:
            by_offset[load.imm].append(load)

        for offset in sorted(by_offset.keys()):
            entries = by_offset[offset]
            addrs = ", ".join(f"0x{l.offset:05x}" for l in entries[:5])
            if len(entries) > 5:
                addrs += f" ... ({len(entries)} total)"
            out(f"  offset {offset:+5d}: {addrs}")

    out()

    if args.output:
        with open(args.output, 'w') as f:
            f.write("\n".join(output_lines))
        print(f"\nFull catalog written to {args.output}")


if __name__ == "__main__":
    main()
