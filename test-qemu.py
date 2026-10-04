#!/usr/bin/env python3
"""Unattended QEMU test of waybase.img for one base.

Usage: test-qemu.py IMG WORKDIR BASE "COMPOSITORS" [encrypt|plain]
Stdlib only. Env: QEMU, QEMU_IMG, OVMF (UEFI firmware), MEM (MiB, 2048),
ACCEL (kvm|tcg), CPU (default Nehalem = x86-64-v2, so no binary may need AVX).

1. UEFI boot of the live image as a USB stick; install.sh with an answers file.
2. BIOS boot of the installed disk to the passphrase or login prompt.
3. UEFI boot of the installed disk: unlock, log in as the user, then check
   `nix --version`, the nix daemon, and that each compositor starts headless
   and creates a Wayland socket.
Exit 0 only if every check passes. The serial log goes to WORKDIR/BASE.log.
"""
import os, re, socket, subprocess, sys, time

img, work, base, comps = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
encrypt = (sys.argv[5] if len(sys.argv) > 5 else "encrypt") == "encrypt"
disk = os.path.join(work, f"{base}.qcow2")
QEMU = os.environ.get("QEMU", "qemu-system-x86_64")
OVMF = os.environ.get("OVMF", "/usr/share/ovmf/bios.bin")
ACCEL, CPU = os.environ.get("ACCEL", "kvm"), os.environ.get("CPU", "Nehalem")
LOG = open(os.path.join(work, f"{base}.log"), "a", encoding="utf-8", errors="replace")
PW = {"luks": "test-luks", "user": "test-user", "root": "test-root"}


def note(s):
    LOG.write(f"\n##### {s}\n"); LOG.flush(); print(f"##### {base}: {s}", flush=True)


class VM:
    def __init__(self, uefi, live, port=45560):
        args = [QEMU, "-accel", ACCEL, "-cpu", CPU, "-m", os.environ.get("MEM", "2048"), "-smp", "2",
                "-display", "none", "-monitor", "none",
                "-chardev", f"socket,id=s0,host=127.0.0.1,port={port},server=on,wait=on",
                "-serial", "chardev:s0", "-nic", "user,model=virtio-net-pci",
                "-drive", f"file={disk},if=virtio,format=qcow2,cache=unsafe"]
        if uefi:
            args += ["-bios", OVMF]
        if live:
            args += ["-device", "qemu-xhci", "-drive", f"if=none,id=usb,file={img},format=raw,readonly=on",
                     "-device", "usb-storage,drive=usb,bootindex=0"]
        self.p = subprocess.Popen(args)
        for _ in range(150):
            try:
                self.s = socket.create_connection(("127.0.0.1", port)); break
            except OSError:
                time.sleep(0.2)
        else:
            sys.exit("FAIL: no QEMU serial socket")
        self.buf = ""

    def expect(self, pat, timeout):
        end = time.time() + timeout
        while True:
            m = re.search(pat, self.buf, re.S)
            if m:
                self.buf = self.buf[m.end():]
                return m
            if time.time() > end or self.p.poll() is not None:
                self.kill()
                sys.exit(f"FAIL: {base}: timeout or QEMU exit waiting for {pat!r}")
            self.s.settimeout(5)
            try:
                d = self.s.recv(65536)
            except socket.timeout:
                continue
            if not d:
                sys.exit(f"FAIL: {base}: serial closed waiting for {pat!r}")
            t = d.decode("utf-8", "replace")
            if "\x1b[6n" in t:  # busybox ash asks for the cursor position
                self.s.sendall(b"\x1b[50;200R")
            LOG.write(t); LOG.flush()
            self.buf = (self.buf + t)[-200000:]

    def send(self, line):
        self.s.sendall((line + "\r").encode())

    def run(self, script, timeout=600):
        """Run script with sh and return the output between markers."""
        self.buf = ""
        self.send("sh <<'EOS'\recho @@BEG\"\"@@\r" + script.strip().replace("\n", "\r") + "\recho @@END\"\"@@\rEOS")
        return self.expect(r"@@BEG@@(.*?)@@END@@", timeout).group(1)

    def kill(self):
        self.p.kill(); self.p.wait()


