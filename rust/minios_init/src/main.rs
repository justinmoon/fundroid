#![warn(clippy::all, clippy::pedantic)]

use anyhow::Result;
use libc::{LINUX_REBOOT_CMD_RESTART, SYS_reboot, c_ulong};
use log::{debug, error, info};
use std::ffi::CString;
use std::fs::{OpenOptions, create_dir_all};
use std::io::Write;
use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn main() -> Result<()> {
    init_logger();
    info!("MiniOS phase1 init starting (pid={})", std::process::id());

    mount_required_fs();
    info!("mounted dev/proc/sys");
    ensure_dev_nodes();
    write_marker();
    for idx in 0..3 {
        info!("phase1 heartbeat {idx}");
        println!("minios heartbeat {idx}");
        thread::sleep(Duration::from_millis(200));
    }

    if let Err(err) = Command::new("/bin/sh")
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
    force_reboot();

    loop {
        thread::sleep(Duration::from_secs(60));
    }
}

fn mount_required_fs() {
    try_mount_dir("/dev", Some("devtmpfs"), "devtmpfs", 0, Some("mode=0755"));
    try_mount_dir("/proc", Some("proc"), "proc", 0, None);
    try_mount_dir("/sys", Some("sysfs"), "sysfs", 0, None);
}

fn try_mount_dir(
    target: &str,
    source: Option<&str>,
    fstype: &str,
    flags: c_ulong,
    data: Option<&str>,
) {
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

fn ensure_dev_nodes() {
    const NODES: &[(&str, libc::mode_t, u32, u32)] = &[
        ("/dev/console", libc::S_IFCHR | 0o600, 5, 1),
        ("/dev/null", libc::S_IFCHR | 0o666, 1, 3),
        ("/dev/urandom", libc::S_IFCHR | 0o644, 1, 9),
        ("/dev/kmsg", libc::S_IFCHR | 0o600, 1, 11),
        ("/dev/tty", libc::S_IFCHR | 0o666, 5, 0),
    ];

    for &(path, mode, major, minor) in NODES {
        if Path::new(path).exists() {
            continue;
        }
        match CString::new(path) {
            Ok(c_path) => {
                let dev = libc::makedev(major, minor);
                let ret = unsafe { libc::mknod(c_path.as_ptr(), mode, dev) };
                if ret != 0 {
                    let err = std::io::Error::last_os_error();
                    error!("mknod {path} failed: {err}");
                    continue;
                }
                if unsafe { libc::chmod(c_path.as_ptr(), mode & 0o777) } != 0 {
                    let err = std::io::Error::last_os_error();
                    error!("chmod {path} failed: {err}");
                }
            }
            Err(err) => error!("CString::new({path}) failed: {err}"),
        }
    }
}

fn write_marker() {
    const MARKER_DIR: &str = "/metadata/minios_phase1";
    if let Err(err) = create_dir_all(MARKER_DIR) {
        error!("creating marker dir failed: {err}");
        return;
    }
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|dur| dur.as_secs())
        .unwrap_or_default();
    let contents = format!("phase1 ran at {timestamp}\n");
    let path = format!("{MARKER_DIR}/last_run");
    match std::fs::write(&path, contents) {
        Ok(()) => info!("wrote marker {path}"),
        Err(err) => error!("writing marker file failed: {err}"),
    }
}

fn force_reboot() {
    const MAGIC1: libc::c_long = 0xfee1_dead;
    const MAGIC2: libc::c_long = 0x2812_1969;
    unsafe {
        libc::sync();
        let res = libc::syscall(
            SYS_reboot,
            MAGIC1,
            MAGIC2,
            LINUX_REBOOT_CMD_RESTART as libc::c_long,
            0,
        );
        if res != 0 {
            let err = std::io::Error::last_os_error();
            error!("syscall(SYS_reboot) failed: {err}");
        }
    }
}

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
            let _ = writeln!(
                file,
                "minios_init[{}]: {}",
                std::process::id(),
                record.args()
            );
            let _ = file.flush();
        } else {
            eprintln!("minios_init[{}]: {}", std::process::id(), record.args());
        }
    }

    fn flush(&self) {}
}
