#!/usr/bin/env python3
import struct
import sys
from pathlib import Path

def extract_ramdisk(boot_img_path, output_path):
    with open(boot_img_path, 'rb') as f:
        magic = f.read(8)
        if magic != b'ANDROID!':
            print(f"Error: Not an Android boot image (magic: {magic})", file=sys.stderr)
            sys.exit(1)
        
        kernel_size = struct.unpack('<I', f.read(4))[0]
        kernel_addr = struct.unpack('<I', f.read(4))[0]
        ramdisk_size = struct.unpack('<I', f.read(4))[0]
        ramdisk_addr = struct.unpack('<I', f.read(4))[0]
        second_size = struct.unpack('<I', f.read(4))[0]
        second_addr = struct.unpack('<I', f.read(4))[0]
        tags_addr = struct.unpack('<I', f.read(4))[0]
        page_size = struct.unpack('<I', f.read(4))[0]
        header_version = struct.unpack('<I', f.read(4))[0]
        
        print(f"Header version: {header_version}", file=sys.stderr)
        print(f"Page size: {page_size}", file=sys.stderr)
        print(f"Kernel size: {kernel_size}", file=sys.stderr)
        print(f"Ramdisk size: {ramdisk_size}", file=sys.stderr)
        
        kernel_pages = (kernel_size + page_size - 1) // page_size
        ramdisk_offset = page_size * (1 + kernel_pages)
        
        print(f"Ramdisk offset: {ramdisk_offset}", file=sys.stderr)
        
        f.seek(ramdisk_offset)
        ramdisk = f.read(ramdisk_size)
        
        if len(ramdisk) != ramdisk_size:
            print(f"Error: Read {len(ramdisk)} bytes, expected {ramdisk_size}", file=sys.stderr)
            sys.exit(1)
        
        with open(output_path, 'wb') as out:
            out.write(ramdisk)
        
        print(f"Extracted {ramdisk_size} bytes to {output_path}", file=sys.stderr)

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <boot.img> <ramdisk.out>", file=sys.stderr)
        sys.exit(1)
    
    extract_ramdisk(sys.argv[1], sys.argv[2])
