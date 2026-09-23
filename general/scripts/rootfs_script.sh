#!/bin/bash
DATE=$(date +%y.%m.%d)
FILE=${TARGET_DIR}/usr/lib/os-release
LATE_OVERLAY_LIST="${BR2_EXTERNAL_GENERAL_PATH}/scripts/late-overlays.list"
LATE_POST_BUILD_HOOKS="${BR2_EXTERNAL_GENERAL_PATH}/scripts/late-post-build-hooks.list"

echo OPENIPC_VERSION=${DATE:0:1}.${DATE:1} >> ${FILE}
date +GITHUB_VERSION="\"${GIT_BRANCH-local}+${GIT_HASH-build}, %Y-%m-%d"\" >> ${FILE}
echo BUILD_OPTION=${OPENIPC_VARIANT} >> ${FILE}
echo BUILD_ID=${BUILD_ID:-local-$(date -u +%Y%m%d)-${GIT_HASH-build}} >> ${FILE}
echo BUILD_SHA=${BUILD_SHA:-${GIT_HASH-build}} >> ${FILE}
echo BUILD_PLATFORM=${BUILD_PLATFORM:-${OPENIPC_SOC_MODEL}_${OPENIPC_VARIANT}} >> ${FILE}
date +TIME_STAMP=%s >> ${FILE}

CONF="USES_GLIBC=y|OSDRV_T30=y|OSDRV_V85X=y|LIBV4L=y|MAVLINK_ROUTER=y|RUBYFPV=y|ONYXFPV=y|WIFIBROADCAST=y|WIFIBROADCAST_NG=y|AUDIO_PROCESSING_OPENIPC=y"
if ! grep -qP ${CONF} ${BR2_CONFIG}; then
	rm -f ${TARGET_DIR}/usr/lib/libstdc++*
fi

if grep -q "USES_MUSL=y" ${BR2_CONFIG}; then
	ln -sf libc.so ${TARGET_DIR}/lib/ld-uClibc.so.0
	ln -sf ../../lib/libc.so ${TARGET_DIR}/usr/bin/ldd
fi

LIST="${BR2_EXTERNAL_GENERAL_PATH}/scripts/excludes/${OPENIPC_SOC_MODEL}_${OPENIPC_VARIANT}.list"
if [ -f "${LIST}" ]; then
	# These lists name files by hand, so they go stale in one direction without
	# anything saying so: a package renames or drops a sensor blob and the entry
	# that used to prune it silently prunes nothing, while the board keeps paying
	# for whatever replaced it. OpenIPC/builder's hi3518ev200_lite list names 25
	# sensor .so files where the package now ships 17. The old form was a single
	# `xargs -a ... rm -f`, which cannot tell the two cases apart -- and fed its
	# `#` separator lines to rm as literal paths besides.
	#
	# Report, never fail: an image that ships a few kB it meant to drop is a
	# size problem to look at, not a reason to break the build.
	stale=0
	total=0
	while IFS= read -r entry || [ -n "${entry}" ]; do
		case "${entry}" in
			''|\#*) continue ;;
		esac
		total=$((total + 1))
		if [ -e "${TARGET_DIR}${entry}" ] || [ -L "${TARGET_DIR}${entry}" ]; then
			rm -f "${TARGET_DIR}${entry}"
		else
			stale=$((stale + 1))
			echo "excludes: ${entry} matched no file"
		fi
	done < "${LIST}"
	if [ ${stale} -gt 0 ]; then
		echo "excludes: ${stale} of ${total} entries in ${LIST##*/} matched no file"
	fi
fi

if [ -f "${LATE_OVERLAY_LIST}" ]; then
	while IFS=: read -r symbol overlay_relpath; do
		[ -n "${symbol}" ] || continue
		case "${symbol}" in
			\#*) continue ;;
		esac

		if grep -q "^${symbol}=y" "${BR2_CONFIG}"; then
			overlay_dir="${BR2_EXTERNAL_GENERAL_PATH}/${overlay_relpath}"
			if [ -d "${overlay_dir}" ]; then
				rsync -a "${overlay_dir}/" "${TARGET_DIR}/"
			fi
		fi
	done < "${LATE_OVERLAY_LIST}"
