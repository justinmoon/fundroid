#![warn(clippy::all, clippy::pedantic)]

use anyhow::Result;
use libc::c_ulong;
use log::{debug, error, info};
use std::ffi::CString;
use std::fs::{create_dir_all, OpenOptions};
use std::io::Write;
use std::process::Command;
use std::thread;
use std::time::Duration;

fn main() -> Result<()> {
    init_logger();
    info!("MiniOS phase1 init starting (pid={})", std::process::id());

    mount_required_fs();
    info!("mounted dev/proc/sys");

    if let Err(err) = Command::new("/system/bin/sh")
        .arg("-c")
        .arg("echo [minios_init] init running > /dev/kmsg")
        .status()
    {
        error!("failed to write marker via shell: {err}");
    }

    match drm_rect::fill_display((0x00, 0x88, 0xFF)) {
        Ok(()) => info!("display painted successfully"),
        Err(err) => error!("failed to paint display: {err:?}"),
    }

    info!("sleeping before reboot");
    thread::sleep(Duration::from_secs(5));

    info!("triggering reboot");
    let _ = Command::new("/system/bin/sh")
        .arg("-c")
        .arg("/system/bin/reboot -f")
        .status();

    loop {
        thread::sleep(Duration::from_secs(60));
    }
}

fn mount_required_fs() {
    try_mount_dir("/dev", Some("devtmpfs"), "devtmpfs", 0, Some("mode=0755"));
    try_mount_dir("/proc", Some("proc"), "proc", 0, None);
    try_mount_dir("/sys", Some("sysfs"), "sysfs", 0, None);
}

fn try_mount_dir(target: &str, source: Option<&str>, fstype: &str, flags: c_ulong, data: Option<&str>) {
    if let Err(err) = create_dir_all(target) {
        error!("mkdir {target} failed: {err}");
    }
    if let Err(err) = mount(source, target, fstype, flags, data) {
        error!("mount {fstype} on {target} failed: {err}");
    }
}

fn mount(
    source: Option<&str>,
    target: &str,
    fstype: &str,
    flags: c_ulong,
    data: Option<&str>,
) -> Result<()> {
    let src_c = source.map(CString::new).transpose()?;
    let tgt_c = CString::new(target)?;
    let fs_c = CString::new(fstype)?;
    let data_c = data.map(CString::new).transpose()?;

    let ret = unsafe {
        libc::mount(
            src_c
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr().cast::<libc::c_char>()),
            tgt_c.as_ptr(),
            fs_c.as_ptr(),
            flags,
            data_c
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr().cast::<libc::c_void>()),
        )
    };
    if ret == 0 {
        Ok(())
    } else {
        let err = std::io::Error::last_os_error();
        if matches!(err.raw_os_error(), Some(code) if code == libc::EBUSY || code == libc::ENODEV) {
            debug!(
                "mount {fstype} on {target} skipped (errno={})",
                err.raw_os_error().unwrap()
            );
            Ok(())
        } else {
            Err(err.into())
        }
    }
}

struct KmsgLogger;

static LOGGER: KmsgLogger = KmsgLogger;

fn init_logger() {
    let _ = log::set_logger(&LOGGER);
    log::set_max_level(log::LevelFilter::Info);
}

impl log::Log for KmsgLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        if let Ok(mut file) = OpenOptions::new().write(true).open("/dev/kmsg") {
            let _ = writeln!(file, "minios_init[{}]: {}", std::process::id(), record.args());
            let _ = file.flush();
        } else {
            eprintln!("minios_init[{}]: {}", std::process::id(), record.args());
        }
    }

    fn flush(&self) {}
}
