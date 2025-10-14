use std::{path::PathBuf, time::Duration};

use anyhow::Result;
use capsule_tools::{binder::BinderDeviceConfig, wait_for_binder_device};
use clap::Parser;

#[derive(Parser, Debug)]
#[command(author, version, about = "Wait for the binder driver to become available", long_about = None)]
struct Args {
    /// Binder device to probe.
    #[arg(short, long, default_value = "/dev/binder")]
    device: PathBuf,

    /// Timeout in seconds before giving up.
    #[arg(short, long, default_value_t = 30)]
    timeout: u64,

    /// Poll interval in milliseconds between attempts.
    #[arg(long, default_value_t = 200)]
    interval: u64,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let timeout = Duration::from_secs(args.timeout);
    let interval = Duration::from_millis(args.interval.max(1));

    let config = BinderDeviceConfig::new(args.device).with_poll_interval(interval);
    wait_for_binder_device(&config, timeout)?;
    println!("binder device ready at {}", config.path().display());

    Ok(())
}
