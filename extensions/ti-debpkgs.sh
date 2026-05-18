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

    # Disable network apt sources during local-deb install to prevent the apt http
    # method from trying to reach ports.ubuntu.com (or other remote repos) via DNS.
    # DNS is unreachable inside the QEMU chroot container, causing indefinite hangs.
    # Restore the sources after install so later steps (e.g. post_customize_image)
    # can still use them.
    local -a disabled_sources=()
    for src in "${SDCARD}/etc/apt/sources.list.d/"*.sources \
               "${SDCARD}/etc/apt/sources.list.d/"*.list; do
        [[ -f "${src}" ]] || continue
        run_host_command_logged mv "${src}" "${src}.tmp_disabled"
        disabled_sources+=("${src}")
    done

    display_alert "Installing EdgeAI debs" "${#debs_in_chroot[@]} packages" "info"
    declare -g if_error_detail_message="EdgeAI deb installation failed ${BOARD} ${RELEASE}"
    local install_exit=0
    DONT_MAINTAIN_APT_CACHE="yes" \
        chroot_sdcard_apt_get --no-install-recommends install "${debs_in_chroot[@]}" || install_exit=$?

    # Restore network sources regardless of install outcome
    for src in "${disabled_sources[@]}"; do
        run_host_command_logged mv "${src}.tmp_disabled" "${src}"
    done

    # Remove staged .deb files from /root/ — they were only needed for apt resolution
    display_alert "Cleaning up staged EdgeAI debs from /root/" "" "info"
    for deb in "${debs_in_chroot[@]}"; do
        run_host_command_logged rm -f "${SDCARD}${deb}"
    done

    return ${install_exit}
}

function pre_customize_image__install_vision_apps_scripts() {
	# Install /opt/vision_apps/setup.sh — firmware load + env setup helper.
	# Always install; the script works even when ti-vision-apps-data is absent
	# (it simply has no vx_app_* binaries to reference).
	run_host_command_logged "mkdir -p ${SDCARD}/opt/vision_apps"
	run_host_command_logged "install -m 755 $SRC/packages/bsp/ti/vision_apps/setup.sh \
		${SDCARD}/opt/vision_apps/setup.sh"
	display_alert "Installed /opt/vision_apps/setup.sh" "" "info"
}

function pre_customize_image__enable_services() {
	# Weston: only install and enable if the binary is present in the image.
	# Enabling a missing binary puts systemd in degraded state and causes
	# armbian-firstlogin to loop forever on "Waiting for system to finish booting".
	if [[ -x "${SDCARD}/usr/bin/weston" ]]; then
		run_host_command_logged "mkdir -p ${SDCARD}/lib/systemd/system/"
		run_host_command_logged "cp -v $SRC/packages/bsp/ti/weston/weston.socket ${SDCARD}/lib/systemd/system/weston.socket"
		run_host_command_logged "cp -v $SRC/packages/bsp/ti/weston/weston.service ${SDCARD}/lib/systemd/system/weston.service"
		run_host_command_logged "cp -v $SRC/packages/bsp/ti/weston/weston ${SDCARD}/etc/default/weston"
		chroot_sdcard "systemctl enable weston" || display_alert "systemctl enable weston failed"
	else
		display_alert "weston binary not found; skipping weston service setup" "" "wrn"
	fi

	# NetworkManager: disable wpa_supplicant (NM manages wifi internally) and
	# re-enable NM to ensure its wants symlinks are present.
	chroot_sdcard "systemctl disable wpa_supplicant.service" || display_alert "systemctl disable for wpa_supplicant failed"
	chroot_sdcard "systemctl disable NetworkManager" || display_alert "systemctl disable for NetworkManager failed"
	chroot_sdcard "systemctl enable NetworkManager" || display_alert "systemctl enable for NetworkManager failed"

	# Mask services that cause boot hangs on K3 (j784s4-evm):
	#
	# systemd-networkd: masked because NM is used instead; leaving networkd
	# active with a masked service can still stall through socket activation.
	#
	# systemd-network-generator: enabled by net-systemd-networkd extension in
	# sysinit.target.wants; generates networkd config but networkd is masked,
	# stalling sysinit.target -> basic.target.
	#
	# armbian-resize-filesystem: calls fdisk on the mounted root which changes
	# MBR disk signatures; all PARTUUIDs change and partprobe hangs on K3 eMMC.
	chroot_sdcard "systemctl mask systemd-networkd.service"          || display_alert "systemctl mask systemd-networkd.service failed"
	chroot_sdcard "systemctl mask systemd-networkd.socket"           || display_alert "systemctl mask systemd-networkd.socket failed"
	chroot_sdcard "systemctl mask systemd-network-generator.service" || display_alert "systemctl mask systemd-network-generator.service failed"
	chroot_sdcard "systemctl mask armbian-resize-filesystem.service" || display_alert "systemctl mask armbian-resize-filesystem.service failed"

	# Watchdog: install hardware watchdog config and enable the daemon.
	# Requires the 'watchdog' package in PACKAGE_LIST_ADDITIONAL.
	if [[ -x "${SDCARD}/usr/sbin/watchdog" ]]; then
		run_host_command_logged "mkdir -p ${SDCARD}/etc"
		run_host_command_logged "cp -v $SRC/packages/bsp/ti/watchdog/watchdog ${SDCARD}/etc/default/watchdog"
		run_host_command_logged "cp -v $SRC/packages/bsp/ti/watchdog/watchdog.conf ${SDCARD}/etc/watchdog.conf"
		chroot_sdcard "systemctl enable watchdog.service" || display_alert "systemctl enable watchdog.service failed"
	else
		display_alert "watchdog daemon not installed; skipping watchdog setup" "" "wrn"
	fi
}

