### 1 introduction
This guide is for Gentoo Linux installation with GPG keyfile for Swap and Root partitions.
In this installation we will be using sys-kernel/gentoo-sources, ugRD for the initramfs and EFI Stub. 
	List we need to change:
		• Generate GPG key file for partitions 
		• Configure kernel
		• Configure ugRD for auto unlock swap/root
	This guide also assumes the user has:
		• EFI/UEFI Support
		• Working ethernet/WIFI
		• Disk size ≥ 100 GB
		• A separate USB with Disk size ≥ 3 GB for boot and key storage
***Before continuation:*** *Any operations involving disks are performed at the user's discretion. Data loss, and UUIDs are subject to change.*
### 2 Disk Preparations
```
root # fdisk /dev/sdX
Welcome to fdisk (util-linux 2.38.1).
Changes will remain in memory only, until you decide to write
them.
Be careful before using the write command.
Device does not contain a recognized partition table.
Created a new DOS disklabel with disk identifier 0x8191dbc.
Command (m for help): g
Created a new GPT disklabel (GUID: GPT_LABEL_ARRAY)
```
Create the ESP partition, a 1GB partition:
```
Command (m for help): n
Partition number (1-128, default 1): 
First sector (2048-121008094, default 2048): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-121008094, default 121006079): +1G

Created a new partition 1 of type 'Linux filesystem' and of size 1 GiB.
```
Create the Extended boot partition, a 1GB partition:
```
Command (m for help): n
Partition number (2-128, default 2): 
First sector (2099200-121008094, default 2099200): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-121008094, default 121006094): +1G

Created a new partition 1 of type 'Linux filesystem' and of size 1 GiB.
```
Now we need to change Type for the ESP partition:
```
Command (m for help): t
Partition number (1-2, default 1): 
Partition type or alias (type L to list all): 1
Changed type of partition 'Linux filesystem' to 'EFI System'.
```
Then set the type for the Extended boot partition.
```
Command (m for help): t
Partition number (1-2, default 1): 2
Partition type or alias (type L to list all): 142
Changed type of partition 'Linux filesystem' to 'Linux Extended Boot'.
```
Write changes with w
### 2.1 swap and root partitions
```
root # fdisk /dev/nvme0n1

Welcome to fdisk (util-linux 2.38.1).
Changes will remain in memory only, until you decide to write them.
Be careful before using the write command.

Device does not contain a recognized partition table.
Created a new DOS disklabel with disk identifier 0x81391dbc.

Command (m for help): g
Created a new GPT disklabel (GUID: GPT_LABEL_ARRAY).
```
Creating swap partition:
```
Command (m for help): n
Partition number (1-128, default 1): 
First sector (2048-1953525134, default 2048): 
Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-1953525134, default 1953523711): +4G
 
Created a new partition 2 of type 'Linux filesystem' and of size 4 GiB.
```
Now we can change the type to swap:
```
Command (m for help): t
Selected partition 1
Partition type or alias (type L to list all): 19
 
Changed type of partition 'Linux filesystem' to 'Linux swap'.
```
Creating root partition:
```
Command (m for help): n
partition number (2-128, default 2): 
First sector (10487808-1953525134, default 10487808):
Last sector, +/-sectors or +/-size{K,M,G,T,P} (10487808-1953525134, default 1953523711): 

<!--T:238-->
Created a new partition 2 of type 'Linux filesystem' and of size 926.5 GiB..
```
And we do not need to change the type for root partition.

### 2.3 Filesystem (Boot drive)
Making filesystem for the ESP partition:
```
mkfs.vfat -F 32 /dev/sda1
```
Now we can encrypt the second (extended boot partition) for more security:
```
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/sda2
# lukscrypt passphrase:
```
After we need to open it so we can make a filesystem:
```
cryptsetup luksOpen /dev/sda2 luks-keys
# lukscrypt passphrase: 
```
Now we can make the filesystem for extended boot partition:
```
mkfs.ext4 /dev/mapper/luks-keys
```
### 2.4 Key generation and encryption
Before we make a key we first need to mount the extended boot to a directory:
```
mkdir -p /mnt/keys
mount /dev/mapper/luks-keys /mnt/keys
```
After the disk is mounted we can create a key for Swap
```
dd if=/dev/urandom bs=8388608 count=1 | gpg --symmetric --cipher-algo AES256 --output SWAP-KEY.gpg
```
Now we can use the stdin for the decryption of the gpg keyfile and encrypt the disk with the hashed file:
```
gpg --batch --yes --decrypt /path/to/SWAP-KEY.gpg | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/[swap_partition] --key-file=-
```
And now we can open the swap disk:
```
gpg --batch --yes --decrypt /path/to/SWAP-KEY.gpg | cryptsetup open /dev/[swap_partition] cryptswap --key-file=-
```

Now repeat the same process for the root partition:
```
dd if=/dev/urandom bs=8388608 count=1 | gpg --symmetric --cipher-algo AES256 --output ROOT-KEY.gpg
```

