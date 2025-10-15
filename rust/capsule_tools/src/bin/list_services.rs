use std::{path::PathBuf, time::Duration};

use anyhow::Result;
use capsule_tools::{list_services, BinderDeviceConfig};
use clap::Parser;

#[derive(Parser, Debug)]
#[command(author, version, about = "List binder services exposed by the capsule", long_about = None)]
struct Args {
    /// Binder device to probe.
    #[arg(short, long, default_value = "/dev/binder")]
    device: PathBuf,

    /// Timeout in seconds when waiting for the binder device.
    #[arg(short, long, default_value_t = 5)]
    wait: u64,

    /// Poll interval in milliseconds between binder readiness checks.
    #[arg(long, default_value_t = 200)]
    interval: u64,

    /// Dump priority of services to include (matches servicemanager flags).
    #[arg(long, default_value_t = default_dump_priority())]
    dump_priority: i32,
}

#[cfg(target_os = "android")]
const fn default_dump_priority() -> i32 {
    rsbinder::hub::DUMP_FLAG_PRIORITY_ALL
}

#[cfg(not(target_os = "android"))]
const fn default_dump_priority() -> i32 {
    0
}

fn main() -> Result<()> {
    let args = Args::parse();
    let interval = Duration::from_millis(args.interval.max(1));
    let timeout = Duration::from_secs(args.wait);
    let config = BinderDeviceConfig::new(&args.device).with_poll_interval(interval);

    capsule_tools::wait_for_binder_device(&config, timeout)?;

    let services = list_services(config.path(), args.dump_priority)?;
    for service in services {
        println!("{service}");
    }
    Ok(())
}
