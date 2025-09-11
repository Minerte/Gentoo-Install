#!/bin/bash
# Initialize script envireoment
# This will go after gentoo.conf file

set -uo pipefail # Pipestatus: exit status of the last command that threw a non-zero exit code is returned.

function get_source_dir() {
	local source="${BASH_SOURCE[0]}"
	while [[ -h $source ]]
	do
		local tmp
		tmp="$(cd -P "$(dirname "${source}")" && pwd)"
		source="$(readlink "${source}")"
		[[ $source != /* ]] && source="${tmp}/${source}"
	done

	echo -n "$(realpath "$(dirname "${source}")")"
}

ACTUAL_WORKING_DIRECTORY="$(realpath "$(pwd)")" || exit 1
export ACTUAL_WORKING_DIRECTORY
# Set the GENTOO_INSTALL_REPO_DIR to the directory where this script is located
# This allows the script to be run from anywhere, as long as the relative paths are correct
GENTOO_INSTALL_REPO_DIR_ORIGINAL="$(get_source_dir)"
export GENTOO_INSTALL_REPO_DIR_ORIGINAL
export GENTOO_INSTALL_REPO_DIR="$GENTOO_INSTALL_REPO_DIR_ORIGINAL"
export GENTOO_INSTALL_REPO_SCRIPT_ACTIVE=true
export GENTOO_INSTALL_REPO_SCRIPT_PID=$$

source "$GENTOO_INSTALL_REPO_DIR/scripts/main.sh"
source "$GENTOO_INSTALL_REPO_DIR/scripts/utils.sh"
source "$GENTOO_INSTALL_REPO_DIR/scripts/config.sh"
source "$GENTOO_INSTALL_REPO_DIR/scripts/functions.sh"
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh"

# Instantly kill when pressing ctrl-c
trap 'kill "$GENTOO_INSTALL_REPO_SCRIPT_PID"' INT

ACTION=""
CONFIG="$GENTOO_INSTALL_REPO_DIR/gentoo.conf"

while [[ $# -gt 0 ]]; do
	case "$1" in
		""|"help"|"--help"|"-help"|"-h")
			echo "Usage: $0 [opts]... <action>"
			echo "Performs a gentoo installation with GPG encryption."
			echo "The installtion will be configurat by the given configuration file. (gentoo.conf)"
			echo ""
			echo "Actions:"
			echo "  -i, --install                 Installs gentoo as configured. This is the default mode,"
			echo "                                  if the given configuration file exists."
			echo "  -R, --chroot <DIR> [CMD...]   Chroot into an existing system. The root filesystem"
			echo "                                  must already be mounted under DIR. All required special"
			echo "                                  filesystems will be mounted inside, and unmounted when"
			echo "                                  the chroot exits."
			exit 0
			;;
		"-R"|"--chroot")
			[[ -z $ACTION ]] || die "Multiple actions given"
			ACTION="chroot"
			CHROOT_DIR="$2"
			[[ -e "$CHROOT_DIR" ]] || die "Chroot directory not found: '$CHROOT_DIR'"
			shift
			;;
		"-i"|"--install")
			[[ -z $ACTION ]] || die "Multiple actions given"
			ACTION="install"
			;;
		"__install_gentoo_in_chroot")
			ACTION="__install_gentoo_in_chroot"
			;;
		*) die "Invalid option '$1'" ;;
	esac
	shift
done

# Check configuration location
[[ -z "${CONFIG%%"$GENTOO_INSTALL_REPO_DIR"*}" ]] \
	|| die "Configuration file must be inside the installation directory. This is needed so it is accessible from within the chroot environment."

if [[ -z "$ACTION" ]]; then
    if [[ -e "$CONFIG" ]]; then
        ACTION="install"
    else
        die "Configuration file '$CONFIG' does not exist. Please create and edit gentoo.conf before running this script."
    fi
fi

if [[ "$ACTION" != "chroot" ]]; then
	# Load config if we aren't just chrooting
	[[ -e "$CONFIG" ]] \
		 || die "Configuration file '$CONFIG' does not exist. To run the configurator, omit '-i' flag or run ./configure"

	# shellcheck disable=SC1090
	source "$CONFIG" || die "Could not source config"
	[[ $I_HAVE_READ_AND_EDITED_THE_CONFIG_PROPERLY == "true" ]] \
		|| die "You have not properly read the config. Edit the config file and set I_HAVE_READ_AND_EDITED_THE_CONFIG_PROPERLY=true to continue."
fi

[[ $EUID == 0 ]] \
	|| die "Must be root"

case "$ACTION" in
	"chroot")  main_chroot "$CHROOT_DIR" "$@" ;;
	"install") main_install "$@" ;;
	"__install_gentoo_in_chroot") main_install_gentoo_in_chroot "$@" ;;
	*) die "Invalid action '$ACTION'" ;;
esac
