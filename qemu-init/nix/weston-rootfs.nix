{ pkgs ? import <nixpkgs> {} }:

# Build a complete rootfs with all runtime dependencies for Weston
# Uses buildEnv to create a unified directory structure

let
  # Get all runtime dependencies of weston
  westonClosure = pkgs.closureInfo { rootPaths = [ pkgs.weston ]; };
in

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
    libinput.out      # Explicitly get the library output
    libxkbcommon
    
    # Additional runtime dependencies that buildEnv might miss
    glib
    expat
    libffi
    pcre2
    util-linux  # For libuuid, libmount
    systemd     # For libudev
    mtdev
    libevdev
    
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
