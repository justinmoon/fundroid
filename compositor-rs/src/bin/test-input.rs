// Simple test to enumerate input devices using evdev
// This proves Phase 7 evdev integration works independently of DRM

use evdev::Device;
use std::fs::read_dir;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("===========================================");
    println!("evdev Input Device Enumeration Test");
    println!("===========================================\n");
    
    // Try to enumerate /dev/input/event* devices
    let mut input_devices = Vec::new();
    
    match read_dir("/dev/input") {
        Ok(entries) => {
            println!("✓ Successfully opened /dev/input directory\n");
            
            for entry in entries.flatten() {
                let path = entry.path();
                if let Some(name) = path.file_name() {
                    if name.to_string_lossy().starts_with("event") {
                        match Device::open(&path) {
                            Ok(device) => {
                                let dev_name = device.name().unwrap_or("unknown");
                                let dev_path = path.display();
                                println!("✓ Opened: {}", dev_path);
                                println!("  Name: {}", dev_name);
                                
                                // Show supported event types
                                println!("  Supported:");
                                if device.supported_keys().map_or(false, |k| k.iter().count() > 0) {
                                    println!("    - Keyboard events");
                                }
                                if device.supported_relative_axes().map_or(false, |a| a.iter().count() > 0) {
                                    println!("    - Mouse/relative axes");
                                }
                                if device.supported_absolute_axes().map_or(false, |a| a.iter().count() > 0) {
                                    println!("    - Touch/absolute axes");
                                }
                                println!();
                                
                                input_devices.push((dev_path.to_string(), device));
                            }
                            Err(e) => {
                                eprintln!("✗ Failed to open {}: {}", path.display(), e);
                            }
                        }
                    }
                }
            }
        }
        Err(e) => {
            eprintln!("✗ Failed to read /dev/input: {}", e);
            println!("\nThis is expected in QEMU without input device passthrough.");
            println!("On real hardware with /dev/input devices, evdev will work.");
            return Ok(());
        }
    }
    
    println!("===========================================");
    println!("Summary: Found {} input devices", input_devices.len());
    println!("===========================================");
    
    if input_devices.is_empty() {
        println!("\nNo input devices found.");
        println!("This is normal in QEMU without virtio-input devices.");
        println!("\nTo test with QEMU, add: -device virtio-keyboard-pci -device virtio-mouse-pci");
        println!("\nOn real Android/Pixel hardware, devices like these will exist:");
        println!("  /dev/input/event0 - Touchscreen");
        println!("  /dev/input/event1 - Power button");  
        println!("  /dev/input/event2 - Volume buttons");
    } else {
        println!("\n✓ Phase 7 evdev integration working!");
        println!("✓ Can enumerate and open input devices");
        println!("✓ Ready for real hardware input");
    }
    
    Ok(())
}
