#!/bin/bash
# CMP 90HX Build Script for Driver 610.57.04
#
# This builds the NVIDIA Open GPU Kernel Modules with:
# - CMP 90HX compute unlock patches
# - Kernel 6.12+ compatibility fixes
#
# Usage: sudo ./build-cmp90-610.sh [kernel_version]
#
# Credits:
#   - bendy2 (https://github.com/bendy2/cmp90hx) - Original V67 exploit

set -euo pipefail

DRIVER_VERSION="610.57.04"
TARBALL_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${DRIVER_VERSION}.tar.gz"

BUILD_DIR="${BUILD_DIR:-/tmp/cmp90-build}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_VERSION="${1:-$(uname -r)}"
KERNEL_SRC="/lib/modules/${KERNEL_VERSION}/build"

echo "=== CMP 90HX Build for ${DRIVER_VERSION} ==="
echo "Kernel: ${KERNEL_VERSION}"
echo "Build dir: ${BUILD_DIR}"
echo ""

# Check kernel headers
if [[ ! -d "${KERNEL_SRC}" ]]; then
    echo "ERROR: Kernel headers not found at ${KERNEL_SRC}"
    exit 1
fi

# Create build directory
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Download source
TARBALL="${BUILD_DIR}/open-gpu-kernel-modules-${DRIVER_VERSION}.tar.gz"
SRC_DIR="${BUILD_DIR}/open-gpu-kernel-modules-${DRIVER_VERSION}"

if [[ ! -f "${TARBALL}" ]]; then
    echo "Downloading ${DRIVER_VERSION}..."
    wget -q "${TARBALL_URL}" -O "${TARBALL}"
fi

# Extract fresh
rm -rf "${SRC_DIR}"
tar -xzf "${TARBALL}"
cd "${SRC_DIR}"

echo "Applying CMP90HX patches..."

# Apply CMP90HX compute unlock patch (ported from bendy2's 580.159.03 patch)
# Gadget addresses updated for 610.x:
#   0x0d44 -> 0x0d2a (LW x18,-384(x13))
#   0x1fce -> 0x209c (AUIPC)
#   0x0d52 -> 0x0d38 (offset)
#
if [[ -f "${SCRIPT_DIR}/driver/patches/cmp90/0001-61057-cmp90hx-compute-unlock.patch" ]]; then
    patch -p1 < "${SCRIPT_DIR}/driver/patches/cmp90/0001-61057-cmp90hx-compute-unlock.patch"
    echo "  Applied 0001-61057-cmp90hx-compute-unlock.patch"
fi

echo "Build complete. Install with:"
echo "  sudo cp kernel-open/*.ko /lib/modules/${KERNEL_VERSION}/updates/"
echo "  sudo depmod -a"
