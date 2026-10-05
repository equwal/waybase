#!/bin/sh
# firmware.sh - install pinned linux-firmware files into /lib/firmware.
#   sh firmware.sh [-r ROOT] TAG LIST   for each "SHA256 PATH" line of LIST: fetch PATH from
#                                       linux-firmware tag TAG, check the hash, install ROOT/lib/firmware/PATH
#   sh firmware.sh -s TAG               print LIST lines for files the kernel failed to load (dmesg);
#                                       the hashes come from the download: review them before you pin
set -eu
URL=https://gitlab.com/kernel-firmware/linux-firmware/-/raw
die() { echo "firmware.sh: $*" >&2; exit 1; }
ROOT=; SCAN=
[ "${1:-}" = -r ] && { ROOT=$2; shift 2; }
[ "${1:-}" = -s ] && { SCAN=1; shift; }
[ $# -ge 1 ] || die "usage: firmware.sh [-r ROOT] TAG LIST | -s TAG"
TAG=$1
T=$(mktemp); trap 'rm -f "$T"' EXIT
fetch() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o "$T" "$URL/$TAG/$1"; }
safe() { case $1 in /* | *..*) die "bad path: $1" ;; esac; }

if [ -n "$SCAN" ]; then
    dmesg | sed -n 's/.*Direct firmware load for \(.*\) failed with error.*/\1/p' | sort -u |
    while read -r p; do
        safe "$p"
        [ -e "/lib/firmware/$p" ] && continue
        if fetch "$p" 2>/dev/null; then echo "$(sha256sum "$T" | cut -d' ' -f1) $p"; else echo "# not in $TAG: $p"; fi
    done
    exit 0
fi

[ -r "${2:-}" ] || die "list not readable: ${2:-}"
while read -r sum p; do
    case $sum in '' | '#'*) continue ;; esac
    safe "$p"
    fetch "$p" || die "download failed: $p"
    echo "$sum  $T" | sha256sum -c -s - || die "hash mismatch: $p"
    install -D -m 644 "$T" "$ROOT/lib/firmware/$p"
    echo "firmware: $p"
done < "$2"
