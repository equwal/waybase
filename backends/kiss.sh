# KISS: the official chroot tarball plus baseinit (busybox init + runit).
# KISS builds every package from source, so the desktop (compositor, foot,
# PipeWire, seatd, udev) comes from Nix and the kernel is Alpine's linux-lts
# with an Alpine mkinitfs initramfs. Nothing compiles.
# shellcheck shell=sh disable=SC2034
bootstrap() {
    v=$(curl -fsSL https://api.github.com/repos/kisslinux/repo/releases/latest |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
    f=$(fetch "https://github.com/kisslinux/repo/releases/download/$v/kiss-chroot-$v.tar.xz")
    tar -xJf "$f" -C $M --numeric-owner && rm "$f"
    chroot_mounts
    ch "git clone -q https://github.com/kisslinux/repo /var/db/kiss/repo"
    ch "KISS_PATH=/var/db/kiss/repo/core KISS_PROMPT=0 kiss build baseinit" >/dev/null
    mkdir -p $M/etc/sv $M/var/service
    sv() { # sv NAME COMMAND: runit service
        mkdir -p $M/etc/sv/$1
        printf '#!/bin/sh\nexec %s\n' "$2" > $M/etc/sv/$1/run
        chmod 755 $M/etc/sv/$1/run
        ln -sfn /etc/sv/$1 $M/var/service/$1
    }
    p=/nix/var/nix/profiles/waybase/bin
    sv udevd "$p/udevd"
    sv seatd "$p/seatd -g video"
    # udev database for libinput, then DHCP on the first wired interface
    printf '%s\n' "$p/udevadm trigger --action=add 2>/dev/null; $p/udevadm settle 2>/dev/null" \
        'for i in /sys/class/net/e*; do [ -e "$i" ] && udhcpc -b -i "${i##*/}" -s /etc/udhcpc.script >/dev/null 2>&1 && break; done' \
        > $M/etc/rc.d/waybase.boot
    cat > $M/etc/udhcpc.script <<'EOF'
#!/bin/sh
[ "$1" = bound ] || [ "$1" = renew ] || exit 0
ip addr flush dev "$interface"; ip addr add "$ip/${mask:-24}" dev "$interface"
[ -n "$router" ] && ip route add default via "${router%% *}" dev "$interface"
: > /etc/resolv.conf; for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
EOF
    chmod 755 $M/etc/udhcpc.script
}
pkg() { :; }
pkg_install() { return 1; }
extra_pkgs() { echo seatd eudev; }
user_add() {
    ch "adduser -D -s /bin/sh $1"
    for g in wheel video input audio; do ch "addgroup $1 $g" 2>/dev/null || true; done
}
serial_getty() { echo 'ttyS0::respawn:/usr/bin/getty -L 115200 ttyS0 vt100' >> $M/etc/inittab; }
nix_native() { return 1; }
nix_service() {
    mkdir -p $M/etc/sv/nix-daemon
    printf '#!/bin/sh\nexec /nix/var/nix/profiles/default/bin/nix-daemon\n' > $M/etc/sv/nix-daemon/run
    chmod 755 $M/etc/sv/nix-daemon/run
    ln -sfn /etc/sv/nix-daemon $M/var/service/nix-daemon
}
boot_cmd() { echo "$1" >> $M/etc/rc.d/waybase.boot; }
kernel() {
    k=/tmp/waybase-kernel; rm -rf $k; mkdir -p $k
    apk fetch -q -o $k linux-lts
    [ "${FIRMWARE:-}" = no ] || apk fetch -q -R -o $k linux-firmware
    for f in "$k"/*.apk; do tar -xzf "$f" -C $M --keep-directory-symlink --exclude='.[A-Z]*' 2>/dev/null; done
    rm -rf $k
    kv=$(ls $M/lib/modules | head -1)
    # Alpine's mkinitfs (live system) with the target's modules
    mount --bind $M/lib/modules /lib/modules
    mkinitfs -F "ata base cryptsetup ext4 keymap mmc nvme scsi usb virtio" -o $M/boot/initramfs-lts "$kv" >/dev/null
    umount /lib/modules
    KERNEL=vmlinuz-lts INITRD=initramfs-lts
    KARGS="modules=sd-mod,usb-storage,ext4"
    CRYPTARGS="cryptroot=UUID=$UL cryptdm=root"
}
