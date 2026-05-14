#!/bin/bash

# --- 1. KONFIGURACJA ---
clear
echo "=== ARCH  BY RUNNER INSTALLER (Secure Boot + zRAM + AUR + Power) ==="
echo "-------------------------------------------------------------------"

lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
echo "-------------------------------------------------------------------"
read -p "Wpisz nazwę dysku (np. sda lub nvme0n1): " DISK_NAME
DRIVE="/dev/$DISK_NAME"
read -p "Podaj nazwę komputera (Hostname): " MY_HOSTNAME

echo -e "\nWybierz GPU:\n1) NVIDIA\n2) AMD\n3) Brak"
read -p "Wybór: " GPU_CHOICE

# Automatyczne wykrywanie CPU dla Microcode
CPU_UCODE=""
if grep -q "GenuineIntel" /proc/cpuinfo; then CPU_UCODE="intel-ucode"; fi
if grep -q "AuthenticAMD" /proc/cpuinfo; then CPU_UCODE="amd-ucode"; fi

if [[ $DRIVE == *"nvme"* ]]; then PART_BOOT="${DRIVE}p1"; PART_ROOT="${DRIVE}p2"
else PART_BOOT="${DRIVE}1"; PART_ROOT="${DRIVE}2"; fi

read -p "Sformatować $DRIVE? (y/N): " CONFIRM
[[ $CONFIRM != "y" ]] && exit 1

# --- 2. PRZYGOTOWANIE ---
loadkeys pl
timedatectl set-ntp true

# --- 3. PARTYCJONOWANIE (1GB Boot) ---
sed -e 's/\s*\([\+0-9a-zA-Z]*\),.*/\1/' << EOF | sfdisk $DRIVE
  label: gpt
  size=1G, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF

# --- 4. FORMATOWANIE ---
mkfs.fat -F 32 $PART_BOOT
mkfs.ext4 $PART_ROOT
mount $PART_ROOT /mnt
mkdir -p /mnt/boot/efi
mount $PART_BOOT /mnt/boot/efi

# --- 5. INSTALACJA (Dodano: NTFS, Power, Microcode) ---
PKGS="base linux linux-firmware $CPU_UCODE sof-firmware sudo base-devel grub efibootmgr nano networkmanager zram-generator sbctl pacman-contrib git ntfs-3g exfatprogs dosfstools tlp power-profiles-daemon acpi acpi_call"

if [ "$GPU_CHOICE" == "1" ]; then PKGS="$PKGS nvidia nvidia-utils nvidia-settings"; fi
if [ "$GPU_CHOICE" == "2" ]; then PKGS="$PKGS mesa lib32-mesa xf86-video-amdgpu"; fi

pacstrap /mnt $PKGS
genfstab -U /mnt >> /mnt/etc/fstab

# --- 6. CHROOT ---
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "pl_PL.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=pl" > /etc/vconsole.conf
echo "$MY_HOSTNAME" > /etc/hostname
echo "root:1234" | chpasswd

# zRAM
echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf

# Bootloader & Secure Boot
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
sbctl create-keys
sbctl enroll-keys -m
sbctl sign -s /boot/efi/EFI/GRUB/grubx64.efi
sbctl sign -s /boot/vmlinuz-linux

# --- 7. AUR (YAY & PARU) ---
useradd -m -G wheel builder
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
sudo -u builder bash <<AUR
cd /home/builder
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin && makepkg -si --noconfirm
cd ..
git clone https://aur.archlinux.org/paru-bin.git
cd paru-bin && makepkg -si --noconfirm
AUR
userdel -r builder
sed -i '/builder/d' /etc/sudoers

# Usługi
systemctl enable NetworkManager
systemctl enable tlp
EOF

umount -R /mnt
echo "Gotowe! System posiada sterowniki, zRAM, AUR i wsparcie dysków. Reboot!"
