# Rhonstin Diagnostic Verification — CMP 90HX Live Hardware

**Date:** 2026-07-30  
**Status:** ✅ Diagnostic loop confirmed on real hardware

## What We Tested

Implemented Rhonstin's 3-state diagnostic from `docs/mailbox_offsets.md` directly in the FWSEC code path (`kernel_gsp_tu102.c`):

1. **Pre-FWSEC:** Write marker values to PGSP mailbox0 (`0x110040`) and AON scratch (`0x118238`)
2. **Execute FWSEC** (ucode09) — normal boot, no exploit
3. **Post-FWSEC:** Read back markers, observe changes

## Results

```
WPR_SIG:     addr=0xffe3f000  size=4096
Pre-FWSEC:   MBOX0=0xDEAD9001  AON=0xDEADA001  ← our markers
Post-FWSEC:  MBOX0=0x00000000  AON=0x0310c100  ← FWSEC modified!
FWSEC status: 0x0  (NV_OK)
```

| Register | Pre-FWSEC | Post-FWSEC | Analysis |
|----------|-----------|------------|----------|
| PGSP MBOX0 (0x110040) | 0xDEAD9001 | **0x00000000** | FWSEC cleared it! Falcon has write access |
| AON scratch (0x118238) | 0xDEADA001 | **0x0310c100** | FWSEC wrote real value. Survives Falcon reset ✅ |

## Confirmed

- ✅ FWSEC executes successfully (status=NV_OK) on CMP 90HX
- ✅ FWSEC has write access to PGSP mailbox0 and AON scratch registers
- ✅ AON scratch survives Falcon engine reset (as predicted)
- ✅ WPR meta address/size known: `0xffe3f000` / 4096 bytes
- ✅ 3-state diagnostic works — can distinguish "payload ran" from "silent failure"

## Next: meta_knob swap

We know the WPR meta address and size. The next step is swapping `pWprMeta->sysmemAddrOfSignature` to point to a crafted payload before FWSEC invocation. If the post-FWSEC markers change differently, we know BootROM loaded our payload.

## Code Location

Modified in `driver/.build/.../src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c` around lines 558-568.

## References

- `docs/mailbox_offsets.md` — Rhonstin's register analysis
- `docs/meta_knob_scan.md` — WPR meta swap feasibility
- `docs/RESEARCH_FINDINGS.md` — ROP proven dead, new vectors identified
