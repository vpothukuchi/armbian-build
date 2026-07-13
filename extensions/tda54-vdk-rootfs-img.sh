#!/usr/bin/env bash
# Extract the root filesystem partition from the tda54-vdk image as rootfs-img.ext4

function post_build_image__tda54_vdk_extract_rootfs() {
	if [[ "${BOARD}" != "tda54-vdk" ]]; then
		return 0
	fi

	display_alert "Extracting root filesystem" "rootfs-img.ext4 for tda54-vdk" "info"

	local start size
	start=$(sfdisk -d "${FINAL_IMAGE_FILE}" | awk '/type=83/{match($0,/start=[[:space:]]*([0-9]+)/,a); print a[1]; exit}')
	size=$(sfdisk -d "${FINAL_IMAGE_FILE}" | awk '/type=83/{match($0,/size=[[:space:]]*([0-9]+)/,a); print a[1]; exit}')

	run_host_command_logged dd if="${FINAL_IMAGE_FILE}" of="${DESTIMG}/${version}.rootfs-img.ext4" bs=512 skip="${start}" count="${size}"

	display_alert "Rootfs extracted" "${version}.rootfs-img.ext4" "info"
}
