#!/bin/bash

# This script is heavily inspired by and even copies from https://github.com/mietinen/archer/ at times

if [[ -f "config" ]]; then
    . config
else
    echo "Config file doesn't exist"
    exit 1
fi

if [ "${disk::8}" == "/dev/nvm" ] ; then
    bootdev="${disk}p1"
    rootdev="${disk}p2"
else
    bootdev="${disk}1"
    rootdev="${disk}2"
fi
for var in disk kernel hostname username timezone locale language aurhelper installdotfiles dotfilesurl multilib swapfilesize userpassword rootpassword cryptpassword
do
    if [[ ! -v $var ]]; then
        echo "Variable $var not set"
        exit 1
    fi
done
# Run at launch
check() {
    if [ ! "$(uname -n)" = "archiso" ]; then
        echo "This script is ment to be run from the Archlinux live medium." ; exit
    fi
    if [ "$(id -u)" -ne 0 ]; then
         echo "This script must be run as root." ; exit
    fi
}

# Partitioning
partition_disk() {
    echo "Partitioning disk"
    sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk ${disk} >/dev/null 2>>error.txt || error=true
    g # clear the in memory partition table
    n # new partition
    p # primary partition
    1 # partition number 1
      # default - start at beginning of disk 
    +500M # 100 MB boot parttion
    t # Change type
    uefi # Type
    n # new partition
    p # primary partition
    2 # partion number 2
      # default, start immediately after preceding partition
      # default, extend partition to end of disk
    w # write the partition table
EOF
    showresult
}

# Encryption
encrypt_disk() {
    echo "Encrypting disk"
    echo -n "$cryptpassword" | cryptsetup -q luksFormat --align-payload=8192 -s 256 -c aes-xts-plain64 "$rootdev" -
    echo "Opening encrypted disk"
    echo -n "$cryptpassword" | cryptsetup -q open "$rootdev" cryptroot -
    mapper="/dev/mapper/cryptroot"
    showresult
}

# Formaatting
format_disk() {
    echo "Formatting disk"
    mkfs.fat -F32 $bootdev >/dev/null 2>>error.txt || error=true
    echo "Done"
    mkfs.btrfs "/dev/mapper/cryptroot" >/dev/null 2>>error.txt || error=true
    showresult
}

# Subvolumes
create_subvolumes() {
    echo "Creating subvolumes"
    mount $mapper /mnt
    btrfs subvolume create /mnt/@ >/dev/null 2>>error.txt || error=true
    btrfs subvolume create /mnt/@home >/dev/null 2>>error.txt || error=true
    btrfs subvolume create /mnt/@var_log >/dev/null 2>>error.txt || error=true
    btrfs subvolume create /mnt/@snapshots >/dev/null 2>>error.txt || error=true
    btrfs subvolume create /mnt/@swap >/dev/null 2>>error.txt || error=true

    umount /mnt
    showresult
}

# Mounting
mount_partitions() {
    echo "Mounting partitions"
    mount $mapper -o compress=zstd:3,subvol=@ /mnt >/dev/null 2>>error.txt || error=true
    mkdir -p /mnt/{home,boot,.snapshots,.swap} >/dev/null 2>>error.txt || error=true
    mkdir -p /mnt/var/log >/dev/null 2>>error.txt || error=true
    mount $bootdev /mnt/boot >/dev/null 2>>error.txt || error=true
    mount -o compress=zstd:3,subvol=@home $mapper /mnt/home >/dev/null 2>>error.txt || error=true
    mount -o compress=zstd:3,subvol=@var_log $mapper /mnt/var/log >/dev/null 2>>error.txt || error=true
    mount -o compress=zstd:3,subvol=@snapshots $mapper /mnt/.snapshots >/dev/null 2>>error.txt || error=true
    mount -o compress=zstd:3,subvol=@swap $mapper /mnt/.swap >/dev/null 2>>error.txt || error=true
    showresult
}

# Create swap
create_swap() {
    echo "Creating swapfile"
    truncate -s 0 /mnt/.swap/swapfile
    chattr +C /mnt/.swap/swapfile
    btrfs property set /mnt/.swap/swapfile compression none
    dd if=/dev/zero of=/mnt/.swap/swapfile bs=1M count=$swapfilesize >/dev/null 2>>error.txt || error=true
    chmod 600 /mnt/.swap/swapfile
    mkswap /mnt/.swap/swapfile
    swapon /mnt/.swap/swapfile
    showresult
}

