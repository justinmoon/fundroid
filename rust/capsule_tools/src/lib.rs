//! Capsule tooling helpers for interacting with the on-device binder services.
//!
//! The crate exposes a minimal binder helper module that can be reused by
//! small command-line utilities which we ship alongside the capsule rootfs.

pub mod binder;
mod error;

pub use crate::binder::{list_services, wait_for_binder_device, BinderDeviceConfig};
pub use crate::error::{Error, Result};
