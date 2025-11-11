use std::env;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::net::TcpListener;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use chrono::Local;
use serde::Serialize;
use tempfile::{Builder as TempDirBuilder, TempDir};
use tracing::{debug, info, warn};

use crate::adb::{adb_connect, adb_shell_getprop, resolve_active_adb_serial};
use crate::daemon::{tail_file, CfctlDaemonConfig};
use crate::launcher::{spawn_guest_process, LaunchParams};
use crate::protocol::BootVerificationResult;

#[derive(Debug, Clone)]
pub struct RunConfig {
    pub boot_image: Option<PathBuf>,
    pub init_boot_image: Option<PathBuf>,
    pub logs_dir: Option<PathBuf>,
    pub disable_webrtc: bool,
    pub verify_boot: bool,
    pub skip_adb_wait: bool,
    pub timeout_secs: Option<u64>,
    pub keep_state: bool,
    pub track: Option<String>,
    pub run_as_root: bool,
    pub state_dir: Option<PathBuf>,
    pub instances_dir: Option<PathBuf>,
    pub assembly_dir: Option<PathBuf>,
    pub system_image_dir: Option<PathBuf>,
    pub guest_user: Option<String>,
    pub guest_group: Option<String>,
    pub cuttlefish_fhs: Option<PathBuf>,
    pub adb_host: Option<String>,
    pub base_adb_port: Option<u16>,
}

#[derive(Debug, Serialize)]
pub struct RunSummary {
    pub logs_dir: PathBuf,
    pub run_log: PathBuf,
    pub console_log: Option<PathBuf>,
    pub logcat_log: Option<PathBuf>,
    pub adb_serial: Option<String>,
    pub verification: Option<BootVerificationResult>,
    pub kept_state_dir: Option<PathBuf>,
}

