################################################################################
#
# saz1051-vendor
#
# Board-specific firmware blobs for the SAZ1051 (Hi3516CV610 + OS05L10 + WS73)
# 128MB SPI-NAND camera. Ships prebuilt vendor artifacts that are NOT built from
# source in this tree:
#   * MPP kernel modules (open_*.ko, CONFIG_PM=n ABI, vermagic 5.10.221)
#       -> /lib/modules/5.10.221/hisilicon
#   * OS05L10 sensor userspace lib + ini
#       -> /usr/lib/sensors, /etc/sensors, /etc, /system/etc
#   * WS73 USB-WiFi driver ko + RF firmware + wpa_supplicant config
#       -> /opt/saz_wifi, /etc/ws73, /etc/wireless
#   * board init + bring-up scripts  -> /opt/oipc, /opt/tools
#   * majestic.yaml                  -> /etc/majestic.yaml
#
# MPP userspace .so and the 128MB-tuned load_hisilicon come from the upstream
# hisilicon-osdrv-hi3516cv6xx package (selected alongside this one). That
# package installs load_hisilicon to /usr/bin, which is what oipc_init.sh calls
# (its PATH puts /usr/bin ahead of /opt/oipc).
#
# ABI note: the prebuilt open_*.ko were built against a kernel configured with
# CONFIG_PM=n, matching saz1051.generic.config. Shipping them (instead of
# building from hisilicon-opensdk source) preserves that ABI — the proven
# working setup from the device's new5 image.
#
################################################################################

SAZ1051_VENDOR_VERSION =
SAZ1051_VENDOR_LICENSE = "PROPRIETARY"
SAZ1051_VENDOR_LICENSE_FILES = LICENSE

# Vendor tree lives outside the package dir, at <ext>/../vendor/saz1051
SAZ1051_VENDOR_TREE = $(BR2_EXTERNAL)/../vendor/saz1051

define SAZ1051_VENDOR_INSTALL_TARGET_CMDS

	# ---- MPP kernel modules (prebuilt, CONFIG_PM=n, vermagic 5.10.221) ----
	$(INSTALL) -m 755 -d $(TARGET_DIR)/lib/modules/5.10.221/hisilicon
	$(foreach ko,$(wildcard $(SAZ1051_VENDOR_TREE)/ko/open_*.ko), \
		$(INSTALL) -m 644 -t $(TARGET_DIR)/lib/modules/5.10.221/hisilicon $(ko); \
	)
	# Minimal modules.dep so busybox modprobe can resolve `open_*` by name
	# (load_hisilicon does `modprobe open_osal` etc., cd'd into this dir).
	# Hand-written to avoid depending on host depmod tooling; the ko vermagic
	# already matches the running 5.10.221 kernel, so force-load is not needed.
	{ cd $(TARGET_DIR)/lib/modules/5.10.221/hisilicon && \
	  for f in open_*.ko; do echo "hisilicon/$$f:"; done; } \
	  > $(TARGET_DIR)/lib/modules/5.10.221/modules.dep

	# ---- OS05L10 sensor (userspace lib + ini, mirrored to 3 locations) ----
	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/lib/sensors
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/lib/sensors \
		$(SAZ1051_VENDOR_TREE)/sensors/libsns_os05l10.so
	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/sensors $(TARGET_DIR)/etc $(TARGET_DIR)/system/etc
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/sensors $(SAZ1051_VENDOR_TREE)/sensors/os05l10.ini
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc          $(SAZ1051_VENDOR_TREE)/sensors/os05l10.ini
	$(INSTALL) -m 644 -t $(TARGET_DIR)/system/etc   $(SAZ1051_VENDOR_TREE)/sensors/os05l10.ini

	# ---- WS73 USB WiFi ----
	$(INSTALL) -m 755 -d $(TARGET_DIR)/opt/saz_wifi
	$(foreach ko,$(wildcard $(SAZ1051_VENDOR_TREE)/wifi/*.ko), \
		$(INSTALL) -m 644 -t $(TARGET_DIR)/opt/saz_wifi $(ko); \
	)
	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/wireless
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/wireless \
		$(SAZ1051_VENDOR_TREE)/wifi/wpa_supplicant.conf
	# RF firmware: plat_soc.ko filp_open's /etc/ws73/ws73.bin at load time;
	# missing -> wlan_power_open_cmd waits forever (D-state hang). Ship all 4.
	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/ws73
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/ws73 $(SAZ1051_VENDOR_TREE)/wifi/ws73/btc_cali.bin
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/ws73 $(SAZ1051_VENDOR_TREE)/wifi/ws73/wifi_cali.bin
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/ws73 $(SAZ1051_VENDOR_TREE)/wifi/ws73/wow.bin
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/ws73 $(SAZ1051_VENDOR_TREE)/wifi/ws73/ws73.bin
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc        $(SAZ1051_VENDOR_TREE)/wifi/ws73_cfg.ini
	$(INSTALL) -m 644 -t $(TARGET_DIR)/system/etc $(SAZ1051_VENDOR_TREE)/wifi/ws73_cfg.ini

	# ---- board scripts ----
	$(INSTALL) -m 755 -d $(TARGET_DIR)/opt/oipc $(TARGET_DIR)/opt/tools
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/oipc $(SAZ1051_VENDOR_TREE)/scripts/oipc_init.sh
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/tools $(SAZ1051_VENDOR_TREE)/scripts/sensor_mux.sh
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/tools $(SAZ1051_VENDOR_TREE)/scripts/bringup_wifi.sh
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/tools $(SAZ1051_VENDOR_TREE)/scripts/os05l10_replay.sh

	# ---- majestic config (validated: video0 only, audio/HLS off) ----
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc $(SAZ1051_VENDOR_TREE)/majestic.yaml

endef

$(eval $(generic-package))
