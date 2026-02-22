use crate::config::ColorOrder;
use std::ptr;

/// FPGA register offsets (from AXI-Lite base address).
const REG_CTRL: usize = 0x0000;
const REG_STATUS: usize = 0x0004;
const REG_PIX_COUNT: usize = 0x0008;
const REG_CH_ENABLE: usize = 0x000C;
const REG_VERSION: usize = 0x0010;

/// Per-channel pixel count registers (v2.0.0+).
const REG_CH0_PIX_COUNT: usize = 0x0014;
const REG_CH1_PIX_COUNT: usize = 0x0018;
const REG_CH2_PIX_COUNT: usize = 0x001C;
const REG_CH3_PIX_COUNT: usize = 0x0020;
const REG_CH4_PIX_COUNT: usize = 0x0024;
const REG_CH5_PIX_COUNT: usize = 0x0028;
const REG_CH6_PIX_COUNT: usize = 0x002C;
const REG_CH7_PIX_COUNT: usize = 0x0030;

/// Per-channel pixel format register (bit N=1 -> channel N uses 32-bit RGBW).
const REG_PIX_FMT: usize = 0x0034;

/// Per-channel pixel count register offsets, indexed by channel number.
const CH_PIX_COUNT_REGS: [usize; 8] = [
    REG_CH0_PIX_COUNT,
    REG_CH1_PIX_COUNT,
    REG_CH2_PIX_COUNT,
    REG_CH3_PIX_COUNT,
    REG_CH4_PIX_COUNT,
    REG_CH5_PIX_COUNT,
    REG_CH6_PIX_COUNT,
    REG_CH7_PIX_COUNT,
];

/// Channel data base offsets: channel N data starts at 0x1000 * (N+1).
const CH_DATA_BASE: usize = 0x1000;
const CH_DATA_STRIDE: usize = 0x1000;

/// Total mmap region size (covers all 8 channels + control registers).
const MMAP_SIZE: usize = 0x10000; // 64 KB

/// STATUS register bit masks.
const STATUS_BUSY: u32 = 1 << 0;
const STATUS_DONE: u32 = 1 << 1;

/// Memory-mapped FPGA register interface.
///
/// Opens /dev/mem and mmaps the AXI-Lite register region. All register
/// access uses volatile reads/writes for correct hardware interaction.
pub struct FpgaRegisters {
    base: *mut u8,
    #[allow(dead_code)]
    fd: i32,
}

// Safety: the mmap'd region is only accessed through volatile operations
// and we ensure single-threaded access in main.rs.
unsafe impl Send for FpgaRegisters {}

impl FpgaRegisters {
    /// Open /dev/mem and mmap the FPGA register region.
    ///
    /// # Safety
    /// Requires root privileges. The base_addr must be the correct
    /// AXI-Lite base address for the WS2812 IP core.
    pub fn new(base_addr: u64) -> Result<Self, String> {
        unsafe {
            let fd = libc::open(
                b"/dev/mem\0".as_ptr() as *const libc::c_char,
                libc::O_RDWR | libc::O_SYNC,
            );
            if fd < 0 {
                return Err(format!(
                    "Failed to open /dev/mem (are you root?): errno {}",
                    *libc::__errno_location()
                ));
            }

            let base = libc::mmap(
                ptr::null_mut(),
                MMAP_SIZE,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                base_addr as libc::off_t,
            );

            if base == libc::MAP_FAILED {
                libc::close(fd);
                return Err(format!(
                    "Failed to mmap 0x{:X}: errno {}",
                    base_addr,
                    *libc::__errno_location()
                ));
            }

            Ok(FpgaRegisters {
                base: base as *mut u8,
                fd,
            })
        }
    }

    /// Write a 32-bit value to a register at the given byte offset.
    fn write_reg(&self, offset: usize, value: u32) {
        unsafe {
            let addr = self.base.add(offset) as *mut u32;
            ptr::write_volatile(addr, value);
        }
    }

    /// Read a 32-bit value from a register at the given byte offset.
    fn read_reg(&self, offset: usize) -> u32 {
        unsafe {
            let addr = self.base.add(offset) as *const u32;
            ptr::read_volatile(addr)
        }
    }

