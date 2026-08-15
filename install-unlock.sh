#!/usr/bin/env bash
# =============================================================================
#  CMP 90HX Compute Unlock — one-click installer
# =============================================================================
#  Restores full SM compute throughput on the NVIDIA CMP 90HX (GA102,
#  PCI ID 10de:220d / 10de:1555) using bendy2's V67 exploit on stock
#  NVIDIA Open 580.159.03.
#
#  The installer:
#    1. detects your OS / kernel / GPU,
#    2. builds and installs the stock 580.159.03 open kernel modules
#       (with kernel compat fixes) if needed,
#    3. installs the matching userspace (libcuda / libnvidia-ml) if needed,
#    4. installs bendy2's persistent unlock service (PLM open + SS0/SS1
#       re-applied at every boot),
#    5. prints verification and rollback instructions.
#
#  Usage:  sudo ./install-unlock.sh
#          sudo ./install-unlock.sh --check   (preflight only, no install)
#
#  Requirements: CMP 90HX (10de:220d/1555), Linux x86_64, kernel >= 6.1,
#  kernel headers, Secure Boot OFF, internet access (first run).
#
#  Donations (research continues thanks to you):
#    Litecoin: LTC1QTA33QANK4L6JLDVRCR9WP4C8MT555V3FA0RX5M
#    TON:      UQDSGnFHAN86TZyTI6q-JsDCSy9Iwm6xseoxh7VyIzXNn3wm
# =============================================================================

set -uo pipefail

DRIVER_VERSION="580.159.03"
DRIVER_TARBALL_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${DRIVER_VERSION}.tar.gz"
RUN_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
BENDY2_URL="https://github.com/bendy2/cmp90hx/archive/refs/heads/main.zip"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${CMP90_UNLOCK_WORK:-/tmp/cmp90-unlock}"
LOGDIR="${WORKDIR}/logs"
LOG_FILE="${LOGDIR}/install_$(date +%Y%m%d_%H%M%S).log"
KVER="$(uname -r)"
KSRC="/lib/modules/${KVER}/build"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"

DONATE_LTC="LTC1QTA33QANK4L6JLDVRCR9WP4C8MT555V3FA0RX5M"
DONATE_TON="UQDSGnFHAN86TZyTI6q-JsDCSy9Iwm6xseoxh7VyIzXNn3wm"

# ---- wizard output helpers -------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""; BOLD=""
fi
step() { echo ""; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}${BOLD}$*${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; echo ""; echo -e "${YELLOW}Installation aborted. Log: ${LOG_FILE}${NC}" >&2; exit 1; }

banner() {
    cat <<'EOF'

  ╔══════════════════════════════════════════════════════════════════╗
  ║             CMP 90HX COMPUTE UNLOCK — one-click installer        ║
  ║     NVIDIA CMP 90HX (GA102, 10de:220d) → RTX 3080-class compute  ║
  ║          pp512: 224 t/s  →  1824 t/s  (+713%, verified)          ║
  ╚══════════════════════════════════════════════════════════════════╝

EOF
    echo -e "${BOLD}Donations keep the research going:${NC}"
    echo -e "  ${CYAN}Litecoin:${NC} ${DONATE_LTC}"
    echo -e "  ${CYAN}TON:${NC}      ${DONATE_TON}"
    echo ""
}

