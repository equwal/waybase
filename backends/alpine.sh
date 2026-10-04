# Alpine: apk --root from the live system. OpenRC, eudev, seatd, dbus.
# shellcheck shell=sh disable=SC2034
bootstrap() {
    mkdir -p $M/etc/apk/keys $M/etc/mkinitfs
    cp /etc/apk/keys/* $M/etc/apk/keys/
    grep '^http' /etc/apk/repositories > $M/etc/apk/repositories
    apk add -q --root $M --initdb alpine-base
    chroot_mounts
    echo 'features="ata base cryptsetup ext4 keymap mmc nvme scsi usb virtio"' > $M/etc/mkinitfs/mkinitfs.conf
    fw=linux-firmware; [ "${FIRMWARE:-}" = no ] && fw=linux-firmware-none
    ch "apk add -q linux-lts $fw mkinitfs cryptsetup e2fsprogs eudev seatd dbus shadow \
        mesa-dri-gallium font-dejavu fontconfig"
    for s in devfs dmesg udev udev-trigger udev-settle; do ch "rc-update -q add $s sysinit"; done
    for s in modules sysctl hostname bootmisc syslog hwclock; do ch "rc-update -q add $s boot"; done
    for s in networking seatd dbus; do ch "rc-update -q add $s default"; done
    for s in killprocs savecache mount-ro; do ch "rc-update -q add $s shutdown"; done
    printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' > $M/etc/network/interfaces
}
pkg() { case $1 in pipewire) echo "pipewire pipewire-pulse" ;; river) echo river-classic ;; *) echo "$1" ;; esac; }
pkg_install() { ch "apk add -q $*"; }
extra_pkgs() { :; }
user_add() {
    ch "adduser -D -s /bin/sh $1"
    for g in wheel video input audio seat; do ch "addgroup $1 $g" 2>/dev/null || true; done
}
serial_getty() { echo 'ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100' >> $M/etc/inittab; }
nix_native() { ch "apk add -q nix"; }
nix_service() { ch "rc-update -q add nix-daemon default"; }
boot_cmd() {
    printf '#!/bin/sh\n%s\n' "$1" >> $M/etc/local.d/waybase.start
    chmod 755 $M/etc/local.d/waybase.start
    ch "rc-update -q add local default"
}
kernel() {
    ch "mkinitfs \$(ls /lib/modules | head -1)" >/dev/null
    KERNEL=vmlinuz-lts INITRD=initramfs-lts
    KARGS="modules=sd-mod,usb-storage,ext4"
    CRYPTARGS="cryptroot=UUID=$UL cryptdm=root"
}
