#![deny(clippy::all, clippy::pedantic)]

use std::ffi::CString;
use std::os::raw::c_char;

#[cfg(target_os = "android")]
extern "C" {
    fn binder_ndk_ping(instance: *const c_char) -> bool;
}

/// Perform a binder `ping` call against the provided service instance name.
#[must_use]
#[cfg(target_os = "android")]
pub fn ping(instance: &str) -> bool {
    let cstr = match CString::new(instance) {
        Ok(s) => s,
        Err(_) => return false,
    };
    // Safety: the C shim expects a valid, null-terminated string for the service name.
    unsafe { binder_ndk_ping(cstr.as_ptr()) }
}

#[cfg(not(target_os = "android"))]
pub fn ping(instance: &str) -> bool {
    let _ = instance;
    panic!("hal_ndk::ping is only supported on Android targets");
}
