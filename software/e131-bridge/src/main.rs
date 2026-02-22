mod config;
mod fpga_io;
mod sacn_receiver;

use clap::Parser;
use config::{Config, PixelType};
use fpga_io::FpgaRegisters;
use log::{error, info, warn};
use sacn_receiver::E131Receiver;
use std::path::PathBuf;
use std::time::{Duration, Instant};

#[derive(Parser, Debug)]
#[command(name = "e131-bridge", about = "E1.31/sACN to FPGA WS2812 bridge")]
struct Args {
    /// Path to TOML configuration file
    #[arg(short, long, default_value = "config.toml")]
    config: PathBuf,

    /// Use default configuration (ignore config file)
    #[arg(long)]
    default_config: bool,

    /// Print FPGA version register and exit
    #[arg(long)]
    version_check: bool,
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let args = Args::parse();

    // Load configuration
    let config = if args.default_config {
        info!("Using default configuration");
        Config::default_config()
    } else {
        match Config::load(&args.config) {
            Ok(c) => {
                info!("Loaded config from {}", args.config.display());
                c
            }
            Err(e) => {
                error!("Failed to load config {}: {}", args.config.display(), e);
                std::process::exit(1);
            }
        }
    };

    // Initialize FPGA registers
    let fpga = match FpgaRegisters::new(config.fpga_base_addr) {
        Ok(f) => f,
        Err(e) => {
            error!("Failed to initialize FPGA: {}", e);
            error!("Make sure you're running as root and the bitstream is loaded.");
            std::process::exit(1);
        }
    };

    // Version check mode
    if args.version_check {
        let version = fpga.read_version();
        info!(
            "FPGA IP version: {}.{}.{}",
            (version >> 16) & 0xFF,
            (version >> 8) & 0xFF,
            version & 0xFF
        );
        return;
    }

    info!(
        "FPGA IP version: 0x{:08X}",
        fpga.read_version()
    );

    // Set per-channel pixel counts
    for output in &config.outputs {
        fpga.set_channel_pixel_count(output.channel, output.pixel_count);
        info!(
            "Channel {}: {} pixels, {:?}, {:?}",
            output.channel, output.pixel_count, output.color_order, output.pixel_type
        );
    }

    // Compute and set pixel format mask (RGBW channels)
    let pix_fmt_mask: u8 = config
        .outputs
        .iter()
        .filter(|o| o.pixel_type == PixelType::Rgbw)
        .fold(0u8, |mask, o| mask | (1 << o.channel));
    fpga.set_pixel_format(pix_fmt_mask);
    if pix_fmt_mask != 0 {
        info!("RGBW pixel format mask: 0b{:08b}", pix_fmt_mask);
    }

    // Set channel enable mask
    let ch_enable: u8 = config.outputs.iter().fold(0u8, |mask, o| mask | (1 << o.channel));
    fpga.set_channel_enable(ch_enable);
    info!("Channel enable mask: 0b{:08b}", ch_enable);

    // Initialize E1.31 receiver
    let universes = config.all_universes();
    info!("Subscribing to E1.31 universes: {:?}", universes);

    let mut receiver = match E131Receiver::new(&universes) {
        Ok(r) => r,
        Err(e) => {
            error!("Failed to start E1.31 receiver: {}", e);
            std::process::exit(1);
        }
    };

    // Main loop
    let frame_interval = Duration::from_micros(1_000_000 / config.target_fps as u64);
    let mut last_frame = Instant::now();
    let mut frame_count: u64 = 0;
    let mut stats_time = Instant::now();

    info!(
        "Starting main loop at {} fps target",
        config.target_fps
    );

    // Install ctrl-c handler (signal_hook sets flag to true on signal)
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    ctrlc_setup(&stop);

    while !stop.load(std::sync::atomic::Ordering::Relaxed) {
        // Receive E1.31 data (non-blocking with short timeout)
        let receive_timeout = frame_interval
            .saturating_sub(last_frame.elapsed())
            .as_millis() as u64;
        let receive_timeout = receive_timeout.max(1);

        match receiver.receive(Some(receive_timeout)) {
            Ok(_) => {}
            Err(e) => {
                warn!("Receive error: {}", e);
            }
        }

        // Check if it's time for a new frame
        if last_frame.elapsed() < frame_interval {
            continue;
        }
        last_frame = Instant::now();

        // Wait for any previous FPGA output to complete
        if fpga.is_busy() {
            if let Err(e) = fpga.wait_for_done(50_000) {
                warn!("FPGA busy timeout: {}", e);
                continue;
            }
        }

        // Write pixel data to FPGA for each configured output
        if receiver.any_dirty() {
            for output in &config.outputs {
                let bpp = output.pixel_type.bytes_per_pixel();
                let pixel_data = receiver.assemble_channel_data(
                    &output.universes,
                    output.pixel_count,
                    bpp,
                );
                let rgbw = output.pixel_type == PixelType::Rgbw;
                fpga.write_pixels_bulk(output.channel, &pixel_data, output.color_order, rgbw);
            }
            receiver.clear_dirty();

            // Trigger FPGA to output the data
            fpga.trigger_output();
        }

        frame_count += 1;

        // Print stats every 10 seconds
        if stats_time.elapsed() >= Duration::from_secs(10) {
            let fps = frame_count as f64 / stats_time.elapsed().as_secs_f64();
            info!("Stats: {:.1} fps, {} frames", fps, frame_count);
            frame_count = 0;
            stats_time = Instant::now();
        }
    }

    info!("Shutting down.");
}

/// Set up Ctrl-C / SIGTERM handler to gracefully stop the main loop.
/// `stop` flag is set to `true` when a signal is received.
fn ctrlc_setup(stop: &std::sync::Arc<std::sync::atomic::AtomicBool>) {
    signal_hook::flag::register(signal_hook::consts::SIGINT, stop.clone())
        .expect("Failed to register SIGINT handler");
    signal_hook::flag::register(signal_hook::consts::SIGTERM, stop.clone())
        .expect("Failed to register SIGTERM handler");
}