pub fn run_once(cfg: RunConfig) -> Result<RunSummary> {
    if cfg.verify_boot && cfg.skip_adb_wait {
        bail!("cannot combine --verify-boot with --skip-adb-wait");
    }

    let logs_dir = cfg.logs_dir.unwrap_or_else(default_logs_dir);
    fs::create_dir_all(&logs_dir)
        .with_context(|| format!("creating logs directory {}", logs_dir.display()))?;
    let run_log_path = logs_dir.join("cfctl-run.log");
    let run_log = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&run_log_path)
        .with_context(|| format!("opening run log {}", run_log_path.display()))?;

    let mut runtime_cfg = config_from_env();
    let state_dir = cfg
        .state_dir
        .clone()
        .or_else(|| env::var("CFCTL_STATE_DIR").ok().map(PathBuf::from))
        .unwrap_or_else(|| logs_dir.join("state"));
    runtime_cfg.state_dir = state_dir;

    if let Some(dir) = &cfg.instances_dir {
        runtime_cfg.cuttlefish_instances_dir = dir.clone();
    }
    if let Some(dir) = &cfg.assembly_dir {
        runtime_cfg.cuttlefish_assembly_dir = dir.clone();
    }
    if let Some(dir) = &cfg.system_image_dir {
        runtime_cfg.cuttlefish_system_image_dir = dir.clone();
    }
    if let Some(user) = &cfg.guest_user {
        runtime_cfg.guest_user = user.clone();
    }
    if let Some(group) = &cfg.guest_group {
        runtime_cfg.guest_primary_group = group.clone();
    }
    if let Some(fhs) = &cfg.cuttlefish_fhs {
        runtime_cfg.cuttlefish_fhs = fhs.clone();
    }
    if let Some(host) = &cfg.adb_host {
        runtime_cfg.adb_host = host.clone();
    }
    runtime_cfg.base_adb_port = cfg.base_adb_port.unwrap_or(7200);
    if cfg.state_dir.is_none() && env::var("CFCTL_ETC_DIR").is_err() {
        runtime_cfg.etc_instances_dir = logs_dir.join("etc");
    }
    fs::create_dir_all(&runtime_cfg.state_dir)?;
    fs::create_dir_all(&runtime_cfg.etc_instances_dir)?;

    let uid = resolve_uid(&runtime_cfg.guest_user)?;
    let gid = resolve_gid(&runtime_cfg.guest_primary_group)?;

    let temp_dir = TempDirBuilder::new()
        .prefix("cfctl-run-")
        .tempdir_in("/tmp")
        .context("creating temporary cfctl-lite workspace")?;
    let mut temp_guard = TempState::new(temp_dir, cfg.keep_state);
    chown_path(temp_guard.path(), uid, gid)
        .with_context(|| format!("setting owner on {}", temp_guard.path().display()))?;

    runtime_cfg.cuttlefish_instances_dir = temp_guard.path().join("instances");
    runtime_cfg.cuttlefish_assembly_dir = temp_guard.path().join("assembly");
    fs::create_dir_all(&runtime_cfg.cuttlefish_instances_dir)?;
    chown_path(&runtime_cfg.cuttlefish_instances_dir, uid, gid).with_context(|| {
        format!(
            "setting owner on {}",
            runtime_cfg.cuttlefish_instances_dir.display()
        )
    })?;
    fs::create_dir_all(&runtime_cfg.cuttlefish_assembly_dir)?;
    chown_path(&runtime_cfg.cuttlefish_assembly_dir, uid, gid).with_context(|| {
        format!(
            "setting owner on {}",
            runtime_cfg.cuttlefish_assembly_dir.display()
        )
    })?;

    let (instance_name, adb_port) = allocate_instance_slot(runtime_cfg.base_adb_port)?;
    let instance_dir = runtime_cfg.cuttlefish_instances_dir.join(&instance_name);
    let assembly_dir = runtime_cfg.cuttlefish_assembly_dir.join(&instance_name);
    fs::create_dir_all(&instance_dir)?;
    chown_path(&instance_dir, uid, gid)
        .with_context(|| format!("setting owner on instance dir {}", instance_dir.display()))?;
    fs::create_dir_all(&assembly_dir)?;
    chown_path(&assembly_dir, uid, gid)
        .with_context(|| format!("setting owner on assembly dir {}", assembly_dir.display()))?;

    let boot_image = cfg
        .boot_image
        .unwrap_or_else(|| runtime_cfg.default_boot_image.clone());
    let init_boot_image = cfg
        .init_boot_image
        .unwrap_or_else(|| runtime_cfg.default_init_boot_image.clone());

    let connect_serial = format!("0.0.0.0:{adb_port}");
    let adb_serial = format!("{}:{adb_port}", runtime_cfg.adb_host);

    info!(
        target: "cfctl",
        "Launching cfctl-lite instance {} (logs at {})",
        instance_name,
        logs_dir.display()
    );
    let launch = LaunchParams {
        instance_name: &instance_name,
        adb_port,
        instance_dir: &instance_dir,
        assembly_dir: &assembly_dir,
        boot_image: &boot_image,
        init_boot_image: &init_boot_image,
        enable_webrtc: !cfg.disable_webrtc,
        track: cfg.track.as_deref(),
        use_guest_credentials: !cfg.run_as_root,
    };
    let child = spawn_guest_process(&runtime_cfg, &launch, run_log)
        .context("failed to spawn cuttlefish guest")?;
    let mut guest = GuestGuard::new(
        child,
        instance_dir.clone(),
        assembly_dir.clone(),
        instance_name.clone(),
    );

    let mut active_serial: Option<String> = None;
    if cfg.skip_adb_wait {
        info!(target: "cfctl", "Skipping adb wait for cfctl-lite run");
    } else {
        let serial = wait_for_adb(
            guest.child_mut(),
            &runtime_cfg,
            &connect_serial,
            &adb_serial,
            cfg.timeout_secs,
            &run_log_path,
        )?;
        active_serial = Some(serial);
    }

    let console_src = console_log_path(&instance_dir, &instance_name);
    let mut verification = None;
    if cfg.verify_boot {
        let serial = active_serial
            .as_deref()
            .ok_or_else(|| anyhow!("boot verification requires adb to be ready"))?;
        let result = verify_boot_completed(
            &runtime_cfg,
            serial,
            &connect_serial,
            cfg.timeout_secs,
            &console_src,
            &run_log_path,
        )?;
        verification = Some(result);
    }

    let mut logcat_path = None;
    if let Some(serial) = active_serial.as_deref() {
        let dest = logs_dir.join("logcat.txt");
        match capture_logcat(&runtime_cfg, serial, &dest) {
            Ok(()) => logcat_path = Some(dest),
            Err(err) => warn!(target: "cfctl", "failed to capture logcat: {:#}", err),
        }
    }

    guest.stop().context("failed to stop guest cleanly")?;

    let console_log = if console_src.exists() {
        let dest = logs_dir.join("console.log");
        if let Err(err) = fs::copy(&console_src, &dest) {
            warn!(
                target: "cfctl",
                "failed to copy console log {} -> {}: {:#}",
                console_src.display(),
                dest.display(),
                err
            );
            None
        } else {
            Some(dest)
        }
    } else {
        None
    };

    let kept_state_dir = if cfg.keep_state {
        let path = temp_guard.path().to_path_buf();
        temp_guard.keep();
        Some(path)
    } else {
        None
    };

    Ok(RunSummary {
        logs_dir,
        run_log: run_log_path,
        console_log,
        logcat_log: logcat_path,
        adb_serial: active_serial,
        verification,
        kept_state_dir,
    })
}

