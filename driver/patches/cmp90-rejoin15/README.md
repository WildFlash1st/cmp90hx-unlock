# cmp90-rejoin15 — persistent compute unlock (610.43.03)

V67 compute-unlock, inlined into the driver init path (no systemd service, no
bootstrap module). Ported from pearlfortune/cmpunlocker v0.1.28 stockflow
patches (rejoin14 + rejoin15), validated 2026-08-16 on CMP 90HX
(10de:220d / subsystem 10de:1555) + NVIDIA open 610.43.03 + kernel 6.12.95:
check.sh 9/9 full speed, pp512 ~1770 t/s.

## Patches

| Patch | Purpose |
|---|---|
| `0014-…rejoin14-multigpu-state.patch` | rejoin14: per-GPU state isolation, early PLM handoff, official PCIe FLR after selector write, `nv_start_device` retry in `nv.c` |
| `0015-…rejoin15-serialized-start.patch` | rejoin15: serialize `nv_start_device` across GPUs (multi-GPU rigs) |

Mechanism: after `GFW_BOOT OK` in `kgspInitRm`, `pSignatureMemdesc` is swapped
for a 0xfa00 buffer carrying the V67 ROP chain (value@0xf948=0xffffffff,
reg@0xf960=0x00823804 FEAT_OVR_PLM, terminator 0x81ee@0xf9ec). The chain runs
during the RM booter load, opens PLM, then the driver writes
SS0=0x88888888 / SS1=0x00000008, restores the stock signature and triggers an
official FLR; `nv_start_device` retry completes init. "PLM open = success" is
the acceptance contract (booter returns non-OK after the chain hijacks it).

## Build/install

Use `sudo ./install.sh --profile=cmp90-rejoin15` (builds 610.43.03 + these
patches + kernel compat fixes from source, installs to
`/lib/modules/$(uname -r)/updates/cmpunlocker/`).

Requirements: NVIDIA open **610.43.03** installed (userspace + GSP firmware at
`/lib/firmware/nvidia/610.43.03/gsp_ga10x.bin`), kernel headers present,
Secure Boot off. Do **not** combine with the bendy2 bootstrap service
(`cmp90hx-persistent.service`) — the unlock is driver-internal.

## Rollback

`sudo ./remove.sh --yes` removes the patched modules; reboot to return to the
stock 610.43.03 driver.

## Notes

- PCIe: these patches contain **no** Gen2/Gen3 logic (only the FLR reset
  mechanism). On the CMP 90HX the link stays Gen1 x16 — the PHY advertises
  only 2.5GT/s (LnkCap2) and is fused; verified again on this stack.
- Rejoin variants 1-13 (probe0…rejoin13) are superseded by rejoin14/15; only
  the final two are vendored here.

## Credits / License

Patches derived from pearlfortune/cmpunlocker v0.1.28
(https://github.com/pearlfortune/cmpunlocker, MIT), stockflow package for
610.43.03. Their work builds on bendy2/cmp90hx V67 exploit and the GA100
research lineage. Distributed under the same MIT license as this project;
see top-level LICENSE and NOTICE.
