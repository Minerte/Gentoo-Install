# This is for Disk and Systyem configurations

source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1
source "$GENTOO_INSTALL_REPO_DIR/gentoo.conf" || { echo "Could not source gentoo.conf"; exit 1; }

# must reside in /tmp to allow the chrooted system to access the files
TMP_DIR="/tmp/gentoo-install"
# Mountpoint for the new system
ROOT_MOUNTPOINT="$TMP_DIR/root"
# Mountpoint for the script files for access from chroot
GENTOO_INSTALL_REPO_BIND="$TMP_DIR/bind"
# Mountpoint for the script files for access from chroot
UUID_STORAGE_DIR="$TMP_DIR/uuids"

# Since we're requiring EFI
declare IS_EFI=true        
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

    # Boot disk
    echo "Editing disk for drive"
    parted "$BOOT" --script \
        mklabel gpt \
        mkpart primary fat32 1MiB 1GiB \
        mkpart primary ext4 1GiB 2GiB \
        set 1 esp on \
        set 2 legacy_boot on \
        print

    # Root and Swap disk
    parted "$ROOT" --script \
        mklabel gpt \
        mkpart primary linux-swap 0% "${SWAP_SIZE}G" \
        mkpart primary btrfs "${SWAP_SIZE}G" 100% \
        set 1 swap on \
        print

    verify_partitions
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
}

function apply_disk_conf() {
	local LABEL="$ROOT_LABEL"

    mkswap /dev/mapper/cryptswap
    swapon /dev/mapper/cryptswap

    mkfs.btrfs -L "$LABEL" /dev/mapper/cryptroot
    mkdir $ROOT_MOUNTPOINT/activeroot
    mount -t btrfs -o defaults,noatime,compress=zstd /dev/mapper/cryptroot $ROOT_MOUNTPOINT/activeroot

    for sub in activeroot home etc var log tmp; do 
        btrfs subvolume create $ROOT_MOUNTPOINT/activeroot/$sub  || { echo "Failed to create subvolume $sub"; exit 1; }
    done

    mkdir -p $ROOT_MOUNTPOINT/gentoo/{home,etc,var,log,tmp,efi,boot}

    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=activeroot /dev/mapper/cryptroot $ROOT_MOUNTPOINT/gentoo/
    for sub in home etc var log; do
        mount -t btrfs -o defaults,noatime,compress=zstd,subvol=$sub /dev/mapper/cryptroot $ROOT_MOUNTPOINT/gentoo/$sub   || { echo "Failed to mount subvolume $sub"; exit 1; }
    done
    mount -t btrfs -o defaults,noatime,nosuid,noexec,nodev,compress=lzo,subvol=tmp /dev/mapper/cryptroot $ROOT_MOUNTPOINT/gentoo/tmp
}