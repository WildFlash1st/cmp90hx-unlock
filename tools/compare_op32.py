#!/usr/bin/env python3
"""Compare OP-32 (0x3b) instructions between firmware versions."""

import struct
import sys

def find_op32(fw):
    results = []
    for i in range(0, len(fw) - 4, 4):
        v = struct.unpack_from('<I', fw, i)[0]
        if (v & 0x7f) == 0x3b:
            funct3 = (v >> 12) & 0x7
            funct7 = (v >> 25) & 0x7f
            rd = (v >> 7) & 0x1f
            rs1 = (v >> 15) & 0x1f
            rs2 = (v >> 20) & 0x1f
            results.append({
                'offset': i,
                'value': v,
                'funct3': funct3,
                'funct7': funct7,
                'rd': rd, 'rs1': rs1, 'rs2': rs2
            })
    return results

def main():
    with open('firmware/extracted_580/fwimage.bin', 'rb') as f:
        fw580 = f.read(0x10000)
    with open('firmware/extracted/fwimage.bin', 'rb') as f:
        fw610 = f.read(0x10000)

    print('=== Comparing OP-32 (0x3b) instructions ===')
    print()

    op32_580 = find_op32(fw580)
    op32_610 = find_op32(fw610)

    print('580.x: {} OP-32 instructions'.format(len(op32_580)))
    for r in op32_580:
        print('  0x{:04x}: 0x{:08x}  f7={:02x} f3={} rd={:02d} rs1={:02d} rs2={:02d}'.format(
            r['offset'], r['value'], r['funct7'], r['funct3'], r['rd'], r['rs1'], r['rs2']))

    print()
    print('610.x: {} OP-32 instructions'.format(len(op32_610)))
    for r in op32_610:
        print('  0x{:04x}: 0x{:08x}  f7={:02x} f3={} rd={:02d} rs1={:02d} rs2={:02d}'.format(
            r['offset'], r['value'], r['funct7'], r['funct3'], r['rd'], r['rs1'], r['rs2']))

if __name__ == '__main__':
    main()