Root decryption and encryption:
```
gpg --batch --yes --decrypt /path/to/ROOT-KEY.gpg | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/[root_partition] --key-file=-
```
Open root disk:
```
gpg --batch --yes --decrypt /path/to/ROOT-KEY.gpg | cryptsetup open /dev/[root_partition] cryptroot --key-file=-
```

### 2.5 Configure Swap/Root drive
Make a swap:
```
mkswap /dev/mapper/cryptswap
swapon /dev/mapper/cryptswap
```
Root Filesystem:
	We first need to mount the partition to /mnt/root for we are going to have separated subvolumes for the Root partition:
	```
	mkdir -p /mnt/root
	mkfs.btrfs -L BTROOT /dev/mapper/cryptroot
	mount -t btrfs -o defaults,noatime,compress=lzo /dev/mapper/cryptroot /mnt/root
	```
After that we can create the subvolumes for the partition:
```
btrfs subvolume create /mnt/root/activeroot
btrfs subvolume create /mnt/root/home
btrfs subvolume create /mnt/root/etc
btrfs subvolume create /mnt/root/var
btrfs subvolume create /mnt/root/log
btrfs subvolume create /mnt/root/tmp
```
And now we need to create directory so we can mount the subvolumes to Root so we can chroot in later:
```
mkdir /mnt/gentoo/home
mkdir /mnt/gentoo/etc
mkdir /mnt/gentoo/efi # For later use
mkdir /mnt/gentoo/boot # For later use
mkdir /mnt/gentoo/var
mkdir /mnt/gentoo/log
mkdir /mnt/gentoo/tmp
```
Now we will just mount everything to /mnt/gentoo{.....}:
```
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=activeroot /dev/mapper/cryptroot /mnt/gentoo/
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=home /dev/mapper/cryptroot /mnt/gentoo/home
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=etc /dev/mapper/cryptroot /mnt/gentoo/etc
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=var /dev/mapper/cryptroot /mnt/gentoo/var
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=log /dev/mapper/cryptroot /mnt/gentoo/log
mount -t btrfs -o defaults,noatime,nosuid,noexec,nodev,compress=lzo,subvol=tmp /dev/mapper/cryptroot /mnt/gentoo/tmp
```