fn wait_for_adb(
    child: &mut Child,
    config: &CfctlDaemonConfig,
    connect_serial: &str,
    host_serial: &str,
    timeout_secs: Option<u64>,
    run_log: &Path,
) -> Result<String> {
    let timeout = timeout_secs
        .filter(|secs| *secs > 0)
        .map(Duration::from_secs)
        .unwrap_or(config.adb_wait_timeout);
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child
            .try_wait()
            .context("failed to poll launch_cvd status")?
        {
            let err = anyhow!("launch_cvd exited prematurely with {}", status);
            return Err(append_run_log(err, run_log));
        }

        if let Err(err) = adb_connect(&config.cuttlefish_fhs, connect_serial) {
            if Instant::now() >= deadline {
                return Err(append_run_log(
                    anyhow!("timeout waiting for adb on {}: {:#}", host_serial, err),
                    run_log,
                ));
            }
            thread::sleep(Duration::from_secs(1));
            continue;
        }

        match resolve_active_adb_serial(&config.cuttlefish_fhs, host_serial, connect_serial) {
            Ok(Some(serial)) => return Ok(serial),
            Ok(None) => {
                if Instant::now() >= deadline {
                    return Err(append_run_log(
                        anyhow!("adb device {connect_serial} never appeared"),
                        run_log,
                    ));
                }
                thread::sleep(Duration::from_secs(1));
            }
            Err(err) => {
                if Instant::now() >= deadline {
                    return Err(append_run_log(
                        anyhow!("adb devices failed repeatedly: {:#}", err),
                        run_log,
                    ));
                }
                thread::sleep(Duration::from_secs(1));
            }
        }
    }
}

