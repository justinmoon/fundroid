#![warn(clippy::all, clippy::pedantic)]

use anyhow::{Context, Result, anyhow};
use drm::Device as BasicDevice;
use drm::buffer::DrmFourcc;
use drm::control::dumbbuffer::DumbBuffer;
use drm::control::{Device as ControlDevice, connector};
use log::{debug, info, warn};
use std::fs::OpenOptions;
use std::os::unix::io::{AsFd, BorrowedFd};

/// Fill the primary DRM connector with a solid RGB colour.
///
/// # Errors
///
/// Returns an error if the DRM device cannot be opened, if a suitable connector
/// cannot be found, or if any of the KMS ioctls fail.
pub fn fill_display(color: (u8, u8, u8)) -> Result<()> {
    info!("drm_rect: starting");

    let mut card = open_card("/dev/dri/card0")?;
    let res_handles = card
        .resource_handles()
        .context("failed to fetch DRM resource handles")?;

    let connector_info = find_connected_connector(&card, &res_handles)?;
    let connector_handle = connector_info.handle();
    let mode = connector_info
        .modes()
        .first()
        .copied()
        .ok_or_else(|| anyhow!("connected connector {connector_handle:?} reported no modes"))?;
    info!(
        "using connector {connector_handle:?} with mode {}x{} @ {}Hz",
        mode.size().0,
        mode.size().1,
        mode.vrefresh()
    );

    let encoder_handle = connector_info
        .current_encoder()
        .or_else(|| connector_info.encoders().first().copied())
        .ok_or_else(|| anyhow!("connector {connector_handle:?} reported no encoder"))?;
    let encoder = card
        .get_encoder(encoder_handle)
        .with_context(|| format!("failed to query encoder {encoder_handle:?}"))?;
    let crtc_handle = encoder
        .crtc()
        .ok_or_else(|| anyhow!("encoder {encoder_handle:?} reported no CRTC"))?;
    info!("using CRTC {crtc_handle:?}");

    let (width, height) = mode.size();
    let width = u32::from(width);
    let height = u32::from(height);
    info!("allocating dumb buffer {width}x{height}");
    let mut dumb = card
        .create_dumb_buffer((width, height), DrmFourcc::Xrgb8888, 32)
        .context("failed to allocate dumb buffer")?;

    let fb_handle = card
        .add_framebuffer(&dumb, 24, 32)
        .context("failed to create framebuffer")?;
    info!("created framebuffer {fb_handle:?}");

    fill_buffer_with_color(&mut card, &mut dumb, color).context("failed to fill dumb buffer")?;

    info!("setting CRTC {crtc_handle:?} to FB {fb_handle:?}");
    card.set_crtc(
        crtc_handle,
        Some(fb_handle),
        (0, 0),
        &[connector_handle],
        Some(mode),
    )
    .context("failed to set CRTC configuration")?;

    std::thread::sleep(std::time::Duration::from_secs(30));

    if let Err(err) = card.set_crtc(crtc_handle, None, (0, 0), &[], None) {
        warn!("failed to clear CRTC {crtc_handle:?}: {err:?}");
    }

    info!("destroying framebuffer {fb_handle:?}");
    card.destroy_framebuffer(fb_handle)
        .context("failed to destroy framebuffer")?;

    info!("destroying dumb buffer");
    card.destroy_dumb_buffer(dumb)
        .context("failed to destroy dumb buffer")?;

    Ok(())
}

fn open_card(path: &str) -> Result<Card> {
    info!("opening KMS device {path}");
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .with_context(|| format!("failed to open {path}"))?;
    Ok(Card(file))
}

/// Thin wrapper around a `File` so we can implement the DRM device traits.
struct Card(std::fs::File);

impl AsFd for Card {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }
}

impl BasicDevice for Card {}
impl ControlDevice for Card {}

fn find_connected_connector(
    card: &Card,
    res_handles: &drm::control::ResourceHandles,
) -> Result<drm::control::connector::Info> {
    for handle in res_handles.connectors() {
        let info = card
            .get_connector(*handle, true)
            .with_context(|| format!("failed to query connector {handle:?}"))?;
        let state = info.state();
        debug!("connector {handle:?} state {state:?}");
        if state == connector::State::Connected && !info.modes().is_empty() {
            return Ok(info);
        }
    }
    Err(anyhow!(
        "no connected connector with available modes was found"
    ))
}

fn fill_buffer_with_color(card: &mut Card, dumb: &mut DumbBuffer, rgb: (u8, u8, u8)) -> Result<()> {
    let (r, g, b) = rgb;
    info!("mapping dumb buffer to fill with color #{r:02x}{g:02x}{b:02x}");
    let mut mapping = card
        .map_dumb_buffer(dumb)
        .context("failed to map dumb buffer")?;

    for px in mapping.as_mut().chunks_exact_mut(4) {
        px[0] = b;
        px[1] = g;
        px[2] = r;
        px[3] = 0xFF;
    }

    Ok(())
}
