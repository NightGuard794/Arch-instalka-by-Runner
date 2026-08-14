#!/usr/bin/env bash
# ============================================================================
#  ARCH LINUX — automatyczny skrypt instalacyjny
# ----------------------------------------------------------------------------
#  UEFI  |  GRUB  |  NetworkManager  |  zram (pod gry)  |  yay  |  auto-GPU
# ----------------------------------------------------------------------------
#  Uruchamiać z Live ISO Archa, po podłączeniu do internetu.
#  Użycie:  bash arch-install.sh
# ============================================================================

set -e

# ---- kolory logów skryptu (tylko podczas instalacji, nie zmieniają systemu) -
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }


# ==============================================================================
# 0. Weryfikacja trybu UEFI
# ==============================================================================
if [ ! -d /sys/firmware/efi ]; then
    err "System nie jest w trybie UEFI. Przerywam."
    exit 1
fi


# ==============================================================================
# 1. Wybór dysku i podstawowe dane
# ==============================================================================
lsblk -d -o NAME,SIZE,MODEL
echo
read -rp "Podaj dysk do instalacji (np. sda, nvme0n1): " DISKNAME
DISK="/dev/${DISKNAME}"

if [[ "$DISK" == *"nvme"* ]]; then
    PART_BOOT="${DISK}p1"
    PART_ROOT="${DISK}p2"
else
    PART_BOOT="${DISK}1"
    PART_ROOT="${DISK}2"
fi

warn "WSZYSTKIE DANE NA $DISK ZOSTANĄ USUNIĘTE!"
read -rp "Wpisz 'tak' aby kontynuować: " CONFIRM
[ "$CONFIRM" != "tak" ] && { err "Przerwano."; exit 1; }

read -rp "Podaj nazwę hosta (hostname), np. arch-pc: " HOSTNAME


# ==============================================================================
# 2. Partycjonowanie (GPT)  ->  1 GB EFI  +  reszta na root
# ==============================================================================
info "Partycjonowanie $DISK ..."

sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1G -t1:ef00 -c1:"EFI"  "$DISK"
sgdisk -n2:0:0    -t2:8300 -c2:"ROOT" "$DISK"

partprobe "$DISK"
sleep 2


# ==============================================================================
# 3. Formatowanie
# ==============================================================================
info "Formatowanie partycji ..."

mkfs.fat -F32 "$PART_BOOT"
mkfs.ext4 -F  "$PART_ROOT"


# ==============================================================================
# 4. Montowanie
# ==============================================================================
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount "$PART_BOOT" /mnt/boot


# ==============================================================================
# 5. Detekcja karty graficznej -> dobór sterownika
# ==============================================================================
info "Wykrywanie karty graficznej ..."

GPU_PKGS="mesa vulkan-icd-loader"

if lspci | grep -Ei "vga|3d|display" | grep -qi nvidia; then
    info "Wykryto NVIDIA"
    GPU_PKGS="$GPU_PKGS nvidia nvidia-utils nvidia-settings"

elif lspci | grep -Ei "vga|3d|display" | grep -qi amd; then
    info "Wykryto AMD"
    GPU_PKGS="$GPU_PKGS xf86-video-amdgpu vulkan-radeon"

elif lspci | grep -Ei "vga|3d|display" | grep -qi intel; then
    info "Wykryto Intel"
    GPU_PKGS="$GPU_PKGS xf86-video-intel vulkan-intel intel-media-driver"

else
    warn "Nie rozpoznano karty graficznej, instaluję tylko mesa."
fi


# ==============================================================================
# 6. Instalacja bazowego systemu (pacstrap)
# ==============================================================================
info "Instalacja bazowego systemu (pacstrap) ..."

pacstrap -K /mnt \
    base base-devel linux linux-firmware linux-headers \
    grub efibootmgr networkmanager \
    sudo git vim nano \
    zram-generator earlyoom \
    $GPU_PKGS

genfstab -U /mnt >> /mnt/etc/fstab


# ==============================================================================
# 7. Konfiguracja systemu wewnątrz chroot
# ==============================================================================
info "Konfiguracja systemu (chroot) ..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# ---- strefa czasowa: Polska --------------------------------------------
ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime
hwclock --systohc

