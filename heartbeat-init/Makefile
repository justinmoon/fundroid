.PHONY: all clean repack

BINARY := heartbeat_init
CC := zig cc
CFLAGS := -target x86_64-linux-musl -static -O2 -Wall -Wextra
INIT_BOOT_SRC ?=
INIT_BOOT_OUT ?= init_boot.img
WORKDIR := $(shell pwd)/.build
AVBTOOL ?= avbtool
AVB_KEY ?= $(shell pwd)/../third_party/avb/testkey_rsa4096.pem
PARTITION_NAME ?= init_boot

all: $(BINARY)

$(BINARY): heartbeat_init.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(BINARY)
	rm -rf $(WORKDIR)

repack: $(BINARY)
	@if [ -z "$(INIT_BOOT_SRC)" ]; then \
		echo "Error: INIT_BOOT_SRC not set. Usage: make repack INIT_BOOT_SRC=/path/to/init_boot.img" >&2; \
		exit 1; \
	fi
	@if [ ! -f "$(INIT_BOOT_SRC)" ]; then \
		echo "Error: init_boot source image not found: $(INIT_BOOT_SRC)" >&2; \
		exit 1; \
	fi
	@echo "Repacking $(INIT_BOOT_SRC) -> $(INIT_BOOT_OUT)"
	@mkdir -p $(WORKDIR)
	@echo "Extracting boot image with unpack_bootimg..."
	@cd $(WORKDIR) && unpack_bootimg --boot_img "$(abspath $(INIT_BOOT_SRC))" --out . --format=mkbootimg > mkbootimg_args.txt 2>&1
	@test -f "$(WORKDIR)/mkbootimg_args.txt" || { echo "Error: mkbootimg_args.txt not produced. Update Android mkbootimg/unpack_bootimg tools." >&2; exit 1; }
	@echo "Decompressing ramdisk..."
	@cd $(WORKDIR) && ( \
		case "$$(file -b ramdisk)" in \
			*LZ4*) lz4 -d ramdisk ramdisk.cpio ;; \
			*gzip*) gunzip -c ramdisk > ramdisk.cpio ;; \
			*) cp ramdisk ramdisk.cpio ;; \
		esac \
	)
	@echo "Modifying ramdisk: renaming /init to /init.stock and adding heartbeat_init as /init..."
	@python3 ../scripts/cpio_edit.py \
		-i $(WORKDIR)/ramdisk.cpio \
		-o $(WORKDIR)/ramdisk_modified.cpio \
		--rename init=init.stock \
		--add init=$(abspath $(BINARY))
	@echo "Compressing modified ramdisk (lz4 -l legacy header)..."
	@cd $(WORKDIR) && lz4 -l -9 ramdisk_modified.cpio ramdisk_modified
	@echo "Repacking boot image with mkbootimg (preserving original args)..."
	@cd $(WORKDIR) && mkbootimg $$(sed 's|--ramdisk [^ ]*|--ramdisk ramdisk_modified|' mkbootimg_args.txt) \
		--output "$(abspath $(INIT_BOOT_OUT))"
	@echo "Signing $(INIT_BOOT_OUT) with AVB hash footer..."
	@command -v $(AVBTOOL) >/dev/null 2>&1 || { echo "Error: avbtool not found. Set AVBTOOL=/path/to/avbtool" >&2; exit 1; }
	@test -f "$(AVB_KEY)" || { echo "Error: AVB key not found at $(AVB_KEY). Set AVB_KEY=/path/to/testkey_rsa4096.pem" >&2; exit 1; }
	@$(AVBTOOL) info_image --image "$(abspath $(INIT_BOOT_SRC))" > "$(WORKDIR)/avb_info_stock.txt"
	@PARTITION_SIZE=$$(awk -F: '/[Ii]mage size:/ {gsub(/^[ \t]+| bytes$$/,"",$$2); print $$2; exit}' "$(WORKDIR)/avb_info_stock.txt"); \
	 ALGO=$$(awk -F: '/Algorithm:/ {gsub(/^[ \t]+/,"",$$2); print $$2; exit}' "$(WORKDIR)/avb_info_stock.txt"); \
	 RBI=$$(awk -F: '/Rollback Index:/ {gsub(/^[ \t]+/,"",$$2); print $$2; exit}' "$(WORKDIR)/avb_info_stock.txt"); \
	 RBIL=$$(awk -F: '/Rollback Index Location:/ {gsub(/^[ \t]+/,"",$$2); print $$2; exit}' "$(WORKDIR)/avb_info_stock.txt"); \
	 SALT=$$(awk -F: '/Salt:/ {gsub(/^[ \t]+/,"",$$2); print $$2; exit}' "$(WORKDIR)/avb_info_stock.txt"); \
	 test -n "$$PARTITION_SIZE" || { echo "Error: could not extract partition_size from stock image" >&2; exit 1; }; \
	 echo "Using: partition_name=$(PARTITION_NAME) partition_size=$$PARTITION_SIZE algo=$$ALGO rb_index=$$RBI rb_loc=$$RBIL"; \
	 NEW_SIZE=$$(stat -f%z "$(abspath $(INIT_BOOT_OUT))" 2>/dev/null || stat -c%s "$(abspath $(INIT_BOOT_OUT))"); \
	 if [ "$$PARTITION_SIZE" -le "$$NEW_SIZE" ]; then \
	   echo "Error: init_boot.img (size $$NEW_SIZE) exceeds partition_size $$PARTITION_SIZE" >&2; exit 1; \
	 fi; \
	 $(AVBTOOL) add_hash_footer \
	   --image "$(abspath $(INIT_BOOT_OUT))" \
	   --partition_name "$(PARTITION_NAME)" \
	   --partition_size "$$PARTITION_SIZE" \
	   --algorithm "$${ALGO:-SHA256_RSA4096}" \
	   --key "$(AVB_KEY)" \
	   $$(test -n "$$RBI" && echo "--rollback_index $$RBI") \
	   $$(test -n "$$RBIL" && echo "--rollback_index_location $$RBIL") \
	   $$(test -n "$$SALT" && echo "--salt $$SALT")
	@echo "AVB footer added successfully"
	@$(AVBTOOL) info_image --image "$(abspath $(INIT_BOOT_OUT))" | head -20
	@echo "Created $(INIT_BOOT_OUT)"
