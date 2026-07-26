#!/bin/bash
set -euo pipefail
SRC_DIR="${CMPUNLOCKER_BUILD_DIR:-/build/nv-build}/open-gpu-kernel-modules-${CMPUNLOCKER_DRIVER_VERSION:-610.43.03}"

# Fix backlight rename
BACKLIGHT="${SRC_DIR}/kernel-open/nvidia/nv-backlight.c"
[ -f "$BACKLIGHT" ] && sed -i 's/get_backlight_device_by_name(/backlight_device_get_by_name(/g' "$BACKLIGHT" && echo "Fixed backlight"

# Fix of_dma_configure 3 args
PLATFORM="${SRC_DIR}/kernel-open/nvidia/nv-platform.c"
[ -f "$PLATFORM" ] && sed -i 's/of_dma_configure(dev, np)/of_dma_configure(dev, np, false)/g' "$PLATFORM" && echo "Fixed of_dma_configure"

# Fix nv-linux.h: add missing DMA includes
NVLINUX="${SRC_DIR}/kernel-open/common/inc/nv-linux.h"
if [ -f "$NVLINUX" ] && ! grep -q "linux/dma-map-ops.h" "$NVLINUX"; then
    sed -i '/#include <linux\/pci.h>/a #include <linux/dma-map-ops.h>\n#include <linux/dma-direct.h>' "$NVLINUX" 2>/dev/null || \
    sed -i '/#include "nv.h"/a #include <linux/dma-map-ops.h>\n#include <linux/dma-direct.h>' "$NVLINUX" 2>/dev/null || \
    sed -i '1a #include <linux/dma-map-ops.h>\n#include <linux/dma-direct.h>' "$NVLINUX"
    echo "Fixed nv-linux.h includes"
fi

# Fix of_property_for_each_u32 args count
DSI="${SRC_DIR}/kernel-open/nvidia/nv-dsi-parse-panel-props.c"
if [ -f "$DSI" ]; then
    sed -i 's/of_property_for_each_u32(np_dsi_panel, "nvidia,dsi-dpd-pads", temp)/of_property_for_each_u32(np_dsi_panel, "nvidia,dsi-dpd-pads", temp, index, temp)/g' "$DSI" 2>/dev/null || true
    echo "Fixed dsi-parse"
fi
