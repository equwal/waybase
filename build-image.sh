#!/bin/sh
# build-image.sh - build waybase.img: the official Alpine "standard" ISO with
# the installer added under /waybase. The result is a hybrid image (BIOS and
# UEFI, CD or USB/SD). Needs docker, or run it on Alpine as root with DOCKER=0.
#   sh build-image.sh [OUT_DIR]        (default: ./out)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "${1:-$here/out}"; OUT=$(cd "${1:-$here/out}" && pwd)
build() {
    set -eu
    apk add -q xorriso
    V=$(cut -d. -f1,2 /etc/alpine-release) R=$(cat /etc/alpine-release)
    ISO=$OUT/alpine-standard-$R-x86_64.iso
    [ -s "$ISO" ] || wget -q -O "$ISO" "https://dl-cdn.alpinelinux.org/alpine/v$V/releases/x86_64/${ISO##*/}"
    W=$(mktemp -d); mkdir -p "$W/waybase"
    cp -r "$SRC/install.sh" "$SRC/answers.example" "$SRC/backends" "$W/waybase/"
    # serial console as well as the screen, so the installer runs headless too
    xorriso -osirrox on -indev "$ISO" -extract /boot/grub/grub.cfg "$W/grub.cfg" \
        -extract /boot/syslinux/syslinux.cfg "$W/syslinux.cfg" 2>/dev/null
    chmod u+w "$W"/*.cfg
    sed -i '/modules=/s/$/ console=ttyS0,115200 console=tty0/' "$W/grub.cfg" "$W/syslinux.cfg"
    rm -f "$OUT/waybase.img"
    xorriso -indev "$ISO" -outdev "$OUT/waybase.img" -map "$W/waybase" /waybase \
        -map "$W/grub.cfg" /boot/grub/grub.cfg -map "$W/syslinux.cfg" /boot/syslinux/syslinux.cfg \
        -boot_image any replay 2>&1 | grep -E 'Written to|FAILURE' || true
    rm -rf "$W"
    ls -l "$OUT/waybase.img"
}
if [ "${DOCKER:-1}" = 0 ]; then
    SRC=$here; build
else
    docker run --rm -i -v "$here:/src:ro" -v "$OUT:/out" alpine:latest sh -c \
        "$(sed -n '/^build() {/,/^}/p' "$0"); SRC=/src OUT=/out build"
fi
