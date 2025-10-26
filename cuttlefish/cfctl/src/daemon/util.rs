use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::Path,
    process::Command,
    time::Instant,
};

use anyhow::{anyhow, Context, Result};
use tracing::{debug, error, trace};

pub fn tail_file(path: &Path, lines: usize) -> Result<String> {
    const MAX_TAIL_BYTES: u64 = 1 * 1024 * 1024; // 1 MiB cap per request

    let mut file =
        File::open(path).with_context(|| format!("opening log file {}", path.display()))?;
    let metadata = file
        .metadata()
        .with_context(|| format!("stat log file {}", path.display()))?;
    let len = metadata.len();
    if len > MAX_TAIL_BYTES {
        file.seek(SeekFrom::Start(len - MAX_TAIL_BYTES))
            .with_context(|| format!("seek tail for {}", path.display()))?;
    } else {
        file.seek(SeekFrom::Start(0))?;
    }

    let mut buf = String::new();
    file.read_to_string(&mut buf)?;

    // If we started mid-line, drop the first incomplete chunk.
    if len > MAX_TAIL_BYTES {
        if let Some(pos) = buf.find('\n') {
            buf = buf[pos + 1..].to_string();
        } else {
            buf.clear();
        }
    }

    let mut collected: Vec<&str> = buf.lines().collect();
    if collected.len() > lines {
        collected = collected[collected.len() - lines..].to_vec();
    }
    Ok(collected.join("\n"))
}

pub fn run_command_capture(cmd: &str, args: &[&str]) -> Result<String> {
    debug!(target: "cfctl", "run_command_capture: executing {} {:?}", cmd, args);
    let start_time = Instant::now();

    let output = Command::new(cmd)
        .args(args)
        .output()
        .with_context(|| format!("launching {} {:?}", cmd, args))?;

    let elapsed = start_time.elapsed();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    debug!(target: "cfctl", "run_command_capture: {} {:?} completed in {:?} with status {}", cmd, args, elapsed, output.status);
    trace!(target: "cfctl", "run_command_capture: {} {:?} stdout: {}", cmd, args, stdout.trim());
    if !stderr.is_empty() {
        trace!(target: "cfctl", "run_command_capture: {} {:?} stderr: {}", cmd, args, stderr.trim());
    }

    if !output.status.success() {
        error!(target: "cfctl", "run_command_capture: {} {:?} failed with {} after {:?}", cmd, args, output.status, elapsed);
        error!(target: "cfctl", "run_command_capture: {} {:?} stderr: {}", cmd, args, stderr.trim());
        return Err(anyhow!("command {:?} {:?} failed: {}", cmd, args, stderr));
    }
    Ok(stdout.to_string())
}

pub fn run_command_allow_failure(cmd: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(cmd).args(args).status()?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!(
            "command {:?} {:?} exited with {}",
            cmd,
            args,
            status
        ))
    }
}

pub fn epoch_secs() -> Result<u64> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs())
}
