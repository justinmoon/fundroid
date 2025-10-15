use anyhow::{Context, Result};

fn main() -> Result<()> {
    let ms = std::env::args()
        .nth(1)
        .map(|arg| {
            arg.parse::<u32>()
                .with_context(|| format!("invalid duration: {arg}"))
        })
        .transpose()?
        .unwrap_or(60);

    let caps = hal_vibrator::capabilities()?;
    println!("caps: {:?}", caps);
    hal_vibrator::vibrate(ms)?;
    println!("vibrated for {ms}ms");
    Ok(())
}
