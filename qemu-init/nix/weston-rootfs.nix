{ pkgs ? import <nixpkgs> {} }:

# Use symlinkJoin instead of buildEnv to get better library linking
pkgs.symlinkJoin {
  name = "weston-rootfs";
  
  paths = with pkgs; [
    # Core Weston Stack
    weston
    mesa
    libdrm
    wayland  # Provides libwayland-client.so, libwayland-server.so, etc.
    wayland-protocols
    pixman
    # Note: Using minimal glibc from qemu-init/ instead of full glibc package
    
    # Session/Seat Management
    seatd
    libinput
    libxkbcommon
    
    # Input/Event Handling
    libevdev
    mtdev
    
    # Graphics and Rendering
    cairo
    pango
    
    # Font Support
    fontconfig
    dejavu_fonts
    liberation_ttf
    
    # Image Libraries
    libpng
    libjpeg
    
    # XCursor for mouse cursors
    xorg.xcursorthemes
    
    # Icon themes
    hicolor-icon-theme
    
    # Wayland utilities for debugging
    wayland-utils
  ];
}
