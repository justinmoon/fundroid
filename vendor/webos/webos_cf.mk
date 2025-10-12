$(call inherit-product, device/google/cuttlefish/vsoc_x86_64/phone/device.mk)

PRODUCT_NAME := webos_cf_x86_64
PRODUCT_DEVICE := vsoc_x86_64
PRODUCT_BRAND := webos
PRODUCT_MODEL := WebOS Dev CF
PRODUCT_MANUFACTURER := webos

PRODUCT_PACKAGES += \
    webosd

PRODUCT_COPY_FILES += \
    vendor/webos/init.webosd.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/init.webosd.rc

PRODUCT_PROPERTY_OVERRIDES += \
    ro.webos.noframework=1 \
    persist.webosd.enabled=1
