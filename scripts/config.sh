# This is for Disk and Systyem configurations

source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1

# must reside in /tmp to allow the chrooted system to access the files
TMP_DIR="/tmp/gentoo-install"
# Mountpoint for the new system
ROOT_MOUNTPOINT="$TMP_DIR/root"
# Mountpoint for the script files for access from chroot
GENTOO_INSTALL_REPO_BIND="/tmp/gentoo-install/bind"
# Mountpoint for the script files for access from chroot
UUID_STORAGE_DIR="$TMP_DIR/uuids"
       
# An associative array to check for existing ids (maps to uuids)
declare -gA DISK_ID_TO_UUID

function disk_creation() {
    # Check if BOOT_DRIVE and ROOT_DRIVE are set
    if [[ -z "$BOOT_DRIVE" || -z "$ROOT_DRIVE" || -z "$SWAP_SIZE" ]]; then
        die "BOOT_DRIVE, ROOT_DRIVE, or SWAP_SIZE not set. Please configure them in gentoo.conf"
    fi

    local BOOT="$BOOT_DRIVE"
    local ROOT="$ROOT_DRIVE"
    local SWAP_SIZE="$SWAP_SIZE"

    # Pre-flight checks
    echo "Performing pre-flight checks..."
    [[ -b "$BOOT" ]] || die "Boot drive $BOOT is not a block device"
    [[ -b "$ROOT" ]] || die "Root drive $ROOT is not a block device"
    
    # Check if devices are mounted and unmount if necessary
    echo "Checking for mounted filesystems on target devices..."
    if mountpoint -q -- "$BOOT" 2>/dev/null || grep -q "^$BOOT" /proc/mounts; then
        echo "Unmounting $BOOT..."
        umount "$BOOT" || die "Failed to unmount $BOOT"
    fi
    if mountpoint -q -- "$ROOT" 2>/dev/null || grep -q "^$ROOT" /proc/mounts; then
        echo "Unmounting $ROOT..."
        umount "$ROOT" || die "Failed to unmount $ROOT"
    fi
    
    # Unmount any existing partitions
    for dev in "${BOOT}"* "${ROOT}"*; do
        if [[ -b "$dev" ]] && mountpoint -q -- "$dev" 2>/dev/null; then
            echo "Unmounting partition $dev..."
            umount "$dev" 2>/dev/null || true
        fi
    done

    # Clean up any existing partition table remnants
    echo "Cleaning existing partition tables..."
    wipefs -a "$BOOT" 2>/dev/null || true
    wipefs -a "$ROOT" 2>/dev/null || true
    
    # Remove any lingering device files
    rm -f "${BOOT}"[0-9]* "${ROOT}"[0-9]* 2>/dev/null || true
    
    sync
    partprobe 2>/dev/null || true
    sleep 1

    # Boot disk partitioning
    echo "Creating partitions on boot disk $BOOT"
    if ! parted "$BOOT" --script \
        mklabel gpt \
        mkpart primary fat32 1MiB 1GiB \
        mkpart primary ext4 1GiB 2GiB \
        set 1 esp on \
        set 2 legacy_boot on \
        print; then
        die "Failed to create partitions on boot disk $BOOT"
    fi

    # Root and Swap disk partitioning
    echo "Creating partitions on root disk $ROOT"
    if ! parted "$ROOT" --script \
        mklabel gpt \
        mkpart primary linux-swap 0% "${SWAP_SIZE}G" \
        mkpart primary btrfs "${SWAP_SIZE}G" 100% \
        set 1 swap on \
        print; then
        die "Failed to create partitions on root disk $ROOT"
    fi
    
    # Force kernel to re-read partition tables
    echo "Forcing kernel to re-read partition tables..."
    sync
    partprobe "$BOOT" "$ROOT"
    sleep 2
    partprobe
    sleep 3

    verify_partitions
}

