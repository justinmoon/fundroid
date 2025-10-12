PRODUCT_NAME := webos_cf_x86_64
PRODUCT_DEVICE := vsoc_x86_64
PRODUCT_BRAND := webos
PRODUCT_MODEL := webos for Cuttlefish (x86_64)
PRODUCT_MANUFACTURER := webos

$(call inherit-product, device/google/cuttlefish/vsoc_x86_64/device.mk)

PRODUCT_PACKAGES += \
    webosd

PRODUCT_COPY_FILES += \
    vendor/webos/init.webosd.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/init.webosd.rc
