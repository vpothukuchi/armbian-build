function extension_prepare_config__add_packages() {
	if [[ ${#TI_PACKAGES[@]} -gt 0 ]] ; then
		add_packages_to_image "${TI_PACKAGES[@]}"
	fi
}

function custom_apt_repo__install_ti_packages() {
    # Read JSON array into Bash array safely
	mapfile -t valid_suites < <(
		curl -s https://api.github.com/repos/TexasInstruments/ti-debpkgs/contents/dists |
		jq -r '.[].name'
	)
	display_alert "TI Repo has the following valid suites - ${valid_suites[@]}..."

	if printf '%s\n' "${valid_suites[@]}" | grep -qx "${RELEASE}"; then
		# Get the sources file
		run_host_command_logged "mkdir -p \"$SDCARD/tmp\""
		run_host_command_logged "wget -qO $SDCARD/tmp/ti-debpkgs.sources https://raw.githubusercontent.com/TexasInstruments/ti-debpkgs/main/ti-debpkgs.sources"

		# Update suite in source file
		chroot_sdcard "sed -i 's/bookworm/${RELEASE}/g' /tmp/ti-debpkgs.sources"

		# Copy updated sources file into chroot
		chroot_sdcard "cp /tmp/ti-debpkgs.sources /etc/apt/sources.list.d/ti-debpkgs.sources"

		# Clean up inside the chroot
		chroot_sdcard "rm -f /tmp/ti-debpkgs.sources"

		chroot_sdcard "mkdir -p /etc/apt/preferences.d/"
		run_host_command_logged "cp \"$SRC/packages/bsp/ti/ti-debpkgs/ti-debpkgs\" \"$SDCARD/etc/apt/preferences.d/\""

	else
		# Error if suite is not valid but continue building image anyway
		display_alert "Error: Detected OS suite '$RELEASE' is not valid based on TI package repository. Skipping!"
		display_alert "Valid Options Would Have Been: ${valid_suites[@]}"
	fi
}

function pre_customize_image__install_edgeai_debs() {
    local deb deb_basename
    local -a debs_in_chroot=()

    # Stage all EdgeAI debs into chroot /root/ first so apt-get can resolve
    # cross-package dependencies (e.g. -dev requires its runtime counterpart)
    # in a single pass rather than failing on individual installs.
    for deb in "${DEB_STORAGE}/extra/"*.deb; do
        [[ -f "${deb}" ]] || continue
        deb_basename="$(basename "${deb}")"
        display_alert "Staging EdgeAI deb" "${deb_basename}" "info"
        run_host_command_logged cp -pv "${deb}" "${SDCARD}/root/${deb_basename}"
        debs_in_chroot+=("/root/${deb_basename}")
    done

    [[ ${#debs_in_chroot[@]} -eq 0 ]] && return 0

    display_alert "Installing EdgeAI debs" "${#debs_in_chroot[@]} packages" "info"
    declare -g if_error_detail_message="EdgeAI deb installation failed ${BOARD} ${RELEASE}"
    DONT_MAINTAIN_APT_CACHE="yes" \
        chroot_sdcard_apt_get --no-install-recommends install "${debs_in_chroot[@]}"

    # Remove staged .deb files from /root/ — they were only needed for apt resolution
    display_alert "Cleaning up staged EdgeAI debs from /root/" "" "info"
    for deb in "${debs_in_chroot[@]}"; do
        run_host_command_logged rm -f "${SDCARD}${deb}"
    done
}

function pre_customize_image__enable_services() {
	run_host_command_logged "mkdir -p $DEST/lib/systemd/system/"
	run_host_command_logged "cp -v $SRC/packages/bsp/ti/weston/weston.socket $SDCARD/lib/systemd/system/weston.socket"
	run_host_command_logged "cp -v $SRC/packages/bsp/ti/weston/weston.service $SDCARD/lib/systemd/system/weston.service"
	run_host_command_logged "cp -v $SRC/packages/bsp/ti/weston/weston $SDCARD/etc/default/weston"

	chroot_sdcard "systemctl enable weston" || display_alert "systemctl enable failed"

	chroot_sdcard "systemctl disable NetworkManager" || display_alert "systemctl disable for NetworkManager failed"
	chroot_sdcard "systemctl disable wpa_supplicant.service" || display_alert "systemctl disable for wpa_supplicant failed"
	chroot_sdcard "systemctl enable NetworkManager" || display_alert "systemctl enable for NetworkManager failed"
}

function post_install_kernel_debs__activate_dkms() {
    if [[ ${GPU_SUPPORT} == "yes" ]] ; then
        kernel_version=$(grab_version "${SRC}/cache/sources/${LINUXSOURCEDIR}")
        kernel_version_family="${kernel_version}-${BRANCH}-${LINUXFAMILY}"
        chroot_sdcard "dkms autoinstall --verbose --kernelver ${kernel_version_family}"
    fi
}

function pre_umount_final_image__disable_uboot_rproc() {
    if [[ -f "${SDCARD}/boot/uEnv.txt" ]]; then
        if ! grep -q "dorprocboot" "${SDCARD}/boot/uEnv.txt"; then
            echo "dorprocboot=0" >> "${SDCARD}/boot/uEnv.txt"
            display_alert "Disabled U-Boot remoteproc auto-boot" "dorprocboot=0" "info"
        fi
        if ! grep -q "name_overlays" "${SDCARD}/boot/uEnv.txt"; then
            echo "name_overlays=ti/k3-j784s4-vision-apps.dtbo" >> "${SDCARD}/boot/uEnv.txt"
            display_alert "Added vision-apps DTS overlay" "k3-j784s4-vision-apps.dtbo" "info"
        fi
    fi
}

function post_customize_image__rm_aptconf() {
    display_alert "Removing apt.conf file"
    run_host_command_logged "rm ${SDCARD}/etc/apt/apt.conf"
    chroot_sdcard_apt_get_update || true
    display_alert "Removed apt.conf"
}
