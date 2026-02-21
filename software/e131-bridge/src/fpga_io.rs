use std::ptr;

/// FPGA register offsets (from AXI-Lite base address).
const REG_CTRL: usize = 0x0000;
const REG_STATUS: usize = 0x0004;
const REG_PIX_COUNT: usize = 0x0008;
const REG_CH_ENABLE: usize = 0x000C;
const REG_VERSION: usize = 0x0010;

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

    /// Write a single pixel's GRB data to a channel's pixel buffer.
    ///
    /// `channel`: 0-7, `index`: pixel index, `grb`: packed 24-bit GRB value.
    pub fn write_pixel(&self, channel: u8, index: u16, grb: u32) {
        let offset = CH_DATA_BASE + (channel as usize) * CH_DATA_STRIDE + (index as usize) * 4;
        self.write_reg(offset, grb & 0x00FF_FFFF);
    }

    /// Write a full channel's pixel data from a byte slice of RGB triplets.
    ///
    /// The input `rgb_data` is a flat array of [R, G, B, R, G, B, ...].
    /// This function converts RGB to GRB ordering as required by WS2812.
    pub fn write_pixels_bulk(&self, channel: u8, rgb_data: &[u8]) {
        let pixel_count = rgb_data.len() / 3;
        for i in 0..pixel_count {
            let r = rgb_data[i * 3] as u32;
            let g = rgb_data[i * 3 + 1] as u32;
            let b = rgb_data[i * 3 + 2] as u32;
            // WS2812 expects GRB order
            let grb = (g << 16) | (r << 8) | b;
            self.write_pixel(channel, i as u16, grb);
        }
    }

    /// Set the pixel count register (applies to all channels).
    pub fn set_pixel_count(&self, count: u16) {
        self.write_reg(REG_PIX_COUNT, count as u32);
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
