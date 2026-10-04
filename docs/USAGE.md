# waybase

A bootable USB/SD installer that puts a fresh Linux on a blank disk: your pick
of **KISS, Gentoo, Arch or Alpine**, plus the **Nix** package manager and a
**Wayland-only** desktop (no X11) with the compositor you choose.

One POSIX `sh` installer core (`install.sh`, about 300 lines) and one short
backend per base (`backends/*.sh`). It asks a few questions from plain text
menus, or reads an answers file for unattended installs.

## Quickstart

```sh
git clone https://github.com/equwal/waybase && cd waybase
sh build-image.sh out             # needs docker; writes out/waybase.img
dd if=out/waybase.img of=/dev/sdX bs=4M conv=fsync   # sdX = your USB stick or SD card
```

Boot the stick (UEFI or BIOS), log in as `root` (no password), connect
Ethernet, and run:

```sh
sh /media/*/waybase/install.sh                 # interactive
sh /media/*/waybase/install.sh answers.txt     # unattended, see answers.example
```

Reboot, log in on tty1, and the compositor starts. Super+Return opens foot,
Super+d opens fuzzel (dwl: Alt+Shift+Return and Alt+p, its built-in keys).

## What you get

| | KISS | Gentoo | Arch | Alpine |
|---|---|---|---|---|
| Bootstrap | official chroot tarball + `baseinit` | desktop-openrc stage3 + binary packages only (`getbinpkg`, `usepkgonly`) | official bootstrap tarball + pacman | `apk --root` |
| Init | busybox init + runit | OpenRC | systemd | OpenRC |
| Seat | seatd (Nix) | elogind | systemd-logind | seatd |
| Kernel | Alpine linux-lts + mkinitfs | gentoo-kernel-bin + dracut | linux + mkinitcpio | linux-lts + mkinitfs |
| Nix | release tarball, multi-user daemon (runit) | release tarball, multi-user daemon (OpenRC) | release tarball, multi-user daemon (systemd socket) | Alpine `nix` package, daemon (OpenRC) |
| Desktop packages | all from Nix | binpkg when one exists, else Nix | native | native (dwl from Nix) |

Every install also gets PipeWire + WirePlumber, the foot terminal, the fuzzel
launcher, optional LUKS2 encryption of the root partition, GRUB for both UEFI
(removable path, no NVRAM writes) and BIOS, and one user account in the
`wheel`, `video`, `input` and `audio` groups.

Disk layout (GPT): 1 MiB BIOS boot, 512 MiB ESP, 1 GiB `/boot` (ext4,
unencrypted), the rest is `/` (ext4, on LUKS2 if you choose encryption).

Compositors: **sway, river (river-classic 0.3; river 0.4+ needs a separate
window manager), labwc, dwl**. Hyprland is left out: it has no headless
software-rendering mode to test and needs a GPU. When a base has no native
package, the installer takes it from Nix into the system profile
`/nix/var/nix/profiles/waybase` and links Mesa to `/run/opengl-driver`, so Nix
GL programs find drivers. `/etc/waybase-from-nix` lists what came from Nix.

## Tested matrix

`test.sh` boots the image in QEMU (KVM, `-cpu Nehalem` so nothing may need
AVX), installs unattended, boots the result by BIOS and by UEFI, unlocks LUKS,
logs in as the new user, and checks `nix --version`, the Nix daemon, and that
each compositor starts headless (`WLR_BACKENDS=headless`) and opens a Wayland
socket.

MATRIX

Run one yourself: `sh build-image.sh out && sh test.sh out arch sway encrypt`.

## Security notes

- The installer erases the whole target disk. Interactive mode makes you type
  the disk name twice; `YES=1` in an answers file skips that.
- An answers file is shell code, sourced as root, and holds passwords in plain
  text. Keep it off shared media and delete it after the install.
- `/boot` is not encrypted (kernel and initramfs are readable and could be
  replaced by someone with physical access). Only `/` is on LUKS2.
- Live image: `root` has no password, as on the stock Alpine ISO. Do not boot
  it on an untrusted network longer than the install takes.
- Downloads come over HTTPS from the official mirrors (Alpine, Arch, Gentoo,
  GitHub for KISS, releases.nixos.org). Arch and Gentoo verify package
  signatures with their own keyrings; the KISS tarball and the Nix tarball are
  trusted on HTTPS alone.
- On KISS, the root-run `seatd` and `udevd` come from the root-owned Nix
  profile, which users cannot modify.

## Licences and why no image is released

waybase itself is MIT. The image is the official Alpine ISO with these
scripts added; it contains GPL software, so redistributing it would oblige us
to also ship the matching sources. The bases (KISS, Gentoo, Arch), Nix (LGPL
2.1) and linux-firmware (mixed, redistributable) are downloaded from their
official mirrors at install time and never redistributed by this project. So
this repo ships the build script, not a built image: `build-image.sh` takes
about a minute.

## Prior art

archinstall (Arch only), setup-alpine (Alpine only), Gentoo has no official
installer, nixos-anywhere (NixOS only), KISS has a manual install guide. None
of them offers a choice of base, Nix on that base, and a ready Wayland
session from one image. waybase does, with an unattended mode tested in CI.

## Known gaps

- GPU, audio and input on real hardware are not covered by the QEMU tests.
- Nix-supplied compositors on KISS and Gentoo use Nix's Mesa; NVIDIA needs
  extra work.
- Kernel updates on Gentoo produce new file names; `/boot/grub/grub.cfg` then
  needs the new names by hand.
- No Wi-Fi setup: install over Ethernet.
