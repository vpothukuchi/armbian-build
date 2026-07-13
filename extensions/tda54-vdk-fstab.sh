#!/usr/bin/env bash
# Fix fstab for tda54-vdk: use /dev/vda for root and disable /boot vfat entry

function format_partitions__tda54_vdk_fix_fstab() {
	if [[ "${BOARD}" == "tda54-vdk" ]]; then
		display_alert "Fixing fstab for tda54-vdk" "replacing UUID root with /dev/vda" "info"
		sed -i 's|^UUID=[^ ]* / ext4|/dev/vda       /           ext4|' "${SDCARD}/etc/fstab"
		sed -i 's|^UUID=[^ ]* /boot vfat|# No /boot - specific for tda54-vdk|' "${SDCARD}/etc/fstab"
	fi
}
