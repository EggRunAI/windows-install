#!/bin/bash
# x86/install.sh — Windows 11 x64 into a fresh egg, unattended, on a Linux x86_64 host (KVM).
#
#   x86/install.sh [name] [--iso <Win11 x64 iso>] [--virtio-win <virtio-win.iso>] [--ram 8G] [--cpus 4]
#                  [--disk 64G] [--gpu virtio-gpu|nvidia] [--gpu-address 0000:c1:00.0] [--stream ws|webrtc]
#                  [--keep] [--logo <512x512.png>] [--title "Windows 11"] [--media-only]
#
# Steps, each a hard failure:
#   1. media: the ISO tree + autounattend.xml + egg\ (SetupComplete.cmd, firstlogon.cmd, your
#      provision.cmd) → one ISO (xorriso, efisys_noprompt.bin so no key press is needed);
#      the VirtIO storage/network/input/display drivers from virtio-win go into boot.wim
#      (wimlib) and onto the installed disk, because Windows Setup cannot see a virtio disk
#      or its own virtio CD without them. winpeshl.ini runs Setup with the answer file.
#   2. the egg: a bundle under $EGG_HOME/eggs/<name>.egg (UEFI, NVMe target disk, the media
#      as a read-only virtio disk, virtio-gpu + ramfb); `egg run <name>` boots it
#   3. Setup + OOBE from the answer file; SetupComplete.cmd installs the virtio-win guest
#      tools; first logon persists autologon, runs provision.cmd if present, uploads proof1
#      to the drop box, and shuts down → `egg run` exits
#   4. the media is detached from the egg; a headless cold boot must reach the desktop
#      (proof2 uploaded by the autologon user), and the guest shuts ITSELF down: a Windows
#      egg is never cut from outside (a hard stop leaves NTFS dirty → Automatic Repair)
#   5. with --keep: the golden is made a hub bundle — a cold (disk-only) snapshot named
#      <name>-build.egg, metadata.toml, and `egg card` (logo + the cold-boot screenshot),
#      which signs it; the import / push commands are printed
#
# Default ISO: iso/windows.iso (Windows 11 x64). virtio-win.iso is fetched from fedorapeople
# into out/ when not given. Default name w11. --keep leaves the installed egg (your golden).
# GPU: --gpu virtio-gpu (default, the 2D device every host has) or --gpu nvidia with the
# card's PCI address (whole-card passthrough; the card must be bound to vfio-pci; the NVIDIA
# driver goes in through provision.cmd). The egg streams its display (--stream ws default;
# webrtc = H.264, needs an encoder on the host), so the Carton console can open it.
# Needs: egg (the EggRun runner for Linux x86_64) on PATH or EGG=, xorriso, wimlib-imagex,
# bsdtar, python3, curl, ~20 GB in out/, KVM. ~25-40 min. Exit 0 pass, 1 fail, 2 refused.
# The egg is a SIGNED bundle only after step 5 in the README ("From golden to the hub").
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/.." && pwd)
EGG=${EGG:-$(command -v egg || true)}
D=$TOP/tools/drive.sh
EH=${EGG_HOME:-/root/.egg}
PORT=${EGG_DROPBOX_PORT:-8766}
ISO=$TOP/iso/windows.iso
VWISO=${VIRTIO_WIN_ISO:-$TOP/out/virtio-win.iso}
VWURL=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
# Defaults: 8 vCPUs when the host has 16 or more, else 4; 8 GB; a 64 GB disk (the floor: Windows 11
# plus one real application does not fit in less, and Setup itself wants 52 GB free).
hostcpus=$(nproc 2>/dev/null || echo 4)
name=w11; keep=0; media_only=0; ram=8G; cpus=$([ "$hostcpus" -ge 16 ] && echo 8 || echo 4); disk=64G; gpu=virtio-gpu; gpu_address=; stream=ws; logo=; title="Windows 11"
while [ $# -gt 0 ]; do case "$1" in
  --iso) ISO=$2; shift 2;; --virtio-win) VWISO=$2; shift 2;; --ram) ram=$2; shift 2;; --cpus) cpus=$2; shift 2;;
  --disk) disk=$2; shift 2;; --gpu) gpu=$2; shift 2;; --gpu-address) gpu_address=$2; shift 2;; --stream) stream=$2; shift 2;;
  --keep) keep=1; shift;; --media-only) media_only=1; shift;; --logo) logo=$2; shift 2;; --title) title=$2; shift 2;;
  -h|--help) sed -n 2,26p "$0"; exit 2;; -*) echo "install.sh: unknown option $1" >&2; exit 2;; *) name=$1; shift;; esac; done
