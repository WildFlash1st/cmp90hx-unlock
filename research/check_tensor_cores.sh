#!/bin/bash
# CMP 90HX Tensor Core Status Verification
# Usage: ./check_tensor_cores.sh

echo "=== CMP 90HX Tensor Core Status Check ==="
echo ""

# 1. Check GPU info
echo "1. GPU Information:"
nvidia-smi --query-gpu=name,compute_cap,memory.total,clocks.max.sm --format=csv,noheader 2>/dev/null || echo "   nvidia-smi not available"
echo ""

# 2. Check SS0/SS1 values (requires rm_reg tool or dmesg)
echo "2. SS0/SS1 Register Status (from dmesg):"
if dmesg 2>/dev/null | grep -q "ss0_after\|ss1_after\|SS0.*SS1"; then
    dmesg 2>/dev/null | grep -E "ss0_after|ss1_after|SS0.*SS1" | tail -3
    echo ""

    # Parse values
    SS0=$(dmesg 2>/dev/null | grep -oP 'ss0_after=0x\K[0-9a-fA-F]+' | tail -1)
    SS1=$(dmesg 2>/dev/null | grep -oP 'ss1_after=0x\K[0-9a-fA-F]+' | tail -1)

    if [ "$SS0" = "88888888" ] && [ "$SS1" = "00000008" ]; then
        echo "   [PASS] Compute unlock ACTIVE - Tensor Cores should be enabled"
    else
        echo "   [WARN] SS0=$SS0 SS1=$SS1 - Check if unlock is active"
    fi
else
    echo "   No SS0/SS1 messages in dmesg (may need root or different driver)"
fi
echo ""

# 3. Check SM issue rate fields
echo "3. SM Issue Rate Fields (from check.sh or dmesg):"
if dmesg 2>/dev/null | grep -q "IMLA\|FMLA\|FFMA\|DP="; then
    dmesg 2>/dev/null | grep -E "IMLA|FMLA|FFMA|DP=" | tail -3
else
    # Try to find check.sh output
    if [ -f "check.sh" ]; then
        ./check.sh 2>/dev/null | head -5
    else
        echo "   Run: sudo dmesg | grep -E 'IMLA|FMLA|FFMA'"
    fi
fi
echo ""

# 4. Quick performance test (if llama-bench available)
echo "4. Quick Performance Test:"
if command -v llama-bench &> /dev/null; then
    echo "   llama-bench found. Run manually:"
    echo "   llama-bench -m <model.gguf> -p 512 -n 0 -ngl 99"
    echo ""
    echo "   Expected pp512 throughput:"
    echo "   - Throttled (stock CMP): ~200-300 t/s on 12B Q4"
    echo "   - Unlocked:              ~1500-2000 t/s on 12B Q4"
else
    echo "   llama-bench not in PATH"
fi
echo ""

# 5. Check for tensor_core_bench
echo "5. Tensor Core Microbenchmark:"
if [ -f "tensor_core_bench" ]; then
    echo "   Running tensor_core_bench..."
    ./tensor_core_bench 2>&1 | head -30
elif [ -f "tensor_core_bench.cu" ]; then
    echo "   Source found: tensor_core_bench.cu"
    echo "   Compile: nvcc -arch=sm_86 -O3 tensor_core_bench.cu -o tensor_core_bench"
else
    echo "   Not found. Create with nvcc from tensor_core_bench.cu"
fi
echo ""

# 6. Summary
echo "=== Summary ==="
echo "If Tensor Cores are ENABLED:"
echo "  - SS0 = 0x88888888, SS1 = 0x00000008"
echo "  - All issue-rate fields = full"
echo "  - pp512 > 1500 t/s on 12B Q4 model"
echo "  - IMMA benchmark > 50 TOPS"
echo ""
echo "If Tensor Cores are THROTTLED:"
echo "  - SS0/SS1 at stock values (0x16122002/0x00000006)"
echo "  - Issue-rate fields show 1/32"
echo "  - pp512 ~ 200-300 t/s on 12B Q4 model"
echo "  - IMMA benchmark < 10 TOPS"
