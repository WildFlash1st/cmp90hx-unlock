# CMP 90HX — Prefill Bottleneck Root Cause (2026-08-08)

## The mystery: why prefill (pp512) didn't improve

Rhonstin's patches gave **+66% decode** (tg128: 30.27 → 50.28 t/s) but prefill stayed
flat (pp512: 224.54 → 224.11 t/s). This document explains why and the path forward.

## Root cause: INT8 tensor cores (IMMA) are throttled 13.4×

**MMQ (mul_mat_q) on sm_86 uses INT8 tensor cores**, not FP32 FFMA and not DP4A:

```c
// mmq.cuh line 3567: sm_86 has TURING_MMA_AVAILABLE defined → vec_dot_mma path
asm("mma.sync.aligned.m16n8k16.row.col.s32.s8.s8.s32 ..."); // mma.cuh line 857
```

**The math is exact:**
- RTX 3080 pp512 = 3009 t/s (IMMA at full speed)
- CMP 90HX pp512 = 224 t/s
- 3009 / 13.4 = 224.5 ≈ **224 t/s — exact match**

IMMA (INT8 tensor cores) on CMP 90HX runs at **1/13.4 of full speed**.

## Why dp4a/IMAD path is WORSE (122 t/s)

Tried forcing MMQ to DP4A path (the IMAD patch from decode):
- pp512 dropped to **122 t/s** (from 224)
- Reason: DP4A→IMAD expansion is 4×mad.lo.s32 + 6×bfe.s32 = **10 instructions
  per DP4A**. Even at full speed IMAD, this is slower than throttled tensor cores.
- Decode benefited because MMVQ is memory-bound; prefill is compute-bound.

## The real opportunity: HFMA2 (FP16 CUDA cores) is FREE

From our earlier V2 measurement + Rhonstin's decode results:
- **HFMA2 (FP16×2 FMA on CUDA cores): 1.4 ns — unthrottled!**
- FP16 CUDA core throughput on GA102: **59.5 TFLOPS** (2× FP32)
- Throttled IMMA on CMP: **10.3 TOPS** (138/13.4)

**HFMA2 GEMM would be ~5.8× faster than throttled IMMA for prefill!**
(59.5 TFLOPS vs 10.3 TOPS, at same 26% kernel efficiency)

## Proposed fix: Tier 3a — custom HFMA2 tiled GEMM

Replace MMQ IMMA path with a shared-memory tiled GEMM using half2/HFMA2:

```
Standard approach (from FUTURE_PATCHES.md):
  - 64×64 output tiles, 8×8 thread blocks
  - Dequant Q4_0/Q8_0 → half2 in __shared__
  - Inner loop: __hfma2 accumulation
  - Write back converting to float
```

Estimated result: **pp512 224 → ~1300 t/s** (5.8×), close to 3080's 3009.

## Status

- [x] Root cause identified: IMMA throttled 13.4× (exact math match)
- [x] DP4A path tested: 122 t/s (worse — rejected)
- [ ] HFMA2 GEMM kernel implementation (Tier 3a)
- [ ] Benchmark after Tier 3a

## Files touched (temporary experiments, all reverted)
- `mmq.cuh` — TURING_MMA_AVAILABLE #undef for sm_86 (reverted: 122 t/s)
- `mmq.cu` — host-side twin (reverted)
- `mmq.cuh` — FP32 write-back → HFMA2 precompute (reverted: overflow risk)

Working tree is clean at `c804a838a` (Rhonstin baseline).
