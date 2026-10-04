# Arch: the official bootstrap tarball as the new root, then pacman inside it.
# systemd, systemd-logind (no seatd needed), systemd-networkd.
# shellcheck shell=sh disable=SC2034
ARCH_MIRROR=${ARCH_MIRROR:-https://geo.mirror.pkgbuild.com}
bootstrap() {
    curl -fsSL "$ARCH_MIRROR/iso/latest/archlinux-bootstrap-x86_64.tar.zst" |
        zstd -dc | tar -x -C $M --strip-components=1 --numeric-owner
    echo "Server = $ARCH_MIRROR/\$repo/os/\$arch" > $M/etc/pacman.d/mirrorlist
    sed -i 's/^CheckSpace/#CheckSpace/' $M/etc/pacman.conf   # / is not a mount point in the chroot
    chroot_mounts
    ch "pacman-key --init && pacman-key --populate archlinux" >/dev/null 2>&1
    fw=linux-firmware; [ "${FIRMWARE:-}" = no ] && fw=""
    ch "pacman -Syu --noconfirm --needed base linux $fw mkinitcpio cryptsetup e2fsprogs sudo \
        mesa ttf-dejavu" >/dev/null
    echo LANG=C.UTF-8 > $M/etc/locale.conf
    printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n' > $M/etc/systemd/network/20-wired.network
    ch "systemctl enable systemd-networkd systemd-resolved" >/dev/null 2>&1
}
pkg() { case $1 in pipewire) echo "pipewire pipewire-pulse" ;; river) echo river-classic ;; *) echo "$1" ;; esac; }
pkg_install() { ch "pacman -S --noconfirm --needed $*" >/dev/null; }
extra_pkgs() { :; }
user_add() { ch "useradd -m -G wheel,video,input,audio -s /bin/bash $1"; }
serial_getty() { ch "systemctl enable serial-getty@ttyS0" >/dev/null 2>&1; }
nix_native() { return 1; }
nix_service() {
    for u in nix-daemon.socket nix-daemon.service; do
        ln -sf /nix/var/nix/profiles/default/lib/systemd/system/$u $M/etc/systemd/system/$u
    done
    ch "systemctl enable nix-daemon.socket" >/dev/null 2>&1
}
boot_cmd() {
    printf '[Unit]\nDescription=waybase boot command\n[Service]\nType=oneshot\nExecStart=/bin/sh -c "%s"\n[Install]\nWantedBy=multi-user.target\n' \
        "$1" > $M/etc/systemd/system/waybase-boot.service
    ch "systemctl enable waybase-boot" >/dev/null 2>&1
}
kernel() {
    # No autodetect hook: the disk may move to other hardware.
    sed -i 's/^HOOKS=.*/HOOKS=(base udev modconf kms keyboard keymap block encrypt filesystems fsck)/' $M/etc/mkinitcpio.conf
    ch "mkinitcpio -P" >/dev/null 2>&1
    # last step that needs DNS in the chroot is done; hand resolv.conf to resolved
    ln -sf /run/systemd/resolve/stub-resolv.conf $M/etc/resolv.conf
    KERNEL=vmlinuz-linux INITRD=initramfs-linux.img KARGS=""
    CRYPTARGS="cryptdevice=UUID=$UL:root"
}
