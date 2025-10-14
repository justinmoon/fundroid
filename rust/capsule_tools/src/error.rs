use std::{path::PathBuf, time::Duration};

use thiserror::Error;

/// Common error type returned by the capsule tooling helpers.
#[derive(Debug, Error)]
pub enum Error {
    #[error("timed out waiting for binder device {path} after {elapsed:?}")]
    Timeout {
        path: PathBuf,
        elapsed: Duration,
        last_error: Option<String>,
    },

    #[error("binder device {path} is not accessible: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("invalid binder device path '{0}'")]
    InvalidBinderPath(String),

    #[error("binder process initialization failed: {0}")]
    BinderInit(String),

    #[error("binder operation is only supported on Android targets")]
    UnsupportedPlatform,
}

/// Convenient alias for results returned by this crate.
pub type Result<T> = std::result::Result<T, Error>;