fn verify_boot_completed(
    config: &CfctlDaemonConfig,
    serial: &str,
    connect_serial: &str,
    timeout_secs: Option<u64>,
    console_log: &Path,
    run_log: &Path,
) -> Result<BootVerificationResult> {
    let timeout = timeout_secs
        .filter(|secs| *secs > 0)
        .map(Duration::from_secs)
        .unwrap_or_else(|| Duration::from_secs(120));
    let deadline = Instant::now() + timeout;
    loop {
        if let Err(err) = adb_connect(&config.cuttlefish_fhs, connect_serial) {
            if Instant::now() >= deadline {
                return Err(append_run_log(
                    anyhow!("adb connect never succeeded for {serial}: {:#}", err),
                    run_log,
                ));
            }
            thread::sleep(Duration::from_millis(500));
            continue;
        }

        let active_serial =
            match resolve_active_adb_serial(&config.cuttlefish_fhs, serial, connect_serial) {
                Ok(Some(serial)) => serial,
                Ok(None) => {
                    if Instant::now() >= deadline {
                        return Err(append_run_log(
                            anyhow!("adb serial {connect_serial} did not appear during verify"),
                            run_log,
                        ));
                    }
                    thread::sleep(Duration::from_millis(500));
                    continue;
                }
                Err(err) => {
                    if Instant::now() >= deadline {
                        return Err(append_run_log(
                            anyhow!("adb devices never succeeded: {:#}", err),
                            run_log,
                        ));
                    }
                    thread::sleep(Duration::from_millis(500));
                    continue;
                }
            };

        let value = match adb_shell_getprop(
            &config.cuttlefish_fhs,
            &active_serial,
            "VIRTUAL_DEVICE_BOOT_COMPLETED",
        ) {
            Ok(value) => value.trim().to_string(),
            Err(err) => {
                if console_has_boot_marker(console_log, config.journal_lines)
                    || run_log_has_boot_marker(run_log, config.journal_lines)
                {
                    return Ok(BootVerificationResult {
                        adb_ready: true,
                        boot_marker_observed: true,
                        failure_reason: None,
                    });
                }

                if Instant::now() >= deadline {
                    return Err(append_run_log(
                        anyhow!("adb getprop never succeeded: {:#}", err),
                        run_log,
                    ));
                }
                thread::sleep(Duration::from_millis(500));
                continue;
            }
        };

        if matches!(value.as_str(), "1" | "true" | "TRUE") {
            return Ok(BootVerificationResult {
                adb_ready: true,
                boot_marker_observed: true,
                failure_reason: None,
            });
        }

        if console_has_boot_marker(console_log, config.journal_lines)
            || run_log_has_boot_marker(run_log, config.journal_lines)
        {
            return Ok(BootVerificationResult {
                adb_ready: true,
                boot_marker_observed: true,
                failure_reason: None,
            });
        }

        if Instant::now() >= deadline {
            return Err(anyhow!(
                "VIRTUAL_DEVICE_BOOT_COMPLETED not observed (last value {value})"
            ));
        }

        thread::sleep(Duration::from_secs(1));
    }
}