say() { printf '[w11-x86 %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { say "REFUSED: $*"; exit 2; }
T0=$(date +%s); el() { echo "$(( $(date +%s) - T0 ))s"; }
R=$TOP/results; OUT=$TOP/out; mkdir -p "$R" "$OUT" "$TOP/guest/in"
BUNDLE=$EH/eggs/$name.egg; S=$BUNDLE/run/egg.sock
fail() { say "FAILED after $(el): $*"; [ -S "$S" ] && "$D" "$name" shot "$R/$name-fail.png" >/dev/null 2>&1; say "egg $name kept for a look (egg rm $name to recycle)"; exit 1; }

# ── preconditions ─────────────────────────────────────────────────────────────
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die "this is the Linux x86_64 lane; on a Mac run ./install.sh"
[ "$(id -u)" = 0 ] || die "run as root (the runner needs /dev/kvm and \$EGG_HOME=$EH)"
[ -n "$EGG" ] && [ -x "$EGG" ] || die "no egg binary (install the EggRun host package, or EGG=/path/to/egg)"
for t in xorriso wimlib-imagex python3 curl; do command -v $t >/dev/null || die "$t missing (apt install xorriso wimtools python3 curl)"; done
[ -c /dev/kvm ] || die "/dev/kvm missing: this host has no KVM (a .metal instance on AWS)"
[ -f "$ISO" ] || die "install media not found: $ISO (copy your Windows 11 x64 ISO to iso/windows.iso, or --iso <path>)"
case "$gpu" in virtio-gpu) ;; nvidia) [ -n "$gpu_address" ] || die "--gpu nvidia needs --gpu-address <pci address> (lspci -D | grep -i nvidia; egg gpu ls)";;
  *) die "--gpu must be virtio-gpu or nvidia (x86 hosts attach nothing else)";; esac
case "$stream" in ws|webrtc) ;; *) die "--stream must be ws or webrtc";; esac
disk_gb=$(echo "$disk" | sed -E 's/[Gg][Bb]?$//'); echo "$disk_gb" | grep -Eq '^[0-9]+$' || die "--disk takes gigabytes, e.g. 64G"
[ "$disk_gb" -ge 64 ] || die "--disk $disk is below the 64G floor for a Windows 11 egg"
echo "$cpus" | grep -Eq '^[0-9]+$' && [ "$cpus" -ge 2 ] || die "--cpus must be a number, 2 or more (Windows Setup on one vCPU takes hours)"
HOSTIP=$(hostname -I 2>/dev/null | awk '{print $1}'); [ -n "$HOSTIP" ] || die "no host address (the guest uploads its proofs here)"
if [ $media_only = 0 ]; then
  ss -ltn 2>/dev/null | grep -q ":$PORT " && die "port $PORT is taken; stop it or set EGG_DROPBOX_PORT"
  [ -e "$BUNDLE" ] && die "$name already exists (egg rm $name first, or pick a name)"
fi

# ── 1. media ──────────────────────────────────────────────────────────────────
if [ ! -f "$VWISO" ]; then
  say "fetching virtio-win.iso → $VWISO"
  curl -fL -o "$VWISO.part" "$VWURL" || die "virtio-win download failed (or pass --virtio-win <iso>)"
  mv "$VWISO.part" "$VWISO"
