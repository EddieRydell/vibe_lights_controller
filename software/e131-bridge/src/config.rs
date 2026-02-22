use serde::Deserialize;
use std::path::Path;

/// Color channel ordering for LED strips.
///
/// Different LED chipsets expect color data in different byte orders.
/// The reordering is done in software (Rust) at zero FPGA cost.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "UPPERCASE")]
pub enum ColorOrder {
    RGB,
    GRB,
    BRG,
    RBG,
    GBR,
    BGR,
}

impl Default for ColorOrder {
    fn default() -> Self {
        ColorOrder::GRB
    }
}

impl ColorOrder {
    /// Reorder an (R, G, B) triplet into the target color order.
    /// Returns (first, second, third) in the order the LED expects.
    pub fn reorder(self, r: u8, g: u8, b: u8) -> (u8, u8, u8) {
        match self {
            ColorOrder::RGB => (r, g, b),
            ColorOrder::GRB => (g, r, b),
            ColorOrder::BRG => (b, r, g),
            ColorOrder::RBG => (r, b, g),
            ColorOrder::GBR => (g, b, r),
            ColorOrder::BGR => (b, g, r),
        }
    }
}

/// Pixel type for an LED strip.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
pub enum PixelType {
    /// 24-bit pixels (3 bytes: e.g. WS2812 RGB/GRB)
    Rgb,
    /// 32-bit pixels (4 bytes: e.g. SK6812 RGBW)
    Rgbw,
}

impl Default for PixelType {
    fn default() -> Self {
        PixelType::Rgb
    }
}

impl PixelType {
    /// Bytes per pixel for this pixel type.
    pub fn bytes_per_pixel(self) -> usize {
        match self {
            PixelType::Rgb => 3,
            PixelType::Rgbw => 4,
        }
    }
}

/// Top-level configuration loaded from TOML file.
#[derive(Debug, Deserialize)]
pub struct Config {
    /// FPGA AXI-Lite base address (default: 0x43C0_0000)
    #[serde(default = "default_fpga_base")]
    pub fpga_base_addr: u64,

    /// Target frame rate in Hz (default: 40)
    #[serde(default = "default_fps")]
    pub target_fps: u32,

    /// Output channel configurations
    pub outputs: Vec<OutputConfig>,
}

/// Configuration for a single WS2812/SK6812 output channel.
#[derive(Debug, Deserialize)]
pub struct OutputConfig {
    /// Output channel index (0-7)
    pub channel: u8,

    /// E1.31 universe numbers that feed this output (in order)
    pub universes: Vec<u16>,

    /// Total number of pixels on this output
    pub pixel_count: u16,

    /// Color channel ordering (default: GRB for WS2812)
    #[serde(default)]
    pub color_order: ColorOrder,

    /// Pixel type — Rgb (24-bit) or Rgbw (32-bit) (default: Rgb)
    #[serde(default)]
    pub pixel_type: PixelType,
}

fn default_fpga_base() -> u64 {
    0x43C0_0000
}

fn default_fps() -> u32 {
    40
}

impl Config {
    /// Load configuration from a TOML file.
    pub fn load(path: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        let contents = std::fs::read_to_string(path)?;
        let config: Config = toml::from_str(&contents)?;
        config.validate()?;
        Ok(config)
    }

    /// Create a default configuration (8 outputs, 3 universes each, 170 pixels/universe).
    pub fn default_config() -> Self {
        let outputs = (0..8u8)
            .map(|ch| {
                let base_universe = (ch as u16) * 3 + 1;
                OutputConfig {
                    channel: ch,
                    universes: vec![base_universe, base_universe + 1, base_universe + 2],
                    pixel_count: 510,
                    color_order: ColorOrder::default(),
                    pixel_type: PixelType::default(),
                }
            })
            .collect();

        Config {
            fpga_base_addr: default_fpga_base(),
            target_fps: default_fps(),
            outputs,
        }
    }

    fn validate(&self) -> Result<(), Box<dyn std::error::Error>> {
        for output in &self.outputs {
            if output.channel > 7 {
                return Err(format!("Channel {} out of range (0-7)", output.channel).into());
            }
            let max_pixels = if output.pixel_type == PixelType::Rgbw {
                680
            } else {
                680
            };
            if output.pixel_count == 0 || output.pixel_count > max_pixels {
                return Err(
                    format!(
                        "Pixel count {} out of range (1-{})",
                        output.pixel_count, max_pixels
                    )
                    .into(),
                );
            }
            if output.pixel_type == PixelType::Rgbw && output.pixel_count > 680 {
                log::warn!(
                    "Channel {}: RGBW with {} pixels uses more buffer space (4 bytes/pixel)",
                    output.channel,
                    output.pixel_count
                );
            }
            if output.universes.is_empty() {
                return Err(
                    format!("Channel {} has no universes configured", output.channel).into(),
                );
            }
            for &u in &output.universes {
                if u == 0 || u > 63999 {
                    return Err(format!("Universe {} out of E1.31 range (1-63999)", u).into());
                }
            }
        }
        Ok(())
    }

    /// Get all unique universe numbers from the configuration.
    pub fn all_universes(&self) -> Vec<u16> {
        let mut universes: Vec<u16> = self
            .outputs
            .iter()
            .flat_map(|o| o.universes.iter().copied())
            .collect();
        universes.sort_unstable();
        universes.dedup();
        universes
    }
}