function post_install_kernel_debs__activate_dkms() {
    if [[ ${GPU_SUPPORT} == "yes" ]] ; then
        kernel_version=$(grab_version "${SRC}/cache/sources/${LINUXSOURCEDIR}")
        kernel_version_family="${kernel_version}-${BRANCH}-${LINUXFAMILY}"
        chroot_sdcard "dkms autoinstall --verbose --kernelver ${kernel_version_family}"
    fi
}

function pre_umount_final_image__disable_uboot_rproc() {
    # MOUNT/boot is the mounted FAT boot partition; SDCARD/boot is the
    # temp-rootfs source that was already rsynced to FAT before this hook
    # runs.  Writes must go to MOUNT/boot/uEnv.txt to persist in the image.
    local uenv="${MOUNT}/boot/uEnv.txt"
    if [[ -f "${uenv}" ]]; then
        if ! grep -q "dorprocboot" "${uenv}"; then
            echo "dorprocboot=0" >> "${uenv}"
            display_alert "Disabled U-Boot remoteproc auto-boot" "dorprocboot=0" "info"
        fi
        if ! grep -q "name_overlays" "${uenv}"; then
            echo "name_overlays=ti/k3-j784s4-vision-apps.dtbo" >> "${uenv}"
            display_alert "Added vision-apps DTS overlay" "k3-j784s4-vision-apps.dtbo" "info"
        fi
    fi
}

function post_customize_image__setup_ros2_apt() {
    # Pre-configure the ROS2 Jazzy apt repository so customers can install
    # ROS2 packages without any additional setup steps after flashing.
    # Key source: https://raw.githubusercontent.com/ros/rosdistro/master/ros.key
    local ros_keyring="${SDCARD}/usr/share/keyrings/ros-archive-keyring.gpg"
    local ros_sources="${SDCARD}/etc/apt/sources.list.d/ros2.list"

    display_alert "Setting up ROS2 Jazzy apt repository" "ros2" "info"

    run_host_command_logged "mkdir -p ${SDCARD}/usr/share/keyrings"
    chroot_sdcard bash -c "curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        -o /usr/share/keyrings/ros-archive-keyring.gpg" || {
        display_alert "ROS2 GPG key download failed; skipping ROS2 apt source setup" "" "wrn"
        return 0
    }

    run_host_command_logged "chmod 644 ${ros_keyring}"

    echo "deb [arch=arm64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu noble main" \
        > "${SDCARD}/etc/apt/sources.list.d/ros2.list"

    display_alert "ROS2 Jazzy apt source configured" "packages.ros.org/ros2/ubuntu noble" "info"
}

function post_customize_image__rm_aptconf() {
    display_alert "Removing apt.conf file"
    run_host_command_logged "rm -f ${SDCARD}/etc/apt/apt.conf"
    chroot_sdcard_apt_get_update || true
    display_alert "Removed apt.conf"
}
