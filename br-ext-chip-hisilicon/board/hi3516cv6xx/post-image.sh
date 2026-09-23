#!/bin/bash
#
# Post-image script for the Hi3516CV6xx board family (NAND + NOR).
# Buildroot invokes it as: post-image.sh <BINARIES_DIR>
#
# It builds a U-Boot FIT (kernel zImage + dtb) for every variant, then:
#   * NAND build (rootfs.ubi present)  -> copy the FIT to images/uImage
#     so the top-level `make repack` tars uImage + rootfs.ubi. U-Boot on
#     SAZ1051 only boots a FIT image, so uImage here IS a FIT.
#   * NOR  build (rootfs.squashfs present) -> append the FIT to squashfs as
#     firmware.bin (legacy combined image) and also expose it as uImage for
#     the repack tarball.

BINARIES_DIR=$1
BOARD_DIR="$(dirname "$0")"
ITS_SOURCE="fit-image.its"
ERASEBLOCK_SIZE=$((64 * 1024))

# --- Build the FIT (shared) ---
cp ${BINARIES_DIR}/hi35*.dtb ${BINARIES_DIR}/fdt.dtb
cp ${BOARD_DIR}/${ITS_SOURCE} ${BINARIES_DIR}/

# The kernel image may be zImage (uncompressed) or zImage.xz (XZ). The ITS
# incbins "zImage"; normalize so mkimage always finds a zImage to embed.
if [ -e ${BINARIES_DIR}/zImage.xz ]; then
	cp ${BINARIES_DIR}/zImage.xz ${BINARIES_DIR}/zImage
fi

mkimage -f ${BINARIES_DIR}/${ITS_SOURCE} ${BINARIES_DIR}/fitImage

if [ -e ${BINARIES_DIR}/rootfs.ubi ]; then
	# NAND (SAZ1051): repack expects images/uImage (a FIT) + rootfs.ubi.
	cp ${BINARIES_DIR}/fitImage ${BINARIES_DIR}/uImage
else
	# NOR: append fitImage to squashfs as firmware.bin (legacy combined image).
	# No uImage is emitted here — the original NOR behaviour is preserved; the
	# combined firmware.bin is the NOR deliverable.
	FIT_SIZE=$(stat -c%s "${BINARIES_DIR}/fitImage")
	OFFSET_BLOCKS=$(( (FIT_SIZE + ERASEBLOCK_SIZE - 1) / ERASEBLOCK_SIZE ))

	cp ${BINARIES_DIR}/fitImage ${BINARIES_DIR}/firmware.bin
	dd if=${BINARIES_DIR}/rootfs.squashfs of=${BINARIES_DIR}/firmware.bin \
	   bs=${ERASEBLOCK_SIZE} seek=${OFFSET_BLOCKS} conv=notrunc
	truncate -s %${ERASEBLOCK_SIZE} ${BINARIES_DIR}/firmware.bin
fi
