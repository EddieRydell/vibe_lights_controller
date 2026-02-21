#!/bin/bash
# Deploy e131-bridge binary + bitstream to PYNQ-Z2 board.
#
# Usage: ./deploy.sh [board_ip]
#   Default board IP: 192.168.2.99

set -euo pipefail

BOARD_IP="${1:-192.168.2.99}"
BOARD_USER="xilinx"
REMOTE_DIR="/home/xilinx/ws2812"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BINARY="$PROJECT_ROOT/software/e131-bridge/target/armv7-unknown-linux-gnueabihf/release/e131-bridge"
BITSTREAM="$PROJECT_ROOT/fpga/output/system.bit"
HWH="$PROJECT_ROOT/fpga/output/system.hwh"

echo "=== Deploying to $BOARD_USER@$BOARD_IP ==="

# Check that binary exists
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    echo "Run: cd software/e131-bridge && cross build --target armv7-unknown-linux-gnueabihf --release"
    exit 1
fi

# Create remote directory
ssh "$BOARD_USER@$BOARD_IP" "mkdir -p $REMOTE_DIR"

# Copy binary
echo "Copying e131-bridge binary..."
scp "$BINARY" "$BOARD_USER@$BOARD_IP:$REMOTE_DIR/e131-bridge"

# Copy bitstream if it exists
if [ -f "$BITSTREAM" ]; then
    echo "Copying bitstream..."
    scp "$BITSTREAM" "$BOARD_USER@$BOARD_IP:$REMOTE_DIR/system.bit"
fi

if [ -f "$HWH" ]; then
    echo "Copying hardware handoff..."
    scp "$HWH" "$BOARD_USER@$BOARD_IP:$REMOTE_DIR/system.hwh"
fi

# Copy default config if no config exists on board
ssh "$BOARD_USER@$BOARD_IP" "test -f $REMOTE_DIR/config.toml" 2>/dev/null || {
    echo "Creating default config.toml on board..."
    cat <<'EOF' | ssh "$BOARD_USER@$BOARD_IP" "cat > $REMOTE_DIR/config.toml"
# E1.31 to WS2812 Bridge Configuration

fpga_base_addr = 0x43C00000
target_fps = 40

[[outputs]]
channel = 0
universes = [1, 2, 3]
pixel_count = 510

[[outputs]]
channel = 1
universes = [4, 5, 6]
pixel_count = 510

[[outputs]]
channel = 2
universes = [7, 8, 9]
pixel_count = 510

[[outputs]]
channel = 3
universes = [10, 11, 12]
pixel_count = 510

[[outputs]]
channel = 4
universes = [13, 14, 15]
pixel_count = 510

[[outputs]]
channel = 5
universes = [16, 17, 18]
pixel_count = 510

[[outputs]]
channel = 6
universes = [19, 20, 21]
pixel_count = 510

[[outputs]]
channel = 7
universes = [22, 23, 24]
pixel_count = 510
EOF
}

echo ""
echo "=== Deploy complete ==="
echo "On the board, run:"
echo "  cd $REMOTE_DIR"
echo "  sudo ./load_bitstream.sh  # if bitstream was updated"
echo "  sudo ./e131-bridge --config config.toml"
