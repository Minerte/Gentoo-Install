source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1
source "$GENTOO_INSTALL_REPO_DIR/gentoo.conf" || { echo "Could not source gentoo.conf"; exit 1; }

function install_stage3() {
	prep_installation_environment
	preprocess_config
	apply_disk_conf
	dowmload_stage3
	extract_stage3
}

function configure_base_system() {
	# Set LOCALE
	echo "$LOCALES" > /etc/locale.gen \
		|| die "Could not write /etc/locale.gen"
	locale-gen \
		|| die "Could not generate locales"
	
	# Set TIMEZONE
	echo "$TIMEZONE" > /etc/timezone \
		|| die "Could not write /etc/timezone"
	try emerge -v --config sys-libs/timezone-data

	# Set KEYMAP
	sed -i "/keymap=/c\\keymap=\"$KEYMAP\"" /etc/conf.d/keymaps \
		|| die "Could not sed replace in /etc/conf.d/keymaps"

	# Set LOLCALE TO $LOCALE
	try eselect locale set "$LOCALE"

	# Update enviroment
	env-update && source /etc/profile
}

function configure_portage() {
	try cp "$GENTOO_INSTALL_REPO_DIR/config/make.conf /etc/portage/make.conf" \
		|| die "Could not copy make.conf to portage directory"

	try mv "$GENTOO_INSTALL_REPO_DIR/config/package.use/Merge /etc/portage/pakage.use/" \
		|| die "Could not copy package.use to portage/package.use/ directory"
	try mv "$GENTOO_INSTALL_REPO_DIR/config/package.env /etc/portage/" \
		|| die "Could not move package.env to portage directory"
	try mv "$GENTOO_INSTALL_REPO_DIR/config/env /etc/portage/" \
		|| die "Could not move env folder to portage directory"
}