fi
STAGE=$OUT/stage; DRV=$OUT/drv; VW=$OUT/vw; M1=$OUT/mnt-win; M2=$OUT/mnt-vw
umount_all() { umount "$M1" 2>/dev/null; umount "$M2" 2>/dev/null; }
rm -rf "$STAGE" "$DRV" "$VW"; mkdir -p "$STAGE" "$DRV" "$VW" "$M1" "$M2"
trap 'umount_all; rm -rf "$STAGE" "$DRV" "$VW" "$M1" "$M2"' EXIT
# The Windows ISO is UDF (its install.wim is bigger than ISO9660 allows); the kernel reads it,
# user-space extractors do not. Mount, copy, unmount.
say "media: copying $(basename "$ISO") and the virtio-win drivers"
mount -o loop,ro "$ISO" "$M1" || die "could not mount $ISO"
mount -o loop,ro "$VWISO" "$M2" || die "could not mount $VWISO"
cp -a "$M1"/. "$STAGE"/ || die "copying the media tree failed (disk full in $OUT?)"
cp -a "$M2"/. "$VW"/ || die "copying virtio-win failed"
umount_all
chmod -R u+w "$STAGE" "$VW"
[ -f "$STAGE/sources/boot.wim" ] || die "no sources/boot.wim in the media (not a Windows install ISO?)"
# xorriso writes ISO9660, which caps a file at 4 GB; Setup reads a split image (install.swm,
# install2.swm, …) exactly like install.wim.
if [ -f "$STAGE/sources/install.wim" ] && [ "$(stat -c %s "$STAGE/sources/install.wim")" -gt 4000000000 ]; then
  say "media: splitting install.wim ($(du -h "$STAGE/sources/install.wim" | cut -f1)) into .swm parts"
  wimlib-imagex split "$STAGE/sources/install.wim" "$STAGE/sources/install.swm" 3800 >/dev/null || die "wimlib split failed"
  rm -f "$STAGE/sources/install.wim"