fi

if [ -f "${LATE_POST_BUILD_HOOKS}" ]; then
	while IFS=: read -r symbol hook_relpath; do
		[ -n "${symbol}" ] || continue
		case "${symbol}" in
			\#*) continue ;;
		esac

		if grep -q "^${symbol}=y" "${BR2_CONFIG}"; then
			hook_script="${BR2_EXTERNAL_GENERAL_PATH}/${hook_relpath}"
			if [ -x "${hook_script}" ]; then
				"${hook_script}" "${TARGET_DIR}"
			fi
		fi
	done < "${LATE_POST_BUILD_HOOKS}"
fi

# Root's login shell on an unclaimed camera is /usr/sbin/openipc-claim (see
# overlay/etc/passwd), and dropbear checks a login shell against /etc/shells
# through getusershell() BEFORE it ever runs -- an unlisted shell is rejected at
# authentication with "Permission denied", so the gate would never get to run
# and, worse, could never disable itself either: the self-heal that puts /bin/sh
# back happens at login, and there is no login. Verified on hi3516ev300, where
# key auth stopped working the moment the shell changed.
#
# Appended here rather than shipped as overlay/etc/shells because the file is
# built up by TARGET_FINALIZE_HOOKS -- busybox adds /bin/ash, skeleton-init
# adds /bin/sh -- and the overlay is rsynced over the target AFTER those hooks
# have run. An overlay copy would replace their work with a hardcoded list that
# goes quietly wrong the next time buildroot changes what it registers. The
# post-build script runs after both, so appending composes with whatever they
# decided. Same grep guard buildroot's own hooks use, so a re-run adds nothing.
CLAIM_SHELL=/usr/sbin/openipc-claim
if [ -x "${TARGET_DIR}${CLAIM_SHELL}" ]; then
	grep -qsE "^${CLAIM_SHELL}\$" "${TARGET_DIR}/etc/shells" \
		|| echo "${CLAIM_SHELL}" >> "${TARGET_DIR}/etc/shells"
fi

# Comments are worth writing and worth keeping in git; they are not worth
# flashing. sysupgrade alone had grown to 52KB, 57% of it comment, and on
# 2026-08-18 it pushed hi3519v101_lite 4KB past its 5120KB rootfs cap -- a board
# that had been sitting at exactly 5120/5120 for some time. Stripping here buys
# 16KB back on that image and ~24KB across all shipped scripts.
#
# Runs LAST, so the late overlays and hooks above are covered too. Discovery is
# by shebang, matching test_shell_parse.sh -- including its one exception,
# /etc/profile, which the login shell sources and which carries no shebang.
STRIPPER="${BR2_EXTERNAL_GENERAL_PATH}/scripts/strip-shell-comments.awk"
if [ -f "${STRIPPER}" ]; then
	STRIP_TMP=$(mktemp)
	STRIP_ERR=$(mktemp)
	# -type f skips the busybox applet symlinks; writing through `cat` rather
	# than `mv` keeps each file's own mode and inode.
	find "${TARGET_DIR}" -type f | while IFS= read -r script; do
		# Weed out binaries before reading a line of one: a rootfs is mostly
		# ELF, and their NUL bytes make the shebang test below warn per file.
		grep -Iq . "${script}" 2>/dev/null || continue

		case "$(head -1 "${script}" 2>/dev/null)" in
			'#!'*sh*) ;;
			*) [ "${script}" = "${TARGET_DIR}/etc/profile" ] || continue ;;
		esac

		awk -f "${STRIPPER}" "${script}" > "${STRIP_TMP}" 2>/dev/null || continue
		# A truncated result means awk gave up half way; keep the original.
		[ -s "${STRIP_TMP}" ] || continue

		# The redirection truncates ${script} before cat writes a byte, so a
		# failure here -- ENOSPC is the realistic one, on a runner that has just
		# built a rootfs -- leaves a half-written or empty script in the image.
		# That is the exact thing this pass must not do: an empty S40network or
		# load_hisilicon still builds green and bricks the camera quietly. There
		# is no original left to restore by then, so fail the build instead.
		if ! cat "${STRIP_TMP}" > "${script}"; then
			echo "rootfs_script: failed to write stripped ${script}" >&2
			echo failed > "${STRIP_ERR}"
			break
		fi
	done

	# `find | while` runs the loop in a subshell, so the failure comes back
	# through the file rather than through its exit status.
	if [ -s "${STRIP_ERR}" ]; then
		rm -f "${STRIP_TMP}" "${STRIP_ERR}"
		exit 1
	fi
	rm -f "${STRIP_TMP}" "${STRIP_ERR}"
