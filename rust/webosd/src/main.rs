use android_logger::Config;
use log::{info, LevelFilter};
use std::time::Duration;

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

    loop {
        std::thread::sleep(SLEEP_INTERVAL);
    }
}
