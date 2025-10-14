use std::{path::PathBuf, time::Duration};

use capsule_tools::{wait_for_binder_device, BinderDeviceConfig, Error};

#[test]
fn wait_for_binder_times_out_fast() {
    let path = PathBuf::from("/nonexistent/binder-device");
    let config = BinderDeviceConfig::new(&path).with_poll_interval(Duration::from_millis(1));
    match wait_for_binder_device(&config, Duration::from_millis(2)) {
        Err(Error::Timeout { .. }) => {}
        other => panic!("expected timeout error, got {:?}", other),
    }
}

#[cfg(target_os = "android")]
#[test]
fn list_services_smoke() -> anyhow::Result<()> {
    if std::env::var("CAPSULE_TESTS").ok().as_deref() != Some("1") {
        eprintln!("skipping binder integration test (CAPSULE_TESTS != 1)");
        return Ok(());
    }

    let binder_path = std::env::var_os("CAPSULE_BINDER_DEVICE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/dev/binder"));

    let config =
        BinderDeviceConfig::new(&binder_path).with_poll_interval(Duration::from_millis(200));
    wait_for_binder_device(&config, Duration::from_secs(5))?;

    let services =
        capsule_tools::list_services(config.path(), rsbinder::hub::DUMP_FLAG_PRIORITY_ALL)?;
    assert!(
        !services.is_empty(),
        "service manager returned an empty service list"
    );
    Ok(())
}