function verify_partitions() {
    # Wait for partitions to be recognized
    echo "Waiting for partitions to be recognized by the kernel..."
    sync
    partprobe
    sleep 2
    
    # Additional wait and probing for stubborn systems
    partprobe "$BOOT_DRIVE" "$ROOT_DRIVE" 2>/dev/null
    sleep 3

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
        
        echo "Debug: Checking for partition $device ($id)..."
        
        # Check if it exists as any kind of file
        if [[ -e "$device" ]]; then
            if [[ -b "$device" ]]; then
                echo "Debug: $device exists as a block device ✓"
            elif [[ -f "$device" ]]; then
                echo "Error: $device exists as a regular file (not block device)"
                echo "This indicates partition creation failed. File details:"
                ls -la "$device"
                echo "Attempting to remove the file and re-probe..."
                rm -f "$device"
                sync
                partprobe "$BOOT_DRIVE" "$ROOT_DRIVE" 2>/dev/null
                sleep 2
                if [[ -b "$device" ]]; then
                    echo "Success: $device is now a proper block device after cleanup"
                else
                    die "Failed to create proper block device $device after cleanup"
                fi
            else
                echo "Error: $device exists but is neither a regular file nor block device"
                ls -la "$device"
                die "Partition $device ($id) has unexpected file type!"
            fi
        else
            echo "Error: Block device $device does not exist. Available devices:"
            ls -la "${device%[0-9]*}"* 2>/dev/null || echo "No devices found with pattern ${device%[0-9]*}*"
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


function create_gpg_disk_layout() {
    # Check if BOOT_DRIVE and ROOT_DRIVE are set
    if [[ -z "$BOOT_DRIVE" || -z "$ROOT_DRIVE" || -z "$SWAP_SIZE" ]]; then
        die "BOOT_DRIVE, ROOT_DRIVE, or SWAP_SIZE not set. Please configure them in gentoo.conf"
    fi

    local BOOT="$BOOT_DRIVE"
    local ROOT="$ROOT_DRIVE"
    
    export GPG_TTY=$(tty)

    # Create partitions if they dont exist
    mkfs.vfat -F 32 "${BOOT}1"
    cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${BOOT}2"
    cryptsetup luksOpen "${BOOT}2" luks-keys
    mkfs.ext4 /dev/mapper/luks-keys
    
    mkdir -p /mnt/keys
    mount /dev/mapper/luks-keys /mnt/keys

    # Swap setup
    dd if=/dev/urandom bs=8388608 count=1 | gpg --symmetric --cipher-algo AES256 --output /mnt/keys/SWAP-KEY.gpg
    gpg --batch --yes --decrypt /mnt/keys/SWAP-KEY.gpg | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${ROOT}1" --key-file=-
    gpg --batch --yes --decrypt /mnt/keys/SWAP-KEY.gpg | cryptsetup open "${ROOT}1" cryptswap --key-file=-
    # Root setup
    dd if=/dev/urandom bs=8388608 count=1 | gpg --symmetric --cipher-algo AES256 --output /mnt/keys/ROOT-KEY.gpg
    gpg --batch --yes --decrypt /mnt/keys/ROOT-KEY.gpg | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${ROOT}2" --key-file=-
    gpg --batch --yes --decrypt /mnt/keys/ROOT-KEY.gpg | cryptsetup open "${ROOT}2" cryptroot --key-file=-
    
    # Create resolve entries for the encrypted devices
    create_resolve_entry_device "ROOT" "/dev/mapper/cryptroot"
    create_resolve_entry_device "SWAP" "/dev/mapper/cryptswap"
    # Create resolve entries for boot partitions
    create_resolve_entry_device "EFI" "${BOOT}1"
    create_resolve_entry_device "BOOT" "/dev/mapper/luks-keys"
}

function apply_disk_conf() {
	local LABEL="$ROOT_LABEL"

    mkswap /dev/mapper/cryptswap
    swapon /dev/mapper/cryptswap

    # Create necessary directory structure
    mkdir -p "/mnt/root"

    mkfs.btrfs -L "$LABEL" /dev/mapper/cryptroot
    
    # Mount the root filesystem to create subvolumes
    mount -t btrfs -o defaults,noatime,compress=zstd /dev/mapper/cryptroot "/mnt/root"

    # Create btrfs subvolumes (note: activeroot subvolume shouldn't be created inside itself)
    for sub in activeroot home etc var log tmp; do 
        btrfs subvolume create "/mnt/root/$sub" || { echo "Failed to create subvolume $sub"; exit 1; }
    done
    
    mount -t btrfs -o defaults,noatime,compress=zstd,subvol=activeroot /dev/mapper/cryptroot "$ROOT_MOUNTPOINT/gentoo"
    # Create mount points for the final system AFTER mounting activeroot
    mkdir -p "$ROOT_MOUNTPOINT/gentoo"
    mkdir -p "$ROOT_MOUNTPOINT/gentoo/"{home,etc,var,log,tmp,efi,boot}
    # Mount other subvolumes
    for sub in home etc var log; do
        mount -t btrfs -o defaults,noatime,compress=zstd,subvol=$sub /dev/mapper/cryptroot "$ROOT_MOUNTPOINT/gentoo/$sub" || { echo "Failed to mount subvolume $sub"; exit 1; }
    done
    # Different rule for TMP
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=tmp /dev/mapper/cryptroot "$ROOT_MOUNTPOINT/gentoo/tmp"
}