# Run reflector
reflector_run() {
    echo "Run reflector"
    reflector -p http,https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist >/dev/null 2>>error.txt || error=true
    showresult
}

# Run pacstrap
run_pacstrap() {
    echo "Running pacstrap"
    pacstrap /mnt base $kernel linux-firmware btrfs-progs base-devel git dhcpcd iwd zsh >/dev/null 2>>error.txt || error=true
    genfstab -U /mnt >> /mnt/etc/fstab 2>>error.txt || error=true
    showresult
}

# Run chroot
run_chroot() {
    cp config /mnt/root/config
    cp install.sh /mnt/root/install.sh
    chmod +x /mnt/root/install.sh
    arch-chroot /mnt bash -c "cd ~; /root/install.sh --chroot"
    rm -f /mnt/root/install.sh \
        /mnt/root/config \
        /mnt/error.txt
}

# To be run in chroot

# Locales
set_locale() {
    echo 'Setting up locales'
    sed -i '/^#'$locale'/s/^#//g' /etc/locale.gen >/dev/null 2>>error.txt || error=true
    sed -i '/^#'$language'/s/^#//g' /etc/locale.gen >/dev/null 2>>error.txt || error=true
    sed -i '/^#en_US/s/^#//g' /etc/locale.gen >/dev/null 2>>error.txt || error=true
    printf "LANG=%s.UTF-8\n" "$language" > /etc/locale.conf
    showresult
}

# Setting timezones
set_timezone() {
    ln -sf /usr/share/zoneinfo/"$timezone" /etc/localtime >/dev/null 2>>error.txt || error=true
    hwclock --systohc >/dev/null 2>>error.txt || error=true
    showresult
}

# Setting hostname
set_hostname() {
    echo 'Setting hostname'
    printf "%s\n" "$hostname" > /etc/hostname
    printf "127.0.0.1\tlocalhost\n" > /etc/hosts
    printf "::1\t\tlocalhost\tip6-localhost\tip6-loopback\n" >> /etc/hosts
    printf "127.0.1.1\t%s\t%s.home.arpa\n" "$hostname" "$hostname" >> /etc/hosts
    showresult
}

# Creating new initramfs
set_initramfs() {
    echo 'Creating new initramfs'
    sed -i '/^MODULES=/s/=()/=(btrfs)/' /etc/mkinitcpio.conf >/dev/null 2>>error.txt || error=true
    sed -i '/^HOOKS=/s/\(filesystems\)/encrypt \1/' /etc/mkinitcpio.conf >/dev/null 2>>error.txt || error=true
    sed -i '/^HOOKS=/s/\(autodetect\)/keyboard keymap \1/' /etc/mkinitcpio.conf >/dev/null 2>>error.txt || error=true
    sed -i ':s;/^HOOKS=/s/\(\<\S*\>\)\(.*\)\<\1\>/\1\2/g;ts;/^HOOKS=/s/  */ /g' /etc/mkinitcpio.conf >/dev/null 2>>error.txt || error=true
    mkinitcpio -P >/dev/null 2>>error.txt || error=true
    showresult
}

# Changes to pacman.conf and makepkg.conf
set_pacconf() {
    echo 'Changes to pacman.conf and makepkg.conf'
    sed -i "s/^#Color/Color/" /etc/pacman.conf >/dev/null 2>>error.txt || error=true
    echo "ILoveCandy" >> /etc/pacman.conf
    sed -i "s/-j2/-j$(nproc)/;s/^#MAKEFLAGS/MAKEFLAGS/" /etc/makepkg.conf >/dev/null 2>>error.txt || error=true
    if [ "$multilib" = true ] ; then
        sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf >/dev/null 2>>error.txt || error=true
    fi
    showresult
}

