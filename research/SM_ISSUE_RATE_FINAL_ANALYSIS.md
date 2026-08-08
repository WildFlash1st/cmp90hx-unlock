# SM Issue Rate Modifier — Final Analysis (2026-08-08)

## Goal
Unlock CMP 90HX (GA102, 0x220D) FP32 compute to RTX 3080 levels.

## Definitive comparison data

| Field | CMP 90HX | RTX 3080 |
|-------|----------|----------|
| FMLA16 | **5 (1/32)** | 0 (FULL) |
| DP | 1 (1/2) | 0 (FULL) |
| FMLA32 | **5 (1/32)** | 1 (1/2) ← NORMAL |
| FFMA | **5 (1/32)** | 0 (FULL) |
| IMLA0-4 | **5 (1/32)** | 0 (FULL), IMLA4=1 (1/2) |
| **FP32** | **0.72 TFLOPS (3%)** | 29.24 TFLOPS (98%) |

FMLA32=1/2 and IMLA4=1/2 are NORMAL on healthy GA102. The FP32 benchmark
uses FFMA which is at FULL_SPEED on RTX 3080 and 1/32 on CMP 90HX.

## PROVEN: throttle is in hardware eFuse, NOT in VBIOS

1. **VBIOS CMP and RTX 3080 are IDENTICAL in issue-rate areas:**
   - CMP 0xd1b8 == RTX 0xd231 (64 bytes identical)
   - CMP 0x80b4b == RTX 0x7fa23 (64 bytes identical)
   - CMP 0x8e5be == RTX 0x8d24e (128 bytes identical)
   - Both contain the healthy pattern (00 00 00 01 00 00 00 00 01)
   - The CMP throttle pattern (05 05 01 05 05 05 05 05 05) is ABSENT from
     the CMP VBIOS entirely

2. **eFuse registers found (BAR0 offsets):**
   - 0x8207d4-0x8207ec: seven registers = 0x5 (1/32) ← throttle fuses
   - 0x8207d0 = 0x1 (DP=1/2)
   - 0x8204d8 = 0x220d (device ID fuse)
   - 0x82074c = 0x1 (NV_FUSE_OPT_SECURE_GSP_DEBUG_DIS — debug disabled)

3. **eFuse writes are silently ignored** via GPU_EXEC_REG_OPS
   (regStatus=0x0, value unchanged). mmap BAR0 blocked by driver.

4. **GSP-RM firmware is PKC-signed (RSA-3K)** — Booter loads it into WPR2
   with signature verification. Booter itself is loaded into SECURE IMEM
   and verified by BROM. Cannot be patched.

## Conclusion

**Software unlock of FP32 on CMP 90HX is impossible.** The SM issue rate
modifier values are burned into hardware eFuse at the factory. VBIOS
modification, RM register writes, and firmware patching are all blocked.

**What DOES work:** INT32 path is at 98% (5.67 TOPS). For AI workloads,
INT8/INT4 quantized models run at full speed — this is the standard
path for LLM inference (llama.cpp, vLLM).

## Tools

- `rm_smrate_v2.c` — definitive V2/V1 SM issue rate query (correct struct)
- `rm_reg.c` — GPU_EXEC_REG_OPS (0x20800122) register read/write as root
- `rm_batch2.c` — batch register scanner (64 per call)
- `bar0.c` — direct BAR0 mmap attempt (blocked by driver)
- `extract_booter.py` — decompress Booter ucode from driver bindata (gzip)
- `gsp_fwimage.bin` — extracted GSP-RM RISC-V code for disassembly

## Register map references

- FUSE block: BAR0 0x820000+
- SM issue rate fuses: 0x8207d0-0x8207ec (value 0x5 = 1/32 on CMP)
- Device ID fuse: 0x8204d8 (0x220d CMP / 0x2206 RTX 3080)
- GSP debug disable fuse: 0x82074c
- GR engine base: 0x400000 (GPC0), GPC stride 0x80000
- GSP Falcon: BAR0 0x110000+ (see gsp_registers.md memory)
