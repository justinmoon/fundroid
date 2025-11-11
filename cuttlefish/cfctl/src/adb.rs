use std::path::Path;
use std::process::Command;

use anyhow::{anyhow, Context, Result};

pub fn adb_connect(fhs: &Path, serial: &str) -> Result<()> {
    let mut cmd = Command::new(fhs);
    cmd.arg("--").arg("adb").arg("connect").arg(serial);
    let output = cmd
        .output()
        .with_context(|| format!("invoking adb connect {serial}"))?;
    if !output.status.success() {
        return Err(anyhow!(
            "adb connect returned {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(())
}

pub fn resolve_active_adb_serial(
    fhs: &Path,
    serial_a: &str,
    serial_b: &str,
) -> Result<Option<String>> {
    let mut cmd = Command::new(fhs);
    cmd.arg("--").arg("adb").arg("devices");
    let output = cmd
        .output()
        .with_context(|| "invoking adb devices".to_string())?;
    if !output.status.success() {
        return Err(anyhow!(
            "adb devices returned {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let mut parts = line.split_whitespace();
        let Some(entry) = parts.next() else {
            continue;
        };
        let status = parts.next().unwrap_or("");
        if (entry == serial_a || entry == serial_b) && status == "device" {
            return Ok(Some(entry.to_string()));
        }
    }

    Ok(None)
}

pub fn adb_shell_getprop(fhs: &Path, serial: &str, property: &str) -> Result<String> {
    let mut cmd = Command::new(fhs);
    cmd.arg("--")
        .arg("adb")
        .arg("-s")
        .arg(serial)
        .arg("shell")
        .arg("getprop")
        .arg(property);
    let output = cmd
        .output()
        .with_context(|| format!("invoking adb getprop {property} for {serial}"))?;
    if !output.status.success() {
        return Err(anyhow!(
            "adb getprop returned {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}