def login(vm, user, pw):
    vm.expect(r"login: ", 1800)
    vm.send(user)
    vm.expect("Password:", 60)
    vm.send(pw)
    time.sleep(10)


fails = []
def check(name, ok, detail=""):
    note(f"CHECK {name}: {'ok' if ok else 'FAIL'} {detail}")
    ok or fails.append(name)


if os.path.exists(disk):
    os.remove(disk)
subprocess.run([os.environ.get("QEMU_IMG", "qemu-img"), "create", "-q", "-f", "qcow2", disk, "32G"], check=True)
note(f"compositors={comps} encrypt={encrypt} accel={ACCEL} cpu={CPU}")

note("1/3 UEFI live boot + unattended install")
t0 = time.time()
vm = VM(uefi=True, live=True)
vm.expect("login:", 900); vm.send("root"); time.sleep(5)
answers = (f"BASE={base}\nCOMPOSITOR='{comps}'\nDISK=/dev/vda\nYES=1\nSERIAL=1\nFIRMWARE=no\n"
           f"ENCRYPT={'yes' if encrypt else 'no'}\nLUKS_PASS={PW['luks']}\nUSERNAME=tester\n"
           f"USER_PASS={PW['user']}\nROOT_PASS={PW['root']}\n")
vm.run(f"cat > /tmp/answers <<'EOA'\n{answers}EOA")
vm.send("sh /media/*/waybase/install.sh /tmp/answers; echo INSTALL_RC=$?; sleep 2; poweroff")
m = vm.expect(r"INSTALL_RC=(\d+)", 4 * 3600)
vm.p.wait(300)
note(f"install took {int(time.time() - t0)} s")
if int(m.group(1)):
    sys.exit(f"FAIL: {base}: install.sh rc={m.group(1)}")

prompt = "Enter passphrase|Passphrase|passphrase for" if encrypt else "login: "
note("2/3 BIOS boot of the installed disk")
vm = VM(uefi=False, live=False); vm.expect(prompt, 900); vm.kill()
check("BIOS boot reaches " + ("passphrase" if encrypt else "login"), True)

note("3/3 UEFI boot of the installed disk + checks")
vm = VM(uefi=True, live=False)
if encrypt:
    vm.expect(prompt, 900); time.sleep(2); vm.send(PW["luks"])
login(vm, "tester", PW["user"])
r = vm.run(r"""
. /etc/profile >/dev/null 2>&1
nix --version 2>&1 | head -1 | sed 's/^/NIXVER /'
nix store info --store daemon >/tmp/ns.log 2>&1 && echo NIXDAEMON_OK || tail -3 /tmp/ns.log
for b in foot fuzzel pipewire wireplumber waybase-session; do command -v $b >/dev/null || echo MISSING:$b; done
echo FROMNIX $(cat /etc/waybase-from-nix)
for c in %s; do
  d=$(mktemp -d); chmod 700 $d
  XDG_RUNTIME_DIR=$d WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 $c >/tmp/$c.log 2>&1 &
  pid=$!; i=0
  while [ $i -lt 30 ] && ! ls $d | grep -q '^wayland-[0-9]*$'; do sleep 1; i=$((i+1)); done
  if ls $d | grep -q '^wayland-[0-9]*$'; then echo UP:$c; else echo DOWN:$c; tail -5 /tmp/$c.log; fi
  kill $pid 2>/dev/null; sleep 1
done
""" % comps, 900)
check("nix --version", "NIXVER nix (Nix)" in r, (re.search(r"NIXVER (.*)", r) or [None, ""])[1].strip())
check("nix daemon reachable", "NIXDAEMON_OK" in r)
check("session programs", "MISSING:" not in r, " ".join(re.findall(r"MISSING:\S+", r)))
note("supplied by Nix: " + (re.search(r"FROMNIX(.*)", r) or [None, ""])[1].strip())
for c in comps.split():
    check(f"{c} starts headless", f"UP:{c}" in r)
vm.send("exit"); time.sleep(3)
vm.kill()
note(f"QEMU TEST {base} " + ("PASSED" if not fails else "FAILED: " + ", ".join(fails)))
sys.exit(1 if fails else 0)
