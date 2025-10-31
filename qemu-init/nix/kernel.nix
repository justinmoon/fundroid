{ pkgs, lib }:

# Custom kernel with virtio-gpu and virtio-input support for QEMU testing
# This enables:
# - virtio-gpu for DRM (/dev/dri/card0)  
# - virtio-input for keyboard/mouse (/dev/input/event*)

pkgs.linux_latest.override {
  structuredExtraConfig = with lib.kernel; {
    # DRM and virtio-gpu support (for graphics)
    DRM = yes;
    DRM_VIRTIO_GPU = yes;
    
    # virtio-input support (for keyboard/mouse)
    VIRTIO_INPUT = yes;
    HID_SUPPORT = yes;
    INPUT_EVDEV = yes;
    
    # Basic virtio infrastructure
    VIRTIO = yes;
    VIRTIO_PCI = yes;
    VIRTIO_MMIO = yes;
    VIRTIO_BALLOON = yes;
    VIRTIO_BLK = yes;
    VIRTIO_NET = yes;
    
    # Console/framebuffer support
    FRAMEBUFFER_CONSOLE = yes;
    FB = yes;
    
    # TTY for serial console
    TTY = yes;
    SERIAL_8250 = yes;
    SERIAL_8250_CONSOLE = yes;
  };
}
