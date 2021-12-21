#!/bin/bash

PS3="Please select the disk where Arch Linux is going to be installed: "
select entry in $(lsblk -dpnoNAME | grep -P "/dev/sd|nvme|vd"); do
  disk=${entry}
  echo "Installing Arch Linux on ${disk}."
  break
done

# Deleting old partition scheme.
read -r -p "This will delete the current partition table on ${disk}. Do you agree [y/N]? " response
response=${response,,}
if [[ ${response} =~ ^(yes|y)$ ]]; then
  wipefs -af "${disk}"
  sgdisk -Zo "${disk}"
else
  exit
fi

#Partitioning
sgdisk -n 1:0:+256M -c 1:"BOOT" -t 1:ef00 "${disk}"
sgdisk -n 2:0:0 -c 2:"ROOT" -t 2:8300 "${disk}"

boot="/dev/disk/by-partlabel/BOOT"
cryptroot="/dev/disk/by-partlabel/ROOT"

read -r -s -p "Insert password for the LUKS container (you're not going to see the password): " password
if [ -z "${password}" ]; then
  print "You need to enter a password for the LUKS Container in order to continue."
  password_selector
fi
echo -n "${password}" | cryptsetup luksFormat "${cryptroot}" -d -
cryptroot_uuid=$(blkid -s UUID -o value ${cryptroot})
echo -n "${password}" | cryptsetup open "${cryptroot}" cryptlvm -d -

cryptlvm="/dev/mapper/cryptlvm"

pvcreate "${cryptlvm}"

vgcreate MAIN "${cryptlvm}"

lvcreate -L 128G MAIN -n root
lvcreate -l 100%FREE MAIN -n home

root='/dev/MAIN/root'
home='/dev/MAIN/home'

mkfs.ext4 "${root}"
mkfs.ext4 "${home}"
mkfs.fat -F 32 "${boot}"

mount "${root}" /mnt
mkdir /mnt/home
mount "${home}" /mnt/home
mkdir /mnt/boot
mount "${boot}" /mnt/boot

pacstrap /mnt base base-devel linux-zen linux-firmware networkmanager efibootmgr lvm2

genfstab -U /mnt >>/mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/"$(curl -s http://ip-api.com/line?fields=timezone)" /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >/etc/locale.gen
locale-gen

echo "LANG=en_US.UTF-8" >/etc/locale.conf
echo "KEYMAP=de-latin1" >/etc/vconsole.conf

echo "Workstation" >/etc/hostname

cat >/etc/mkinitcpio.conf 'HOOKS=(base systemd keyboard autodetect sd-vconsole modconf block sd-encrypt lvm2 filesystems fsck)'

mkinitcpio -P
passwd

useradd -m -G wheel admin
passwd admin
echo "admin ALL=(ALL) ALL" >>/etc/sudoers.d/admin

efibootmgr --disk "${disk}" --part 1 --create --label 'Arch Linux' --loader /vmlinuz-linux --unicode "rd.luks.name=${cryptroot_uuid}=cryptlvm root=${root} rw initrd=/initramfs-linux-zen.img"
EOF
