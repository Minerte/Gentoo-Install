# This is a guide and what the autoscript is doing
### The guide is taken from [Full Disk Encryption from scratch](https://wiki.gentoo.org/wiki/Full_Disk_Encryption_From_Scratch) from the Gentoo wiki, also note that Readme.md only include the diskpepration with encryption and kernel changes that needs to be done. For more information please check the other sources at the bottom of the Readme.md.

The disk visiual:
```
/dev/sda #boot drive
├── /dev/sda1      [EFI]   /efi      1 GB         fat32       Bootloader
└── /dev/sda2      [BOOTX]
      └──  /dev/mapper/luks_keys     1 GB         ext4        Bootloader support files, kernel and initramfs

/dev/nvme0n1 # root drive
 ├── /dev/nvme0n1p1
 |    └──  /dev/mapper/cryptswap  SWAP      ->END        SWAP
 └── /dev/nvme0n1p2 [ROOT]  (root)          ->END        luks        Encrypted root device, mapped to the name 'root'
      └──  /dev/mapper/cryptroot  /         ->END        btrfs       root filesystem
                                  /home     subvolume                Subvolume created for the home directory
                                  /etc      subvolume
                                  /var      subvolume
                                  /log      subvolume
                                  /tmp      subvolume
```
### Preparing the boot drive
We need to create filesystem for /dev/sda1 and /dev/sda2 (our boot drive).
```
mkfs.vfat -F 32 /dev/sda1 # Boot

cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/sda2 # Key
# lukscrypt passphrase:
cryptsetup luksOpen /dev/sda2 luks_keys
# lukscrypt passphrase:

mkfs.ext4 /dev/mapper/luks_keys
# Note that /dev/sda1 is the bootloader and /dev/sda2 is for storage of keyfile
```
After successfully create a filesystem we need to mount /dev/sda2 to /media/sda2 so we can generate Keyfile to partition
```
mkdir -p /mnt/keys
mount /dev/mapper/luks_keys /mnt/keys
```

### Key generation for SWAP and ROOT partition
Here we generate a keyfile, the keyfile of should be **8MB**
```
# Swap 
dd if=/dev/urandom of=/mnt/keys/SWAP-KEY bs=8388608 count=1 # User can change bs= to any number that is higher then 512bytes
gpg --symmetric --cipher-algo AES256 --output SWAP-KEY.gpg SWAP-KEY
# Root
dd if=/dev/urandom of=/mnt/keys/ROOT-KEY bs=8388608 count=1 # User can change bs= to any number that is higher then 512bytes
gpg --symmetric --cipher-algo AES256 --output ROOT-KEY.gpg ROOT-KEY
```

Formatting the disk for swap and root
```
gpg --batch --yes --decrypt /path/to/SWAP-KEY.gpg | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/[swap_partition] --key-file=-
gpg --batch --yes --decrypt /path/to/ROOT-KEY.gpg | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/[root_partition] --key-file=-
```
Now we can open the disk for modification.
```
gpg --batch --yes --decrypt /path/to/SWAP-KEY.gpg | cryptsetup open /dev/[swap_partition] cryptswap --key-file=-
gpg --batch --yes --decrypt /path/to/ROOT-KEY.gpg | cryptsetup open /dev/[root_partition] cryptroot --key-file=-
```

And then you might want to securely remove the **swap-keyfile/luks-keyfile** with the command:
#### Caution do not delete the swap-keyfile.gpg/luks-keyfile.gpg in /media/sda2! Or you data will be lost!
```
shred -u /mnt/keys/SWAP-KEY
shred -u /mnt/keys/ROOT-KEY
```

### Now we can start to format the partition for usage
##### For swap:
```
mkswap /dev/mapper/cryptswap
swapon /dev/mapper/cryptswap
```
#### For Root:
```
mkdir -p /mnt/root
mkfs.btrfs -L BTROOT /dev/mapper/cryptroot
mount -t btrfs -o defaults,noatime,compress=lzo /dev/mapper/cryptroot /mnt/root
```
now we can create sub volumes for btrfs.
```
btrfs subvolume create /mnt/root/activeroot
btrfs subvolume create /mnt/root/home
btrfs subvolume create /mnt/root/etc
btrfs subvolume create /mnt/root/var
btrfs subvolume create /mnt/root/log
btrfs subvolume create /mnt/root/tmp
```
Then we need to create directory for the home, etc, var, log and tmp in directory /mnt/gentoo/
```
mkdir /mnt/gentoo/home
mkdir /mnt/gentoo/etc
mkdir /mnt/gentoo/var
mkdir /mnt/gentoo/log
mkdir /mnt/gentoo/tmp
```
now we can mount the cryptroot subvolumes to /mnt/gentoo/
```
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=activeroot /dev/mapper/cryptroot /mnt/gentoo/
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=home /dev/mapper/cryptroot /mnt/gentoo/home
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=etc /dev/mapper/cryptroot /mnt/gentoo/etc
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=var /dev/mapper/cryptroot /mnt/gentoo/var
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=log /dev/mapper/cryptroot /mnt/gentoo/log
mount -t btrfs -o defaults,noatime,nosuid,noexec,nodev,compress=lzo,subvol=tmp /dev/mapper/cryptroot /mnt/gentoo/tmp
```

