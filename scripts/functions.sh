# This is the "Working Horse" of the script

source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1
source "$GENTOO_INSTALL_REPO_DIR/gentoo.conf" || { echo "Could not source gentoo.conf"; exit 1; }

function prep_installation_environment() {
	einfo "Preparing installation environment"

	local wanted_programs=(
		gpg
		hwclock
		lsblk
		ntpd
		partprobe
		python3
		"?rhash"
		sha512sum
		sgdisk
		uuidgen
		wget
	)

	# Check for existence of required programs
	check_wanted_programs "${wanted_programs[@]}"

	# Sync time now to prevent issues later
	sync_time
}

function sync_time() {
	einfo "Syncing time"
	if command -v ntpd &> /dev/null; then
		try ntpd -g -q
	elif command -v chrony &> /dev/null; then
		# See https://github.com/oddlama/gentoo-install/pull/122
		try chronyd -q
	else
		# why am I doing this?
		try date -s "$(curl -sI http://example.com | grep -i ^date: | cut -d' ' -f3-)"
	fi

	einfo "Current date: $(LANG=C date)"
	einfo "Writing time to hardware clock"
	hwclock --systohc --utc \
		|| die "Could not save time to hardware clock"
}

function download_stage3() {
	cd "$TMP_DIR" \
		|| die "Could not cd into '$TMP_DIR'"

	local STAGE3_BASENAME_FINAL
	if [[ ("$GENTOO_ARCH" == "amd64" && "$STAGE3_VARIANT" == *x32*) || ("$GENTOO_ARCH" == "x86" && -n "$GENTOO_SUBARCH") ]]; then
		STAGE3_BASENAME_FINAL="$STAGE3_BASENAME_CUSTOM"
	else
		STAGE3_BASENAME_FINAL="$STAGE3_BASENAME"
	fi

	local STAGE3_RELEASES="$GENTOO_MIRROR/releases/$GENTOO_ARCH/autobuilds/current-$STAGE3_BASENAME_FINAL/"

	# Download upstream list of files
	CURRENT_STAGE3="$(download_stdout "$STAGE3_RELEASES")" \
		|| die "Could not retrieve list of tarballs"
	# Decode urlencoded strings
	CURRENT_STAGE3=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))' <<< "$CURRENT_STAGE3")
	# Parse output for correct filename
	CURRENT_STAGE3="$(grep -o "\"${STAGE3_BASENAME_FINAL}-[0-9A-Z]*.tar.xz\"" <<< "$CURRENT_STAGE3" \
		| sort -u | head -1)" \
		|| die "Could not parse list of tarballs"
	# Strip quotes
	CURRENT_STAGE3="${CURRENT_STAGE3:1:-1}"
	# File to indiciate successful verification
	CURRENT_STAGE3_VERIFIED="${CURRENT_STAGE3}.verified"

	maybe_exec 'before_download_stage3' "$STAGE3_BASENAME_FINAL"

	# Download file if not already downloaded
	if [[ -e $CURRENT_STAGE3_VERIFIED ]]; then
		einfo "$STAGE3_BASENAME_FINAL tarball already downloaded and verified"
	else
		einfo "Downloading $STAGE3_BASENAME_FINAL tarball"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}" "${CURRENT_STAGE3}"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}.DIGESTS" "${CURRENT_STAGE3}.DIGESTS"

		# Import gentoo keys
		einfo "Importing gentoo gpg key"
		local GENTOO_GPG_KEY="$TMP_DIR/gentoo-keys.gpg"
		download "https://gentoo.org/.well-known/openpgpkey/hu/wtktzo4gyuhzu8a4z5fdj3fgmr1u6tob?l=releng" "$GENTOO_GPG_KEY" \
			|| die "Could not retrieve gentoo gpg key"
		gpg --quiet --import < "$GENTOO_GPG_KEY" \
			|| die "Could not import gentoo gpg key"

		# Verify DIGESTS signature
		einfo "Verifying tarball signature"
		gpg --quiet --verify "${CURRENT_STAGE3}.DIGESTS" \
			|| die "Signature of '${CURRENT_STAGE3}.DIGESTS' invalid!"

		# Check hashes
		einfo "Verifying tarball integrity"
		# Extract only the SHA512 hash line from the DIGESTS file
		digest_line=$(grep -A1 "# SHA512 HASH" "${CURRENT_STAGE3}.DIGESTS" | grep 'tar.xz$' | head -1 | sed -e 's/  .*stage3-/  stage3-/')
		if [[ -z "$digest_line" ]]; then
			# Fallback: try to find any SHA512 line for the tarball
			digest_line=$(grep 'tar.xz$' "${CURRENT_STAGE3}.DIGESTS" | tail -1 | sed -e 's/  .*stage3-/  stage3-/')
		fi
		if type rhash &>/dev/null; then
			rhash -P --check <(echo "# SHA512"; echo "$digest_line") \
				|| die "Checksum mismatch!"
		else
			sha512sum --check <<< "$digest_line" \
				|| die "Checksum mismatch!"
		fi

		# Create verification file in case the script is restarted
		touch_or_die 0644 "$CURRENT_STAGE3_VERIFIED"
	fi

	maybe_exec 'after_download_stage3' "${CURRENT_STAGE3}"
}

