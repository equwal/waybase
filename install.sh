#!/bin/sh
# waybase installer: install KISS, Gentoo, Arch or Alpine with Nix and a
# Wayland compositor onto a blank disk. Runs as root from the waybase live
# image (Alpine), with network:   sh /media/*/waybase/install.sh [ANSWERS]
#
# ANSWERS is an optional shell file that presets any of the variables below
# (see answers.example). Unset variables are asked for interactively.
#   BASE        kiss | gentoo | arch | alpine
#   COMPOSITOR  sway | river (river-classic 0.3) | labwc | dwl  (a list installs several; the
#               first one starts on tty1 login)
#   DISK        target disk, for example /dev/sda. ALL DATA ON IT IS ERASED.
#   ENCRYPT     yes | no (LUKS2 on the root partition)
#   LUKS_PASS, USERNAME, USER_PASS, ROOT_PASS, HOSTNAME_NEW
#   YES=1       skip the "type the disk name again" check
#   SERIAL=1    login getty on ttyS0 and kernel console there (for tests)
#   NIXPKGS     flake ref for Nix-supplied packages (default: nixpkgs)
#   FIRMWARE=no skip linux-firmware (VMs; real hardware usually needs it)
set -eu
D=$(cd "$(dirname "$0")" && pwd)
M=/mnt/waybase
BASES="kiss gentoo arch alpine"
COMPOSITORS="sway river labwc dwl"
# shellcheck disable=SC1090
[ -n "${1:-}" ] && . "$(cd "$(dirname "$1")" && pwd)/${1##*/}"

