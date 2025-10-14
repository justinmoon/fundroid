use std::{
    fs::OpenOptions,
    path::{Path, PathBuf},
    thread::sleep,
    time::{Duration, Instant},
};

use crate::{Error, Result};

/// Default poll interval while waiting for binder availability.
const DEFAULT_POLL_INTERVAL: Duration = Duration::from_millis(200);

/// Configuration describing the binder device to probe.
#[derive(Clone, Debug)]
pub struct BinderDeviceConfig {
    path: PathBuf,
    poll_interval: Duration,
}

impl BinderDeviceConfig {
    /// Create a new configuration for the provided device path.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            poll_interval: DEFAULT_POLL_INTERVAL,
        }
    }

    /// Override the poll interval used between attempts.
    pub fn with_poll_interval(mut self, interval: Duration) -> Self {
        self.poll_interval = interval;
        self
    }

    /// Access the configured binder path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Access the configured polling interval.
    pub fn poll_interval(&self) -> Duration {
        self.poll_interval
    }
}

impl Default for BinderDeviceConfig {
    fn default() -> Self {
        Self::new("/dev/binder")
    }
}

/// Blocks until the binder device at `config.path()` becomes accessible or the timeout elapses.
pub fn wait_for_binder_device(config: &BinderDeviceConfig, timeout: Duration) -> Result<()> {
    let start = Instant::now();

    loop {
        match try_open_binder(config.path()) {
            Ok(()) => return Ok(()),
            Err(err) => {
                if start.elapsed() >= timeout {
                    return Err(Error::Timeout {
                        path: config.path().to_path_buf(),
                        elapsed: start.elapsed(),
                        last_error: Some(err.to_string()),
                    });
                }
            }
        }

        sleep(config.poll_interval());
    }
}

fn try_open_binder(path: &Path) -> Result<()> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map(|_| ())
        .map_err(|source| Error::Io {
            path: path.to_path_buf(),
            source,
        })
}

#[cfg(target_os = "android")]
use std::sync::OnceLock;

#[cfg(target_os = "android")]
use rsbinder::ProcessState;

#[cfg(target_os = "android")]
static PROCESS_STATE: OnceLock<&'static ProcessState> = OnceLock::new();

#[cfg(target_os = "android")]
static PROCESS_DRIVER: OnceLock<PathBuf> = OnceLock::new();

/// Ensure the current process is attached to the binder driver at `path`.
///
/// On Android targets a singleton `ProcessState` is initialised. Non-Android
/// builds return [`Error::UnsupportedPlatform`].
#[cfg(target_os = "android")]
pub fn ensure_process_state(path: &Path) -> Result<&'static ProcessState> {
    if let Some(state) = PROCESS_STATE.get() {
        if let Some(existing) = PROCESS_DRIVER.get() {
            if existing != path {
                return Err(Error::BinderInit(format!(
                    "process already attached to binder driver {} (requested {})",
                    existing.display(),
                    path.display()
                )));
            }
        }
        return Ok(*state);
    }

    let driver = path_to_str(path)?;
    let state = ProcessState::init(&driver, 0);
    ProcessState::start_thread_pool();

    if PROCESS_DRIVER.set(path.to_path_buf()).is_err() {
        if let Some(existing) = PROCESS_DRIVER.get() {
            if existing != path {
                return Err(Error::BinderInit(format!(
                    "process already attached to binder driver {} (requested {})",
                    existing.display(),
                    path.display()
                )));
            }
        }
    }

    if PROCESS_STATE.set(state).is_err() {
        if let Some(existing) = PROCESS_STATE.get() {
            return Ok(*existing);
        }
        return Err(Error::BinderInit(
            "process state initialisation raced".into(),
        ));
    }

    Ok(state)
}

#[cfg(not(target_os = "android"))]
#[allow(unused_variables)]
pub fn ensure_process_state(path: &Path) -> Result<()> {
    Err(Error::UnsupportedPlatform)
}

#[cfg(target_os = "android")]
fn path_to_str(path: &Path) -> Result<String> {
    path.to_str()
        .map(|s| s.to_owned())
        .ok_or_else(|| Error::InvalidBinderPath(path.display().to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wait_for_binder_device_succeeds_when_file_is_available() {
        let tmp_dir = tempfile::tempdir().expect("tempdir");
        let binder_path = tmp_dir.path().join("binder");
        OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(&binder_path)
            .expect("create binder placeholder");

        let config =
            BinderDeviceConfig::new(&binder_path).with_poll_interval(Duration::from_millis(10));
        wait_for_binder_device(&config, Duration::from_secs(1)).expect("binder ready");
    }
}
