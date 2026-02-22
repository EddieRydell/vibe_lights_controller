#!/usr/bin/env python3
"""Convert Xilinx .bit file to .bin format for FPGA Manager.

The FPGA Manager on Zynq expects byte-swapped 32-bit words.
"""
import struct
import sys

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} input.bit output.bin")
    sys.exit(1)

with open(sys.argv[1], "rb") as f:
    data = f.read()

# Find sync word 0xAA995566
sync = b"\xaa\x99\x55\x66"
idx = data.find(sync)
if idx < 0:
    print("ERROR: sync word not found in .bit file")
    sys.exit(1)

# Extract from sync word onwards
raw = data[idx:]
# Pad to 4-byte boundary
while len(raw) % 4:
    raw += b"\x00"

# Byte-swap each 32-bit word (MSB->LSB for FPGA manager)
out = bytearray(len(raw))
for i in range(0, len(raw), 4):
    out[i]   = raw[i+3]
    out[i+1] = raw[i+2]
    out[i+2] = raw[i+1]
    out[i+3] = raw[i]

with open(sys.argv[2], "wb") as f:
    f.write(out)

print(f"Converted {len(out)} bytes: {sys.argv[1]} -> {sys.argv[2]}")
