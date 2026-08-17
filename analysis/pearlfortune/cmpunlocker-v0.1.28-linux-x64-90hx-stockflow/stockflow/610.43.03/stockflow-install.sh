#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

readonly driver_version="610.43.03"
readonly install_ack="I-ACCEPT-90HX-STOCKFLOW-PERSISTENT-INSTALL"
readonly project_id="cmpunlocker-90hx-stockflow"
readonly install_relative_dir="updates/cmpunlocker-90hx-stockflow"
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly kernel_release="$(uname -r)"
readonly default_artifact="${script_dir}/artifacts/${driver_version}-${kernel_release}-rejoin14-multigpu-state"
readonly module_files=(nvidia.ko nvidia-uvm.ko nvidia-modeset.ko nvidia-drm.ko nvidia-peermem.ko)
readonly module_names=(nvidia nvidia_uvm nvidia_modeset nvidia_drm nvidia_peermem)
readonly module_override_names=(nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem)
readonly depmod_config="/etc/depmod.d/${project_id}.conf"

artifact="${default_artifact}"
ack=""
dry_run=0

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo ./stockflow-install.sh [--dry-run] [--artifact DIR]
       --acknowledge ${install_ack}

Installs the CMP 90HX 610.43.03 rejoin13/rejoin14 stockflow modules into an isolated
updates/ directory for the next boot. It does not create systemd units and does
not hot-unload NVIDIA modules. Reboot after a successful install.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact)
            [[ $# -ge 2 ]] || die "--artifact requires a directory"
            artifact="$2"
            shift 2
            ;;
        --acknowledge)
            [[ $# -ge 2 ]] || die "--acknowledge requires a value"
            ack="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sha256_file() {
    sha256sum -- "$1" | awk '{print $1}'
}

verify_checksums_file() {
    local dir="$1"
    local sums="${dir}/checksums.sha256"
    [[ -f "${sums}" ]] || return 0

    while read -r expected path _; do
        [[ -n "${expected}" && "${expected}" =~ ^[0-9a-f]{64}$ ]] || \
            die "bad checksum line in ${sums}"
        local base
        base="$(basename -- "${path}")"
        [[ -f "${dir}/${base}" ]] || die "checksum target missing: ${base}"
        [[ "$(sha256_file "${dir}/${base}")" == "${expected}" ]] || \
            die "checksum mismatch: ${base}"
    done < "${sums}"
}

verify_artifact() {
    local dir="$1"
    [[ -d "${dir}" && ! -L "${dir}" ]] || die "artifact dir is unsafe: ${dir}"

    for module in "${module_files[@]}"; do
        local file="${dir}/${module}"
        [[ -f "${file}" && ! -L "${file}" ]] || die "missing artifact module: ${module}"
        [[ "$(modinfo -F version "${file}")" == "${driver_version}" ]] || \
            die "${module} driver version mismatch"
        [[ "$(modinfo -F vermagic "${file}" | awk '{print $1}')" == "${kernel_release}" ]] || \
            die "${module} vermagic does not match ${kernel_release}"
    done

    grep -aFq "CMP90_STOCKFLOW_REJOIN12" "${dir}/nvidia.ko" || \
        die "artifact lacks rejoin12 marker"
    if ! grep -aFq "CMP90_STOCKFLOW_REJOIN14" "${dir}/nvidia.ko"; then
        grep -aFq "CMP90_STOCKFLOW_REJOIN13" "${dir}/nvidia.ko" || \
            die "artifact lacks rejoin13/rejoin14 marker"
    fi
    verify_checksums_file "${dir}"
}

artifact_variant() {
    local dir="$1"
    if grep -aFq "CMP90_STOCKFLOW_REJOIN14" "${dir}/nvidia.ko"; then
        printf 'rejoin14-multigpu-state\n'
    else
        printf 'rejoin13-open-retry\n'
    fi
}

artifact_marker() {
    local dir="$1"
    if grep -aFq "CMP90_STOCKFLOW_REJOIN14" "${dir}/nvidia.ko"; then
        printf 'CMP90_STOCKFLOW_REJOIN14\n'
    else
        printf 'CMP90_STOCKFLOW_REJOIN13\n'
    fi
}

verify_running_stack() {
    local current_nvidia="$1"
    [[ "$(modinfo -F version "${current_nvidia}")" == "${driver_version}" ]] || \
        die "current nvidia.ko is not ${driver_version}: ${current_nvidia}"
    [[ "$(modinfo -F vermagic "${current_nvidia}" | awk '{print $1}')" == "${kernel_release}" ]] || \
        die "current nvidia.ko vermagic does not match ${kernel_release}"

    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi -L | grep -Fq "CMP 90HX" || die "no CMP 90HX visible in nvidia-smi"
        local versions
        versions="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | sort -u | tr '\n' ' ')"
        [[ "${versions}" == "${driver_version} " ]] || \
            die "nvidia-smi driver versions are '${versions}', expected ${driver_version}"
    else
        warn "nvidia-smi not found; skipping visible GPU check"
    fi
}

refresh_initramfs() {
    local kver="$1"
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "${kver}"
    elif command -v dracut >/dev/null 2>&1; then
        dracut -f --kver "${kver}"
    else
        warn "no update-initramfs/dracut found; depmod was updated but initramfs was not refreshed"
    fi
}

write_depmod_config() {
    local stamp="$1"
    local depmod_tmp="${depmod_config}.tmp.${stamp}"

    {
        printf '# Managed by cmpunlocker-rs 90HX stockflow.\n'
        printf '# Prefer cmpunlocker 90HX stockflow modules over DKMS stock modules.\n'
        for name in "${module_override_names[@]}"; do
            printf 'override %s * %s\n' "${name}" "${install_relative_dir}"
        done
    } > "${depmod_tmp}"
    chmod 0644 -- "${depmod_tmp}"
    sync -f -- "${depmod_tmp}"
    mv -f -- "${depmod_tmp}" "${depmod_config}"
    sync -f -- "$(dirname -- "${depmod_config}")"
}

verify_module_resolution() {
    for i in "${!module_names[@]}"; do
        local name="${module_names[$i]}"
        local module_file="${module_files[$i]}"
        local resolved
        resolved="$(readlink -f -- "$(modinfo -n "${name}")")" || die "cannot resolve ${name} after depmod"
        [[ "${resolved}" == "${target}/${module_file}" ]] || \
            die "${name} resolves to ${resolved}, not ${target}/${module_file}"
    done
}

require_command awk
require_command basename
require_command date
require_command depmod
require_command grep
require_command install
require_command mkdir
require_command mv
require_command modinfo
require_command readlink
require_command sha256sum
require_command sync

[[ "${EUID}" -eq 0 ]] || die "run as root"

readonly module_root="$(readlink -f -- "/lib/modules/${kernel_release}")"
readonly target="${module_root}/${install_relative_dir}"
readonly target_parent="$(dirname -- "${target}")"
readonly state_root="/var/lib/${project_id}"
readonly state_dir="${state_root}/${kernel_release}"
readonly state_file="${state_dir}/install.env"
readonly backup_dir="${state_root}/backups/${kernel_release}"
readonly archive_dir="${state_root}/archives/${kernel_release}"

case "${target}" in
    "${module_root}"/updates/cmpunlocker-90hx-stockflow) ;;
    *) die "refusing unexpected install target: ${target}" ;;
