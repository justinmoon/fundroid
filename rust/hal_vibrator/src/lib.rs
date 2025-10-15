#![deny(clippy::all, clippy::pedantic)]

use anyhow::{anyhow, bail, Result};

bitflags::bitflags! {
    /// Capability mask exposed by the AIDL IVibrator service.
    pub struct Caps: u64 {
        const ON_CALLBACK = 1 << 0;
        const PERFORM_CALLBACK = 1 << 1;
        const AMPLITUDE_CONTROL = 1 << 2;
        const EXTERNAL_CONTROL = 1 << 3;
        const EXTERNAL_AMPLITUDE_CONTROL = 1 << 4;
        const COMPOSE_EFFECTS = 1 << 5;
        const ALWAYS_ON_CONTROL = 1 << 6;
        const GET_RESONANT_FREQUENCY = 1 << 7;
        const GET_Q_FACTOR = 1 << 8;
        const FREQUENCY_CONTROL = 1 << 9;
        const COMPOSE_PWLE_EFFECTS = 1 << 10;
    }
}

#[cfg(target_os = "android")]
#[link(name = "vibrator_shim")]
extern "C" {
    fn vib_get_capabilities(out: *mut u64) -> i32;
    fn vib_on_ms(ms: i32) -> i32;
}

#[cfg(target_os = "android")]
fn rc_to_result(rc: i32, context: &'static str) -> Result<()> {
    match rc {
        0 => Ok(()),
        -1 => bail!("{context}: service unavailable"),
        -2 => bail!("{context}: invalid binder client"),
        -3 => bail!("{context}: binder call failed"),
        -22 => bail!("{context}: invalid argument"),
        other => bail!("{context}: unexpected error code {other}"),
    }
}

#[cfg(target_os = "android")]
pub fn capabilities() -> Result<Caps> {
    let mut raw = 0_u64;
    rc_to_result(
        unsafe { vib_get_capabilities(&mut raw as *mut u64) },
        "capabilities",
    )?;
    Ok(Caps::from_bits_truncate(raw))
}

#[cfg(target_os = "android")]
pub fn vibrate(duration_ms: u32) -> Result<()> {
    let ms = i32::try_from(duration_ms).map_err(|_| anyhow!("duration exceeds i32::MAX ms"))?;
    rc_to_result(unsafe { vib_on_ms(ms) }, "vibrate")
}

#[cfg(not(target_os = "android"))]
pub fn capabilities() -> Result<Caps> {
    bail!("hal_vibrator::capabilities is only available on Android targets");
}

#[cfg(not(target_os = "android"))]
pub fn vibrate(_duration_ms: u32) -> Result<()> {
    bail!("hal_vibrator::vibrate is only available on Android targets");
}
