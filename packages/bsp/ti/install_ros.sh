#!/bin/bash
# install_ros.sh — Install ROS 2 on Ubuntu Noble (aarch64)
#
# Usage:
#   bash install_ros.sh [--distro <name>] [--proxy <url>] [--no-proxy]
#
# Options:
#   --distro <name>  ROS 2 distro to install (default: jazzy)
#   --proxy <url>    HTTP proxy URL to use for apt and curl.
#                    If omitted, uses $http_proxy / $https_proxy from environment.
#   --no-proxy       Ignore any environment proxy and connect directly
#
# What is installed:
#   ros-<distro>-perception           — perception meta-package (image_transport,
#                                       cv_bridge, vision_msgs, camera_info_manager,
#                                       image_pipeline, tf2, nav_msgs, diagnostics, ...)
#   ros-<distro>-rosbag2              — bag recording/playback
#   python3-catkin-pkg                — from ROS 2 repo (provides catkin-pkg-modules)
#   python3-rosdep                    — dependency tool
#   python3-colcon-common-extensions  — colcon build tool + all extensions
#
# After installation source /opt/ros/<distro>/setup.bash in your shell or .bashrc

set -euo pipefail

# ---------------------------------------------------------------------------
# ROS 2 distro — update this when moving to a new release
# ---------------------------------------------------------------------------
ROS_DISTRO="jazzy"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PROXY="${http_proxy:-${HTTP_PROXY:-}}"
USE_PROXY=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --distro)   ROS_DISTRO="$2"; shift 2 ;;
        --proxy)    PROXY="$2"; USE_PROXY=1; shift 2 ;;
        --no-proxy) USE_PROXY=0; PROXY=""; shift ;;
        *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Must run as root (sudo $0)"
[[ "$(uname -m)" == "aarch64" ]] || die "This script is for aarch64 only"
. /etc/os-release
[[ "$VERSION_CODENAME" == "noble" ]] || die "Requires Ubuntu Noble (24.04), got $VERSION_CODENAME"

info "ROS 2 distro: ${ROS_DISTRO}"

# ---------------------------------------------------------------------------
# Proxy setup
# ---------------------------------------------------------------------------
if [[ $USE_PROXY -eq 1 && -n "$PROXY" ]]; then
    info "Proxy: $PROXY"
    export http_proxy="$PROXY"
    export https_proxy="$PROXY"
    export HTTP_PROXY="$PROXY"
    export HTTPS_PROXY="$PROXY"
    export no_proxy="localhost,127.0.0.1"
    export NO_PROXY="$no_proxy"

    cat > /etc/apt/apt.conf.d/99-ros-install-proxy.conf << EOF
Acquire::http::Proxy "$PROXY";
Acquire::https::Proxy "$PROXY";
EOF
elif [[ $USE_PROXY -eq 0 ]]; then
    info "No proxy (--no-proxy)"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
else
    info "No proxy configured (set http_proxy in environment or use --proxy)"
fi

# ---------------------------------------------------------------------------
# 1. Locale
# ---------------------------------------------------------------------------
info "Setting locale..."
apt-get install -y locales
locale-gen en_US en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8

# ---------------------------------------------------------------------------
# 2. Universe repo
# ---------------------------------------------------------------------------
info "Enabling universe repository..."
apt-get install -y software-properties-common
add-apt-repository -y universe

# ---------------------------------------------------------------------------
# 3. ROS 2 apt repository
# ---------------------------------------------------------------------------
info "Adding ROS 2 apt repository..."
apt-get install -y curl gnupg lsb-release

mkdir -p /usr/share/keyrings
curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    -o /usr/share/keyrings/ros-archive-keyring.gpg

echo "deb [arch=arm64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
http://packages.ros.org/ros2/ubuntu noble main" \
    > /etc/apt/sources.list.d/ros2.list

apt-get update

# ---------------------------------------------------------------------------
# 4. Replace Ubuntu's python3-catkin-pkg with the ROS 2 version
# ---------------------------------------------------------------------------
# Ubuntu Noble ships python3-catkin-pkg but it does NOT provide the
# python3-catkin-pkg-modules virtual package that ROS 2 packages require.
# The ROS 2 repo's python3-catkin-pkg does.  Remove the Ubuntu version first.
if dpkg -s python3-catkin-pkg &>/dev/null; then
    info "Replacing Ubuntu python3-catkin-pkg with ROS 2 version..."
    apt-get remove -y python3-catkin-pkg
fi

# ---------------------------------------------------------------------------
# 5. ROS 2 packages
# ---------------------------------------------------------------------------
info "Installing ROS 2 ${ROS_DISTRO} packages..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "ros-${ROS_DISTRO}-perception" \
    "ros-${ROS_DISTRO}-rosbag2" \
    python3-catkin-pkg \
    python3-rosdep \
    python3-colcon-common-extensions

# ---------------------------------------------------------------------------
# 6. rosdep init (skip if already done)
# ---------------------------------------------------------------------------
info "Initialising rosdep..."
if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    rosdep init
fi
if [[ -n "${SUDO_USER:-}" ]]; then
    su - "$SUDO_USER" -c "rosdep update"
else
    rosdep update
fi

# ---------------------------------------------------------------------------
# 7. Source ROS 2 in .bashrc for root and SUDO_USER
# ---------------------------------------------------------------------------
_add_source() {
    local rc="$1"
    local line="source /opt/ros/${ROS_DISTRO}/setup.bash"
    grep -qF "$line" "$rc" 2>/dev/null || echo "$line" >> "$rc"
}

_add_source /root/.bashrc
[[ -n "${SUDO_USER:-}" ]] && _add_source "/home/${SUDO_USER}/.bashrc"

# ---------------------------------------------------------------------------
# 8. Clean up temporary proxy apt config
# ---------------------------------------------------------------------------
rm -f /etc/apt/apt.conf.d/99-ros-install-proxy.conf

info ""
info "ROS 2 ${ROS_DISTRO} installed successfully."
info "Start a new shell or run:  source /opt/ros/${ROS_DISTRO}/setup.bash"
