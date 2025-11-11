use std::fs::File;
use std::path::Path;
use std::process::{Child, Command, Stdio};

use anyhow::{bail, Context, Result};
use tracing::{debug, info};

use crate::daemon::CfctlDaemonConfig;

pub struct LaunchParams<'a> {
    pub instance_name: &'a str,
    pub adb_port: u16,
    pub instance_dir: &'a Path,
    pub assembly_dir: &'a Path,
    pub boot_image: &'a Path,
    pub init_boot_image: &'a Path,
    pub enable_webrtc: bool,
    pub track: Option<&'a str>,
}

pub fn spawn_guest_process(
    config: &CfctlDaemonConfig,
    params: &LaunchParams<'_>,
    log_file: File,
) -> Result<Child> {
    let log_clone = log_file
        .try_clone()
        .context("cloning run log file for stderr")?;

    let inst_name = params.instance_name;
    let target_user = &config.guest_user;
    let primary_group = &config.guest_primary_group;

    let uid = resolve_uid(target_user)?;
    let gid = resolve_gid(primary_group)?;

    info!(
        target: "cfctl",
        "spawn_guest_process: resolved credentials uid={}:{} gid={}:{} caps={:?}",
        target_user, uid, primary_group, gid, config.guest_capabilities
    );

    let preserve_vars = [
        "CUTTLEFISH_INSTANCE",
        "CUTTLEFISH_INSTANCE_NUM",
        "CUTTLEFISH_ADB_TCP_PORT",
        "CUTTLEFISH_DISABLE_HOST_GPU",
        "GFXSTREAM_DISABLE_GRAPHICS_DETECTOR",
        "GFXSTREAM_HEADLESS",
    ];

    let mut cmd = Command::new("sudo");
    cmd.arg("-u").arg(target_user).arg("-g").arg(primary_group);
    for var in &preserve_vars {
        cmd.arg(format!("--preserve-env={var}"));
    }
    cmd.arg("--");

    if !config.guest_capabilities.is_empty() {
        let caps_arg = config
            .guest_capabilities
            .iter()
            .map(|c| {
                if c.starts_with('+') || c.starts_with('-') {
                    c.clone()
                } else {
                    format!("+{c}")
                }
            })
            .collect::<Vec<_>>()
            .join(",");
        cmd.arg("setpriv")
            .arg("--ambient-caps")
            .arg(&caps_arg)
            .arg("--");
    }

    if let Some(track) = params.track {
        info!(target: "cfctl", "spawn_guest_process: using track '{}'", track);
        cmd.arg("cfenv").arg("-t").arg(track).arg("--");
    } else {
        cmd.arg(&config.cuttlefish_fhs).arg("--");
    }

    cmd.arg("launch_cvd")
        .arg(format!(
            "--system_image_dir={}",
            config.cuttlefish_system_image_dir.display()
        ))
        .arg(format!("--instance_dir={}", params.instance_dir.display()))
        .arg(format!("--assembly_dir={}", params.assembly_dir.display()))
        .arg("--vm_manager=qemu_cli")
        .arg("--enable_wifi=false")
        .arg("--enable_host_bluetooth=false")
        .arg("--enable_modem_simulator=false")
        .arg(format!(
            "--start_webrtc={}",
            if params.enable_webrtc {
                "true"
            } else {
                "false"
            }
        ))
        .arg(format!(
            "--start_webrtc_sig_server={}",
            if params.enable_webrtc {
                "true"
            } else {
                "false"
            }
        ))
        .arg("--report_anonymous_usage_stats=n")
        .arg("--daemon=false")
        .arg("--console=true")
        .arg("--verbosity=DEBUG")
        .arg("--resume=false");

    add_image_arg(&mut cmd, "--boot_image", params.boot_image);
    add_image_arg(&mut cmd, "--init_boot_image", params.init_boot_image);

    if config.disable_host_gpu {
        cmd.env("CUTTLEFISH_DISABLE_HOST_GPU", "1");
    }

    cmd.env("GFXSTREAM_DISABLE_GRAPHICS_DETECTOR", "1");
    cmd.env("GFXSTREAM_HEADLESS", "1");
    cmd.env("CUTTLEFISH_INSTANCE", inst_name);
    cmd.env("CUTTLEFISH_INSTANCE_NUM", inst_name);
    cmd.env("CUTTLEFISH_ADB_TCP_PORT", params.adb_port.to_string());
    cmd.stdin(Stdio::null())
        .stdout(Stdio::from(log_file))
        .stderr(Stdio::from(log_clone));

    if let Some(parent) = params.instance_dir.parent() {
        cmd.current_dir(parent);
    }

    let child = cmd.spawn().with_context(|| {
        format!(
            "spawning cuttlefish guest {} via {}",
            inst_name,
            config.cuttlefish_fhs.display()
        )
    })?;

    Ok(child)
}

fn add_image_arg(cmd: &mut Command, flag: &str, path: &Path) {
    if path.exists() {
        cmd.arg(format!("{flag}={}", path.display()));
    } else {
        debug!(
            target: "cfctl",
            "spawn_guest_process: {} {} missing; skipping",
            flag,
            path.display()
        );
    }
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