fn capture_logcat(config: &CfctlDaemonConfig, serial: &str, dest: &Path) -> Result<()> {
    let mut cmd = Command::new(&config.cuttlefish_fhs);
    cmd.arg("--")
        .arg("adb")
        .arg("-s")
        .arg(serial)
        .arg("logcat")
        .arg("-d");
    let output = cmd
        .output()
        .with_context(|| format!("capturing logcat for {serial}"))?;
    if !output.status.success() {
        bail!(
            "adb logcat failed with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }
    fs::write(dest, &output.stdout)
        .with_context(|| format!("writing logcat output {}", dest.display()))?;
    Ok(())
}

fn console_has_boot_marker(path: &Path, lines: usize) -> bool {
    if !path.exists() {
        return false;
    }
    match tail_file(path, lines) {
        Ok(content) => content.contains("VIRTUAL_DEVICE_BOOT_COMPLETED"),
        Err(err) => {
            debug!(
                target: "cfctl",
                "failed to read console log {}: {}",
                path.display(),
                err
            );
            false
        }
    }
}

fn run_log_has_boot_marker(path: &Path, lines: usize) -> bool {
    match tail_file(path, lines) {
        Ok(content) => content.contains("VIRTUAL_DEVICE_BOOT_COMPLETED"),
        Err(err) => {
            debug!(
                target: "cfctl",
                "failed to read run log {}: {}",
                path.display(),
                err
            );
            false
        }
    }
}

fn append_run_log(err: anyhow::Error, run_log: &Path) -> anyhow::Error {
    match tail_file(run_log, 200) {
        Ok(tail) => err.context(format!("cfctl-run.log tail:\n{tail}")),
        Err(_) => err,
    }
}

fn allocate_instance_slot(base_port: u16) -> Result<(String, u16)> {
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u64)
        .unwrap_or(0);
    let pid = std::process::id() as u64;

    for offset in 0..90u64 {
        let value = 10 + ((seed + pid + offset) % 90);
        let port = base_port + value as u16 - 1;
        if port_available(port)? {
            return Ok((format!("{value:02}"), port));
        }
    }
    bail!("unable to allocate free adb port after 90 attempts");
}

fn port_available(port: u16) -> Result<bool> {
    match TcpListener::bind(("127.0.0.1", port)) {
        Ok(listener) => {
            drop(listener);
            Ok(true)
        }
        Err(err) => {
            if err.kind() == std::io::ErrorKind::AddrInUse {
                Ok(false)
            } else {
                Err(err.into())
            }
        }
    }
}

fn console_log_path(instance_dir: &Path, instance_name: &str) -> PathBuf {
    instance_dir
        .join("instances")
        .join(format!("cvd-{}", instance_name))
        .join("console_log")
}

struct GuestGuard {
    child: Option<Child>,
    instance_dir: PathBuf,
    assembly_dir: PathBuf,
    instance_name: String,
}

impl GuestGuard {
    fn new(
        child: Child,
        instance_dir: PathBuf,
        assembly_dir: PathBuf,
        instance_name: String,
    ) -> Self {
        Self {
            child: Some(child),
            instance_dir,
            assembly_dir,
            instance_name,
        }
    }

    fn child_mut(&mut self) -> &mut Child {
        self.child
            .as_mut()
            .expect("guest child missing while still alive")
    }

    fn stop(&mut self) -> Result<()> {
        if let Some(mut child) = self.child.take() {
            if let Err(err) = child.kill() {
                warn!(target: "cfctl", "failed to kill launch_cvd: {:#}", err);
            }
            let _ = child.wait();
        }
        kill_guest_processes(&self.instance_name, &self.instance_dir, &self.assembly_dir);
        cleanup_network(&self.instance_name);
        Ok(())
    }
}

impl Drop for GuestGuard {
    fn drop(&mut self) {
        if self.child.is_some() {
            let _ = self.stop();
        }
    }
}

fn kill_guest_processes(_instance_name: &str, instance_dir: &Path, assembly_dir: &Path) {
    let patterns = vec![
        format!("--instance_dir={}", instance_dir.display()),
        format!("--assembly_dir={}", assembly_dir.display()),
        instance_dir.display().to_string(),
        assembly_dir.display().to_string(),
    ];
    for pattern in &patterns {
        let _ = Command::new("pkill")
            .args(["-9", "-f", "--", pattern])
            .status();
    }
    thread::sleep(Duration::from_millis(200));

    for pid in collect_guest_pids(&patterns) {
        let pid_str = pid.to_string();
        let _ = Command::new("kill").args(["-9", &pid_str]).status();
    }
}

fn collect_guest_pids(patterns: &[String]) -> Vec<i32> {
    let mut pids = Vec::new();
    for pattern in patterns {
        if let Ok(output) = Command::new("pgrep").args(["-f", "--", pattern]).output() {
            if output.status.success() {
                for line in String::from_utf8_lossy(&output.stdout).lines() {
                    if let Ok(pid) = line.trim().parse::<i32>() {
                        pids.push(pid);
                    }
                }
            }
        }
    }
    pids
}

fn cleanup_network(instance_name: &str) {
    if let Ok(id) = instance_name.parse::<u32>() {
        let inst_padded = format!("{id:02}");
        let device = format!("cvd-eth-{inst_padded}");
        let _ = Command::new("ip")
            .arg("link")
            .arg("del")
            .arg(&device)
            .status();
    }
}

struct TempState {
    dir: Option<TempDir>,
    keep: bool,
}

impl TempState {
    fn new(dir: TempDir, keep: bool) -> Self {
        Self {
            dir: Some(dir),
            keep,
        }
    }

    fn path(&self) -> &Path {
        self.dir
            .as_ref()
            .map(|d| d.path())
            .expect("temporary directory missing")
    }

    fn keep(&mut self) {
        self.keep = true;
    }
}

impl Drop for TempState {
    fn drop(&mut self) {
        if self.keep {
            if let Some(dir) = self.dir.take() {
                let _ = dir.keep();
            }
        }
    }
}

fn default_logs_dir() -> PathBuf {
    let stamp = Local::now().format("run-%Y%m%d-%H%M%S").to_string();
    PathBuf::from("logs").join(stamp)
}

fn resolve_uid(username: &str) -> Result<u32> {
    use std::ffi::CString;
    let cname = CString::new(username).with_context(|| format!("invalid username: {username}"))?;
    unsafe {
        let pwd = libc::getpwnam(cname.as_ptr());
        if pwd.is_null() {
            bail!("user '{username}' not found");
        }
        Ok((*pwd).pw_uid)
    }
}

fn resolve_gid(groupname: &str) -> Result<u32> {
    use std::ffi::CString;
    let cname =
        CString::new(groupname).with_context(|| format!("invalid group name: {groupname}"))?;
    unsafe {
        let grp = libc::getgrnam(cname.as_ptr());
        if grp.is_null() {
            bail!("group '{groupname}' not found");
        }
        Ok((*grp).gr_gid)
    }
}

fn chown_path(path: &Path, uid: u32, gid: u32) -> Result<()> {
    let c_path =
        CString::new(path.as_os_str().as_bytes()).with_context(|| format!("path {:?}", path))?;
    let rc = unsafe { libc::chown(c_path.as_ptr(), uid as libc::uid_t, gid as libc::gid_t) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("chown {}", path.display()));
    }
    Ok(())
}