esac

current_nvidia="$(readlink -f -- "$(modinfo -n nvidia)")" || die "cannot resolve current nvidia.ko"
if [[ "${current_nvidia}" == "${target}/nvidia.ko" ]]; then
    [[ ! -L "${depmod_config}" ]] || die "refusing symlink depmod config: ${depmod_config}"
    verify_artifact "${target}"
    verify_running_stack "${current_nvidia}"

    info "Driver: ${driver_version}"
    info "Kernel: ${kernel_release}"
    info "Install target: ${target}"
    info "Current nvidia.ko: ${current_nvidia}"

    if [[ "${dry_run}" -eq 1 ]]; then
        info "DRY RUN: stockflow is already resolved; no files changed"
        exit 0
    fi

    [[ "${ack}" == "${install_ack}" ]] || die "required acknowledgement: ${install_ack}"
    stamp="$(date -u +%Y%m%dT%H%M%SZ).$$"
    write_depmod_config "${stamp}"
    depmod "${kernel_release}"
    refresh_initramfs "${kernel_release}"
    verify_module_resolution

    printf 'PASS_CMP90HX_STOCKFLOW_ALREADY_INSTALLED\n%s\n' "${state_file}"
    exit 0
fi

artifact="$(readlink -f -- "${artifact}")" || die "artifact does not exist: ${artifact}"
[[ ! -e "${target}" && ! -L "${target}" ]] || die "target already exists: ${target}"
[[ ! -e "${state_file}" && ! -L "${state_file}" ]] || die "state already exists: ${state_file}"
[[ ! -L "${depmod_config}" ]] || die "refusing symlink depmod config: ${depmod_config}"

