#!/bin/bash
# Full RM control checks - run on CMP and RTX 3080
cd /home/it/cmpunlocker-research

echo "===== SM ISSUE RATE (critical!) ====="
./rm_cmd 20801230 00000000 00000000 00000000 00000000 00000000 00000000 00000000

echo ""
echo "===== SM ISSUE RATE V2 ====="
./rm_cmd 2080123c 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000

echo ""
echo "===== TPC PARTITION MODE ====="
./rm_cmd 2080122c 00000000 00000000 00000000 00000000

echo ""
echo "===== GPC TILE MAP ====="
./rm_cmd 2080120a 00000000 00000000 00000000 00000000

echo ""
echo "===== PHYS GPC MASK ====="
./rm_cmd 20801232 00000000 00000000 00000000

echo ""
echo "===== FP32 benchmark ====="
./fp32_tp 2>&1 | grep -E 'FP32|Efficiency'
