#!/bin/bash
# x86/install.sh — Windows 11 x64 into a fresh egg, unattended, on a Linux x86_64 host (KVM).
#
#   x86/install.sh [name] [--iso <Win11 x64 iso>] [--virtio-win <virtio-win.iso>] [--ram 8G] [--cpus 4]
#                  [--disk 64G] [--gpu virtio-gpu|nvidia] [--gpu-address 0000:c1:00.0] [--stream ws|webrtc]
#                  [--keep] [--logo <512x512.png>] [--title "Windows 11"] [--media-only]
#
# Steps, each a hard failure:
#   1. media: a GPT disk image with one FAT32 volume (a "USB stick"): the ISO's tree with
#      install.wim split into <4 GB .swm parts, plus autounattend.xml and egg\ (the guest
#      scripts, virtio-win guest tools, your provision.cmd). Its boot.wim gets the VirtIO
#      drivers, deploy.cmd and a winpeshl.ini that runs deploy.cmd instead of Setup: Windows
#      Setup will not take an ISO on a VirtIO disk as install media, and a second NVMe
#      controller hangs the x86 guest, so WinPE applies the image itself with DISM.
#   2. the egg: a bundle under $EGG_HOME/eggs/<name>.egg (UEFI, NVMe system disk, virtio-gpu +
#      ramfb, streaming on) with the media image attached read-only; `egg run <name>` boots
#      WinPE, deploy.cmd partitions the NVMe disk, applies the Pro image, adds the drivers,
#      plants the answer file and C:\egg, writes the boot entries, powers off
#   3. media detached; boot two: Windows' specialize and OOBE passes run from the planted
#      answer file; SetupComplete.cmd installs the virtio-win guest tools; the first logon
#      persists autologon, runs provision.cmd if present, uploads proof1, shuts down
#   4. boot three, headless cold boot: the autologon desktop uploads proof2 and the guest shuts
#      ITSELF down. A Windows egg is never cut from outside (a hard stop leaves NTFS dirty).
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
# Needs: egg (the EggRun runner for Linux x86_64) on PATH or EGG=, 7z (p7zip-full), wimlib-imagex,
# mtools, dosfstools, sfdisk, python3, curl, ~25 GB in out/, KVM. ~30-45 min. Exit 0 pass, 1 fail, 2 refused.
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
# The machine a Windows egg gets, every time: 8 vCPUs, 16 GB, a 64 GB disk. These are floors as
# well as defaults (--cpus/--ram/--disk may only raise them): Windows 11 plus one real
# application is slow below them, and Setup itself wants 52 GB free.
name=w11; keep=0; media_only=0; ram=16G; cpus=8; disk=64G; gpu=virtio-gpu; gpu_address=; stream=ws; stream_port=3456; logo=; title="Windows 11"
while [ $# -gt 0 ]; do case "$1" in
  --iso) ISO=$2; shift 2;; --virtio-win) VWISO=$2; shift 2;; --ram) ram=$2; shift 2;; --cpus) cpus=$2; shift 2;;
  --disk) disk=$2; shift 2;; --gpu) gpu=$2; shift 2;; --gpu-address) gpu_address=$2; shift 2;; --stream) stream=$2; shift 2;; --stream-port) stream_port=$2; shift 2;;
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
for t in wimlib-imagex mcopy mkfs.vfat sfdisk python3 curl; do command -v $t >/dev/null || die "$t missing (apt install p7zip-full wimtools mtools dosfstools util-linux python3 curl)"; done
[ -c /dev/kvm ] || die "/dev/kvm missing: this host has no KVM (a .metal instance on AWS)"
[ -f "$ISO" ] || die "install media not found: $ISO (copy your Windows 11 x64 ISO to iso/windows.iso, or --iso <path>)"
case "$gpu" in virtio-gpu) ;; nvidia) [ -n "$gpu_address" ] || die "--gpu nvidia needs --gpu-address <pci address> (lspci -D | grep -i nvidia; egg gpu ls)";;
  *) die "--gpu must be virtio-gpu or nvidia (x86 hosts attach nothing else)";; esac
