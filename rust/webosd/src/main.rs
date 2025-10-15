use android_logger::Config;
use log::{info, LevelFilter};
use std::{env, path::{Path, PathBuf}, time::Duration};

/// Binder endpoints resolved from environment variables.
///
/// Bridge components should read the resolved paths from this structure when
/// initialising binder clients. Switching between the host drivers (`/dev/*`)
/// and the capsule namespace (`/data/local/tmp/capsule/dev/*`) is as simple as
/// exporting different environment variables; no code changes required. Android
/// init exports both capsule-specific (`BINDER_DEVICE=/data/local/tmp/...`) and
/// host defaults (`HOST_BINDER_DEVICE=/dev/binder`), so bridges can flip between
/// the two families at runtime by updating the environment before spawning the
/// worker threads.
#[derive(Debug, Clone)]
pub struct BinderDevices {
    binder: PathBuf,
    hwbinder: PathBuf,
    vndbinder: PathBuf,
}

impl BinderDevices {
    pub fn from_env() -> Self {
        Self {
            binder: resolve_path("BINDER_DEVICE", "/dev/binder"),
            hwbinder: resolve_path("HWBINDER_DEVICE", "/dev/hwbinder"),
            vndbinder: resolve_path("VNDBINDER_DEVICE", "/dev/vndbinder"),
        }
    }

    pub fn binder(&self) -> &Path {
        &self.binder
    }

    pub fn hwbinder(&self) -> &Path {
        &self.hwbinder
    }

    pub fn vndbinder(&self) -> &Path {
        &self.vndbinder
    }
}

fn resolve_path(var: &str, fallback: &str) -> PathBuf {
    match env::var(var) {
        Ok(val) if !val.trim().is_empty() => PathBuf::from(val),
        _ => PathBuf::from(fallback),
    }
}

const SLEEP_INTERVAL: Duration = Duration::from_secs(60);

fn main() {
    android_logger::init_once(
        Config::default()
            .with_max_level(LevelFilter::Info)
            .with_tag("webosd"),
    );

    let pid = unsafe { libc::getpid() };
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };

    info!(
        "webosd v{} started (pid={}, uid={}, gid={})",
        env!("CARGO_PKG_VERSION"),
        pid,
        uid,
        gid
    );

    let binder_devices = BinderDevices::from_env();
    info!(
        "binder targets: binder={} hwbinder={} vndbinder={}",
        binder_devices.binder().display(),
        binder_devices.hwbinder().display(),
        binder_devices.vndbinder().display()
    );

    loop {
        std::thread::sleep(SLEEP_INTERVAL);
    }
}