function extract_stage3() {
	# First, ensure any existing mounts are cleaned up
	gentoo_umount
	
	# Now mount the root filesystem fresh
	mount_root

	[[ -n $CURRENT_STAGE3 ]] \
		|| die "CURRENT_STAGE3 is not set"
	[[ -e "$TMP_DIR/$CURRENT_STAGE3" ]] \
		|| die "stage3 file does not exist"

	# For BTRFS setups, check if we should extract to gentoo subdirectory
	local extract_path="$ROOT_MOUNTPOINT"
	if [[ -d "$ROOT_MOUNTPOINT/gentoo" ]] && mountpoint -q "$ROOT_MOUNTPOINT/gentoo" 2>/dev/null; then
		einfo "Detected BTRFS activeroot setup, extracting to $ROOT_MOUNTPOINT/gentoo"
		extract_path="$ROOT_MOUNTPOINT/gentoo"
	fi

	# Go to the correct extraction directory
	cd "$extract_path" \
		|| die "Could not move to '$extract_path'"
	
	# Check if directory is empty (excluding lost+found)
	local non_empty_files
	non_empty_files=$(find . -mindepth 1 -maxdepth 1 -not -name 'lost+found' | head -5)
	if [[ -n $non_empty_files ]]; then
		ewarn "Extraction directory '$extract_path' is not empty, found:"
		echo "$non_empty_files"
		einfo "Checking for mount points before cleaning..."
		
		# Check each item to see if it's a mount point
		local items_to_remove=()
		while IFS= read -r item; do
			local full_path="$extract_path/${item#./}"
			if mountpoint -q "$full_path" 2>/dev/null; then
				ewarn "Skipping mounted filesystem: $item"
			else
				# Check if any subdirectories are mount points
				local has_mounts=false
				if [[ -d "$item" ]]; then
					while IFS= read -r subitem; do
						if [[ -n "$subitem" ]] && mountpoint -q "$extract_path/${subitem#./}" 2>/dev/null; then
							ewarn "Directory $item contains mount point: $subitem"
							has_mounts=true
						fi
					done < <(find "$item" -type d 2>/dev/null || true)
				fi
				
				if [[ "$has_mounts" == "false" ]]; then
					items_to_remove+=("$item")
				else
					ewarn "Skipping directory with mount points: $item"
				fi
			fi
		done <<< "$non_empty_files"
		
		# Remove only non-mounted items
		if [[ ${#items_to_remove[@]} -gt 0 ]]; then
			einfo "Cleaning non-mounted items from extraction directory..."
			for item in "${items_to_remove[@]}"; do
				einfo "Removing: $item"
				rm -rf "$item" || ewarn "Could not remove $item"
			done
		else
			einfo "All items are mounted or contain mount points - skipping cleanup"
		fi
	fi

	# Extract tarball
	einfo "Extracting stage3 tarball to $extract_path"
	tar xpf "$TMP_DIR/$CURRENT_STAGE3" --xattrs-include='*.*' --numeric-owner \
		|| die "Error while extracting tarball"
	cd "$TMP_DIR" \
		|| die "Could not cd into '$TMP_DIR'"
}

function gentoo_umount() {
	if mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		einfo "Unmounting root filesystem"
		# For btrfs setups, try to unmount subvolumes first
		if [[ -d "$ROOT_MOUNTPOINT/gentoo" ]] && mountpoint -q "$ROOT_MOUNTPOINT/gentoo" 2>/dev/null; then
			einfo "Detected btrfs subvolume setup, unmounting subvolumes first"
			# Try to unmount any virtual filesystems in the subvolume first
			for vfs in proc run tmp sys dev; do
				if mountpoint -q "$ROOT_MOUNTPOINT/gentoo/$vfs" 2>/dev/null; then
					einfo "Unmounting virtual filesystem: $ROOT_MOUNTPOINT/gentoo/$vfs"
					umount -l "$ROOT_MOUNTPOINT/gentoo/$vfs" 2>/dev/null || true
				fi
			done
		fi
		umount -R -l "$ROOT_MOUNTPOINT" \
			|| die "Could not unmount filesystems"
	fi
}

function check_config() {
	[[ $KEYMAP =~ ^[0-9A-Za-z-]*$ ]] \
		|| die "KEYMAP contains invalid characters"

	local hostname_regex='^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$'
	[[ $HOSTNAME =~ $hostname_regex ]] \
		|| die "'$HOSTNAME' is not a valid hostname"
}


function preprocess_config() {
    disk_creation
    disk_configuration
    check_config
}

function mount_efivars() {
	# Skip if already mounted
	mountpoint -q -- "/sys/firmware/efi/efivars" \
		&& return

	# Mount efivars
	einfo "Mounting efivars"
	mount -t efivarfs efivarfs "/sys/firmware/efi/efivars" \
		|| die "Could not mount efivarfs"
}

# shellcheck disable=SC2120
function  mount_root() {
	mount_by_id "$DISK_ID_ROOT" "$ROOT_MOUNTPOINT"
}

function mount_by_id() {
		local dev
	local id="$1"
	local mountpoint="$2"

	# Skip if already mounted
	mountpoint -q -- "$mountpoint" \
		&& return

	# Mount device
	einfo "Mounting device with id=$id to '$mountpoint'"
	mkdir -p "$mountpoint" \
		|| die "Could not create mountpoint directory '$mountpoint'"
	dev="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"
	mount "$dev" "$mountpoint" \
		|| die "Could not mount device '$dev'"
}

function bind_repo_dir() {
	# The bind mount needs to be inside the chroot directory
	# For the Gentoo-Install setup, the actual root is at $ROOT_MOUNTPOINT/gentoo/
	local chroot_bind_path="$ROOT_MOUNTPOINT/gentoo$GENTOO_INSTALL_REPO_BIND"
	
	# Use the bind location for scripts inside chroot
	export GENTOO_INSTALL_REPO_DIR="$GENTOO_INSTALL_REPO_BIND"

	# Check if already mounted
	mountpoint -q -- "$chroot_bind_path" \
		&& return

	# Create the bind mount directory inside the chroot
	einfo "Bind mounting repo directory to chroot"
	mkdir -p "$chroot_bind_path" \
		|| die "Could not create mountpoint directory '$chroot_bind_path'"
	mount --bind "$GENTOO_INSTALL_REPO_DIR_ORIGINAL" "$chroot_bind_path" \
		|| die "Could not bind mount '$GENTOO_INSTALL_REPO_DIR_ORIGINAL' to '$chroot_bind_path'"
}

function gentoo_chroot() {
	if [[ $# -eq 1 ]]; then
		einfo "To later unmount all virtual filesystems, simply use umount -l ${1@Q}"
		gentoo_chroot "$1" /bin/bash --init-file <(echo 'init_bash')
	fi

	[[ ${EXECUTED_IN_CHROOT-false} == "false" ]] \
		|| die "Already in chroot"

	local chroot_dir="$1"
	shift

	# Bind repo directory to tmp
	bind_repo_dir

	# Copy resolv.conf
	einfo "Preparing chroot environment"
	
	# Ensure essential directories exist
	for essential_dir in etc proc run tmp sys dev; do
		mkdir -p "$chroot_dir/$essential_dir" || die "Could not create directory '$chroot_dir/$essential_dir'"
	done
	
	install --mode=0644 /etc/resolv.conf "$chroot_dir/etc/resolv.conf" \
		|| die "Could not copy resolv.conf"

	# Mount virtual filesystems
	einfo "Mounting virtual filesystems"
	
	(
		mountpoint -q -- "$chroot_dir/proc" || mount -t proc /proc "$chroot_dir/proc" || exit 1
		mountpoint -q -- "$chroot_dir/run"  || {
			mount --rbind /run  "$chroot_dir/run" &&
			mount --make-rslave "$chroot_dir/run"; } || exit 1
		mountpoint -q -- "$chroot_dir/tmp"  || {
			mount --rbind /tmp  "$chroot_dir/tmp" &&
			mount --make-rslave "$chroot_dir/tmp"; } || exit 1
		mountpoint -q -- "$chroot_dir/sys"  || {
			mount --rbind /sys  "$chroot_dir/sys" &&
			mount --make-rslave "$chroot_dir/sys"; } || exit 1
		mountpoint -q -- "$chroot_dir/dev"  || {
			mount --rbind /dev  "$chroot_dir/dev" &&
			mount --make-rslave "$chroot_dir/dev"; } || exit 1
	) || die "Could not mount virtual filesystems"

	# Cache lsblk output, because it doesn't work correctly in chroot (returns almost no info for devices, e.g. empty uuids)
	cache_lsblk_output

	# Execute command
	einfo "Chrooting..."
	EXECUTED_IN_CHROOT=true \
		TMP_DIR="$TMP_DIR" \
		CACHED_LSBLK_OUTPUT="$CACHED_LSBLK_OUTPUT" \
		exec chroot -- "$chroot_dir" "$GENTOO_INSTALL_REPO_DIR/scripts/dispatch_chroot.sh" "$@" \
			|| die "Failed to chroot into '$chroot_dir'."
}