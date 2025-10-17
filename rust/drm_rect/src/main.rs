use android_logger::Config;
use log::LevelFilter;

fn main() -> anyhow::Result<()> {
    android_logger::init_once(
        Config::default()
            .with_tag("drm_rect")
            .with_max_level(LevelFilter::Info),
    );
    drm_rect::fill_display((255, 136, 0))
}
