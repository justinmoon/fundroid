{ pkgs ? import <nixpkgs> {} }:

# Build a complete rootfs with ALL runtime dependencies for Weston
# Uses closureInfo to get the full transitive dependency tree
# This ensures all shared libraries (libinput, libudev, etc.) are included

let
  # Get all runtime dependencies of weston and seatd
  westonClosure = pkgs.closureInfo { rootPaths = [ pkgs.weston pkgs.seatd ]; };
in

# Create a rootfs by copying all files from the closure
pkgs.runCommand "weston-rootfs-optimized" {
  # Ensure we can access the closure paths
  inherit westonClosure;
} ''
  mkdir -p $out/{bin,lib,share,etc}
  
  echo "Building Weston rootfs from closure..."
  
  # Copy all files from each store path in the closure
  # BUT be selective to reduce size (initramfs has limits)
  while IFS= read -r path; do
    # Copy binaries
    if [ -d "$path/bin" ]; then
      cp -rL "$path/bin"/* $out/bin/ 2>/dev/null || true
    fi
    
    # Copy ONLY .so libraries (not .a, .la, pkgconfig, etc. to save space)
    if [ -d "$path/lib" ]; then
      # Copy shared libraries recursively, preserving directory structure
      # First copy all .so* files (actual files)
      find "$path/lib" -name "*.so*" -type f | while read -r lib; do
        relpath="''${lib#$path/lib/}"
        mkdir -p "$out/lib/$(dirname "$relpath")"
        cp -L "$lib" "$out/lib/$relpath" 2>/dev/null || true
      done
      # Then copy symlinks to preserve lib versioning (libfoo.so.1 -> libfoo.so.1.2.3)
      find "$path/lib" -name "*.so*" -type l | while read -r link; do
        relpath="''${link#$path/lib/}"
        mkdir -p "$out/lib/$(dirname "$relpath")"
        # Get the target of the symlink
        target=$(readlink "$link")
        # Create relative symlink
        ln -sf "$target" "$out/lib/$relpath" 2>/dev/null || true
      done
      # Copy udev rules if present
      if [ -d "$path/lib/udev" ]; then
        mkdir -p $out/lib/udev
        cp -rL "$path/lib/udev"/* $out/lib/udev/ 2>/dev/null || true
      fi
    fi
    
    # Copy ONLY essential shared resources (skip docs, locales, man pages)
    if [ -d "$path/share" ]; then
      # Copy fonts (essential for text rendering)
      if [ -d "$path/share/fonts" ]; then
        mkdir -p $out/share/fonts
        cp -rL "$path/share/fonts"/* $out/share/fonts/ 2>/dev/null || true
      fi
      # Copy icons (for UI)
      if [ -d "$path/share/icons" ]; then
        mkdir -p $out/share/icons
        cp -rL "$path/share/icons"/* $out/share/icons/ 2>/dev/null || true
      fi
      # Copy wayland protocols
      if [ -d "$path/share/wayland" ]; then
        mkdir -p $out/share/wayland
        cp -rL "$path/share/wayland"/* $out/share/wayland/ 2>/dev/null || true
      fi
      # Copy weston data
      if [ -d "$path/share/weston" ]; then
        mkdir -p $out/share/weston
        cp -rL "$path/share/weston"/* $out/share/weston/ 2>/dev/null || true
      fi
    fi
    
    # Skip etc configs - we provide our own weston.ini
  done < ${westonClosure}/store-paths
  
  echo "Rootfs created with $(find $out -type f | wc -l) files"
  
  # Verify key libraries are present
  echo "Verifying critical libraries:"
  ls -la $out/lib/libinput* 2>/dev/null && echo "  ✓ libinput found" || echo "  ✗ libinput MISSING"
  ls -la $out/lib/libwayland* 2>/dev/null && echo "  ✓ libwayland found" || echo "  ✗ libwayland MISSING"
  ls -la $out/lib/libudev* 2>/dev/null && echo "  ✓ libudev found" || echo "  ✗ libudev MISSING"
  
  echo "Build complete!"
''
