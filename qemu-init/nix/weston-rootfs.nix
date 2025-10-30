{ pkgs ? import <nixpkgs> {} }:

pkgs.buildEnv {
  name = "weston-rootfs";
  
  paths = with pkgs; [
    # Core Weston Stack
    weston
    mesa
    libdrm
    wayland
    wayland-protocols
    pixman
    
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
  
  pathsToLink = [
    "/bin"
    "/lib"
    "/share"
    "/etc"
  ];
}