function generate_fstab() {
	einfo "Generating fstab"
	install -m0644 -o root -g root "$GENTOO_INSTALL_REPO_DIR/contrib/fstab" /etc/fstab \
		|| die "Could not overwrite /etc/fstab"
	if [[ $USED_ZFS != "true" && -n $DISK_ID_ROOT_TYPE ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")" "/" "$DISK_ID_ROOT_TYPE" "$DISK_ID_ROOT_MOUNT_OPTS" "0 1"
	fi
	if [[ $IS_EFI == "true" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_EFI")" "/boot/efi" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	else
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_BIOS")" "/boot/bios" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	fi
	if [[ -v "DISK_ID_SWAP" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_SWAP")" "none" "swap" "defaults,discard" "0 0"
	fi
}

function configure_kernel() {
	einfo "executing genkernel with luks, firmware, btrfs, keymap, oldconfig, save-config, menuconfig and install all"
	try genkernel --luks --firmware --btrfs --keymap --oldconfig --save-config --menuconfig --install all
}

function install_kernel() {
	try emerge --verbose sys-boot/efibootmgr

	# Copy kernel to EFI
	local kernel_file
	kernel_file="$(find "/boot" \( -name "vmlinuz-*" -or -name 'kernel-*' \) -printf '%f\n' | sort -V | tail -n 1)" \
		|| die "Could not list newest kernel file"

	try cp "/boot/$kernel_file" "/boot/efi/vmlinuz.efi"

	generate_initramfs "/boot/efi/initramfs.img"

	# Create boot entry
	einfo "Creating EFI boot entry"
	local efipartdev
	efipartdev="$(resolve_device_by_id "$DISK_ID_EFI")" \
		|| die "Could not resolve device with id=$DISK_ID_EFI"
	efipartdev="$(realpath "$efipartdev")" \
		|| die "Error in realpath '$efipartdev'"

	# Get the sysfs path to EFI partition
	local sys_efipart
	sys_efipart="/sys/class/block/$(basename "$efipartdev")" \
		|| die "Could not construct /sys path to EFI partition"

	# Extract partition number, handling both standard and RAID cases
	local efipartnum
	if [[ -e "$sys_efipart/partition" ]]; then
		efipartnum="$(cat "$sys_efipart/partition")" \
			|| die "Failed to find partition number for EFI partition $efipartdev"
	else
		efipartnum="1" # Assume partition 1 if not found, common for RAID-based EFI
		einfo "Assuming partition 1 for RAID-based EFI on device $efipartdev"
	fi

	# Non-RAID case: Create a single EFI boot entry
	gptdev="/dev/$(basename "$(readlink -f "$sys_efipart/..")")" \
		|| die "Failed to find parent device for EFI partition $efipartdev"
	if [[ ! -e "$gptdev" ]] || [[ -z "$gptdev" ]]; then
		gptdev="$(resolve_device_by_id "${DISK_ID_PART_TO_GPT_ID[$DISK_ID_EFI]}")" \
			|| die "Could not resolve device with id=${DISK_ID_PART_TO_GPT_ID[$DISK_ID_EFI]}"
	fi
	try efibootmgr --verbose --create --disk "$gptdev" --part "$efipartnum" --label "gentoo" --loader '\vmlinuz.efi' --unicode 'initrd=\initramfs.img'" $(get_cmdline)"

	# Create script to repeat adding efibootmgr entry
	cat > "/boot/efi/efibootmgr_add_entry.sh" <<EOF
#!/bin/bash
# This is the command that was used to create the efibootmgr entry when the
# system was installed using gentoo-install.
efibootmgr --verbose --create --disk "$gptdev" --part "$efipartnum" --label "gentoo" --loader '\\vmlinuz.efi' --unicode 'initrd=\\initramfs.img'" $(get_cmdline)"
EOF
}

function generate_initramfs() {
	einfo "Generating initramfs"

	local kver
	kver="$(readlink /usr/src/linux)" \
		|| die "Could not figure out kernel version from /usr/src/linux symlink."
	kver="${kver#linux-}"

	local initramfs_file
    initramfs_file="$(find /boot -type f -name "initramfs-${kver}.img" | sort -V | tail -n 1)"

    if [[ -z "$initramfs_file" ]]; then
        die "Could not find initramfs for kernel version $kver in /boot"
    fi

	try ugrd --kver "$kver" /boot/"$initramfs_file".img \
		|| die "Could not generate initramfs at '/boot/$initramfs_file.img'. Make sure you have the 'ugrd' package installed."

	eiofo "Configuring ugrd /etc/ugrd/config.toml"

	# Get the UUID of the second partition of BOOT_DRIVE
	local bootkeys_uuid
	bootkeys_uuid="$(blkid -s UUID -o value "${BOOT_DRIVE}2")" \
    	|| die "Could not get UUID for ${BOOT_DRIVE}2"

	cat << EOF > /etc/ugrd/config.toml
modules = [
  "ugrd.kmod.usb",
  "ugrd.crypto.gpg"
]

# This will auto-mount the key partition *after* unlocking it
auto_mounts = [
  "/boot"
  "/mnt/bootkeys"
]

# First, define how to unlock the encrypted key partition
[cryptsetup.bootkeys]
device = "/dev/disk/by-uuid/${bootkeys_uuid}"  # This is the encrypted LUKS device
name = "bootkeys"
key_type = "password"                        # You will enter passphrase at boot
mountpoint = "/mnt/bootkeys"

[[mounts]]
device = "/dev/mapper/luks-keys"              # Now unlocked device
mountpoint = "/mnt/bootkeys"
filesystem = "ext4"
options = "ro"

# Now tell ugrd to use the decrypted keyfiles from /mnt/bootkeys
[cryptsetup.root]
key_type = "gpg"
key_file = "/mnt/bootkeys/ROOT-KEY.gpg"

[cryptsetup.swap]
key_type = "gpg"
key_file = "/mnt/bootkeys/SWAP-KEY.gpg"
EOF
}

function main_install_gentoo_in_chroot() {
	[[ $# == 0 ]] || die "Too many arguments"

	# Remove the root password, making the account accessible for automated
	# tasks during the period of installation.
	einfo "Clearing root password"
	passwd -d root \
		|| die "Could not change root password"

	# Sync portage
	einfo "Syncing portage tree"
	try emerge --sync --quiet

	# Mount efi partition
	mount_efivars
	einfo "Mounting efi partition"
	mount_by_id "$DISK_ID_EFI" "/boot/efi"

	# Configure basic system things like timezone, locale, ...
	configure_base_system

	# Prepare portage environment
	configure_portage

	# Install git (for git portage overlays)
	einfo "Installing git"
	try emerge --verbose dev-vcs/git

	# Install required programs and kernel now, in order to
	# prevent emerging module before an imminent kernel upgrade
	try emerge --verbose sys-kernel/gentoo-sources app-arch/zstd

	# Install cryptsetup if we used LUKS
	einfo "Installing cryptsetup"
	try emerge --verbose sys-fs/cryptsetup

	# Install btrfs-progs if we used Btrfs
	einfo "Installing btrfs-progs"
	try emerge --verbose sys-fs/btrfs-progs

	# Install kernel and initramfs
	einfo "Configuring kernel manually"
	configure_kernel
	einfo "Installing kernel and initramfs"
	install_kernel

	# Generate a valid fstab file
	generate_fstab

	# Install gentoolkit
	einfo "Installing gentoolkit"
	try emerge --verbose app-portage/gentoolkit

	# Install and enable dhcpcd
	einfo "Installing dhcpcd"
	try emerge --verbose net-misc/dhcpcd #change to net-misc/NetworkManager maybe create a function for the setup
	#networkmanager_setup

	# Install additional packages, if any.
	if [[ ${#ADDITIONAL_PACKAGES[@]} -gt 0 ]]; then
		einfo "Installing additional packages"
		# shellcheck disable=SC2086
		try emerge --verbose --autounmask-continue=y -- "${ADDITIONAL_PACKAGES[@]}"
	fi

	if ask "Do you want to assign a root password now?"; then
		try passwd root
		einfo "Root password assigned"
	else
		try passwd -d root
		ewarn "Root password cleared, set one as soon as possible!"
	fi

	# If configured, change to gentoo testing at the last moment.
	# This is to ensure a smooth installation process. You can deal
	# with the blockers after installation ;)
	if [[ $USE_PORTAGE_TESTING == "true" ]]; then
		einfo "Adding ~$GENTOO_ARCH to ACCEPT_KEYWORDS"
		echo "ACCEPT_KEYWORDS=\"~$GENTOO_ARCH\"" >> /etc/portage/make.conf \
			|| die "Could not modify /etc/portage/make.conf"
	fi

	einfo "Gentoo installation complete."
	[[ $USED_LUKS == "true" ]] \
		&& einfo "A backup of your luks headers can be found at '$LUKS_HEADER_BACKUP_DIR', in case you want to have a backup."
	einfo "You may now reboot your system or execute ./install --chroot $ROOT_MOUNTPOINT to enter your system in a chroot."
	einfo "Chrooting in this way is always possible in case you need to fix something after rebooting."
}

function main_install() {
	[[ $# == 0 ]] || die "Too many arguments"
	
	gentoo_umount
	install_stage3

	mount_efivars
	gentoo_chroot "$ROOT_MOUNTPOINT" "$GENTOO_INSTALL_REPO_BIND/install" __install_gentoo_in_chroot
}

function main_chroot() {
	# Skip if already mounted
	mountpoint -q -- "$1" \
		|| die "'$1' is not a mountpoint"

	gentoo_chroot "$@"
}