log() { printf '\n=== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
ask() { # ask VAR "prompt" [secret]: read VAR unless the answers file set it
    eval "[ -n \"\${$1:-}\" ]" && return 0
    printf '%s: ' "$2"
    [ -n "${3:-}" ] && stty -echo
    read -r v
    [ -n "${3:-}" ] && { stty echo; echo; }
    eval "$1=\$v"
}
menu() { # menu VAR "prompt" choice...: numbered menu unless VAR is set
    eval "[ -n \"\${$1:-}\" ]" && return 0
    var=$1 prompt=$2; shift 2
    i=0; for o; do i=$((i + 1)); echo "  $i) $o"; done
    while :; do
        printf '%s [1-%d]: ' "$prompt" $#; read -r n
        case $n in '' | *[!0-9]*) continue ;; esac
        [ "$n" -ge 1 ] && [ "$n" -le $# ] && break
    done
    eval "$var=\${$n}"
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
ch() { chroot $M /bin/sh -c "$*"; }
fetch() { # fetch URL: download into $M/tmp with retries (resumes), print the path
    mkdir -p $M/tmp; f=$M/tmp/${1##*/}
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -C - -o "$f" "$1" || curl -fsSL --retry 5 -o "$f" "$1"
    echo "$f"
}

# --- questions -----------------------------------------------------------
menu BASE "base system" $BASES
in_list "$BASE" "$BASES" || die "unknown BASE: $BASE"
menu COMPOSITOR "compositor" $COMPOSITORS
for c in $COMPOSITOR; do in_list "$c" "$COMPOSITORS" || die "unknown compositor: $c"; done
lsblk -dno NAME,SIZE,MODEL,TRAN | grep -v '^loop' || true
ask DISK "target disk (for example /dev/sda) - ALL DATA ON IT IS ERASED"
[ -b "$DISK" ] || die "not a block device: $DISK"
grep -q "^$DISK" /proc/mounts && die "$DISK is mounted (is it the boot media?)"
if [ "${YES:-}" != 1 ]; then
    printf 'Type %s again to erase it: ' "$DISK"; read -r again
    [ "$again" = "$DISK" ] || die aborted
fi
menu ENCRYPT "encrypt the root partition with LUKS2" yes no
if [ "$ENCRYPT" = yes ]; then ask LUKS_PASS "LUKS passphrase" s; fi
ask USERNAME "user name"
echo "$USERNAME" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "bad user name: $USERNAME"
ask USER_PASS "password for $USERNAME" s
ask ROOT_PASS "password for root" s
HOSTNAME_NEW=${HOSTNAME_NEW:-waybase}
NIXPKGS=${NIXPKGS:-nixpkgs}
if [ "${SERIAL:-}" = 1 ]; then CONSOLE="console=tty0 console=ttyS0,115200"; else CONSOLE=""; fi

# --- live tools ----------------------------------------------------------
log "live tools"
if ! ip route | grep -q '^default'; then
    for i in /sys/class/net/e*; do
        i=${i##*/}; ip link set "$i" up && timeout 30 udhcpc -q -n -i "$i" >/dev/null 2>&1 && break
    done
fi
ip route | grep -q '^default' || die "no network (plug in Ethernet, or run setup-interfaces)"
V=$(cut -d. -f1,2 /etc/alpine-release)
grep -q '^http' /etc/apk/repositories ||
    printf 'https://dl-cdn.alpinelinux.org/alpine/v%s/%s\n' "$V" main "$V" community >> /etc/apk/repositories
apk update -q
apk add -q sfdisk wipefs e2fsprogs cryptsetup dosfstools lsblk blkid grub grub-efi grub-bios \
    curl tar xz zstd mkinitfs util-linux-misc ca-certificates
modprobe -a ext4 vfat nls_cp437 nls_iso8859-1 dm_crypt 2>/dev/null || true

# --- disk ----------------------------------------------------------------
# GPT: BIOS boot, ESP, /boot (ext4, unencrypted so GRUB needs no LUKS
# support), root (ext4, optionally on LUKS2).
log "partition $DISK"
case $DISK in *[0-9]) P=${DISK}p ;; *) P=$DISK ;; esac
wipefs -aq "$DISK"
sfdisk -q "$DISK" <<EOF
label: gpt
size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name=bios
size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=esp
size=1GiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=boot
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=root
EOF
mdev -s 2>/dev/null || true; sleep 1
mkfs.vfat -F32 -n ESP "${P}2" >/dev/null
mkfs.ext4 -qF -L boot "${P}3"
ROOTDEV=${P}4
if [ "$ENCRYPT" = yes ]; then
    printf %s "$LUKS_PASS" | cryptsetup -q luksFormat --type luks2 "${P}4" -
    printf %s "$LUKS_PASS" | cryptsetup open "${P}4" root -
    ROOTDEV=/dev/mapper/root
fi
mkfs.ext4 -qF -L root "$ROOTDEV"
mkdir -p $M && mount "$ROOTDEV" $M
mkdir -p $M/boot && mount "${P}3" $M/boot
mkdir -p $M/boot/efi && mount "${P}2" $M/boot/efi
UB=$(blkid -s UUID -o value "${P}3") UE=$(blkid -s UUID -o value "${P}2")
UL=$(blkid -s UUID -o value "${P}4") UR=$(blkid -s UUID -o value "$ROOTDEV")

chroot_mounts() {
    mkdir -p $M/proc $M/sys $M/dev $M/run $M/tmp
    for f in proc sys dev; do mount --rbind /$f $M/$f; done
    mount -t tmpfs tmpfs $M/run
    rm -f $M/etc/resolv.conf; cp /etc/resolv.conf $M/etc/resolv.conf
}

# --- base system ---------------------------------------------------------
# Each backend defines:
#   bootstrap       base system in $M (calls chroot_mounts), init, seat, network
#   pkg NAME        native package(s) for a logical name; empty = take it from Nix
#   pkg_install P.. install native packages; nonzero = fall back to Nix
#   extra_pkgs      logical names this base also needs (from Nix when not native)
#   user_add USER, serial_getty, nix_service, boot_cmd CMD (run CMD at boot)
#   nix_native      install Nix from the base's own packages; nonzero = use the
#                   release tarball
#   kernel          kernel + initramfs; sets KERNEL, INITRD (relative to /boot),
#                   KARGS, CRYPTARGS
# shellcheck disable=SC1090
. "$D/backends/$BASE.sh"
log "bootstrap $BASE"
bootstrap
echo "$HOSTNAME_NEW" > $M/etc/hostname
cat > $M/etc/fstab <<EOF
UUID=$UR / ext4 defaults,noatime 0 1
UUID=$UB /boot ext4 defaults,noatime 0 2
UUID=$UE /boot/efi vfat defaults 0 2
EOF

log "user $USERNAME"
user_add "$USERNAME"
printf 'root:%s\n%s:%s\n' "$ROOT_PASS" "$USERNAME" "$USER_PASS" | ch chpasswd
[ "${SERIAL:-}" = 1 ] && serial_getty

# --- Nix -----------------------------------------------------------------
log "Nix (multi-user daemon)"
mkdir -p $M/etc/nix
printf 'experimental-features = nix-command flakes\nbuild-users-group = nixbld\n' > $M/etc/nix/nix.conf
if ! nix_native; then
    # Official release tarball, registered by hand (what its installer does,
    # without needing bash or useradd, which KISS lacks).
    NV=$(curl -fsSL https://nixos.org/nix/install | grep -o 'releases.nixos.org/nix/nix-[0-9.]*[0-9]' | head -1)
    NV=${NV##*/nix-}
    T=/tmp/nix-$NV-x86_64-linux
    f=$(fetch "https://releases.nixos.org/nix/nix-$NV/nix-$NV-x86_64-linux.tar.xz") && tar -xJf "$f" -C $M/tmp && rm "$f"
    mkdir -p $M/nix/store $M/nix/var/nix/profiles/per-user $M/nix/var/nix/gcroots
    mv $M$T/store/* $M/nix/store/
    NIX=$(cd $M/nix/store && ls -d ./*-nix-"$NV" | head -1); NIX=/nix/store/${NIX#./}
    CA=$(cd $M/nix/store && ls -d ./*-nss-cacert-* | head -1); CA=/nix/store/${CA#./}
    if ! grep -q '^nixbld:' $M/etc/group; then
        members=""
        i=1; while [ $i -le 32 ]; do
            members="$members${members:+,}nixbld$i"
            echo "nixbld$i:x:$((30000 + i)):30000:Nix build user $i:/var/empty:/sbin/nologin" >> $M/etc/passwd
            echo "nixbld$i:!:19000:0:99999:7:::" >> $M/etc/shadow
            i=$((i + 1))
        done
        echo "nixbld:x:30000:$members" >> $M/etc/group
    fi
    ch "$NIX/bin/nix-store --load-db < $T/.reginfo && $NIX/bin/nix-env -p /nix/var/nix/profiles/default -i $NIX $CA" >/dev/null
    rm -rf "$M$T"
    ch "chgrp nixbld /nix/store && chmod 1775 /nix/store"
fi
nix_service
NIXP=/nix/var/nix/profiles/waybase
cat > $M/etc/profile.d/waybase.sh <<EOF
# waybase: Nix in PATH, Nix-supplied programs, compositor on tty1 login.
for f in /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh /etc/profile.d/nix-daemon.sh.nix; do
    [ -r "\$f" ] && . "\$f" && break
done
export PATH="\$HOME/.nix-profile/bin:$NIXP/bin:\$PATH"
export XDG_DATA_DIRS="$NIXP/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
if [ "\$(id -u)" -ne 0 ] && [ -z "\${WAYLAND_DISPLAY:-}" ] && [ "\$(tty)" = /dev/tty1 ]; then
    exec waybase-session
fi
EOF

# --- compositor, terminal, launcher, audio ------------------------------
log "Wayland session: $COMPOSITOR"
want="$COMPOSITOR foot fuzzel pipewire wireplumber"
in_list dwl "$COMPOSITOR" && want="$want wmenu"
fromnix=""
for p in $want $(extra_pkgs); do
    n=$(pkg "$p")
    if [ -n "$n" ] && pkg_install "$n"; then echo "native: $p ($n)"; else fromnix="$fromnix $p"; fi
done
[ -e $M/etc/fonts/fonts.conf ] || fromnix="$fromnix dejavu_fonts fontconfig"
if [ -n "$fromnix" ]; then
    # Nix GL apps on a foreign distro find Mesa through /run/opengl-driver.
    fromnix="$fromnix mesa"
    echo "from Nix:$fromnix"
    refs=""
    for p in $fromnix; do
        case $p in river) p=river-classic ;; esac  # river 0.4+ needs a separate WM
        refs="$refs $NIXPKGS#$p"
    done
    ch "f=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; [ -r \$f ] && . \$f; nix profile install --profile $NIXP $refs"
    [ -e $M/etc/fonts/fonts.conf ] || { mkdir -p $M/etc/fonts && cat > $M/etc/fonts/fonts.conf <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig><dir>$NIXP/share/fonts</dir><cachedir>/var/cache/fontconfig</cachedir></fontconfig>
EOF
    }
    boot_cmd "ln -sfn $NIXP /run/opengl-driver"
fi
echo "$fromnix" > $M/etc/waybase-from-nix
set -- $COMPOSITOR
mkdir -p $M/usr/local/bin
cat > $M/usr/local/bin/waybase-session <<EOF
#!/bin/sh
# Start the default compositor ($1) with PipeWire.
: "\${XDG_RUNTIME_DIR:=/tmp/runtime-\$(id -u)}"; export XDG_RUNTIME_DIR
mkdir -p -m 700 "\$XDG_RUNTIME_DIR"
if [ ! -d /run/systemd/system ]; then  # systemd user units start PipeWire on Arch
    pipewire & sleep 1; wireplumber & pipewire-pulse &
fi
command -v dbus-run-session >/dev/null && exec dbus-run-session -- "\${1:-$1}"
exec "\${1:-$1}"
EOF
chmod 755 $M/usr/local/bin/waybase-session

# Small per-compositor configs: Super+Return = foot, Super+d = fuzzel.
H=$M/home/$USERNAME/.config
for c in $COMPOSITOR; do case $c in
sway) mkdir -p $H/sway && cat > $H/sway/config <<'EOF'
set $mod Mod4
bindsym $mod+Return exec foot
bindsym $mod+d exec fuzzel
bindsym $mod+Shift+q kill
bindsym $mod+Shift+e exit
bindsym $mod+h focus left
bindsym $mod+l focus right
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
EOF
;;
river) mkdir -p $H/river && cat > $H/river/init <<'EOF'
#!/bin/sh
riverctl map normal Super Return spawn foot
riverctl map normal Super D spawn fuzzel
riverctl map normal Super+Shift Q close
riverctl map normal Super+Shift E exit
riverctl map normal Super J focus-view next
riverctl map normal Super K focus-view previous
riverctl default-layout rivertile
rivertile -view-padding 4 -outer-padding 4 &
EOF
chmod 755 $H/river/init ;;
labwc) mkdir -p $H/labwc && cat > $H/labwc/rc.xml <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <keyboard>
    <default />
    <keybind key="W-Return"><action name="Execute" command="foot" /></keybind>
    <keybind key="W-d"><action name="Execute" command="fuzzel" /></keybind>
  </keyboard>
</labwc_config>
EOF
;;
dwl) ;; # dwl is configured at build time: Alt+Shift+Return = foot, Alt+p = wmenu
esac; done
ch "chown -R $USERNAME:\$(id -g $USERNAME) /home/$USERNAME"

# --- kernel, initramfs, bootloader --------------------------------------
log "kernel + initramfs"
kernel
if [ "$ENCRYPT" = yes ]; then ROOTARG="root=/dev/mapper/root $CRYPTARGS"; else ROOTARG="root=UUID=$UR"; fi
log "GRUB (UEFI removable path + BIOS)"
grub-install --target=x86_64-efi --efi-directory=$M/boot/efi --boot-directory=$M/boot --removable --no-nvram >/dev/null
grub-install --target=i386-pc --boot-directory=$M/boot "$DISK" >/dev/null
cat > $M/boot/grub/grub.cfg <<EOF
set timeout=3
menuentry "waybase: $BASE" {
    search --no-floppy --fs-uuid --set=root $UB
    linux /$KERNEL $ROOTARG rootfstype=ext4 rw $KARGS $CONSOLE
    initrd /$INITRD
}
EOF

log "unmount"
sync
for p in /proc/[0-9]*; do  # daemons left by package scripts (gpg-agent, ...)
    [ "$(readlink "$p/root" 2>/dev/null)" = $M ] && kill "${p#/proc/}" 2>/dev/null || true
done
sleep 2
umount -l $M/proc $M/sys $M/dev $M/run 2>/dev/null || true
umount $M/boot/efi $M/boot $M
[ "$ENCRYPT" = yes ] && cryptsetup close root
log "DONE: $BASE with $COMPOSITOR on $DISK. Remove the install media and reboot."
