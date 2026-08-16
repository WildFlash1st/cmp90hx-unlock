# cmpunlocker — CMP 90HX Compute Unlock

[![Status](https://img.shields.io/badge/status-compute%20UNLOCKED-brightgreen)](STATUS.md)
[![Kernel](https://img.shields.io/badge/kernel-6.12.95-blue)](https://kernel.org)
[![GPU](https://img.shields.io/badge/GPU-CMP%2090HX%20(GA102)-76B900)](https://www.nvidia.com)

**Full SM compute throughput restored on the NVIDIA CMP 90HX (GA102, PCI ID `10de:220d`, 10 GB GDDR6X).**
Prefill speed went from **224 t/s → 1770 t/s (~7.9×)** on a 12B Q4_0 model, with all
9 SM issue-rate fields verified full.

**Primary stack: rejoin15 on NVIDIA Open `610.43.03`** — V67 exploit inlined into driver init
(no systemd service, survives reboots). Alternative: bendy2's V67 on `580.159.03` with systemd service.

---

## TL;DR

| What | Before | After |
|------|--------|-------|
| pp512 (12B Q4_0, prefill) | 224.10 t/s | **1824.15 t/s (+713%)** |
| tg16 (decode) | throttled | 55.96 t/s |
| SM issue-rate fields (9) | throttled (05/01/05 pattern) | **all 9 full** |
| PLM (FEAT_OVR) | locked (`0xffffff8f`) | **open (`0xffffffff`)** |
| Perplexity | 202.67 (throttled, sane) | 53.05 (sane) |
| PCIe | Gen1 x16 | Gen1 x16 *(hardware link cap, see Roadmap)* |

Verification: `check.sh` reports `DP=full FFMA=full FMLA16=full FMLA32=full IMLA0..4=full`.
dmesg shows `CMP90HX: V67 attempt=0 status=0x65 PLM=0xffffffff` and
`compute selectors enabled PLM=0xffffffff SS0=0x88888888 SS1=0x00000008`.

---

## Background

The CMP 90HX is a physically complete GA102 die (same silicon as RTX 3080, sm_86, 50 SMs)
with compute throttled via **eFuse-set SM issue-rate modifiers**. VBIOS mods cannot change
eFuse defaults. The throttle is bypassed by writing the **FEAT_OVR override registers**
(`SS0=0x88888888`, `SS1=0x00000008`) — but those registers are only writable after opening
the **PLM (Privilege Level Masks)**, which requires arbitrary code execution on the GSP
Falcon coprocessor.

**The vulnerability** (originally disclosed by Jon Pry, "A Canary in the Crypto Mine"): the
shipping GSP debug booter is encrypted with a trivial key and contains a DMA-driven buffer
overflow that runs arbitrary code *after* signature verification, including a stack-canary
bypass.

**Why 610.43.03 now works (rejoin trick):** earlier 610.x attempts failed because the V67
payload was injected *pre-GFW* — the boot-time FWSEC/WPR-meta checks rejected it. The
rejoin14/15 patches move the injection to *after* `GFW_BOOT OK`: swap signature memdesc →
run V67 chain (PLM opens) → driver writes SS0/SS1 → official FLR + `nv_start_device` retry.
The 580.159.03 stack (bendy2 + systemd service) remains a valid alternative.

---

## The Working Stack

### Option A: rejoin15 on 610.43.03 (recommended)

V67 exploit inlined into driver init — no systemd service, survives reboots.

| Component | What | Where |
|-----------|------|-------|
| Driver | NVIDIA Open `610.43.03` + rejoin14/15 patches | kernel modules, `updates/cmpunlocker/` |
| Userspace | `610.43.03` (libcuda, libnvidia-ml, nvidia-smi) | from `.run` installer |
| GSP firmware | `gsp_ga10x.bin` | `/lib/firmware/nvidia/610.43.03/` |

Install: `sudo ./install.sh --profile=cmp90-rejoin15`

### Option B: bendy2 on 580.159.03 (legacy)

V67 via systemd service — re-applies at every boot (~2 min).

| Component | What | Where |
|-----------|------|-------|
| Runtime driver | **stock** NVIDIA Open `580.159.03` (unmodified) | kernel modules, `updates/cmpunlocker/` |
| Bootstrap module | `580.159.03` + bendy2's direct-compute patch (V67) | `updates/cmp90hx-persistent/nvidia.ko.bootstrap` |
| Service | `cmp90hx-persistent.service` — at every boot: load bootstrap → V67 → PLM open → write SS0/SS1 → 2× PCIe bus reset → reload stock driver | systemd (enabled) |
| Userspace | `580.159.03` (libcuda, libnvidia-ml, nvidia-smi) | from `NVIDIA-Linux-x86_64-580.159.03.run` |
| Kernel compat | 6.12.95 build fixes for 580.159.03 | [`tools/fix-580-kernel612.sh`](tools/fix-580-kernel612.sh) |

---

## One-Click Installer

For most users, everything is automated — download this repository (Code → Download ZIP),
extract, and run:

```bash
cd cmpunlocker-master
# Recommended: rejoin15 on 610.43.03 (V67 inlined into driver, no service)
sudo ./install.sh --profile=cmp90-rejoin15

# Alternative: bendy2 on 580.159.03 (V67 via systemd service)
sudo ./install-unlock.sh
```

**rejoin15** builds 610.43.03 + rejoin14/15 patches from source, installs to
`/lib/modules/$(uname -r)/updates/cmpunlocker/`. Requires GSP firmware
(`/lib/firmware/nvidia/610.43.03/gsp_ga10x.bin`) from the 610.43.03 `.run` installer.

**bendy2** installs stock 580.159.03 + systemd service that re-applies V67 at every boot
(~2 min wait after reboot).

Then: `sudo reboot` → verify with `check.sh` (9/9 fields "full").
The installer backs up your previous driver modules automatically.

Requirements: CMP 90HX (10de:220d/1555), x86_64 Linux, kernel ≥ 6.1, Secure Boot off,
internet on first run.

---

## Donations

This research is done in the open. If the unlock helped you, a donation keeps the
investigation going (PCIe Gen3, 20 GB VRAM memory upgrade, graphics):

```
Litecoin: LTC1QTA33QANK4L6JLDVRCR9WP4C8MT555V3FA0RX5M
TON:      UQDSGnFHAN86TZyTI6q-JsDCSy9Iwm6xseoxh7VyIzXNn3wm
```

---

## Reproducing (for other researchers)

**Prerequisites:**
- CMP 90HX with PCI ID `10de:220d / 10de:1555` (check: `lspci -nn`)
- x86_64 Linux, kernel headers (`/lib/modules/$(uname -r)/build`), Secure Boot **off**

### Method A: rejoin15 on 610.43.03 (recommended)

```bash
# 1. Install stock 610.43.03 (userspace + GSP firmware)
wget https://download.nvidia.com/XFree86/Linux-x86_64/610.43.03/NVIDIA-Linux-x86_64-610.43.03.run
chmod +x NVIDIA-Linux-x86_64-610.43.03.run
sudo ./NVIDIA-Linux-x86_64-610.43.03.run --silent --no-kernel-modules
# GSP firmware: /lib/firmware/nvidia/610.43.03/gsp_ga10x.bin

# 2. Build & install patched modules
sudo ./install.sh --profile=cmp90-rejoin15
sudo reboot

# 3. Verify
./check.sh   # 9/9 issue-rate fields full
nvidia-smi   # 610.43.03
dmesg | grep CMP90   # PLM=0xffffffff, SS0=0x88888888
```

### Method B: bendy2 on 580.159.03 (legacy)

```bash
# 1. Build & install stock 580.159.03 for kernel 6.12.x
git clone https://github.com/NVIDIA/open-gpu-kernel-modules --branch 580.159.03
# apply kernel-6.12 compat fixes: see tools/fix-580-kernel612.sh
make -j$(nproc) modules KERNEL_UNAME=$(uname -r)
cp kernel-open/nvidia.ko kernel-open/nvidia-uvm.ko /lib/modules/$(uname -r)/updates/cmpunlocker/
depmod -a
# userspace: NVIDIA-Linux-x86_64-580.159.03.run --silent --no-kernel-modules
# reboot, confirm: nvidia-smi → 580.159.03

# 2. Install bendy2's persistent service
git clone https://github.com/bendy2/cmp90hx
cd cmp90hx
sudo ./install.sh
sudo reboot   # wait ~2 min for service

# 3. Verify
systemctl status cmp90hx-persistent.service     # active (exited) after ~2 min
./check.sh   # 9/9 issue-rate fields full
```

**Rollback:** `sudo ./remove.sh --yes && sudo reboot`

---

## Roadmap / Remaining Work

1. **PCIe Gen3** — the card's link is **hardware-capped at Gen1 x16** (`LnkCap2: 2.5GT/s`).
   The cap is likely fuse/strap-set like the compute throttle; the now-working PLM-open path
   may override it via `PCIE_FUSE` (`0x00823810`), `LINK_CONTROL` (`0x0008c000`),
   `LINK_SPEED` (`0x0008c040`). Next experiment: extend the compute-override payload with
   the PCIe override. Expected: ~4× PCIe bandwidth.
2. **Memory upgrade 10 GB → 20 GB VRAM** — proposal: replace the 10× 8 Gbit GDDR6X modules
   with 16 Gbit (2 GB) modules (same 320-bit bus, same chip count) and unlock the 20 GB
   geometry via FBPA/CFG1/LMR-style overrides (the CMP 170HX 8→64 GB mechanism). Open
   questions: 16 Gbit GDDR6X availability, training tables, memory-controller support.
3. **Graphics (PGRAPH2)** — 3D/graphics remain gated (GSP-RM skips graphics init).
   Separate problem, likely needs GSP-RM firmware work.

---

## History (what didn't work, so you don't repeat it)

| Path | Result |
|------|--------|
| VBIOS mods (SM issue-rate in eFuse) | ❌ eFuse is hardware-locked; VBIOS cannot change it |
| GSP Falcon attack surface (v3–v28, 25 driver iterations) | ❌ all blocked by PKC signatures / hardware firewall / PLM lock |
| V67 payload on 610.x **pre-GFW** (early attempts) | ❌ FWSEC/WPR-meta checks reject pre-GFW injection |
| HFMA2 CUDA-core GEMM in llama.cpp (Tier 3a) | ⚠️ +69% but FP16 accumulator overflow → wrong tokens; **superseded** by driver unlock (see `research/PREFILL_ROOT_CAUSE.md`) |
| **V67 payload on 610.43.03 via rejoin15** | ✅ **PLM opens** (post-GFW injection) |
| **V67 payload on stock 580.159.03** | ✅ **PLM opens on attempt 0** |

---

## Credits

- **bendy2** — V67 exploit + direct-compute patch for 580.159.03 ([github.com/bendy2/cmp90hx](https://github.com/bendy2/cmp90hx)) — the key that opened PLM
- **Jon Pry** ([Zenodo](https://zenodo.org/records/20916112)) — "A Canary in the Crypto Mine" (debug-booter overflow disclosure)
- **d3dx9** — Python Falcon emulator & ROP chain
- **loss-and-quick** — 610.57.04 port, gadget analysis, tools, English translations (merged PR #2)
- **Rhonstin** — CMP 90HX patches
- **amoghmunikote** — original cmpunlocker for CMP 170HX (GA100)


---

## Repository Layout

- `STATUS.md` — full research status (registers, exploit chain, benchmark data)
- `docs/` — exploit writeup, bendy2 analysis, gadget analysis (580.x vs 610.x), testing guide
- `driver/` — build scripts + patches (610.43.03 era and 610.57.04 port)
- `tools/` — analysis tools (`lw_catalog_610.py`, `compare_op32.py`, `extract_ucode.py`, `fix-580-kernel612.sh`)
- `research/` — Falcon attack surface iterations, SM issue-rate comparison

## License

[Same as original cmpunlocker](LICENSE)