fi
for d in viostor NetKVM vioinput viogpudo; do
  l=$(echo $d | tr A-Z a-z); src=$(find "$VW" -maxdepth 1 -iname "$d" | head -1)
  [ -d "$src/w11/amd64" ] || die "virtio-win has no $d/w11/amd64 (layout changed?)"
  mkdir -p "$DRV/$l" && cp "$src"/w11/amd64/* "$DRV/$l/"
done
tools=$(find "$VW" -maxdepth 1 -iname 'virtio-win-guest-tools.exe' | head -1); [ -f "$tools" ] || die "virtio-win-guest-tools.exe not in $VWISO"
mkdir -p "$STAGE/egg"
cp "$tools" "$STAGE/egg/virtio-win-guest-tools.exe"
cp "$HERE/autounattend.xml" "$STAGE/autounattend.xml"
for f in SetupComplete.cmd firstlogon.cmd; do sed "s#@DROPBOX@#http://$HOSTIP:$PORT#g" "$HERE/guest/$f" | sed 's/\r$//; s/$/\r/' > "$STAGE/egg/$f"; done
[ -f "$HERE/guest/provision.cmd" ] && sed "s#@DROPBOX@#http://$HOSTIP:$PORT#g" "$HERE/guest/provision.cmd" | sed 's/\r$//; s/$/\r/' > "$STAGE/egg/provision.cmd"
say "media: drivers into boot.wim (Setup image, index 2) and the answer file"
wimlib-imagex update "$STAGE/sources/boot.wim" 2 >/dev/null <<CMDS || die "wimlib update of boot.wim failed"
add '$HERE/winpeshl.ini' /Windows/System32/winpeshl.ini
add '$HERE/autounattend.xml' /autounattend.xml
add '$DRV' /drivers
CMDS
wimlib-imagex dir "$STAGE/sources/boot.wim" 2 | grep -qi '^/drivers/viostor/viostor.sys' || die "viostor did not land in boot.wim"
MEDIA=$OUT/windows-x64-egg.iso; rm -f "$MEDIA"
xorriso -as mkisofs -iso-level 4 -R -J -joliet-long -D -V WIN11EGG \
  -eltorito-alt-boot -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
  -o "$MEDIA" "$STAGE" >/dev/null 2>&1 || die "xorriso failed"
rm -rf "$STAGE" "$DRV" "$VW" "$M1" "$M2"
say "media ready ($(du -h "$MEDIA" | cut -f1), $(el))"
[ $media_only = 1 ] && exit 0

# ── 2. the egg bundle, booted with the media ──────────────────────────────────
mkdir -p "$BUNDLE/disks" "$BUNDLE/screenshots"
cat > "$BUNDLE/egg.toml" <<TOML
# Windows 11 x64 egg built by windows-install/x86/install.sh. UEFI, NVMe system disk,
# $gpu display with ramfb (bootmgr needs a linear framebuffer), virtio network, streamed.
[boot]
mode = "uefi"

[machine]
ram = "$ram"
cpus = $cpus

[[storage]]
path = "$BUNDLE/disks/$name.raw"
read_only = false
create = "$disk"
bus = "nvme"

[[storage]]
path = "$MEDIA"
read_only = true

[network]
mode = "gateway"

[console]
stdio = false

[display]
width = 1280
height = 800
gpu = "$gpu"
$([ "$gpu" = nvidia ] && echo "gpu_address = \"$gpu_address\"")
ramfb = true
stream = "0.0.0.0:3456"
stream_mode = "$stream"
TOML
rm -f "$TOP/guest/in/w11-proof1.txt" "$TOP/guest/in/w11-proof2.txt"
( cd "$TOP/guest" && EGG_DROPBOX_PORT=$PORT exec python3 "$TOP/tools/dropbox.py" ) >/dev/null 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null' EXIT
LOG=$R/$name-install.log
say "egg run $name with the media (headless; Setup → OOBE → first logon → shutdown, ~20-30 min)"
RUST_LOG=info "$EGG" run "$name" --headless >"$LOG" 2>&1 &
rpid=$!; ralive() { kill -0 $rpid 2>/dev/null; }
for _ in $(seq 60); do [ -S "$S" ] && break; ralive || fail "the runner exited before the egg came up (see $LOG)"; sleep 1; done
[ -S "$S" ] || fail "no control socket after 60 s"
P1=$TOP/guest/in/w11-proof1.txt
for _ in $(seq 720); do [ -s "$P1" ] && break; ralive || break; sleep 5; done
[ -s "$P1" ] || { ralive && fail "no proof1 within 60 min (first logon never ran; see $LOG)"; fail "the runner exited before first logon (see $LOG)"; }
cp "$P1" "$R/$name-proof1.txt"; say "proof1 at $(el)"
grep -q 'elevated=yes' "$R/$name-proof1.txt" || fail "firstlogon.cmd did not run elevated"
tr -d '\r' < "$R/$name-proof1.txt" | grep -q 'AutoAdminLogon *REG_SZ *1' || fail "autologon not set"
"$D" "$name" shot "$R/$name-01-first-logon.png" >/dev/null 2>&1
say "waiting for the guest shutdown"
for _ in $(seq 120); do ralive || break; sleep 3; done
ralive && fail "runner still up 6 min after proof1 (guest did not shut down)"
wait $rpid; say "installed at $(el)"

# ── 3. detach the media, cold boot headless, proof2, clean shutdown ───────────
python3 - "$BUNDLE/egg.toml" "$MEDIA" <<'PY' || fail "could not detach the media from egg.toml"
import sys,re
p,media=sys.argv[1],sys.argv[2]; s=open(p).read()
blk=re.search(r'\n\[\[storage\]\]\npath = "%s"\nread_only = true\n' % re.escape(media), s)
assert blk, 'media block not found'
open(p,'w').write(s.replace(blk.group(0), '\n'))
PY
RLOG=$R/$name-coldboot.log
RUST_LOG=info "$EGG" run "$name" --headless >"$RLOG" 2>&1 &
rpid=$!
say "cold boot (headless)"
for _ in $(seq 60); do [ -S "$S" ] && break; ralive || fail "cold boot exited early (see $RLOG)"; sleep 2; done
P2=$TOP/guest/in/w11-proof2.txt
for _ in $(seq 120); do [ -s "$P2" ] && break; ralive || fail "cold boot died (see $RLOG)"; sleep 5; done
[ -s "$P2" ] || fail "no proof2 within 10 min of the cold boot (autologon desktop not reached)"
cp "$P2" "$R/$name-proof2.txt"
"$D" "$name" shot "$R/$name-02-coldboot.png" >/dev/null 2>&1
say "cold boot desktop at $(el): results/$name-02-coldboot.png; the guest shuts itself down"
# The Startup entry that uploaded proof2 removes itself and runs `shutdown /s`: the golden
# carries no trace of this lane, and Windows closes its own filesystem.
for _ in $(seq 120); do ralive || break; sleep 3; done
ralive && fail "the guest did not shut down within 6 min of proof2 (look at results/$name-02-coldboot.png)"
wait $rpid 2>/dev/null
say "PASS in $(el): $name installed unattended and cold-boots to the desktop"
if [ $keep = 0 ]; then "$EGG" rm "$name" 2>&1 | tail -1; exit 0; fi

# ── 5. the golden as a hub bundle ─────────────────────────────────────────────
# A hub (eggrun.ai, or an Egg Carton's import) wants the bundle SIGNED and its disk packed:
# a cold snapshot in snapshots/<name>-build.egg (the one directory the signature covers),
# metadata.toml at the bundle root, and `egg card`, which re-signs with this machine's key.
say "bundle: cold snapshot → metadata → card (signs)"
"$EGG" snapshot --egg "$name" --snapshot "$name-build" --cold >"$R/$name-bundle.log" 2>&1 || fail "cold snapshot failed (see $R/$name-bundle.log)"
[ -d "$BUNDLE/snapshots/$name-build.egg" ] || fail "no snapshots/$name-build.egg after the cold snapshot (see $R/$name-bundle.log)"
cat > "$BUNDLE/metadata.toml" <<META
# Written by windows-install/x86/install.sh: the card the hub shows for this egg.
description = "$title, installed unattended by windows-install. Local administrator egg, autologon, VirtIO drivers, $gpu display."
category = "Desktop"
tags = ["windows", "x86_64", "desktop"]
license = "Your Microsoft licence applies"
network = "gateway"
base = "windows:11"
expose = []
labels = []
arch = "linux-x86_64"
os = "Windows"
class = "L"
title = "$title"

[login]
user = "egg"
autologin = true
helptext = "Signed in as egg by itself. There is no password."
META
if [ -z "$logo" ]; then
  logo=$OUT/logo-$name.png
  python3 - "$logo" <<'PY' || fail "could not write a placeholder logo"
import struct, zlib, sys
w = h = 512
row = bytes([0]) + bytes([0x1f, 0x6f, 0xeb] * w)      # one flat blue square; replace with --logo
raw = row * h
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'PNG

' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
PY
fi
"$EGG" card "$name" logo "$logo" >>"$R/$name-bundle.log" 2>&1 || fail "egg card logo failed (see $R/$name-bundle.log)"
"$EGG" card "$name" add "$R/$name-02-coldboot.png" >>"$R/$name-bundle.log" 2>&1 || say "note: screenshot not added to the card (see $R/$name-bundle.log)"
[ -s "$BUNDLE/MANIFEST.sig" ] || fail "bundle is not signed (no MANIFEST.sig)"
say "bundle signed: $BUNDLE"
cat <<NEXT
  Run it:            egg run $name
  Clone:             egg clone $name w-01
  Egg Carton import: (on the control box) egg-carton hub import $BUNDLE --as <publisher>/<slug>:<tag> --arch linux-x86_64
  eggrun.ai push:    egg push --egg $name --snapshot $name-build --tag <tag> --as <publisher>
NEXT
exit 0
