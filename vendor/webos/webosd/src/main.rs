use std::env;
use std::fs::{self, File};
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    if let Err(err) = run() {
        eprintln!("[webosd] fatal: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let state_dir = resolve_state_dir()?;
    ensure_directory(&state_dir)?;

    let status_path = state_dir.join("webosd.status");
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?;

    let mut file = File::create(&status_path)?;
    writeln!(
        file,
        "webosd started at {}.{}",
        now.as_secs(),
        now.subsec_millis()
    )?;

    println!(
        "[webosd] initialized state directory at {}",
        state_dir.display()
    );

    Ok(())
}

fn resolve_state_dir() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Ok(path) = env::var("WEBOSD_STATE_DIR") {
        return Ok(PathBuf::from(path));
    }

    #[cfg(target_os = "android")]
    {
        return Ok(PathBuf::from("/data/local/webos"));
    }

    #[cfg(not(target_os = "android"))]
    {
        if let Some(home) = env::var_os("HOME") {
            let mut dir = PathBuf::from(home);
            dir.push(".local");
            dir.push("share");
            dir.push("webosd");
            return Ok(dir);
        }
    }

    Ok(env::current_dir()?.join("webosd-state"))
}

fn ensure_directory(path: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    if path.exists() {
        return Ok(());
    }
    fs::create_dir_all(path)?;
    Ok(())
}