fn config_from_env() -> CfctlDaemonConfig {
    let mut cfg = CfctlDaemonConfig::default();
    if let Ok(val) = env::var("CFCTL_STATE_DIR") {
        cfg.state_dir = PathBuf::from(val);
    }
    if let Ok(val) = env::var("CFCTL_ETC_DIR") {
        cfg.etc_instances_dir = PathBuf::from(val);
    }
    if let Ok(val) = env::var("CFCTL_DEFAULT_BOOT") {
        cfg.default_boot_image = PathBuf::from(val);
    }
    if let Ok(val) = env::var("CFCTL_DEFAULT_INIT_BOOT") {
        cfg.default_init_boot_image = PathBuf::from(val);
    }
    if let Ok(val) = env::var("CFCTL_START_TIMEOUT_SECS") {
        if let Ok(secs) = val.parse::<u64>() {
            cfg.start_timeout = Duration::from_secs(secs);
        }
    }
    if let Ok(val) = env::var("CFCTL_ADB_TIMEOUT_SECS") {
        if let Ok(secs) = val.parse::<u64>() {
            cfg.adb_wait_timeout = Duration::from_secs(secs);
        }
    }
    if let Ok(val) = env::var("CFCTL_JOURNAL_LINES") {
        if let Ok(lines) = val.parse::<usize>() {
            cfg.journal_lines = lines;
        }
    }
    if let Ok(val) = env::var("CFCTL_ADB_HOST") {
        cfg.adb_host = val;
    }
    if let Ok(val) = env::var("CFCTL_BASE_ADB_PORT") {
        if let Ok(port) = val.parse::<u16>() {
            cfg.base_adb_port = port;
        }
    }
    if let Ok(val) = env::var("CFCTL_CUTTLEFISH_FHS") {
        cfg.cuttlefish_fhs = PathBuf::from(val);
    }
    if let Ok(val) = env::var("CFCTL_CUTTLEFISH_INSTANCES_DIR") {
        cfg.cuttlefish_instances_dir = PathBuf::from(val);
    }
    if let Ok(val) = env::var("CFCTL_CUTTLEFISH_ASSEMBLY_DIR") {
        cfg.cuttlefish_assembly_dir = PathBuf::from(val);
    }
    if let Ok(val) = env::var("CFCTL_CUTTLEFISH_SYSTEM_IMAGE_DIR") {
        cfg.cuttlefish_system_image_dir = PathBuf::from(val);
    }
    if let Ok(val) = env::var("CFCTL_DISABLE_HOST_GPU") {
        if let Ok(flag) = val.parse::<bool>() {
            cfg.disable_host_gpu = flag;
        }
    }
    if let Ok(val) = env::var("CFCTL_GUEST_USER") {
        cfg.guest_user = val;
    }
    if let Ok(val) = env::var("CFCTL_GUEST_PRIMARY_GROUP") {
        cfg.guest_primary_group = val;
    }
    if let Ok(val) = env::var("CFCTL_GUEST_CAPABILITIES") {
        cfg.guest_capabilities = val
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
    }
    cfg
}