    /// Write a single pixel's data to a channel's pixel buffer.
    ///
    /// `channel`: 0-7, `index`: pixel index, `value`: packed pixel value
    /// (24-bit for RGB, 32-bit for RGBW).
    pub fn write_pixel(&self, channel: u8, index: u16, value: u32) {
        let offset = CH_DATA_BASE + (channel as usize) * CH_DATA_STRIDE + (index as usize) * 4;
        self.write_reg(offset, value);
    }

    /// Write a full channel's pixel data from a byte slice with configurable color order.
    ///
    /// For RGB mode: `data` is [R, G, B, R, G, B, ...] (or whatever the sACN source sends).
    /// For RGBW mode: `data` is [R, G, B, W, R, G, B, W, ...].
    ///
    /// Color reordering is done in software based on `color_order`.
    pub fn write_pixels_bulk(
        &self,
        channel: u8,
        data: &[u8],
        color_order: ColorOrder,
        rgbw: bool,
    ) {
        let bytes_per_pixel = if rgbw { 4 } else { 3 };
        let pixel_count = data.len() / bytes_per_pixel;
        let base_offset = CH_DATA_BASE + (channel as usize) * CH_DATA_STRIDE;

        for i in 0..pixel_count {
            let off = i * bytes_per_pixel;
            let r = data[off] as u32;
            let g = data[off + 1] as u32;
            let b = data[off + 2] as u32;

            let (c1, c2, c3) = color_order.reorder(r as u8, g as u8, b as u8);
            let packed = if rgbw {
                let w = data[off + 3] as u32;
                ((c1 as u32) << 24) | ((c2 as u32) << 16) | ((c3 as u32) << 8) | w
            } else {
                ((c1 as u32) << 16) | ((c2 as u32) << 8) | (c3 as u32)
            };

            let offset = base_offset + i * 4;
            self.write_reg(offset, packed);
        }
    }

    /// Set the global pixel count register (backward compat — sets CH0 pixel count).
    pub fn set_pixel_count(&self, count: u16) {
        self.write_reg(REG_PIX_COUNT, count as u32);
    }

    /// Set the pixel count for a specific channel (v2.0.0+).
    pub fn set_channel_pixel_count(&self, channel: u8, count: u16) {
        assert!(channel < 8, "Channel must be 0-7");
        self.write_reg(CH_PIX_COUNT_REGS[channel as usize], count as u32);
    }

    /// Set the pixel format register (per-channel RGBW mode bitmask).
    /// Bit N = 1 means channel N uses 32-bit RGBW pixels.
    pub fn set_pixel_format(&self, mask: u8) {
        self.write_reg(REG_PIX_FMT, mask as u32);
    }

    /// Set the channel enable bitmask.
    pub fn set_channel_enable(&self, mask: u8) {
        self.write_reg(REG_CH_ENABLE, mask as u32);
    }

    /// Trigger WS2812 output (write 1 to CTRL.start).
    pub fn trigger_output(&self) {
        self.write_reg(REG_CTRL, 0x01);
    }

    /// Check if the serializer is currently busy.
    pub fn is_busy(&self) -> bool {
        (self.read_reg(REG_STATUS) & STATUS_BUSY) != 0
    }

    /// Check if the serializer is done.
    pub fn is_done(&self) -> bool {
        (self.read_reg(REG_STATUS) & STATUS_DONE) != 0
    }

    /// Read the IP version register.
    pub fn read_version(&self) -> u32 {
        self.read_reg(REG_VERSION)
    }

    /// Wait for the current output cycle to complete (polling).
    /// Returns Ok(()) when done, Err if timeout.
    pub fn wait_for_done(&self, timeout_us: u64) -> Result<(), String> {
        let start = std::time::Instant::now();
        let timeout = std::time::Duration::from_micros(timeout_us);

        while self.is_busy() {
            if start.elapsed() > timeout {
                return Err("Timeout waiting for FPGA output to complete".into());
            }
            std::thread::yield_now();
        }
        Ok(())
    }
}

impl Drop for FpgaRegisters {
    fn drop(&mut self) {
        unsafe {
            libc::munmap(self.base as *mut libc::c_void, MMAP_SIZE);
            libc::close(self.fd);
        }
    }
}
