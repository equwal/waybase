# Gentoo: desktop OpenRC stage3, then binary packages only (getbinpkg,
# usepkgonly), so nothing compiles. A package without a binary comes from Nix.
# OpenRC, elogind, dbus, dhcpcd, gentoo-kernel-bin + dracut.
# shellcheck shell=sh disable=SC2034
GENTOO_MIRROR=${GENTOO_MIRROR:-https://distfiles.gentoo.org}
E="emerge --quiet --getbinpkgonly --usepkgonly --noreplace"
bootstrap() {
    b=$GENTOO_MIRROR/releases/amd64/autobuilds
    f=$(curl -fsSL "$b/latest-stage3-amd64-desktop-openrc.txt" | grep -o '^[^# ]*stage3[^ ]*\.tar\.xz' | head -1)
    f=$(fetch "$b/$f") && tar -xJpf "$f" -C $M --xattrs-include='*.*' --numeric-owner && rm "$f"
    chroot_mounts
    printf 'FEATURES="getbinpkg binpkg-request-signature"\nACCEPT_LICENSE="*"\n' >> $M/etc/portage/make.conf
    mkdir -p $M/etc/portage/package.use $M/etc/dracut.conf.d
    echo 'sys-kernel/installkernel dracut' > $M/etc/portage/package.use/waybase
    printf 'hostonly="no"\nadd_dracutmodules+=" crypt "\n' > $M/etc/dracut.conf.d/waybase.conf
    ch "emerge-webrsync -q" >/dev/null 2>&1
    ch "getuto" >/dev/null 2>&1 || true
    ch "$E sys-fs/cryptsetup net-misc/dhcpcd sys-auth/elogind sys-apps/dbus app-admin/sudo"
    ch "rc-update -q add elogind boot; rc-update -q add dbus default; rc-update -q add dhcpcd default"
}
pkg() {
    case $1 in
    sway | labwc | dwl) echo "gui-wm/$1" ;; # river: 0.4+ is not monolithic; Nix has river-classic
    foot | fuzzel | wmenu) echo "gui-apps/$1" ;;
    pipewire | wireplumber) echo "media-video/$1" ;;
    esac
}
pkg_install() { ch "$E $*"; }
extra_pkgs() { :; }
user_add() { ch "useradd -m -G wheel,video,input,audio,usb -s /bin/bash $1"; }
serial_getty() { echo 's0:12345:respawn:/sbin/agetty -L 115200 ttyS0 vt100' >> $M/etc/inittab; }
nix_native() { return 1; }
nix_service() {
    printf '#!/sbin/openrc-run\ncommand=/nix/var/nix/profiles/default/bin/nix-daemon\ncommand_background=yes\npidfile=/run/nix-daemon.pid\n' \
        > $M/etc/init.d/nix-daemon
    chmod 755 $M/etc/init.d/nix-daemon
    ch "rc-update -q add nix-daemon default"
}
boot_cmd() {
    printf '#!/bin/sh\n%s\n' "$1" >> $M/etc/local.d/waybase.start
    chmod 755 $M/etc/local.d/waybase.start
    ch "rc-update -q add local default"
}
kernel() {
    fw=sys-kernel/linux-firmware; [ "${FIRMWARE:-}" = no ] && fw=""
    ch "$E sys-kernel/installkernel $fw sys-kernel/gentoo-kernel-bin" >/dev/null
    KERNEL=$(cd $M/boot && ls vmlinuz-* | tail -1)
    INITRD=$(cd $M/boot && ls initramfs-* | tail -1)
    KARGS=""
    CRYPTARGS="rd.luks.uuid=$UL rd.luks.name=$UL=root"
}
