#!/usr/bin/env python3
"""Compare CMP 90HX vs RTX 3080 RPC command sets."""
import re
import sys
from collections import Counter

def parse(path):
    cmds = []
    with open(path) as f:
        for line in f:
            m = re.search(r'func=0x([0-9a-f]+) len=(\d+) p0=0x([0-9a-f]+) p1=0x([0-9a-f]+) p2=0x([0-9a-f]+)', line)
            if m:
                cmds.append((int(m.group(5),16), int(m.group(2))))  # (cmd_id, len)
    return cmds

# Known command names
CMD_NAMES = {
    0x20801803: "BUS_GET_PCI_BAR_INFO",
    0x20801804: "BUS_SET_PCIE_LINK_WIDTH",
    0x20801805: "BUS_SET_PCIE_SPEED",
    0x2080200a: "PERF_BOOST",
    0x2080205b: "PERF_SET_POWERSTATE",
    0x2080206e: "PERF_RATED_TDP_GET_CONTROL",
    0x2080206f: "PERF_RATED_TDP_SET_CONTROL",
    0x20802068: "PERF_GET_CURRENT_PSTATE",
    0x2080120a: "GR_SET_GPC_TILE_MAP",
    0x2080122c: "GR_SET_TPC_PARTITION_MODE",
    0x20800a36: "CTRL_0A36",
    0x20800a41: "CTRL_0A41",
    0x208001b0: "CTRL_01B0",
    0x20800a87: "CTRL_0A87",
    0x20800a40: "CTRL_0A40",
    0x20801112: "CTRL_1112",
    0x20800a5c: "CTRL_0A5C",
    0x20800a1c: "CTRL_0A1C",
    0x20800a4b: "CTRL_0A4B",
    0x20800a55: "CTRL_0A55",
    0x20800af3: "CTRL_0AF3",
    0x20800aac: "CTRL_0AAC",
    0x20800a61: "CTRL_0A61",
}

def main():
    cmp_path = sys.argv[1] if len(sys.argv) > 1 else '/home/it/cmpunlocker-research/cmp_rpc_cmds.txt'
    rtx_path = sys.argv[2] if len(sys.argv) > 2 else '/home/it/cmpunlocker-research/rtx_rpc_cmds.txt'

    cmp_cmds = parse(cmp_path)
    rtx_cmds = parse(rtx_path)

    cmp_cnt = Counter(cmp_cmds)
    rtx_cnt = Counter(rtx_cmds)

    print("=== ТОЛЬКО В RTX 3080 (нет в CMP) ===")
    for (cmd, ln), c in sorted((rtx_cnt - cmp_cnt).items()):
        name = CMD_NAMES.get(cmd, f"0x{cmd:X}")
        print(f"  {name:30s} (0x{cmd:X}) len={ln}: {c}x")

    print("\n=== ТОЛЬКО В CMP (нет в RTX) ===")
    for (cmd, ln), c in sorted((cmp_cnt - rtx_cnt).items()):
        name = CMD_NAMES.get(cmd, f"0x{cmd:X}")
        print(f"  {name:30s} (0x{cmd:X}) len={ln}: {c}x")

    print(f"\nRTX: {len(rtx_cmds)} команд, CMP: {len(cmp_cmds)} команд")

if __name__ == '__main__':
    main()