# Installing bootloader
set_bootloader() {
    echo 'Installing bootloader'
    pacman --noconfirm --needed -Syu grub efibootmgr >/dev/null 2>>error.txt || error=true
    rootid=$(blkid --output export "$rootdev" | sed --silent 's/^UUID=//p')
    sed -i '/^GRUB_CMDLINE_LINUX=/s/=""/="cryptdevice=UUID='"$rootid:root"':allow-discards"/' /etc/default/grub >/dev/null 2>>error.txt || error=true
    sed -i 's/^#\?\(GRUB_ENABLE_CRYPTODISK=\).\+/\1y/' /etc/default/grub >/dev/null 2>>error.txt || error=true
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB \
        >/dev/null 2>>error.txt || error=true
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>>error.txt || error=true
    showresult
}

# Adding user
add_user() {
    echo "Adding user"
    useradd -m -G wheel -s /bin/bash "$username" >/dev/null 2>>error.txt || error=true
    sed -i '/^# %wheel ALL=(ALL) ALL/s/^#//g' /etc/sudoers >/dev/null 2>>error.txt || error=true
    sed -i '/^# %wheel ALL=(ALL) NOPASSWD: ALL/s/^#//g' /etc/sudoers >/dev/null 2>>error.txt || error=true
    printf "Defaults:%s timestamp_timeout=240" "$username" >> /etc/sudoers
    showresult
    echo "Setting user password"
    echo -n "$username:$userpassword" | chpasswd
    echo "Setting root password"
    echo -n "root:$rootpassword" | chpasswd
}

# Installing aur helper
install_helper() {
    if [[ -n $aurhelper ]]; then
        aurcmd="$(echo "$aurhelper" | sed -r 's/-(bin|git)//g')"
        echo "Installing aur helper, don't forget to enter your sudo password"
        cd /tmp >/dev/null 2>>error.txt || error=true
        sudo -u "$username" git clone "https://aur.archlinux.org/$aurhelper.git" >/dev/null 2>>error.txt || error=true
        cd "$aurhelper" >/dev/null 2>>error.txt || error=true
        sudo -u "$username" makepkg --noconfirm -si 2>>error.txt || error=true
        cd >/dev/null 2>>error.txt || error=true
        if [[ $installdotfiles = true ]]; then
            echo "Installing yadm"
            sudo -u "$username" "$aurcmd" -S --noconfirm yadm 2>>error.txt || error=true
        fi
    fi
    showresult
}

# Installing dotfiles
install_dotfiles() {
    if [[ $installdotfiles = true ]]; then
        echo "Installing dotfiles"
        sudo -u "$username" yadm clone $dotfilesurl
        echo "This is mostly for me but running /home/$username/scripts/install.sh"
        if [[ -f "/home/$username/scripts/install.sh" ]]; then
            sudo -u "$username" zsh "/home/$username/scripts/install.sh"
        fi
    fi

}

# Enabling services
enable_service() {
    echo "Enabling essential networking services. Everything else should be done manually"
    systemctl enable systemd-networkd.service >/dev/null 2>>error.txt || error=true
    systemctl enable systemd-networkd-wait-online.service >/dev/null 2>>error.txt || error=true
    systemctl enable systemd-resolved.service >/dev/null 2>>error.txt || error=true
    systemctl enable iwd >/dev/null 2>>error.txt || error=true
    systemctl enable dhcpcd >/dev/null 2>>error.txt || error=true
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>>error.txt || error=true
}

showresult() {
    if [ "$error" ] ; then
        printf ' \e[1;31m[ERROR]\e[m\n'
        cat error.txt 2>/dev/null
        printf '\e[1mExit installer? [y/N]\e[m\n'
        read -r exit
        [ "$exit" != "${exit#[Yy]}" ] && exit
    else
        printf ' \e[1;32m[OK]\e[m\n'
    fi
    rm -f error.txt
    unset error
}

if [ "$1" != "--chroot" ]; then
    check
    partition_disk
    encrypt_disk
    format_disk
    create_subvolumes
    mount_partitions
    create_swap
    reflector_run
    run_pacstrap
    run_chroot
else
    set_locale
    set_timezone
    set_hostname
    set_initramfs
    set_pacconf
    set_bootloader
    add_user
    install_helper
    install_dotfiles
    enable_service
    sed -i '/%wheel ALL=(ALL) NOPASSWD: ALL/s/^/#/' /etc/sudoers >/dev/null 2>>error.txt || error=true
fi
