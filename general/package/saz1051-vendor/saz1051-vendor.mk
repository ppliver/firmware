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
#   * factory board GPIO definition (YHTX_HS_IPC_SAZ1051_gpio.json)
#       -> /etc/gpio, /system/etc/gpio
#       Shipped for on-device documentation; nothing parses it yet.
#   * WS73 USB-WiFi driver ko + RF firmware + wpa_supplicant config
#       -> /opt/saz_wifi, /etc/ws73, /etc/wireless
#   * board init + bring-up scripts  -> /opt/oipc, /opt/tools
#   * majestic.yaml                  -> /etc/majestic.yaml
#   * its own S95majestic            -> /etc/init.d/S95majestic
#
# NOTE (2026-09-30): this board is VIDEO-ONLY. The mic/speaker (audio) and
# PTZ (motor_mx2208a) integration was removed after the audio path could not
# be brought up end-to-end; the device is treated as having no mic, speaker
# or pan/tilt. majestic.yaml keeps audio disabled (enabling it wedges the
# vendor majestic's MPP: RTSP up but zero VENC channels). The osdrv MPP
# audio userspace libs stay installed (upstream package, and the vendor
# majestic binary has hard DT_NEEDED entries on libss_mpi_audio.so etc.) —
# they are just never driven: the audio kernel modules (open_aio/ai/ao/...)
# are no longer shipped, so no codec/AIO device exists.
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

	# ---- factory board GPIO definition ----
	# The authoritative wiring table for this exact model, copied verbatim from
	# the factory system partition (system/etc/gpio/, five identical copies,
	# md5 55525a408e71ba0807388c7a3c0dd3d2) and confirmed field for field by
	# the factory swapp boot log still resident in the data partition:
	#   sw_gpio_init ... ircut_open:-1, ircut_close:-1, led:9, white:10,
	#                     red:6, oth:7, speaker:60, rsetkey:61
	# Nothing in this firmware parses it yet -- it ships so the board wiring is
	# documented on the device itself, and so a future LED / IR-cut helper has
	# a stable source of truth. /etc/gpio mirrors the vendor's own path;
	# /system/etc/gpio is the other location the vendor tree uses.
	# See vendor/saz1051/gpio/SOURCE.txt for the full evidence chain.
	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/gpio $(TARGET_DIR)/system/etc/gpio
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc/gpio \
		$(SAZ1051_VENDOR_TREE)/gpio/YHTX_HS_IPC_SAZ1051_gpio.json
	$(INSTALL) -m 644 -t $(TARGET_DIR)/system/etc/gpio \
		$(SAZ1051_VENDOR_TREE)/gpio/YHTX_HS_IPC_SAZ1051_gpio.json

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
	# Expose the WS73 ko chain under /lib/modules/5.10.221 so OpenIPC's
	# network.cgi adapter_scan() can discover the adapter and offer it in the
	# WebUI "Wireless adapter" dropdown. Runtime loading is still performed by
	# /opt/tools/bringup_wifi.sh via explicit insmod (full ordered sequence +
	# ws73_cfg.ini); this presence only satisfies adapter_scan's
	# `find /lib/modules -name '*.ko'` existence check. The modprobe line in
	# the usb entry (ws73-hi3516cv610-saz1051) references wifi_soc_v15.ko.
	# OPTIMIZATION: install these as *symlinks* to /opt/saz_wifi instead of
	# duplicating the ~2.3 MB of .ko binaries in the rootfs. Both directories
	# live in the same read-only squashfs, so the relative symlink always
	# resolves; `find` follows it, so adapter_scan() is unaffected.
	$(foreach ko,$(wildcard $(SAZ1051_VENDOR_TREE)/wifi/*.ko), \
		ln -sf ../../../opt/saz_wifi/$(notdir $(ko)) \
			$(TARGET_DIR)/lib/modules/5.10.221/$(notdir $(ko)); \
	)

	# ---- board scripts ----
	$(INSTALL) -m 755 -d $(TARGET_DIR)/opt/oipc $(TARGET_DIR)/opt/oipc/sbin $(TARGET_DIR)/opt/tools
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/oipc $(SAZ1051_VENDOR_TREE)/scripts/oipc_init.sh

	# load_hisilicon: oipc_init.sh tests /opt/oipc/load_hisilicon by absolute
	# path (it is not resolved through PATH), so the osdrv copy in /usr/bin does
	# not satisfy it. This is the board build new5 ran (7527 B, a68881c8).
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/oipc $(SAZ1051_VENDOR_TREE)/scripts/load_hisilicon

	# SAZ1051 MPP loader alias (2026-10-08 root-cause fix).
	# The board runs the OFFICIAL PID1 (busybox init -> inittab -> rcS ->
	# /etc/init.d/S70vendor), NOT oipc_init.sh. S70vendor does
	#   vendor=$(ipcinfo -v); load_"$vendor" -i
	# and the SAZ1051 ipcinfo shim reports `-v` as `3516cv610_20s`, so the
	# resolved command is `load_3516cv610_20s`. No such script ships, so MPP
	# (open_*.ko) never loads and the camera has NO video. The rename commit
	# d61cac09 introduced the `3516cv610_20s` token but never created a loader
	# by that name -- this is the regression that broke streaming.
	# Provide a board-scoped alias (in /usr/bin, on rcS's PATH) that resolves
	# S70vendor's command to the real, board-tuned loader. Pointed at the
	# /opt/oipc copy (audio-stripped, sc4336p kernel sensor) that oipc_init.sh
	# also uses -- NOT the osdrv /usr/bin/load_hisilicon -- to stay faithful to
	# the proven new5 bring-up. Board-scoped: lives in this package, not the
	# shared generic overlay, so other boards are unaffected.
	ln -sf /opt/oipc/load_hisilicon $(TARGET_DIR)/usr/bin/load_3516cv610_20s

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

	# ---- chip-report shim over ipctool's /usr/bin/ipcinfo (2026-09-30) ----
	# The die reads hi3516cv613 via ipctool, but the board is a Hi3516CV610 and
	# ALL naming must agree on cv610 (user decision 2026-09-30). WebUI
	# common.cgi:535 does soc=$(ipcinfo --chip-name) through this exact PATH
	# (/usr/bin), and that $soc drives network.cgi adapter_scan()'s token
	# match against the /etc/wireless/usb entry (ws73-hi3516cv610-saz1051).
	# Verified live 2026-09-30: with the real ipctool reporting cv613, a
	# cv610-named entry is filtered out of the "Wireless adapter" dropdown.
	# The real binary stays as /usr/bin/ipcinfo.real; the shim falls through
	# to it for queries it does not answer (--family, --temp, ...).
	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/bin
	if [ -f $(TARGET_DIR)/usr/bin/ipcinfo ] && [ ! -L $(TARGET_DIR)/usr/bin/ipcinfo ]; then \
		mv $(TARGET_DIR)/usr/bin/ipcinfo $(TARGET_DIR)/usr/bin/ipcinfo.real; \
	fi
	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin \
		$(SAZ1051_VENDOR_TREE)/scripts/oipc_sbin/ipcinfo

	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/tools $(SAZ1051_VENDOR_TREE)/scripts/sensor_mux.sh
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/tools $(SAZ1051_VENDOR_TREE)/scripts/bringup_wifi.sh
	$(INSTALL) -m 755 -t $(TARGET_DIR)/opt/tools $(SAZ1051_VENDOR_TREE)/scripts/os05l10_replay.sh

	# Official init chain: bring the WS73 radio up after S40network and
	# S41bootmsg. The TF route reaches the same bring-up from oipc_init.sh.
	$(INSTALL) -m 755 -t $(TARGET_DIR)/etc/init.d $(SAZ1051_VENDOR_TREE)/scripts/S42saz_wifi

	# S94saz_warmup: MIPI lane-mode warm-up. Runs AFTER the vendor init that
	# loads the MPP/sensor modules (S70vendor) and BEFORE S95majestic. Root
	# cause it fixes: open_mipi_rx needs lane mode set (via majestic
	# SET_DEV_ATTR) before ENABLE_CLOCK/UNRESET; a cold boot leaves lane mode
	# unset -> PHY never unparks -> VI gets no frames -> black RTSP. The
	# script runs majestic -s once to set lane mode, stops it, then reloads
	# open_isp (lane mode persists) so the real S95majestic gets a live link.
	$(INSTALL) -m 755 -t $(TARGET_DIR)/etc/init.d $(SAZ1051_VENDOR_TREE)/scripts/S94saz_warmup

	# Overrides the copy the generic `majestic` package installs (this package
	# depends on it, so generic installs first). Diff vs upstream: the daemon
	# launch inside start()'s subshell exports SENSOR=os05l10 and
	# MMZ_RESERVE_M=48 — without them an S95-launched majestic brings up the
	# web server but NEVER creates the VENC channels (RTSP answers 200 to
	# DESCRIBE/SETUP yet PLAY yields zero RTP bytes; verified 2026-09-30 with
	# and without the exports). Upstream's SIGHUP reasoning is preserved.
	$(INSTALL) -m 755 -t $(TARGET_DIR)/etc/init.d \
		$(SAZ1051_VENDOR_TREE)/scripts/S95majestic

	# ---- majestic config ----
	# audio stays DISABLED (see the audio block in vendor/saz1051/majestic.yaml):
	# with it enabled the vendor majestic's audio init dies on open_acodec,
	# wedges the MPP and every later run has RTSP but no VENC channels.
	# The audio kernel modules are not shipped anymore (video-only board).
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

# No BUILD_CMDS: everything installed is a prebuilt blob or a plain script.
# (The former libmajaudio.so / swmotor_ctl target builds went away with the
# audio/PTZ removal — video-only board since 2026-09-30.)

# Installed last so it overrides OpenIPC's from-source majestic binary and the
# WebUI files (the `-v` probe patch must run after majestic-webui installs).
# ipctool must install BEFORE this package so the /usr/bin/ipcinfo shim can
# move the real binary aside.
SAZ1051_VENDOR_DEPENDENCIES = majestic majestic-webui ipctool

$(eval $(generic-package))
