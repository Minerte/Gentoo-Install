# This is a guide and what the autoscript is doing
### The guide is taken from [Full Disk Encryption from scratch](https://wiki.gentoo.org/wiki/Full_Disk_Encryption_From_Scratch) from the Gentoo wiki, also note that Readme.md only include the diskpepration with encryption and kernel changes that needs to be done. For more information please check the other sources at the bottom of the Readme.md.

The disk visiual:
```
/dev/sda #boot drive
├── /dev/sda1      [EFI]   /efi      1 GB         fat32       Bootloader
└── /dev/sda2      [BOOTX] /boot     1 GB         ext4        Bootloader support files, kernel and initramfs

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
mkfs.ext4 /dev/sda2 # Key-file storage
### Note that /dev/sda1 is the bootloader and /dev/sda2 is for storage of keyfile
```

After successfully create a filesystem we need to mount /dev/sda2 to /media/sda2 so we can generate Keyfile to partition
```
mkdir /media/sda2
mount /dev/sda2 /media/sda2
```
### Key generation for SWAP and ROOT partition
Here we generate a keyfile, the keyfile of should be **8MB**
```
# Swap 
dd if=/dev/urandom of=/media/sda2/swap-keyfile bs=8388608 count=1 # User can change bs= to any number that is higher then 512bytes
gpg --symmetric --cipher-algo AES256 --output swap-keyfile.gpg swap-keyfile
# Root
dd if=/dev/urandom of=/media/sda2/luks-keyfile bs=8388608 count=1 # User can change bs= to any number that is higher then 512bytes
gpg --symmetric --cipher-algo AES256 --output luke-keyfile.gpg luks-keyfile
```

### Cryptsetup for swap and root
We need to decrypt the gpg file so we can encrypt the partition using the keyfil.
```
# swap
gpg --decrypt --output /tmp/swap-keyfile /media/sda2/swap-keyfile.gpg
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/[swap_partition] --key-file=/tmp/swap-keyfile 
# Root
gpg --decrypt --output /tmp/luks-keyfile /media/sda2/luks-keyfile.gpg
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/[root_pratition] --key-file=/tmp/luks-keyfile
```

Now we can open the disk for modification.
```
cryptsetup open /dev/[swap_partition] cryptswap --key-file=/tmp/swap-keyfile
cryptsetup open /dev/[root_partition] cryptroot --key-file=/tmp/luks-keyfile
```

And then you might want to securely remove the **swap-keyfile/luks-keyfile** with the command:
#### Caution do not delete the swap-keyfile.gpg/luks-keyfile.gpg in /media/sda2! Or you data will be lost!
```
shred -u /tmp/swap-keyfile
shred -u /tmp/luks-keyfile
shred -u /media/sda2/swap-keyfile
shred -u /media/sda2/luks-keyfile
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

We are gone use ugrd. An set up example! \
/etc/ugrd/config.toml
```
modules = [
  "ugrd.kmod.usb",
  "ugrd.crypto.gpg"
]

# These will be automatically mounted early in init
auto_mounts = [
  "/boot",
  "/mnt/bootkeys"
]

[[mounts]]
device = "/dev/disk/by-uuid/<UUID_OF_SDA2>"   # This is your ext4 partition with keyfiles
mountpoint = "/mnt/bootkeys"
filesystem = "ext4"
options = "ro"

[cryptsetup.root]
# luksUUID can be auto-detected, or you can specify it manually
key_type = "gpg"
key_file = "/mnt/bootkeys/luks-keyfile.gpg"

[cryptsetup.swap]
key_type = "gpg"
key_file = "/mnt/bootkeys/swap-keyfile.gpg"

```

The script will allow the user to edit kernel manually! \
When editing kernel user need to add kernel_cmdline or we can add --unicode for efibootmgr
#### AMD64 kernel "example"
***change any other kernel modules to have support to what you need to do***
```
Processor type and features  --->
    [*] Built-in kernel command line
    (root=LABEL=BTROOT rootflags=subvol=activeroot init=/lib/ugrd/init) Built-in kernel command string
```
#### EFIBOOTMGR "example" ***without*** the built-in kernel command line
```
efibootmgr --create --disk <bootdisk> --part 1 \
  --label "Gentoo" \
  --loader "\EFI\Gentoo\bzImage.efi" \
  --unicode 'initrd=\EFI\Gentoo\initramfs-6.1.21-gentoo.img \
  root=LABEL=BTROOT \
  rootflags=subvol=activeroot \
  init=/lib/ugrd/init' \
  --verbose
```
#### EFIBOOTMGR "example" ***with*** the built-in kernel command line
```
efibootmgr --create --disk <bootdisk> --part 1 \
  --label "Gentoo" \
  --loader "\EFI\Gentoo\bzImage.efi" \
  --unicode "initrd=\EFI\Gentoo/initramfs-6.1.21-gentoo.img" \
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