# Now we will edit in chroot
```
/dev/sda
 ├──sda1     BDF2-0139 # BIOS/EFI
 └──sda2     0e86bef-30f8-4e3b-ae35-3fa2c6ae705b # UUID=BOOT_KEY_PARTITION_UUID
/dev/nvme0n1 # root drive
 ├── /dev/nvmeon1p1 cb070f9e-da0e-4bc5-825c-b01bb2707704
 |    └──  /dev/mapper/cryptswap  Swap      
 └── /dev/nvme0n1p2 4bb45bd6-9ed9-44b3-b547-b411079f043b
      └──  /dev/mapper/cryptroot  /
                                  /home     subvolume
                                  /etc      subvolume
                                  /var      subvolume
                                  /log      subvolume
                                  /tmp      subvolume
```

Make sure the directory of /efi and /efi/EFI/Gentoo is created for the right partition ( in our case /dev/sdX1 )
```
mkdir /efi
mount /dev/sdX1 /efi
mkdir -p /efi/EFI/Gentoo
```

We are gone use ugrd. An set up example! \
/etc/ugrd/config.toml
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
device = "/dev/mapper/luks_keys"              # Now unlocked device
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
(**might** not need the /lib/ugrd/init "custom" and if you need it dont forget to add **init=/lib/ugrd/init** into the built-in kernel command line) \
And we need to add this to /lib/ugrd/init 
```
#!/bin/sh

set -e

echo "Unlocking swap partition..."
gpg --batch --yes --quiet --decrypt /mnt/bootkeys/SWAP-KEY.gpg | cryptsetup open /dev/[swap_partition] cryptswap --key-file=-

echo "Unlocking root partition..."
gpg --batch --yes --quiet --decrypt /mnt/bootkeys/ROOT-KEY.gpg | cryptsetup open /dev/[root_partition] cryptroot --key-file=-
```

The script will allow the user to edit kernel manually! \
When editing kernel user need to add kernel_cmdline or we can add --unicode for efibootmgr
#### AMD64 kernel "example"
***change any other kernel modules to have support to what you need to do***
```
Processor type and features  --->
    [*] Built-in kernel command line
    (root=LABEL=BTROOT rootflags=subvol=activeroot) Built-in kernel command string
```

Now we need to generate the initramfs for the kernel.img
```
ugrd --kver 6.12.21-gentoo /efi/EFI/Gentoo/initramfs-6.12.21-gentoo.img
```
***after kernel build run one of these command***
```
# Run one of these
cp /boot/bzImage-* /efi/EFI/Gentoo/bzImage.efi
cp /boot/vmlinuz-* /efi/EFI/Gentoo/bzImage.efi
cp /boot/kernel-* /efi/EFI/Gentoo/bzImage.efi
```

#### EFIBOOTMGR "example" ***without*** the built-in kernel command line
```
efibootmgr --create --disk <bootdisk> --part 1 \
  --label "Gentoo" \
  --loader "\EFI\Gentoo\bzImage.efi" \
  --unicode 'initrd=\EFI\Gentoo\initramfs-6.12.21-gentoo.img \
  root=LABEL=BTROOT \
  rootflags=subvol=activeroot \
  init=/lib/ugrd/init' \ # might not need the init=/lib/ugrd/init
  --verbose
```
#### EFIBOOTMGR "example" ***with*** the built-in kernel command line
```
efibootmgr --create --disk <bootdisk> --part 1 \
  --label "Gentoo" \
  --loader "\EFI\Gentoo\bzImage.efi" \
  --unicode "initrd=\EFI\Gentoo\initramfs-6.12.21-gentoo.img" \
  --verbose
```
***If using embedded initramfs for kernel you can remove "initrd=\EFI\Gentoo\initramfs.img" from efibootmgr --unicode***

!!! Potential issues !!! \
If gpg-keyfile mount to /tmp it might not be able to execute the decrypt because of ***fstab rules*** "defaults,noatime,nosuid,***noexec***,nodev,compress=lzo,subvol=tmp"

WIKI sources: \
[Kernel/Command-line parameters](https://wiki.gentoo.org/wiki/Kernel/Command-line_parameters) \
[Custom Initramfs/Examples](https://wiki.gentoo.org/wiki/Custom_Initramfs/Examples) \
[Gentoo AMD64 Handbook](https://wiki.gentoo.org/wiki/Handbook:AMD64) \
[EFI stub](https://wiki.gentoo.org/wiki/EFI_stub) \
[GnuPG](https://wiki.gentoo.org/wiki/GnuPG) \

USER sources: \
[User:Sakaki/Sakaki's EFI Install Guide/Preparing the LUKS-LVM Filesystem and Boot USB Key](https://wiki.gentoo.org/wiki/User:Sakaki/Sakaki%27s_EFI_Install_Guide/Preparing_the_LUKS-LVM_Filesystem_and_Boot_USB_Key) \
