#!/usr/bin/env python3
"""FPGA register and data path test for WS2812 controller (v2.0.0)."""
import mmap, os, struct, time

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x10000, offset=0x43C00000)

def write_reg(offset, value):
    m[offset:offset+4] = struct.pack('<I', value)

def read_reg(offset):
    return struct.unpack('<I', m[offset:offset+4])[0]

print('=== FPGA Register Test (v2.0.0) ===')
version = read_reg(0x10)
print(f'VERSION:  0x{version:08X}')
assert version == 0x00020000, f'Expected v2.0.0 (0x00020000), got 0x{version:08X}'
print(f'STATUS:   0x{read_reg(0x04):08X}')

print()
print('=== Per-channel pixel count registers ===')
# Write different pixel counts to each channel
ch_pix_counts = [300, 144, 60, 512, 170, 256, 100, 1]
for ch in range(8):
    offset = 0x0014 + ch * 4
    write_reg(offset, ch_pix_counts[ch])

# Read them back
for ch in range(8):
    offset = 0x0014 + ch * 4
    val = read_reg(offset)
    expected = ch_pix_counts[ch]
    status = 'PASS' if val == expected else f'FAIL (got {val})'
    print(f'  CH{ch}_PIX_COUNT: {val} (expected {expected}) — {status}')

# Test backward compat: writing to 0x0008 should set CH0
write_reg(0x0008, 42)
ch0_val = read_reg(0x0014)
compat_val = read_reg(0x0008)
print(f'  Backward compat: wrote 42 to 0x0008, CH0_PIX_COUNT={ch0_val}, PIX_COUNT readback={compat_val}')
assert ch0_val == 42, f'Backward compat failed: CH0_PIX_COUNT={ch0_val}'
assert compat_val == 42, f'Backward compat readback failed: PIX_COUNT={compat_val}'
print('  Backward compat: PASS')

# Restore CH0
write_reg(0x0014, ch_pix_counts[0])

print()
print('=== PIX_FMT register (RGBW mode) ===')
# Set channels 1 and 5 to RGBW mode
write_reg(0x0034, 0x22)  # bits 1 and 5
val = read_reg(0x0034)
print(f'  PIX_FMT: 0x{val:02X} (expected 0x22) — {"PASS" if val == 0x22 else "FAIL"}')
# Clear it
write_reg(0x0034, 0x00)

print()
print('=== Basic pixel data test (RGB mode) ===')
# Write pixel data to channel 0
write_reg(0x1000, 0x00FF00)  # CH0 pixel 0: Red (GRB)
write_reg(0x1004, 0xFF0000)  # CH0 pixel 1: Green (GRB)
write_reg(0x1008, 0x0000FF)  # CH0 pixel 2: Blue (GRB)

# Set pixel count = 3 for CH0
write_reg(0x0014, 3)
print(f'CH0_PIX_COUNT: {read_reg(0x0014)}')

# Enable channel 0 only
write_reg(0x000C, 0x01)
print(f'CH_ENABLE: 0x{read_reg(0x000C):02X}')

# Trigger output
write_reg(0x0000, 0x01)
status = read_reg(0x04)
print(f'STATUS after start: 0x{status:08X} (bit0=busy expected)')

# Wait for completion
time.sleep(0.01)
status = read_reg(0x04)
print(f'STATUS after wait:  0x{status:08X} (bit1=done expected)')

print()
print('=== RGBW pixel test (32-bit mode) ===')
# Set channel 1 to RGBW mode
write_reg(0x0034, 0x02)  # bit 1 = channel 1 RGBW

# Write 32-bit RGBW pixels to channel 1
write_reg(0x2000, 0xFF000000)  # CH1 pixel 0: full first component
write_reg(0x2004, 0x00FF0000)  # CH1 pixel 1: full second component
write_reg(0x2008, 0x0000FF00)  # CH1 pixel 2: full third component
write_reg(0x200C, 0x000000FF)  # CH1 pixel 3: full white

# Set CH1 pixel count = 4
write_reg(0x0018, 4)
print(f'CH1_PIX_COUNT: {read_reg(0x0018)}')

# Enable channels 0 and 1
write_reg(0x000C, 0x03)

# Trigger output
write_reg(0x0000, 0x01)
time.sleep(0.01)
status = read_reg(0x04)
print(f'STATUS after RGBW test: 0x{status:08X} (expect 0x02 = done)')

# Clean up
write_reg(0x0034, 0x00)

print()
print('=== All 8 channels with different pixel counts ===')
for ch in range(8):
    base = 0x1000 + (ch * 0x1000)
    write_reg(base, 0xFFFFFF)  # White pixel
    write_reg(0x0014 + ch * 4, 1)  # 1 pixel per channel

write_reg(0x000C, 0xFF)    # Enable all 8 channels
write_reg(0x0000, 0x01)    # Start

time.sleep(0.01)
status = read_reg(0x04)
print(f'STATUS: 0x{status:08X} (expect 0x02 = done)')

if status & 0x02:
    print('ALL CHANNELS COMPLETED SUCCESSFULLY')
else:
    print(f'WARNING: channels may not have finished (status=0x{status:02X})')

print()
print('=== Throughput test (simulated 300 fps) ===')
# Write 170 pixels to channel 0 and measure how fast we can push frames
pixels = 170
for i in range(pixels):
    write_reg(0x1000 + i*4, (i & 0xFF) << 16 | (i & 0xFF) << 8 | (i & 0xFF))

write_reg(0x0014, pixels)  # CH0 pixel count
write_reg(0x000C, 0x01)

frames = 100
t0 = time.monotonic()
for _ in range(frames):
    write_reg(0x0000, 0x01)  # Start
    # Poll for done
    while not (read_reg(0x04) & 0x02):
        pass
t1 = time.monotonic()

elapsed = t1 - t0
fps = frames / elapsed
frame_us = (elapsed / frames) * 1_000_000
print(f'{frames} frames of {pixels} pixels in {elapsed:.3f}s')
print(f'Frame time: {frame_us:.0f} us')
print(f'Achievable FPS: {fps:.0f}')
print(f'WS2812 theoretical min frame time: {pixels * 30 + 50:.0f} us '
      f'({1_000_000 / (pixels * 30 + 50):.0f} fps max)')

print()
print('=== Per-channel throughput test (mixed lengths) ===')
# CH0: 300 pixels, CH1: 10 pixels — CH1 should finish much faster
write_reg(0x0014, 300)  # CH0
write_reg(0x0018, 10)   # CH1
for i in range(300):
    write_reg(0x1000 + i*4, 0x101010)
for i in range(10):
    write_reg(0x2000 + i*4, 0x202020)

write_reg(0x000C, 0x03)  # Enable CH0 and CH1
write_reg(0x0000, 0x01)  # Start
time.sleep(0.02)
status = read_reg(0x04)
print(f'STATUS after mixed-length test: 0x{status:08X} (expect 0x02 = done)')

m.close()
os.close(fd)
