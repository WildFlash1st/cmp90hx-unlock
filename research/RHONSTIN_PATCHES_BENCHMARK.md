# CMP 90HX — Rhonstin llama.cpp Patches Benchmark (2026-08-08)

## Setup
- **GPU**: NVIDIA CMP 90HX (GA102, sm_86, 9876 MiB)
- **Model**: gemma-4-12B-it-QAT-Q4_0.gguf (6.48 GiB, 11.91B params)
- **Command**: `llama-bench -m ... -t 8 -p 512 -n 128 -ngl 99 -r 3`
- **Build**: Rhonstin/llama-cpp-cmp90hx @ cmp90hx-optimizations (c804a838a)
- **CUDA**: 12.4, `-DCMAKE_CUDA_ARCHITECTURES=86`

## Results

| Config | pp512 (t/s) | tg128 (t/s) | tg vs 3080 |
|---|---|---|---|
| RTX 3080 (reference) | 3009.08 ± 133.01 | 77.94 ± 0.12 | 100% |
| CMP stock llama.cpp | 224.54 ± 0.87 | 30.27 ± 0.06 | 38.8% |
| **CMP + Rhonstin patches** | **224.11 ± 1.01** | **50.28 ± 0.24** | **64.5%** |

## Key Findings

1. **Decode (tg) +66%**: 30.27 → 50.28 tok/s
   - DP4A → PTX IMAD (4×mad.lo.s32) patch works perfectly
   - HFMA2 dequant patches for Q4_K/Q5_K/Q6_K/Q2_K add more
2. **Prefill (pp) unchanged** (224 t/s): cuBLAS SGEMM uses throttled FP32 FFMA
   - This is the remaining bottleneck (Tier 3a: custom HFMA2 tiled GEMM)
3. **Confirms eFuse analysis**: IMAD/IADD/HFMA2 are unthrottled (1.4 ns);
   DP4A (29×) and FFMA (14×) are throttled

## Usage
```bash
# Benchmark
./build/bin/llama-bench -m model.gguf -t 8 -p 512 -n 128 -ngl 99 -r 3

# Server (recommended: f16 KV, flash attention)
./build/bin/llama-server -m model.gguf -ngl 999 -fa 1 -ctk f16 -ctv f16

# TurboQuant KV is net-negative on CMP 90HX — always use f16 KV
```

## Remaining Optimization (FUTURE_PATCHES.md Tier 3a)
Custom HFMA2 tiled GEMM to replace cuBLAS SGEMM for prefill:
- 64×64 output tiles, 8×8 thread blocks
- __shared__ half2 A/B tiles
- __hfma2 accumulation
- Would recover ~12× on prefill (224 → 2500+ t/s)