# ---- locale: system po angielsku, ale czas/klawiatura PL ---------------
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#pl_PL.UTF-8 UTF-8/pl_PL.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# ---- klawiatura konsoli: PL ----------------------------------------------
echo "KEYMAP=pl" > /etc/vconsole.conf

# ---- hostname -------------------------------------------------------------
echo "$HOSTNAME" > /etc/hostname
cat >> /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# ---- hasło roota ------------------------------------------------------------
echo "root:1234" | chpasswd

# ---- dodatkowy user tylko do budowy yay (AUR nie buduje się jako root) ------
useradd -m -G wheel -s /bin/bash user
echo "user:1234" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ---- sieć: NetworkManager ---------------------------------------------------
systemctl enable NetworkManager

# ------------------------------------------------------------------------------
# zram — swap w skompresowanym RAM-ie, dostrojony pod granie:
#   - rozmiar: do 8 GB (gry potrafią zjeść dużo pamięci na tekstury/cache)
#   - najwyższy priorytet, żeby był używany przed jakimkolwiek innym swapem
#   - zstd = dobra kompresja przy niskim koszcie CPU
# ------------------------------------------------------------------------------
cat > /etc/systemd/zram-generator.conf <<ZRAM
[zram0]
zram-size = min(ram, 8192)
compression-algorithm = zstd
swap-priority = 32767
fs-type = swap
ZRAM

# swappiness=100 -> dobre dla zrama (szybki, kompresowany RAM, nie dysk)
# reszta ogranicza "spanikowane" agresywne czyszczenie pamięci pod obciążeniem
cat > /etc/sysctl.d/99-zram.conf <<SYSCTL
vm.swappiness = 100
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
SYSCTL

# ------------------------------------------------------------------------------
# earlyoom — zabija zawieszający się proces ZANIM zabraknie pamięci.
# Bez tego pełny RAM+zram podczas gry = zawieszenie systemu zamiast
# szybkiego ubicia procesu, który zjada pamięć.
#
# Dostrojone pod granie, żeby earlyoom sam nie był problemem:
#   -m 8 -s 5   -> reaguje dopiero gdy WOLNY RAM <8% ORAZ WOLNY zram <5%,
#                  więc nie wystrzeli od zwykłego skoku pamięci przy
#                  ładowaniu levelu/tekstur, tylko gdy naprawdę zaczyna
#                  brakować pamięci
#   -r (avoid)  -> NIGDY nie zabija kluczowych procesów gry/grafiki:
#                  serwer graficzny, kompozytor, Steam, Proton/Wine, audio
#   -p (prefer) -> zamiast tego najpierw zabija mniej istotne tło:
#                  przeglądarkę, Discorda, Spotify itp.
# ------------------------------------------------------------------------------
cat > /etc/default/earlyoom <<'EARLYOOM_CONF'
EARLYOOM_ARGS="-m 8 -s 5 -r '^(Xorg|sway|hyprland|gamescope|steam|steamwebhelper|wine.*|wine64.*|proton.*|pipewire|pulseaudio)$' -p '^(firefox|chrome|chromium|discord|Discord|spotify|Spotify|thunderbird|slack|Slack|code)$'"
EARLYOOM_CONF

systemctl enable earlyoom

# ---- GRUB (UEFI) --------------------------------------------------------------
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# ---- pacman: szybsze pobieranie równoległe (funkcjonalne, nie kosmetyczne) ----
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf

# ---- budowa yay jako user 'user' -----------------------------------------------
su - user -c "
    cd /home/user &&
    git clone https://aur.archlinux.org/yay.git &&
    cd yay &&
    makepkg -si --noconfirm
"

# ---- sprzątanie: usunięcie tymczasowego konta 'user' -----------------------------
# było potrzebne tylko do zbudowania yay (AUR nie buduje się jako root)
userdel -r user
EOF


# ==============================================================================
# Koniec
# ==============================================================================
info "Instalacja zakończona!"
info "Teraz możesz zrobić: umount -R /mnt && reboot"