fi

# SAZ1051 board fixes -- applied here, after the rootfs overlay and after every
# package, so these copies deterministically win.
if grep -q '^BR2_OPENIPC_SOC_MODEL="saz1051"' "${BR2_CONFIG}"; then
	SAZ_VENDOR="${BR2_EXTERNAL_GENERAL_PATH}/../vendor/saz1051"

	# (1) /init. The stock general/overlay/init used to abort unless
	# /proc/filesystems had "overlay", and this kernel lacked OVERLAY_FS --
	# so a self-contained init was installed as /init. CONFIG_OVERLAY_FS is
	# back in the kernel, so the stock init is the default again: it mounts
	# the ubifs rootfs_data volume (SquashFS-on-UBI, official hisilicon NAND
	# layout) as the overlay upper, which is what makes /etc survive a
	# reboot. The board init stays installed at /opt/oipc/oipc_init.sh for
	# the TF-card route, which selects it explicitly from bootargs
	# (init=/opt/oipc/oipc_init.sh); /init itself must remain the stock one.

	# (1b) Board overrides that must deterministically beat the osdrv
	# package copies (this script runs after every package):
	#   * /usr/bin/load_hisilicon -- this copy derives the MMZ layout from
	#     the cmdline mem= (v5 logic); the osdrv copy trusts totalmem from
	#     the (unreadable) U-Boot env and mis-places mmz at mem=64M.
	#   * /usr/lib/sensors/libsns_os05l10.so -- carries the I2C-write fix.
	# S70vendor (official init chain) execs load_hisilicon via PATH, so the
	# /usr/bin path is the one that must be patched.
	if [ -f "${SAZ_VENDOR}/scripts/load_hisilicon" ]; then
		install -m 0755 "${SAZ_VENDOR}/scripts/load_hisilicon" \
			"${TARGET_DIR}/usr/bin/load_hisilicon"
	fi
	if [ -f "${SAZ_VENDOR}/sensors/libsns_os05l10.so" ]; then
		install -m 0644 "${SAZ_VENDOR}/sensors/libsns_os05l10.so" \
			"${TARGET_DIR}/usr/lib/sensors/libsns_os05l10.so"
	fi

	# (2) majestic. The upstream hisilicon-hi3516cv6xx build is fetched from a
	# *moving* target -- majestic.hi3516cv6xx.lite.master.tar.bz2 on OpenIPC's
	# S3, where the ".master." build is whatever was published last. It no
	# longer matches the binary this board was validated with (776496 B,
	# md5 0705f264... vs the 961368 B build S3 serves today), and majestic is
	# the one component that touches the MPP/VENC path at runtime. Ship the
	# validated binary so the image reproduces the known-good set; drop this
	# override to test the current upstream build instead.
	if [ -f "${SAZ_VENDOR}/majestic" ]; then
		install -m 0755 "${SAZ_VENDOR}/majestic" "${TARGET_DIR}/usr/bin/majestic"
	fi

	# fw_env.config -- 让真 fw_printenv/fw_setenv(/usr/sbin, uboot-tools) 找到
	# NAND env 分区。没有它官方 WebUI network.cgi 的 SSID/PSK 存储链
	# (fw_setenv wlanssid/wlanpass) 静默失效。布局实测: mtd1 env.bin 512K,
	# PEB 128K, U-Boot saveenv 验证过 size 0x40000 读写均 OK。
	printf '/dev/mtd1 0x0 0x40000 0x20000\n' \
		> "${TARGET_DIR}/etc/fw_env.config"
fi