verify_artifact "${artifact}"
verify_running_stack "${current_nvidia}"

info "Driver: ${driver_version}"
info "Kernel: ${kernel_release}"
info "Artifact: ${artifact}"
info "Install target: ${target}"
info "Current nvidia.ko: ${current_nvidia}"

if [[ "${dry_run}" -eq 1 ]]; then
    info "DRY RUN: install preflight passed; no files changed"
    exit 0
fi

[[ "${ack}" == "${install_ack}" ]] || die "required acknowledgement: ${install_ack}"

umask 077
mkdir -p -- "${target_parent}" "${state_dir}" "${backup_dir}" "${archive_dir}"
[[ -d "${target_parent}" && ! -L "${target_parent}" ]] || die "unsafe target parent"

stamp="$(date -u +%Y%m%dT%H%M%SZ).$$"
stage="${archive_dir}/install-stage.${stamp}"
state_tmp="${state_dir}/install.env.tmp.${stamp}"
mkdir -p -- "${stage}"

for module in "${module_files[@]}"; do
    install -m 0644 -- "${artifact}/${module}" "${stage}/${module}"
done
(cd "${stage}" && sha256sum ./*.ko > checksums.sha256)
cat > "${stage}/artifact.env" <<EOF
project_id=${project_id}
driver_version=${driver_version}
kernel_release=${kernel_release}
variant=$(artifact_variant "${stage}")
marker=$(artifact_marker "${stage}")
EOF
chmod 0644 -- "${stage}/artifact.env" "${stage}/checksums.sha256"
verify_artifact "${stage}"

{
    printf 'schema=1\n'
    printf 'project_id=%s\n' "${project_id}"
    printf 'driver_version=%s\n' "${driver_version}"
    printf 'kernel_release=%s\n' "${kernel_release}"
    printf 'target_dir=%s\n' "${target}"
    printf 'artifact_dir=%s\n' "${artifact}"
    printf 'depmod_config=%s\n' "${depmod_config}"
    printf 'install_boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
} > "${state_tmp}"

for i in "${!module_names[@]}"; do
    name="${module_names[$i]}"
    module_file="${module_files[$i]}"
    resolved="$(modinfo -n "${name}" 2>/dev/null || true)"
    if [[ -n "${resolved}" && -f "${resolved}" && ! -L "${resolved}" ]]; then
        install -m 0644 -- "${resolved}" "${backup_dir}/${module_file}.before.${stamp}"
        printf 'previous_%s=%s\n' "${name}" "${resolved}" >> "${state_tmp}"
        printf 'previous_%s_sha256=%s\n' "${name}" "$(sha256_file "${backup_dir}/${module_file}.before.${stamp}")" >> "${state_tmp}"
    fi
done

chmod 0600 -- "${state_tmp}"
sync -f -- "${stage}"
sync -f -- "${state_tmp}"

mv -T -- "${stage}" "${target}"
mv -- "${state_tmp}" "${state_file}"
chmod 0755 -- "${target}"
chmod 0644 -- "${target}"/*.ko "${target}/artifact.env" "${target}/checksums.sha256"
sync -f -- "${target_parent}"
sync -f -- "${state_dir}"

umask 022
write_depmod_config "${stamp}"
depmod "${kernel_release}"
refresh_initramfs "${kernel_release}"
verify_module_resolution

printf 'PASS_CMP90HX_STOCKFLOW_INSTALL_READY_REBOOT\n%s\n' "${state_file}"
