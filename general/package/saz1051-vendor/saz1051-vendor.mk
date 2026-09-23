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
# MPP userspace .so come from the upstream hisilicon-osdrv-hi3516cv6xx package
# (selected alongside this one). That package also drops a load_hisilicon in
# /usr/bin, but oipc_init.sh does NOT reach the loader through PATH -- it tests
# the literal path /opt/oipc/load_hisilicon. With only the osdrv copy present the
# init takes the `else` branch, prints "[1] load_hisilicon MISSING" and loads no
# MPP module at all (no /dev/ot_mipi_rx, no sensor, no stream), so this package
# must ship the board copy too.
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
	$(INSTALL) -m 755 -d $(TARGET_DIR)/opt/oipc $(TARGET_DIR)/opt/oipc/sbin $(TARGET_DIR)/opt/tools
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/oipc $(SAZ1051_VENDOR_TREE)/scripts/oipc_init.sh

	# load_hisilicon: oipc_init.sh tests /opt/oipc/load_hisilicon by absolute
	# path (it is not resolved through PATH), so the osdrv copy in /usr/bin does
	# not satisfy it. This is the board build new5 ran (7527 B, a68881c8).
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/oipc $(SAZ1051_VENDOR_TREE)/scripts/load_hisilicon

	# /opt/oipc/sbin sits first on oipc_init.sh's PATH and deliberately shadows
	# the real tools:
	#   modprobe   -- busybox `modprobe <name>` cannot resolve hisilicon/open_*.ko
	#                 (subdirectory, and modprobe-small ignores modules.dep), while
	#                 load_hisilicon's insert_ko() runs `modprobe open_*` after a
	#                 cd. The shim insmods by absolute path instead.
	#   fw_printenv/ipcinfo -- pin totalmem=64M / osmem=32M / sensor=os05l10 so the
	#                 MMZ geometry does not depend on reading the U-Boot env.
	#   fw_setenv  -- set_allocator() writes mmz_allocator; no-op here.
	# Byte-identical to the running new5 image.
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/oipc/sbin $(wildcard $(SAZ1051_VENDOR_TREE)/scripts/oipc_sbin/*)

	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/tools $(SAZ1051_VENDOR_TREE)/scripts/sensor_mux.sh
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/tools $(SAZ1051_VENDOR_TREE)/scripts/bringup_wifi.sh
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/tools $(SAZ1051_VENDOR_TREE)/scripts/os05l10_replay.sh

	# ---- majestic config (validated: video0 only, audio/HLS off) ----
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc $(SAZ1051_VENDOR_TREE)/majestic.yaml

	# ---- proven-streaming majestic binary ----
	# The prebuilt vendor majestic (in this tree) is the binary that has been
	# validated to actually produce an RTSP stream on this board's MPP. OpenIPC's
	# from-source majestic for hi3516cv6xx has never been validated against our
	# prebuilt open_*.ko (CONFIG_PM=n ABI), so we install the vendor binary LAST
	# (this package depends on `majestic`) to override /usr/bin/majestic.
	# NOTE: this vendor binary's `-v` busy-loops; the WebUI patch below neutralizes
	# the version probe so the deadloop can never peg the CPU / OOM the box.
	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin $(SAZ1051_VENDOR_TREE)/majestic

	# ---- defensive WebUI fix: neutralize `majestic -v` version probe ----
	# Runs after majestic-webui is installed (this package depends on it).
	# Use `sh` so it does not depend on the execute bit (git does not track it
	# reliably on Windows checkouts).
	sh $(SAZ1051_VENDOR_TREE)/scripts/patch_webui.sh $(TARGET_DIR)

endef

# Installed last so it overrides OpenIPC's from-source majestic binary and the
# WebUI files (the `-v` probe patch must run after majestic-webui installs).
SAZ1051_VENDOR_DEPENDENCIES = majestic majestic-webui

$(eval $(generic-package))
