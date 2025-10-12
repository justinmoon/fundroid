use std::fs;
use std::io;
use std::path::Path;

fn main() {
    if let Err(err) = inspect_drm_nodes() {
        eprintln!("drm_rect: {err}");
        std::process::exit(1);
    }
}

fn inspect_drm_nodes() -> io::Result<()> {
    let dri_root = Path::new("/dev/dri");
    if !dri_root.exists() {
        println!("drm_rect: /dev/dri not present on this system.");
        return Ok(());
    }

    println!("drm_rect: available DRM nodes:");
    for entry in fs::read_dir(dri_root)? {
        let entry = entry?;
        println!(" - {}", entry.path().display());
    }

    Ok(())
}
