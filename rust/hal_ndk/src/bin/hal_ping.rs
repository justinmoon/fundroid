use anyhow::{bail, Context, Result};

fn main() -> Result<()> {
    let instance = std::env::args()
        .nth(1)
        .with_context(|| "usage: hal_ping <service-instance>")?;
    let ok = hal_ndk::ping(&instance);
    println!("{}: {}", instance, ok);
    if ok {
        Ok(())
    } else {
        bail!("binder ping failed for {}", instance);
    }
}
