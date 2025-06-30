# This is the "Working Horse" of the script

source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1

declare -A DISK_ID_TO_UUID  # Global associative array to store partition UUIDs
declare IS_EFI=true        # Since we're requiring EFI

function verify_disk_ids() {
    # Verify required disk IDs are set
    [[ -v "DISK_ID_ROOT" && -n "$DISK_ID_ROOT" ]] \
        || die "You must assign DISK_ID_ROOT"
    [[ -v "DISK_ID_EFI" && -n "$DISK_ID_EFI" ]] \
        || die "You must assign DISK_ID_EFI"
    [[ -v "DISK_ID_BOOT" && -n "$DISK_ID_BOOT" ]] \
        || die "You must assign DISK_ID_BOOT for extended boot partition"

    # Verify UUIDs exist for all specified disk IDs
    [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_EFI]" ]] \
        && die "Missing uuid for DISK_ID_EFI, have you made sure it is used?"
    [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_BOOT]" ]] \
        && die "Missing uuid for DISK_ID_BOOT, have you made sure it is used?"
    [[ -v "DISK_ID_SWAP" && ! -v "DISK_ID_TO_UUID[$DISK_ID_SWAP]" ]] \
        && die "Missing uuid for DISK_ID_SWAP, have you made sure it is used?"
    [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_ROOT]" ]] \
        && die "Missing uuid for DISK_ID_ROOT, have you made sure it is used?"
}

function check_config() {
	[[ $KEYMAP =~ ^[0-9A-Za-z-]*$ ]] \
		|| die "KEYMAP contains invalid characters"

	local hostname_regex='^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$'
	[[ $HOSTNAME =~ $hostname_regex ]] \
		|| die "'$HOSTNAME' is not a valid hostname"
}

function verify_partitions() {
    # Wait for partitions to be recognized
    sync
    partprobe
    sleep 2

    # Verify and store UUIDs for all partitions
    local partitions=(
        "${BOOT_DRIVE}1:EFI"
        "${BOOT_DRIVE}2:BOOT"  # Extended boot partition for GPG keys
        "${ROOT_DRIVE}1:SWAP"
        "${ROOT_DRIVE}2:ROOT"
    )

    for part in "${partitions[@]}"; do
        local device=${part%:*}
        local id=${part#*:}
        
        if [[ ! -b "$device" ]]; then
            die "Partition $device ($id) not found!"
        fi
        
        DISK_ID_TO_UUID["$id"]=$(blkid -s UUID -o value "$device") || die "Failed to get UUID for $device"
        echo "Verified $id: UUID=${DISK_ID_TO_UUID[$id]}"
    done

    # Map the partition types to their DISK_ID variables
    DISK_ID_TO_UUID["$DISK_ID_EFI"]=${DISK_ID_TO_UUID[EFI]}
    DISK_ID_TO_UUID["$DISK_ID_BOOT"]=${DISK_ID_TO_UUID[BOOT]}
    DISK_ID_TO_UUID["$DISK_ID_ROOT"]=${DISK_ID_TO_UUID[ROOT]}
    [[ -v "DISK_ID_SWAP" ]] && DISK_ID_TO_UUID["$DISK_ID_SWAP"]=${DISK_ID_TO_UUID[SWAP]}

    verify_disk_ids
}

function disk_configuration() {
    # Boot disk
    echo "Editing disk for drive"
    parted "$BOOT_DRIVE" --script \
        mklabel gpt \
        mkpart primary fat32 1MiB 1GiB \
        mkpart primary ext4 1GiB 2GiB \
        set 1 esp on \
        set 2 legacy_boot on \
        print

    # Root and Swap disk
    parted "$ROOT_DRIVE" --script \
        mklabel gpt \
        mkpart primary linux-swap 0% "${SWAP_SIZE}G" \
        mkpart primary btrfs "${SWAP_SIZE}G" 100% \
        set 1 swap on \
        print

    verify_partitions
}

function preprocess_config() {
    disk_configuration
    check_config
}