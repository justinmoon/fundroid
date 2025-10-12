use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::thread;
use std::time::Duration;

const ANDROID_LOG_INFO: i32 = 4;
static TAG: &CStr = unsafe { CStr::from_bytes_with_nul_unchecked(b"webosd\0") };

#[link(name = "log")]
extern "C" {
    fn __android_log_write(prio: i32, tag: *const c_char, text: *const c_char) -> i32;
}

fn log_info(message: &str) {
    let msg = CString::new(message).unwrap_or_else(|_| CString::new("log error").unwrap());
    unsafe {
        __android_log_write(ANDROID_LOG_INFO, TAG.as_ptr(), msg.as_ptr());
    }
}

fn main() {
    log_info("hello from init()");
    loop {
        log_info("still alive");
        thread::sleep(Duration::from_secs(60));
    }
}
