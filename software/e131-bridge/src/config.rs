use serde::Deserialize;
use std::path::Path;

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

/// Configuration for a single WS2812 output channel.
#[derive(Debug, Deserialize)]
pub struct OutputConfig {
    /// Output channel index (0-7)
    pub channel: u8,

    /// E1.31 universe numbers that feed this output (in order)
    pub universes: Vec<u16>,

    /// Total number of pixels on this output
    pub pixel_count: u16,
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
            if output.pixel_count == 0 || output.pixel_count > 680 {
                return Err(
                    format!("Pixel count {} out of range (1-680)", output.pixel_count).into(),
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
