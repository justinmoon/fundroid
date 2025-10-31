{ pkgs ? import <nixpkgs> {} }:

# Custom NixOS Linux kernel for QEMU init testing  
# Builds virtio-gpu and virtio-input as built-in (not modules)
# This ensures /dev/dri/card0 appears at boot without module loading

pkgs.linuxPackages_latest.kernel.override {
  structuredExtraConfig = with pkgs.lib.kernel; {
    # Build virtio-gpu into the kernel (not as module)
    DRM_VIRTIO_GPU = yes;
    
    # Build virtio core and PCI into kernel (not as modules)
    VIRTIO = yes;
    VIRTIO_PCI = yes;
    VIRTIO_INPUT = yes;
    
    # Input event device support  
    INPUT_EVDEV = yes;
  };
}
