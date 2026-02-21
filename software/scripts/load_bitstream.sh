#!/bin/bash
# Load the WS2812 controller bitstream on the PYNQ-Z2.
#
# Usage: sudo ./load_bitstream.sh [bitstream_path]
#   Default: /home/xilinx/ws2812/system.bit
#
# This script uses the Linux FPGA Manager sysfs interface to load
# the bitstream without needing PYNQ Python.

set -euo pipefail

BITSTREAM="${1:-/home/xilinx/ws2812/system.bit}"
FPGA_MANAGER="/sys/class/fpga_manager/fpga0"

if [ ! -f "$BITSTREAM" ]; then
    echo "ERROR: Bitstream not found: $BITSTREAM"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

echo "Loading bitstream: $BITSTREAM"

# Method 1: Using fpga_manager sysfs (works on PYNQ v3.0)
if [ -d "$FPGA_MANAGER" ]; then
    # Copy bitstream to firmware directory
    cp "$BITSTREAM" /lib/firmware/ws2812_system.bit

    # Set flags for full bitstream programming
    echo 0 > "$FPGA_MANAGER/flags"

    # Trigger programming
    echo "ws2812_system.bit" > "$FPGA_MANAGER/firmware"

    # Check state
    STATE=$(cat "$FPGA_MANAGER/state")
    echo "FPGA Manager state: $STATE"

    if [ "$STATE" = "operating" ]; then
        echo "Bitstream loaded successfully!"
    else
        echo "WARNING: FPGA state is '$STATE', expected 'operating'"
        echo "Trying alternative method..."
        # Fall through to method 2
    fi
fi

# Method 2: Using PYNQ Python overlay (fallback)
if [ "$STATE" != "operating" ] 2>/dev/null; then
    echo "Attempting to load via PYNQ Python..."
    python3 -c "
from pynq import Overlay
ol = Overlay('$BITSTREAM')
print('Bitstream loaded via PYNQ Overlay')
print('IP blocks:', list(ol.ip_dict.keys()))
" 2>/dev/null || {
        echo "PYNQ Python method also failed."
        echo "Try loading from a Jupyter notebook: Overlay('$BITSTREAM')"
        exit 1
    }
fi

echo ""
echo "FPGA bitstream loaded. The WS2812 controller is ready."
echo "Verify with: devmem 0x43C00010  (should show version register)"