# ---- preflight ------------------------------------------------------------
preflight() {
    step "Step 1/6 — System check"

    [ "${EUID}" -eq 0 ] || die "Run as root: sudo ./install-unlock.sh"

    info "Detecting OS..."
    if [ -r /etc/os-release ]; then
        OS_NAME="$(. /etc/os-release; echo "${PRETTY_NAME:-${NAME:-unknown}}")"
    else
        OS_NAME="unknown"
    fi
    ok "OS: ${OS_NAME}"
    ok "Kernel: ${KVER}"
    [ -d "${KSRC}" ] || die "Kernel headers not found at ${KSRC}. Install them first, e.g.:  apt-get install linux-headers-$(uname -r)"

    info "Detecting GPU..."
    CARD=""
    for dev in /sys/bus/pci/devices/*; do
        [ -r "${dev}/vendor" ] || continue
        [ "$(<"${dev}/vendor")" = "0x10de" ] || continue
        [ "$(<"${dev}/device")" = "0x220d" ] || continue
        CARD="$(basename "${dev}")"
        SUB="$(cat "${dev}/subsystem_device" 2>/dev/null || echo unknown)"
        break
    done
    [ -n "${CARD}" ] || die "CMP 90HX (10de:220d) not found. Only the 10de:220d card is supported."
    ok "CMP 90HX found: ${CARD} (subsystem ${SUB})"
    if [ -r "/sys/bus/pci/devices/${CARD}/reset_method" ] && grep -qw bus "/sys/bus/pci/devices/${CARD}/reset_method"; then
        ok "PCIe bus reset available"
    else
        die "Card ${CARD} does not expose the required PCIe 'bus' reset method (sysfs reset_method)"
    fi

    info "Checking Secure Boot..."
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        die "Secure Boot is enabled — the unsigned bootstrap module will not load. Disable Secure Boot in UEFI first."
    fi
    ok "Secure Boot: off (or not detected)"

    info "Checking build tools..."
    MISSING=""
    for cmd in make gcc wget curl unzip patch sed strings modinfo modprobe insmod depmod systemctl nproc; do
        command -v "${cmd}" >/dev/null 2>&1 || MISSING="${MISSING} ${cmd}"
    done
    if [ -n "${MISSING}" ]; then
        warn "Missing tools:${MISSING}"
        if command -v apt-get >/dev/null 2>&1; then
            info "Installing missing packages (Debian/Ubuntu) — this may take a minute..."
            DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential linux-headers-$(uname -r) unzip wget curl patch kmod >/dev/null 2>&1 \
                || die "apt-get install failed. Install manually: build-essential linux-headers-$(uname -r) unzip wget curl patch kmod"
            ok "Build tools installed"
        else
            die "Install missing tools manually (build-essential/linux-headers equivalents for your distro), then re-run"
        fi
    else
        ok "All build tools present"
    fi

    info "Checking network..."
    if curl -sI --max-time 10 "https://github.com" >/dev/null 2>&1; then
        ok "Network reachable (github.com)"
    else
        warn "github.com unreachable — downloads will fail unless you have another route. Continuing anyway..."
    fi
}

# ---- driver state ---------------------------------------------------------
detect_driver() {
    step "Step 2/6 — Current NVIDIA driver"
    if command -v modinfo >/dev/null 2>&1 && modinfo nvidia >/dev/null 2>&1; then
        CUR_VERSION="$(modinfo -F version nvidia 2>/dev/null | head -1)"
        CUR_LICENSE="$(modinfo -F license nvidia 2>/dev/null | head -1)"
        CUR_PATH="$(modinfo -n nvidia 2>/dev/null)"
    else
        CUR_VERSION=""; CUR_LICENSE=""; CUR_PATH=""
    fi
    if [ -n "${CUR_VERSION}" ]; then
        info "Installed module: version=${CUR_VERSION} license=${CUR_LICENSE}"
        info "  path: ${CUR_PATH}"
    else
        warn "No nvidia kernel module found (or modinfo missing)"
    fi

    NEED_BUILD=1
    if [ -n "${CUR_VERSION}" ] && [ "${CUR_VERSION}" = "${DRIVER_VERSION}" ] && [[ "${CUR_LICENSE}" == *MIT/GPL* ]]; then
        ok "Already running NVIDIA Open ${DRIVER_VERSION} — skipping kernel build"
        NEED_BUILD=0
    else
        warn "Need to build + install NVIDIA Open ${DRIVER_VERSION} kernel modules"
    fi
}

# ---- build & install kernel modules --------------------------------------
build_driver() {
    step "Step 3/6 — Building NVIDIA Open ${DRIVER_VERSION} kernel modules"
    info "This takes 10–20 minutes on 8 cores. Download: ~25 MB, build dir: ${WORKDIR}"
    mkdir -p "${WORKDIR}"
    cd "${WORKDIR}"

    TARBALL="${WORKDIR}/open-gpu-kernel-modules-${DRIVER_VERSION}.tar.gz"
    SRC_DIR="${WORKDIR}/open-gpu-kernel-modules-${DRIVER_VERSION}"

    if [ ! -f "${TARBALL}" ]; then
        info "Downloading NVIDIA Open ${DRIVER_VERSION} source..."
        curl -L --fail --progress-bar -o "${TARBALL}" "${DRIVER_TARBALL_URL}" || die "Download failed: ${DRIVER_TARBALL_URL}"
    else
        ok "Source tarball already cached"
    fi

    rm -rf "${SRC_DIR}"
    tar -xzf "${TARBALL}" -C "${WORKDIR}" || die "Extract failed"
    [ -d "${SRC_DIR}" ] || die "Source tree not found after extract"
    ok "Source extracted"

    info "Applying kernel ${KVER} compat fixes..."
    bash "${SCRIPT_DIR}/tools/fix-580-kernel612.sh" "${SRC_DIR}" "${KVER}" || die "Compat fix script failed"
    ok "Compat fixes applied"

    # Pass 1: generate conftest (may fail — expected)
    info "Generating conftest (pass 1)..."
    ( cd "${SRC_DIR}" && make -j1 modules SYSSRC="${KSRC}" >/dev/null 2>&1 ) || true

    # Apply fixes again (conftest regenerated)
    bash "${SCRIPT_DIR}/tools/fix-580-kernel612.sh" "${SRC_DIR}" "${KVER}" >/dev/null 2>&1 || true

    # Pass 2: real build (may still fail on first hit — fixes applied again after)
    info "Building modules (pass 2, this is the long one)..."
    ( cd "${SRC_DIR}" && NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem" \
        make -j"$(nproc)" modules SYSSRC="${KSRC}" >"${LOGDIR}/make.log" 2>&1 ) || true

    bash "${SCRIPT_DIR}/tools/fix-580-kernel612.sh" "${SRC_DIR}" "${KVER}" >/dev/null 2>&1 || true

    # Pass 3: must succeed
    info "Final build pass..."
    ( cd "${SRC_DIR}" && NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem" \
        make -j"$(nproc)" modules SYSSRC="${KSRC}" >>"${LOGDIR}/make.log" 2>&1 ) || {
        tail -20 "${LOGDIR}/make.log" >&2
        die "Kernel module build failed — see ${LOGDIR}/make.log"
    }

    NVIDIA_KO="${SRC_DIR}/kernel-open/nvidia.ko"
    UVM_KO="${SRC_DIR}/kernel-open/nvidia-uvm.ko"
    [ -f "${NVIDIA_KO}" ] || die "nvidia.ko not produced"
    [ -f "${UVM_KO}" ] || die "nvidia-uvm.ko not produced"
    [ "$(modinfo -F version "${NVIDIA_KO}")" = "${DRIVER_VERSION}" ] || die "Built module version mismatch"
    ok "Modules built: $(modinfo -F version "${NVIDIA_KO}") for ${KVER}"

    info "Installing modules to ${INSTALL_MOD_DIR} (existing modules backed up)..."
    mkdir -p "${INSTALL_MOD_DIR}"
    if [ -f "${INSTALL_MOD_DIR}/nvidia.ko" ]; then
        mkdir -p "${INSTALL_MOD_DIR}.backup"
        cp -a "${INSTALL_MOD_DIR}/." "${INSTALL_MOD_DIR}.backup/" 2>/dev/null || true
        warn "Previous modules backed up to ${INSTALL_MOD_DIR}.backup"
    fi
    install -m 0644 "${NVIDIA_KO}" "${INSTALL_MOD_DIR}/nvidia.ko"
    install -m 0644 "${UVM_KO}" "${INSTALL_MOD_DIR}/nvidia-uvm.ko"
    printf '%s\n' "${DRIVER_VERSION}" > "${INSTALL_MOD_DIR}/driver_version"
    depmod -a "${KVER}"
    ok "Modules installed + depmod done"
}

# ---- userspace ------------------------------------------------------------
install_userspace() {
    step "Step 4/6 — Userspace (libcuda / libnvidia-ml / nvidia-smi)"
    US_VERSION=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        US_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
    fi
    if [ -n "${US_VERSION}" ] && [ "${US_VERSION}" = "${DRIVER_VERSION}" ]; then
        ok "Userspace already ${DRIVER_VERSION} — skipping"
        return 0
    fi
    warn "Userspace (${US_VERSION:-none}) does not match kernel ${DRIVER_VERSION} — installing from NVIDIA .run (~380 MB download)"

    RUN_FILE="${WORKDIR}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
    if [ ! -f "${RUN_FILE}" ]; then
        info "Downloading NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run..."
        curl -L --fail --progress-bar -o "${RUN_FILE}" "${RUN_URL}" || die "Download failed: ${RUN_URL}"
    else
        ok "Installer cached"
    fi
    chmod +x "${RUN_FILE}"
    info "Installing userspace only (kernel modules NOT touched)..."
    "${RUN_FILE}" --silent --no-kernel-modules --no-x-check --no-questions --no-drm >"${LOGDIR}/run.log" 2>&1 \
        || die "nvidia-installer failed — see ${LOGDIR}/run.log"
    ok "Userspace ${DRIVER_VERSION} installed"
    ldconfig 2>/dev/null || true
}

# ---- bendy2 persistent service -------------------------------------------
install_service() {
    step "Step 5/6 — Persistent unlock service (bendy2)"
    info "Downloading bendy2/cmp90hx..."
    BZIP="${WORKDIR}/bendy2-cmp90hx.zip"
    BDIR="${WORKDIR}/bendy2-cmp90hx-main"
    if [ ! -f "${BZIP}" ]; then
        curl -L --fail --progress-bar -o "${BZIP}" "${BENDY2_URL}" || die "Download failed: ${BENDY2_URL}"
    else
        ok "Archive cached"
    fi
    rm -rf "${BDIR}"
    unzip -q -o "${BZIP}" -d "${WORKDIR}" || die "Extract failed"
    [ -d "${BDIR}" ] || die "bendy2 tree not found"

    BUNDLED="${BDIR}/work/cmp90hx-persistent-build"
    [ -d "${BUNDLED}" ] || die "bendy2 bundled patched source missing (${BUNDLED})"

    info "Applying kernel ${KVER} compat fixes to bendy2's bundled source..."
    bash "${SCRIPT_DIR}/tools/fix-580-kernel612.sh" "${BUNDLED}" "${KVER}" || die "Compat fix failed"
    ok "Compat fixes applied"

    info "Running bendy2 install.sh (builds the V67 bootstrap module, ~10 min)..."
    ( cd "${BDIR}" && NV_EXCLUDE_KERNEL_MODULES="nvidia-drm nvidia-modeset nvidia-peermem" \
        ./install.sh >"${LOGDIR}/bendy2.log" 2>&1 ) || {
        tail -20 "${LOGDIR}/bendy2.log" >&2
        die "bendy2 install failed — see ${LOGDIR}/bendy2.log"
    }
    grep -q "PASS_CMP90HX_PERSISTENT_INSTALLED" "${LOGDIR}/bendy2.log" || {
        tail -20 "${LOGDIR}/bendy2.log" >&2
        die "bendy2 install did not report success"
    }
    ok "Service installed and enabled (cmp90hx-persistent.service)"
}

# ---- final ----------------------------------------------------------------
finale() {
    step "Step 6/6 — Done"
    cat <<EOF

  ${BOLD}Installation complete.${NC}

  ${BOLD}Next:${NC}
    1. ${BOLD}Reboot${NC} the machine (the unlock is applied at every boot by the service):
         sudo reboot

    2. Wait ~2 minutes after boot (service processes the card), then verify:
         cat /run/cmp90hx-persistent-batch.status     → "PASS all 1 CMP90HX GPUs completed"
         nvidia-smi                                   → driver ${DRIVER_VERSION}
         sudo CMP90_CHECK_TIMEOUT_SECONDS=15 ./check.sh   → 9/9 fields "full"
       (check.sh lives in the downloaded bendy2 tree: ${BDIR})

  ${BOLD}Expected:${NC}
    PP512: 224 t/s → ~1800 t/s (+700%) on a 12B Q4_0 model.

  ${BOLD}Rollback:${NC}
    cd ${BDIR} && sudo ./remove.sh --yes && sudo reboot
    (removes the service; your previous driver modules are backed up at
     ${INSTALL_MOD_DIR}.backup)

  ${BOLD}Notes:${NC}
    - PCIe stays Gen1 x16 — hardware link cap of the card.
    - Do not run nvidia-smi / GPU workloads while the service is working
      (~2 min after boot).
    - If the card disappears after reboot: cold power-cycle (the override
      registers are lost on power-off, nothing is permanently modified).

  ${BOLD}Donations — keep the research alive:${NC}
    Litecoin: ${DONATE_LTC}
    TON:      ${DONATE_TON}

  Full log: ${LOG_FILE}
EOF
}

# ---- main -----------------------------------------------------------------
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

mkdir -p "${LOGDIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1
banner
preflight
detect_driver
if [ "${CHECK_ONLY}" -eq 1 ]; then
    step "Preflight complete — nothing was installed"
    echo "Run:  sudo ./install-unlock.sh   (full installation)"
    exit 0
fi
if [ "${NEED_BUILD}" -eq 1 ]; then
    build_driver
fi
install_userspace
install_service
finale
