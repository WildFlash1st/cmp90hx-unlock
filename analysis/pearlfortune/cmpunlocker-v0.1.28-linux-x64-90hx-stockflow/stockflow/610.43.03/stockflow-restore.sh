#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

readonly restore_ack="I-ACCEPT-90HX-STOCKFLOW-RESTORE"
readonly project_id="cmpunlocker-90hx-stockflow"
readonly install_relative_dir="updates/cmpunlocker-90hx-stockflow"
readonly kernel_release="$(uname -r)"
readonly depmod_config="/etc/depmod.d/${project_id}.conf"

ack=""
dry_run=0

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo ./stockflow-restore.sh [--dry-run]
       --acknowledge ${restore_ack}

Removes the CMP 90HX stockflow modules from module resolution by archiving the
isolated updates/ directory. It does not hot-unload NVIDIA modules. Reboot after
a successful restore to return to the stock-loaded driver.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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

read_kv() {
    local file="$1"
    local key="$2"
    grep -E "^${key}=" "${file}" | tail -1 | cut -d= -f2-
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

require_command cut
require_command date
require_command depmod
require_command grep
require_command mv
require_command modinfo
require_command readlink
require_command sync

[[ "${EUID}" -eq 0 ]] || die "run as root"

readonly module_root="$(readlink -f -- "/lib/modules/${kernel_release}")"
readonly target="${module_root}/${install_relative_dir}"
readonly target_parent="$(dirname -- "${target}")"
readonly state_root="/var/lib/${project_id}"
readonly state_dir="${state_root}/${kernel_release}"
readonly state_file="${state_dir}/install.env"
readonly archive_dir="${state_root}/archives/${kernel_release}"

case "${target}" in
    "${module_root}"/updates/cmpunlocker-90hx-stockflow) ;;
    *) die "refusing unexpected install target: ${target}" ;;
esac

[[ -f "${state_file}" && ! -L "${state_file}" ]] || die "state file missing: ${state_file}"
[[ "$(read_kv "${state_file}" project_id)" == "${project_id}" ]] || die "state project mismatch"
[[ "$(read_kv "${state_file}" target_dir)" == "${target}" ]] || die "state target mismatch"
[[ -d "${target}" && ! -L "${target}" ]] || die "target is not installed: ${target}"
[[ -f "${target}/artifact.env" ]] || die "target lacks artifact.env marker"
if ! grep -Fq "CMP90_STOCKFLOW_REJOIN14" "${target}/nvidia.ko"; then
    grep -Fq "CMP90_STOCKFLOW_REJOIN13" "${target}/nvidia.ko" || \
        die "target nvidia.ko lacks rejoin13/rejoin14 marker"
fi

info "Installed target: ${target}"
info "State file: ${state_file}"

if [[ "${dry_run}" -eq 1 ]]; then
    info "DRY RUN: restore preflight passed; no files changed"
    exit 0
fi

[[ "${ack}" == "${restore_ack}" ]] || die "required acknowledgement: ${restore_ack}"

mkdir -p -- "${archive_dir}"
stamp="$(date -u +%Y%m%dT%H%M%SZ).$$"
removed="${archive_dir}/removed.${stamp}"
state_archive="${archive_dir}/install-state.${stamp}.env"
depmod_archive="${archive_dir}/depmod-config.${stamp}.conf"

mv -T -- "${target}" "${removed}"
mv -- "${state_file}" "${state_archive}"
if [[ -f "${depmod_config}" && ! -L "${depmod_config}" ]]; then
    if grep -Fq "${install_relative_dir}" "${depmod_config}"; then
        mv -- "${depmod_config}" "${depmod_archive}"
    else
        warn "leaving unrelated depmod config in place: ${depmod_config}"
    fi
fi
sync -f -- "${target_parent}"
sync -f -- "${archive_dir}"
sync -f -- "$(dirname -- "${depmod_config}")"

depmod "${kernel_release}"
refresh_initramfs "${kernel_release}"

resolved="$(readlink -f -- "$(modinfo -n nvidia)")" || die "cannot resolve nvidia after depmod"
[[ "${resolved}" != "${target}/nvidia.ko" ]] || die "nvidia still resolves to removed 90HX target"

printf 'PASS_CMP90HX_STOCKFLOW_RESTORE_READY_REBOOT\n%s\n' "${removed}"
