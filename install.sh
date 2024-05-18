#!/bin/sh

# Function for error handling
error_exit() {
    echo "$1" >&2
    cleanup
    exit 1
}

# Function for cleanup
cleanup() {
    echo "Unmounting /mnt..."
    umount -R /mnt
    echo "Cleanup done."
}

# Set up trap to call cleanup function on script exit
trap cleanup EXIT

# List available block devices
lsblk

echo -e "\nWARNING: MAKE SURE IT'S THE RIGHT DISK!\n"
echo "Choose your disk: (example: /dev/sda or /dev/nvme0n1p1) "
read DISK

if [ ! -b "$DISK" ]; then
    error_exit "Invalid disk selected."
fi

# Partition disk
cfdisk "${DISK}" || error_exit "Partitioning failed."
clear
lsblk

# Input for partitions

echo -e "\nEnter EFI paritition: (example /dev/sda1)"
read EFI

echo "Enter boot partition (/boot): (example: /dev/sda2)"
read BOOT

echo "Enter Root (/) partition: (example /dev/sda3)"
read ROOT

echo "Enter home partition (/home): (example: /dev/sda4)"
read HOME

echo "Enter your username:"
read USER

echo "Enter your password:"
read PASSWORD

# Make filesystems
echo -e "\nCreating Filesystems...\n"
mkfs.vfat -F 32 "${EFI}" || error_exit "Formatting EFI partition failed."
fatlabel "${EFI}" ESP || error_exit "Labeling EFI partition failed."

echo -e "\nFormatting BOOT partition..\n"
mkfs.ext4 -L "BOOT" "${BOOT}" || error_exit "Formatting BOOT partition failed."

echo -e "\nFormatting ROOT partition...\n"
mkfs.ext4 -L "ROOT" "${ROOT}" || error_exit "Formatting ROOT partition failed."

echo -e "\nFormatting HOME partition...\n"
mkfs.ext4 -L "HOME" "${HOME}" || error_exit "Formatting HOME partition failed."

# Mount partitions
echo -e "\nMounting partitions...\n"
mount "${ROOT}" /mnt || error_exit "Mounting ROOT partition failed."
mkdir /mnt/boot
mkdir /mnt/home
mount "${BOOT}" /mnt/boot || error_exit "Mounting BOOT partition failed."
mount "${HOME}" /mnt/home || error_exit "Mounting HOME partition failed."
mkdir /mnt/boot/efi
mount "${EFI}" /mnt/boot/efi || error_exit "Mounting EFI partition failed."

# Install base system
echo "--------------------------------------"
echo "--  INSTALLING Artix Linux (runit)  --"
echo "--------------------------------------"
#sv up ntpd || error_exit "Failed to start NTP daemon."

echo -e "\nInstalling base system...\n"
basestrap /mnt base base-devel runit elogind-runit --noconfirm --needed || error_exit "Basestrap failed."

# Install kernel
echo -e "\nInstalling kernel...\n"
basestrap /mnt linux linux-firmware --noconfirm --needed || error_exit "Kernel installation failed."

# Install additional packages
basestrap /mnt amd-ucode git neovim --noconfirm --needed || error_exit "Additional packages installation failed."

# Generate fstab
fstabgen -U /mnt >> /mnt/etc/fstab || error_exit "Generating fstab failed."

# Create next script for chroot
cat <<'REALEND' > /mnt/next.sh
#!/bin/sh

# Set timezone and configure locale
ln -sf /usr/share/zoneinfo/Asia/Singapore /etc/localtime
hwclock --systohc
echo "LANG=en_US.UTF-8" >> /etc/locale.conf
echo -e "\nSetup Language to US and set locale...\n"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

# Install bootloader
echo -e "\nInstalling Boot loader...\n"
pacman -S grub os-prober efibootmgr --noconfirm --needed|| error_exit "Bootloader installation failed."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB || error_exit "Generating grub configuration failed."
grub-mkconfig -o /boot/grub/grub.cfg || error_exit "Generating grub configuration failed."

# Add user
echo -e "\Adding user...\n"
useradd -m "$USER" || error_exit "Adding user failed."
usermod -aG wheel,input,video "$USER" || error_exit "Modifying user failed."
echo "$PASSWORD" | passwd --stdin "$USER" || error_exit "Setting user password failed."
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || error_exit "Modifying sudoers failed."

# Configure network
echo -e "\nConfiguring network...\n"
echo "artix" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1	localhost
::1			localhost
127.0.1.1	artix.localdomain	artix
EOF
pacman -S dhcpcd --noconfirm --needed || error_exit "Installing dhcpcd failed."
ln -s /etc/runit/sv/dhcpcd /etc/runit/runsvdir/default || error_exit "Configuring dhcpcd failed."

# Install Display and Audio Driver
echo -e "\nInstalling Display and Audio Driver\n"
pacman -S xorg pipewire pipewire-pulse wireplumber --noconfirm --needed || error_exit "Installing display and audio driver failed."

# Install NVIDIA driver if requested
echo -e "\nDo you want to install proprietary NVIDIA driver? (Y/N)"
read INSTALL_NVIDIA
if [ "$INSTALL_NVIDIA" = "Y" ] || [ "$INSTALL_NVIDIA" = "y" ]; then
    pacman -S nvidia --noconfirm --needed || error_exit "Installing NVIDIA driver failed."
fi

# Desktop Environment
pacman -S i3-wm dmenu xterm --noconfirm --needed || error_exit "Installing i3wm failed."
cat <<EOF > /home/$USER/.xinitrc
/usr/bin/pipewire &
/usr/bin/pipewire-pulse &
/usr/bin/wireplumber &
exec i3
EOF

echo "-------------------------------------------------"
echo "-           Installation Completed              -"
echo "-------------------------------------------------"

REALEND

# Chroot and execute next script
artix-chroot /mnt sh next.sh || error_exit "Chroot execution failed."

