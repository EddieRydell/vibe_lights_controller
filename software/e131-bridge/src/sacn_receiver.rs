use sacn::receive::SacnReceiver;
use std::collections::HashMap;
use std::net::SocketAddr;

/// Maximum DMX channels per universe.
const DMX_CHANNELS_PER_UNIVERSE: usize = 512;

/// Pixels per universe (512 channels / 3 channels per pixel = 170 pixels).
pub const PIXELS_PER_UNIVERSE: usize = 170;

/// Per-universe DMX data buffer.
pub struct UniverseData {
    /// Raw DMX channel data (up to 512 bytes, index 0 = DMX channel 1).
    pub data: [u8; DMX_CHANNELS_PER_UNIVERSE],
    /// Number of valid bytes in data.
    pub len: usize,
    /// Whether new data has arrived since last consumed.
    pub dirty: bool,
}

impl Default for UniverseData {
    fn default() -> Self {
        UniverseData {
            data: [0u8; DMX_CHANNELS_PER_UNIVERSE],
            len: 0,
            dirty: false,
        }
    }
}

/// E1.31/sACN receiver that listens for universe data.
pub struct E131Receiver {
    receiver: SacnReceiver,
    /// Per-universe data storage, keyed by universe number.
    pub universe_data: HashMap<u16, UniverseData>,
}

impl E131Receiver {
    /// Create a new E1.31 receiver bound to the standard sACN port (5568).
    ///
    /// `universes` is the list of universe numbers to subscribe to.
    pub fn new(universes: &[u16]) -> Result<Self, Box<dyn std::error::Error>> {
        let addr: SocketAddr = "0.0.0.0:5568".parse()?;
        let mut receiver = SacnReceiver::with_ip(addr, None)?;

        // Register/subscribe to each universe
        for &universe in universes {
            receiver.listen_universes(&[universe])?;
        }

        let universe_data: HashMap<u16, UniverseData> = universes
            .iter()
            .map(|&u| (u, UniverseData::default()))
            .collect();

        log::info!(
            "E1.31 receiver listening on port 5568 for {} universes",
            universes.len()
        );

        Ok(E131Receiver {
            receiver,
            universe_data,
        })
    }

    /// Receive pending E1.31 data with a timeout.
    ///
    /// Returns the number of universes that received new data.
    /// Updates internal universe_data buffers and sets dirty flags.
    pub fn receive(&mut self, timeout_ms: Option<u64>) -> Result<usize, Box<dyn std::error::Error>> {
        let timeout = timeout_ms.map(std::time::Duration::from_millis);
        let mut updated = 0;

        match self.receiver.recv(timeout) {
            Ok(packets) => {
                for packet in packets {
                    let universe = packet.universe;
                    if let Some(entry) = self.universe_data.get_mut(&universe) {
                        let dmx_data = &packet.values;
                        // sACN data includes start code at index 0; DMX data starts at index 1
                        let data_start = if dmx_data.len() > 1 { 1 } else { 0 };
                        let copy_len = (dmx_data.len() - data_start).min(DMX_CHANNELS_PER_UNIVERSE);
                        entry.data[..copy_len]
                            .copy_from_slice(&dmx_data[data_start..data_start + copy_len]);
                        entry.len = copy_len;
                        entry.dirty = true;
                        updated += 1;
                    }
                }
            }
            Err(e) => {
                // Timeout is normal, other errors should be logged
                let err_str = e.to_string();
                if !err_str.contains("timed out") && !err_str.contains("WouldBlock") {
                    log::warn!("E1.31 receive error: {}", e);
                }
            }
        }

        Ok(updated)
    }

    /// Assemble pixel data for a given output channel from its configured universes.
    ///
    /// Returns a Vec<u8> of RGB triplets assembled from the universe data.
    /// Each universe contributes up to 170 pixels (510 DMX channels).
    pub fn assemble_channel_data(
        &self,
        universes: &[u16],
        pixel_count: u16,
    ) -> Vec<u8> {
        let total_bytes = pixel_count as usize * 3;
        let mut result = vec![0u8; total_bytes];
        let mut offset = 0;

        for &universe in universes {
            if offset >= total_bytes {
                break;
            }
            if let Some(udata) = self.universe_data.get(&universe) {
                let available = udata.len.min(PIXELS_PER_UNIVERSE * 3);
                let copy_len = available.min(total_bytes - offset);
                result[offset..offset + copy_len].copy_from_slice(&udata.data[..copy_len]);
                offset += copy_len;
            }
        }

        result
    }

    /// Check if any universe has new data since the last call to clear_dirty().
    pub fn any_dirty(&self) -> bool {
        self.universe_data.values().any(|u| u.dirty)
    }

    /// Clear all dirty flags.
    pub fn clear_dirty(&mut self) {
        for entry in self.universe_data.values_mut() {
            entry.dirty = false;
        }
    }
}
