#!/bin/bash
DATE=$(date +%y.%m.%d)
FILE=${TARGET_DIR}/usr/lib/os-release

echo OPENIPC_VERSION=${DATE:0:1}.${DATE:1} >> ${FILE}
date +GITHUB_VERSION="\"${GIT_BRANCH-local}+${GIT_HASH-build}, %Y-%m-%d"\" >> ${FILE}
echo BUILD_OPTION=${OPENIPC_VARIANT} >> ${FILE}
date +TIME_STAMP=%s >> ${FILE}

CONF="USES_GLIBC=y|INGENIC_OSDRV_T30=y|LIBV4L=y|MAVLINK_ROUTER=y|RUBYFPV=y|WEBRTC_AUDIO_PROCESSING_OPENIPC=y|WIFIBROADCAST=y"
if ! grep -qP ${CONF} ${BR2_CONFIG}; then
	rm -f ${TARGET_DIR}/usr/lib/libstdc++*
fi

if grep -q "USES_MUSL" ${BR2_CONFIG}; then
	ln -sf libc.so ${TARGET_DIR}/lib/ld-uClibc.so.0
	ln -sf ../../lib/libc.so ${TARGET_DIR}/usr/bin/ldd
fi

LIST="${BR2_EXTERNAL_GENERAL_PATH}/scripts/excludes/${OPENIPC_SOC_MODEL}_${OPENIPC_VARIANT}.list"
if [ -f ${LIST} ]; then
	xargs -a ${LIST} -I % rm -f ${TARGET_DIR}%
fi

# SAZ1051: replace the stock /init (which requires OVERLAY_FS, absent in our
# kernel -> it would `exit 1` and panic) with our self-contained board init.
# This runs AFTER the rootfs overlay is applied, so it wins over
# general/overlay/init. oipc_init.sh is installed to /opt/oipc by the
# saz1051-vendor package; we copy it to /init here.
if grep -q '^BR2_OPENIPC_SOC_MODEL="saz1051"' "${BR2_CONFIG}"; then
	VENDOR_INIT="${BR2_EXTERNAL_GENERAL_PATH}/../vendor/saz1051/scripts/oipc_init.sh"
	if [ -f "${VENDOR_INIT}" ]; then
		install -m 0755 "${VENDOR_INIT}" "${TARGET_DIR}/init"
	fi
fi
