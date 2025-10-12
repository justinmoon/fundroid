fn main() {
    android_logger::init_once(android_logger::Config::default());
    log::info!("webosd: hello from init()");
    loop {
        std::thread::sleep(std::time::Duration::from_secs(60));
    }
}