### 3 Downloading stage 3 file
Before downloading the stage 3 files it might be a good idea to check the date so when installation is done we do not get clock skew:
```
# To check date
date
Mon May 6 14:24:32 PDT 2025
```
Now if the date is not accurate we can use:
```
date 05061824322025
# `MMDDhhmmYYYY`
```
or
```
chronyd -q
```
After date synced we can start downloading the stage 3.
Choose the stage file you will download using:
```
links https://www.gentoo.org/downloads/mirrors/
```
or
```
wget <PASTED_STAGE_FILE_URL>
```
If you also want to verify you should download the STAGE_FILE.asc format also and then import the GPG signatures with:
```
gpg --import /usr/share/openpgp-keys/gentoo-release.asc
```
after that you run:
```
gpg --verify stage3-*.tar.xz.asc stage3-*.tar.xz
```
If everything is correct, we can extract it:
```
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
```
If verification fails, delete the stage3 files (both tar.xz and tar.xz.asc) and redownload them from a different source, or wait a bit and try again.
### 4 Basic System configurations 
Before we chroot into our new system we can edit some basic system like ***FSTAB***, ***Keyboard Layout*** and also custom ***Portage***. Remember that you need to do:
```
mv /path/to/custom_portage/ /mnt/gentoo/etc/portage/RIGHT_PORTAGE_FILE_DIRECTORY
```
### 5 Chroot 
Copy DNS info to chroot environment:
```
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
```
Mounting the necessary filesystems
```
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run
```
### -----------------------------------------------------------------------------
# Chrooted
### 1 New environment
```
chroot /mnt/gentoo /bin/bash
```
Now we need to source the profile and export so if we accidently exit chroot we will know:
```
source /etc/profile && export PS1="(chroot) ${PS1}"
```
After we can already mount the boot usb to the /efi and /boot:
```
mount /dev/sda1 /efi
mount /dev/sda1 /boot
```
And now we can sync with the Gentoo ebuild repository:
```
emerge-webrsync
```
or If we want the latest up to 24h we can do:
```
emerge --sync
# or
emerge --sync --quiet # If using a "slow" terminal
```
### 2 Updating and Selecting systems
Selecting the system can only be used if user selected stage 3 openrc or stage 3 systemd. if user selected any desktop profile or any other fixed stage profile we do not need to do:
```
eselect profile list
eselect profile set PROFILE_NUMBER
```
since we already have the preconfigured stage file.
Before updating we can change so that portage use ***Binary*** packages instead of ***sources***. But we will not be using it.
We can also edit the ***use flag***, ***license*** and change any necessary things before updating. But in this case we already do have configured portage before chrooting and we only need to change cpuid2cpuflags.
so we can emerge the package:
```
emerge --ask --oneshot app-portage/cpuid2cpuflags
```
and then run:
```
cpuid2cpuflags
```
You can now type it in manually or use:
```
CPU_FLAGS=$(cpuid2cpuflags | cut -d' ' -f2-)
if grep -q "^CPU_FLAGS_X86=" /etc/portage/make.conf; then
    sed -i "s/^CPU_FLAGS_X86=.*/CPU_FLAGS_X86=\"${CPU_FLAGS}\"/" /etc/portage/make.conf  || { echo "could not add CPU_FLAGS_X86= and cpuflags to make.conf"; exit 1; }
    echo "cpuid2cpuflags added successfully to make.conf"
else
    echo "CPU_FLAGS_X86=\"${CPU_FLAGS}\"" >> /etc/portage/make.conf || { echo "could not add cpuflags to make.conf"; exit 1; }
fi
```
We can now start to update the system:
```
emerge --ask --verbose --update --deep --changed-use @world
```
For users who activated binary:
```
emerge --ask --verbose --update --deep --newuse --getbinpkg @world
```
For users whom do not trust precompiled packages from stage file:
```
 emerge --emptytree -a -1 @installed # This will take long time
```
change the /etc/locale.gen file to the desired locale after that you can set locale with:
```
locale-gen
```
And then run:
```
env-update && source /etc/profile && export PS1="(chroot) ${PS1}"
```
### 3 Install/openrc-service
after the update we can install the extra tools and packages we need.
For example:
```
emerge --ask sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/installkernel sys-kernel/linux-firmware \
sys-fs/cryptsetup sys-fs/btrfs-progs sys-apps/sysvinit sys-auth/seatd sys-apps/dbus sys-apps/pciutils \
sys-process/cronie net-misc/chrony net-misc/networkmanager app-admin/sysklogd app-shells/bash-completion \
dev-vcs/git sys-apps/mlocate sys-block/io-scheduler-udev-rules sys-boot/efibootmgr sys-firmware/sof-firmware \
app-editors/neovim app-arch/unzip
```
First, we need to deactivate some services to avoid conflicts:
```
rc-service dhcpcd stop
rc-update del hostname boot
rc-update del dhcpcd default
```
Now we also can activate some of the newly added openrc-services:
```
rc-update add dbus default
rc-update add seatd default
rc-update add cronie default
rc-update add chronyd default
rc-update add sysklogd default
rc-update add NetworkManager default

rc-service NetworkManager start
```
Configure networkmanager
```
nmcli general hostname CUSTOM_NAME
```
### 4 Kernel configuration
We will use:
```
genkernel --luks --btrfs --keymap --oldconfig --save-config --menuconfig --install all 
```
First we need to edit the Built-in kernel command line:
```
Processor type and features  --->
    [*] Built-in kernel command line
    (root=LABEL=BTROOT rootflags=subvol=activeroot) Built-in kernel command string
```
The built in command line should match yours root labels and subvolumes names.
And then we need to "activate" some modules:
Cryptographic API support:
```
Cryptographic API  --->
    <*> AES cipher algorithms
    <*> SHA-256 digest algorithm
    <*> User-space interface for hash algorithms

```
Filesystems support:
```
File systems  --->
    <*> ext4 filesystem support
    <*> vfat (if using FAT32-formatted USB)
    <*> Btrfs (if root is Btrfs)
```
***Remove*** systemd if using openrc:
```
Gentoo Linux --->
   Support for init systems, system and service managers --->
      [] systemd
```
USB support:
```
Device Drivers  --->
    [*] USB support  --->
        <*> EHCI HCD (USB 2.0) support
        <*> XHCI HCD (USB 3.0) support
        <*> USB Mass Storage support
        <*> SCSI disk support

Multiple device driver support (raid and LVM) --->
    <*> Device mapper support
    <*> Crypt target support
```
### 4.1 Configure systems
***If you have not configured system before chroot then it is the time to do that now***
Now we can edit the ugRD config: (/etc/ugrd/config.toml)
```
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
device = "/dev/disk/by-uuid/<UUID_OF_SDA2>"  # This is the encrypted LUKS device
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
```
### 5 Bootloader 
Now, just run efibootmgr:
```
efibootmgr --create --disk <bootdisk> --part 1 \
  --label "Gentoo" \
  --loader "\EFI\Gentoo\bzImage.efi" \
  --unicode "initrd=\EFI\Gentoo\initramfs-6.12.21-gentoo.img" \
  --verbose
```

The Guide sources: \
[Kernel/Command-line parameters](https://wiki.gentoo.org/wiki/Kernel/Command-line_parameters) \
[Custom Initramfs/Examples](https://wiki.gentoo.org/wiki/Custom_Initramfs/Examples) \
[Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64) \
[EFI stub](https://wiki.gentoo.org/wiki/EFI_stub) \
[GnuPG](https://wiki.gentoo.org/wiki/GnuPG) \

User Sources: \
[User:Sakaki/Sakaki's EFI Install Guide/Preparing the LUKS-LVM Filesystem and Boot USB Key](https://wiki.gentoo.org/wiki/User:Sakaki/Sakaki%27s_EFI_Install_Guide/Preparing_the_LUKS-LVM_Filesystem_and_Boot_USB_Key) \