case "$stream" in ws|webrtc) ;; *) die "--stream must be ws or webrtc";; esac
echo "$stream_port" | grep -Eq '^[0-9]+$' || die "--stream-port takes a port number"
[ $media_only = 1 ] || ! ss -ltn 2>/dev/null | grep -q ":$stream_port " || die "port $stream_port is taken (another egg streams there); pick --stream-port <n>"
disk_gb=$(echo "$disk" | sed -E 's/[Gg][Bb]?$//'); echo "$disk_gb" | grep -Eq '^[0-9]+$' || die "--disk takes gigabytes, e.g. 64G"
[ "$disk_gb" -ge 64 ] || die "--disk $disk is below the 64G floor for a Windows egg"
ram_gb=$(echo "$ram" | sed -E 's/[Gg][Bb]?$//'); echo "$ram_gb" | grep -Eq '^[0-9]+$' || die "--ram takes gigabytes, e.g. 16G"
[ "$ram_gb" -ge 16 ] || die "--ram $ram is below the 16G floor for a Windows egg"
echo "$cpus" | grep -Eq '^[0-9]+$' && [ "$cpus" -ge 8 ] || die "--cpus $cpus is below the 8 vCPU floor for a Windows egg"
[ "$cpus" -le "$(nproc)" ] || die "--cpus $cpus exceeds this host's $(nproc) cores"
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
# The Windows ISO is UDF (its install.wim is bigger than ISO9660 allows). 7z reads UDF in user
# space, which also works on a hardened host whose kernel has the udf module disabled (CIS);
# without 7z the lane falls back to a loop mount. bsdtar cannot read these images.
extract_iso() { # <iso> <dir> <mountpoint>
  if command -v 7z >/dev/null; then 7z x -y -o"$2" "$1" >/dev/null || die "7z could not extract $1"
  else
    mount -o loop,ro "$1" "$3" || die "could not mount $1 (no 7z, and the kernel refused a UDF loop mount: apt install p7zip-full)"
    cp -a "$3"/. "$2"/ || die "copying $1 failed (disk full in $OUT?)"; umount "$3"
  fi
}
say "media: extracting $(basename "$ISO") and the virtio-win drivers ($(command -v 7z >/dev/null && echo 7z || echo loop mount))"
extract_iso "$ISO" "$STAGE" "$M1"
extract_iso "$VWISO" "$VW" "$M2"
rm -rf "$STAGE/[BOOT]" "$VW/[BOOT]"   # 7z's copy of the El Torito boot images; not part of the tree
chmod -R u+w "$STAGE" "$VW"
[ -f "$STAGE/sources/boot.wim" ] || die "no sources/boot.wim in the media (not a Windows install ISO?)"
[ -f "$STAGE/sources/install.wim" ] || die "no sources/install.wim in the media (an .esd-based ISO is not supported yet)"
# The edition: DISM applies an image by index; find "Windows 11 Pro" in the image's table.
IDX=$(wimlib-imagex info "$STAGE/sources/install.wim" | awk '/^Index:/{i=$2} /^Name:/{sub(/^Name: +/,""); if ($0=="Windows 11 Pro") {print i; exit}}')
[ -n "$IDX" ] || die "install.wim has no image named 'Windows 11 Pro' (wimlib-imagex info $ISO)"
say "media: Windows 11 Pro is image index $IDX; splitting install.wim ($(du -h "$STAGE/sources/install.wim" | cut -f1)) for FAT32"
wimlib-imagex split "$STAGE/sources/install.wim" "$STAGE/sources/install.swm" 3800 >/dev/null || die "wimlib split failed"
rm -f "$STAGE/sources/install.wim"
# viostor is what WinPE and the installed system need for the VirtIO media disk; netkvm, vioinput
# and viogpudo so the first boot has network, a pointer and the display without the guest tools.
for d in viostor NetKVM vioinput viogpudo; do
  l=$(echo $d | tr A-Z a-z); src=$(find "$VW" -maxdepth 1 -iname "$d" | head -1)
  [ -d "$src/w11/amd64" ] || die "virtio-win has no $d/w11/amd64 (layout changed?)"
  mkdir -p "$DRV/$l" && cp "$src"/w11/amd64/* "$DRV/$l/"
done
tools=$(find "$VW" -maxdepth 1 -iname 'virtio-win-guest-tools.exe' | head -1); [ -f "$tools" ] || die "virtio-win-guest-tools.exe not in $VWISO"
mkdir -p "$STAGE/egg"
cp "$tools" "$STAGE/egg/virtio-win-guest-tools.exe"
cp "$HERE/autounattend.xml" "$STAGE/autounattend.xml"
crlf() { sed 's/\r$//; s/$/\r/'; }
for f in SetupComplete.cmd firstlogon.cmd; do sed "s#@DROPBOX@#http://$HOSTIP:$PORT#g" "$HERE/guest/$f" | crlf > "$STAGE/egg/$f"; done
[ -f "$HERE/guest/provision.cmd" ] && sed "s#@DROPBOX@#http://$HOSTIP:$PORT#g" "$HERE/guest/provision.cmd" | crlf > "$STAGE/egg/provision.cmd"
sed "s#@INDEX@#$IDX#" "$HERE/deploy.cmd" | crlf > "$OUT/deploy.cmd"
crlf < "$HERE/winpeshl.ini" > "$OUT/winpeshl.ini"
say "media: WinPE gets the VirtIO drivers and deploy.cmd (boot.wim index 2)"
wimlib-imagex update "$STAGE/sources/boot.wim" 2 >/dev/null <<CMDS || die "wimlib update of boot.wim failed"
add '$OUT/winpeshl.ini' /Windows/System32/winpeshl.ini
add '$OUT/deploy.cmd' /deploy.cmd
add '$STAGE/autounattend.xml' /autounattend.xml
add '$STAGE/egg/SetupComplete.cmd' /SetupComplete.cmd
add '$DRV' /drivers
CMDS
wimlib-imagex dir "$STAGE/sources/boot.wim" 2 | grep -qi '^/drivers/viostor/viostor.sys' || die "viostor did not land in boot.wim"
# One GPT basic-data partition, FAT32, sized to the tree plus headroom; the firmware boots
# efi/boot/bootx64.efi from it like a USB stick.
MEDIA=$OUT/windows-x64-egg.img; rm -f "$MEDIA"
SZ_MB=$(( $(du -sm "$STAGE" | cut -f1) + 400 ))
truncate -s ${SZ_MB}M "$MEDIA"
sfdisk -q "$MEDIA" <<SF || die "sfdisk failed"
label: gpt
start=2048, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=WIN11MEDIA
SF
OFF=$((2048*512)); PSZ=$(( SZ_MB*1024*1024 - OFF - 34*512 ))
mkfs.vfat -F 32 -n WIN11EGG --offset 2048 -S 512 "$MEDIA" $(( PSZ/1024 )) >/dev/null || die "mkfs.vfat failed"
MT="-i $MEDIA@@$OFF"
say "media: writing the FAT32 image (${SZ_MB} MB)"
( cd "$STAGE" && mcopy $MT -s -Q -b -m . ::/ ) || die "mcopy into the media image failed"
mdir $MT ::/sources | grep -qi 'install.swm' || die "install.swm missing from the media image"
mdir $MT ::/efi/boot | grep -qi 'bootx64' || die "efi/boot/bootx64.efi missing from the media image"
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
stream = "0.0.0.0:$stream_port"
stream_mode = "$stream"
TOML
rm -f "$TOP/guest/in/w11-proof1.txt" "$TOP/guest/in/w11-proof2.txt"
( cd "$TOP/guest" && EGG_DROPBOX_PORT=$PORT exec python3 "$TOP/tools/dropbox.py" ) >/dev/null 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null' EXIT
run_egg() { RUST_LOG=info "$EGG" run "$name" --headless >"$1" 2>&1 & rpid=$!; }
ralive() { kill -0 $rpid 2>/dev/null; }
wait_socket() { for _ in $(seq 60); do [ -S "$S" ] && return 0; ralive || return 1; sleep 1; done; [ -S "$S" ]; }
# ── boot one: WinPE deploys the image and powers off ──────────────────────────
LOG=$R/$name-deploy.log
say "boot 1/3: WinPE deploy (DISM apply of the Pro image onto the NVMe disk; ~10-20 min)"
run_egg "$LOG"
wait_socket || fail "the runner exited before WinPE came up (see $LOG)"
for _ in $(seq 480); do ralive || break; sleep 5; done
ralive && { "$D" "$name" shot "$R/$name-deploy-stuck.png" >/dev/null 2>&1; fail "WinPE did not power off within 40 min (deploy.cmd stuck; see results/$name-deploy-stuck.png)"; }
wait $rpid 2>/dev/null
python3 - "$BUNDLE/disks/$name.raw" <<'PY' || fail "the system disk has no GPT after the deploy boot (deploy.cmd failed before partitioning; see results/)"
import sys; f=open(sys.argv[1],'rb'); f.seek(512); sig=f.read(8); assert sig==b'EFI PART', sig
PY
say "deploy boot done at $(el): the disk carries a GPT"
# ── the media comes off; boot two: specialize, OOBE, first logon, shutdown ────
python3 - "$BUNDLE/egg.toml" "$MEDIA" <<'PY' || fail "could not detach the media from egg.toml"
import sys,re
p,media=sys.argv[1],sys.argv[2]; s=open(p).read()
blk=re.search(r'\n\[\[storage\]\]\npath = "%s"\nread_only = true\n' % re.escape(media), s)
assert blk, 'media block not found'
open(p,'w').write(s.replace(blk.group(0), '\n'))
PY
LOG=$R/$name-install.log
say "boot 2/3: Windows first boot (specialize → OOBE → autologon → first logon → shutdown; ~10-20 min)"
run_egg "$LOG"
wait_socket || fail "the runner exited before the first Windows boot came up (see $LOG)"
P1=$TOP/guest/in/w11-proof1.txt
for _ in $(seq 600); do [ -s "$P1" ] && break; ralive || break; sleep 5; done
[ -s "$P1" ] || { ralive && { "$D" "$name" shot "$R/$name-firstboot-stuck.png" >/dev/null 2>&1; fail "no proof1 within 50 min (a Setup/OOBE page is waiting: results/$name-firstboot-stuck.png)"; }; fail "the runner exited before first logon (see $LOG)"; }
cp "$P1" "$R/$name-proof1.txt"; say "proof1 at $(el)"
grep -q 'elevated=yes' "$R/$name-proof1.txt" || fail "firstlogon.cmd did not run elevated"
tr -d '\r' < "$R/$name-proof1.txt" | grep -q 'AutoAdminLogon *REG_SZ *1' || fail "autologon not set"
"$D" "$name" shot "$R/$name-01-first-logon.png" >/dev/null 2>&1
for _ in $(seq 120); do ralive || break; sleep 3; done
ralive && fail "runner still up 6 min after proof1 (guest did not shut down)"
wait $rpid 2>/dev/null; say "installed at $(el)"

# ── boot three: headless cold boot, proof2, the guest shuts itself down ───────
RLOG=$R/$name-coldboot.log
say "boot 3/3: cold boot (headless)"
run_egg "$RLOG"
wait_socket || fail "cold boot exited early (see $RLOG)"
P2=$TOP/guest/in/w11-proof2.txt
for _ in $(seq 120); do [ -s "$P2" ] && break; ralive || fail "cold boot died (see $RLOG)"; sleep 5; done
[ -s "$P2" ] || fail "no proof2 within 10 min of the cold boot (autologon desktop not reached)"
cp "$P2" "$R/$name-proof2.txt"
"$D" "$name" shot "$R/$name-02-coldboot.png" >/dev/null 2>&1
say "cold boot desktop at $(el): results/$name-02-coldboot.png; the guest shuts itself down"
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
