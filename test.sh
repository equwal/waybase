#!/bin/sh
# test.sh WORKDIR BASE "COMPOSITORS" [encrypt|plain]
# Runs test-qemu.py on WORKDIR/waybase.img inside an Alpine container with KVM.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$1" && pwd); shift
docker run --rm -i --device /dev/kvm -v "$here:/src:ro" -v "$W:/work" alpine:latest sh -c \
    'apk add -q qemu-system-x86_64 qemu-img ovmf python3 >/dev/null 2>&1 || command -v qemu-img >/dev/null
     exec python3 -u /src/test-qemu.py /work/waybase.img /work "$@"' sh "$@"
