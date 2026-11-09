#!/bin/bash
# install.sh — Windows 11 ARM64 into a fresh egg, unattended, on a Mac (Apple Silicon).
#
#   install.sh [name] [--iso <Win11 ARM64 iso>] [--gpu-driver <viogpu3d zip>] [--keep] [--media-only] [--coldboot-only]
#
# The product path: `egg build` of the Eggfile here (`FROM windows:11`) with install media
# repacked to carry autounattend.xml at its root and egg\ (the first-logon scripts, the
# optional GPU driver). Steps, each a hard failure:
#   1. media: the ISO tree + autounattend.xml + egg\ → one UDF/ISO9660 image with Microsoft's
#      own efisys.bin as the EFI El Torito image (hdiutil; the user's ISO is never changed)
#   2. `egg build` writes the egg and boots it with the media; this script answers the
#      firmware's "Press any key to boot from CD" on THAT boot only
#   3. Setup + OOBE run from the answer file to an autologged-on desktop; the guest uploads
#      proof1 to the drop box (elevated, Secure Boot, TPM, driver staged when one was given)
#   4. after its reboot the guest uploads proof2 (autologon persisted; with the GPU driver:
#      200 % scaling, 3840x2160, VirtIO display adapter) and shuts down → `egg build` exits 0
#   5. a headless cold boot reaches the desktop; a framebuffer screenshot is saved
#   6. a socket SHUTDOWN stops the egg cleanly
#
# Default ISO: iso/windows.iso (put your Windows 11 ARM64 ISO there). Default name w11.
# --keep leaves the egg installed (that is the golden); without it the egg is removed on
# success. On failure it is always kept for a look. ~10-15 min on an M-series Mac.
# Exit 0 pass, 1 fail, 2 refused. For Linux x86_64 hosts see x86/install.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
EGG=${EGG:-$(command -v egg || true)}
D=$HERE/tools/drive.sh
EH=${EGG_HOME:-$HOME/.egg}
PORT=${EGG_DROPBOX_PORT:-8766}
ISO=$HERE/iso/windows.iso
ZIP=${WINDOWS_GPU_DRIVER_ZIP:-}
name=w11; keep=0; media_only=0; coldboot_only=0
while [ $# -gt 0 ]; do case "$1" in
  --iso) ISO=$2; shift 2;; --gpu-driver) ZIP=$2; shift 2;; --keep) keep=1; shift;; --media-only) media_only=1; shift;;
  --coldboot-only) coldboot_only=1; keep=1; shift;;
  -h|--help) sed -n 2,24p "$0"; exit 2;; -*) echo "install.sh: unknown option $1" >&2; exit 2;; *) name=$1; shift;; esac; done
say() { printf '[w11-install %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { say "REFUSED: $*"; exit 2; }
T0=$(date +%s); el() { echo "$(( $(date +%s) - T0 ))s"; }
R=$HERE/results; mkdir -p "$R" "$HERE/out" "$HERE/guest/in"; LOG=$R/$name-build.log
fail() { say "FAILED after $(el): $*"; [ -S "$EH/eggs/$name.egg/run/egg.sock" ] && "$D" "$name" shot "$R/$name-fail.png" >/dev/null 2>&1; say "egg $name kept for a look (egg rm $name to recycle)"; exit 1; }

# ── preconditions ─────────────────────────────────────────────────────────────
[ "$(uname -s)" = Darwin ] || die "this script is the macOS lane; on Linux x86_64 run x86/install.sh"
[ -n "$EGG" ] && [ -x "$EGG" ] || die "no egg binary (install Egg, or EGG=/path/to/egg)"
if [ $coldboot_only = 0 ]; then
  [ -f "$ISO" ] || die "install media not found: $ISO (copy your Windows 11 ARM64 ISO to iso/windows.iso, or --iso <path>)"
  [ -z "$ZIP" ] || [ -f "$ZIP" ] || die "GPU driver zip not found: $ZIP"
fi
HOSTIP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null); [ -n "$HOSTIP" ] || die "no host LAN address (the guest uploads its proofs to this Mac)"
if [ $media_only = 0 ] && [ $coldboot_only = 0 ]; then
  busy=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | head -1)
  [ -n "$busy" ] && die "port $PORT is taken by pid $busy; stop it or set EGG_DROPBOX_PORT"
  [ -e "$EH/eggs/$name.egg" ] && die "$name already exists (egg rm $name first, or pick a name)"
fi
if [ $coldboot_only = 1 ]; then
  [ -e "$EH/eggs/$name.egg" ] || die "$name does not exist"
  LOG=$R/$name-coldboot.log
fi

if [ $coldboot_only = 0 ]; then
# ── 1. media ──────────────────────────────────────────────────────────────────
# A copy of the media tree plus our files; El Torito with Microsoft's own efisys.bin, the
# FULL image length (hdiutil's default 1024 sectors truncates the FAT image → unbootable).
MEDIA=$HERE/out/windows-arm64-egg.iso
say "media: repacking $(basename "$ISO") with autounattend.xml → $MEDIA"
MNT=$(hdiutil attach -readonly -nobrowse -noverify "$ISO" 2>/dev/null | tail -1 | awk '{print $NF}')
[ -d "$MNT/sources" ] || die "could not mount $ISO"
STAGE=$HERE/out/stage.$$; rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null; rm -rf "$STAGE"' EXIT
cp -R "$MNT"/. "$STAGE"/ || die "copying the media tree failed (disk full?)"
chmod -R u+w "$STAGE"
mkdir -p "$STAGE/egg"
cp "$HERE/autounattend.xml" "$STAGE/autounattend.xml"
for f in firstlogon.cmd postboot.cmd setmode.ps1; do sed "s#@DROPBOX@#http://$HOSTIP:$PORT#g" "$HERE/guest/$f" | perl -pe 's/\r?\n/\r\n/' > "$STAGE/egg/$f"; done
if [ -n "$ZIP" ]; then
  unzip -q "$ZIP" -d "$STAGE/egg"   # → egg/drivers/viogpu3d/
  [ -f "$STAGE/egg/drivers/viogpu3d/viogpu3d.inf" ] || die "unexpected driver zip layout (want drivers/viogpu3d/viogpu3d.inf)"
fi
rm -f "$MEDIA"
hdiutil makehybrid -quiet -o "$MEDIA" -iso -udf -joliet -iso-volume-name EGGWIN11 -udf-volume-name EGGWIN11 -joliet-volume-name EGGWIN11 \
  -eltorito-boot "$STAGE/efi/microsoft/boot/efisys.bin" -no-emul-boot -boot-load-size 3360 -eltorito-platform 239 \
  "$STAGE" || die "hdiutil makehybrid failed"
hdiutil detach "$MNT" -quiet 2>/dev/null; MNT=/nonexistent; rm -rf "$STAGE"
python3 - "$MEDIA" <<'PY' || die "repacked media has no EFI El Torito entry"
import struct,sys
f=open(sys.argv[1],'rb'); f.seek(17*2048); d=f.read(2048)
assert d[1:6]==b'CD001' and b'EL TORITO' in d, 'no boot record'
cat=struct.unpack('<I', d[0x47:0x4b])[0]; f.seek(cat*2048); c=f.read(64)
assert c[1]==0xef and c[32]==0x88, 'not an EFI bootable entry'
print('  boot image: %d sectors, EFI' % struct.unpack('<H', c[38:40])[0])
PY
say "media ready ($(du -h "$MEDIA" | cut -f1), $(el))"
[ $media_only = 1 ] && exit 0

# ── 2. egg build ──────────────────────────────────────────────────────────────
rm -f "$HERE/guest/in/w11-proof1.txt" "$HERE/guest/in/w11-proof2.txt"
( cd "$HERE/guest" && EGG_DROPBOX_PORT=$PORT exec python3 "$HERE/tools/dropbox.py" ) >/dev/null 2>&1 &
srv=$!; trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null; rm -rf "$STAGE"' EXIT
say "egg build --egg $name (the egg window opens; do not touch it)"
"$EGG" build --egg "$name" --iso "$MEDIA" -f "$HERE/Eggfile" "$HERE" >"$LOG" 2>&1 &
bpid=$!
balive() { kill -0 $bpid 2>/dev/null; }
S=$EH/eggs/$name.egg/run/egg.sock
for _ in $(seq 60); do [ -S "$S" ] && break; balive || fail "egg build exited before the egg came up (see $LOG)"; sleep 1; done
[ -S "$S" ] || fail "no control socket after 60 s"
mkdir -p "$EH/eggs/$name.egg/screenshots"

# "Press any key to boot from CD" must be answered on this boot and never again (a key on a
# later boot would run Setup twice). Enter every 0.5 s for 40 s; WinPE ignores the rest.
say "pressing a key for the CD prompt"
for _ in $(seq 80); do printf 'KEY 28 1\n' | nc -U "$S" >/dev/null 2>&1; sleep 0.05; printf 'KEY 28 0\n' | nc -U "$S" >/dev/null 2>&1; sleep 0.45; done
"$D" "$name" shot "$R/$name-01-after-prompt.png" >/dev/null 2>&1

# ── 3./4. Setup → OOBE → desktop → proofs → shutdown ──────────────────────────
P1=$HERE/guest/in/w11-proof1.txt; P2=$HERE/guest/in/w11-proof2.txt
say "waiting for the guest: Setup → first logon (proof1) → reboot (proof2) → shutdown (~10 min)"
shot1=0
for _ in $(seq 600); do
  [ -s "$P1" ] && [ $shot1 = 0 ] && { shot1=1; say "proof1 at $(el)"; "$D" "$name" shot "$R/$name-02-first-logon.png" >/dev/null 2>&1; }
  [ -s "$P2" ] && break
  balive || break
  sleep 5
done
[ -s "$P1" ] || fail "no proof1 (first logon never ran; see results/$name-*.png and $LOG)"
cp "$P1" "$R/$name-proof1.txt"
grep -q 'elevated=yes' "$R/$name-proof1.txt" || fail "firstlogon.cmd did not run elevated"
tr -d '\r' < "$R/$name-proof1.txt" | grep -q 'TPM Present: True' || fail "no TPM 2.0 seen by the guest"
[ -z "$ZIP" ] || grep -q 'pnputil=\(0\|259\|3010\)' "$R/$name-proof1.txt" || fail "GPU driver did not stage (pnputil code in proof1)"
[ -s "$P2" ] || fail "no proof2 within 50 min (the reboot did not reach the desktop)"
cp "$P2" "$R/$name-proof2.txt"
tr -d '\r' < "$R/$name-proof2.txt" | grep -q 'AutoAdminLogon *REG_SZ *1' || fail "autologon not set"
if [ -n "$ZIP" ]; then
  tr -d '\r' < "$R/$name-proof2.txt" | grep -q 'LogPixels.*0xc0' || fail "LogPixels is not 192 (200 %)"
  tr -d '\r' < "$R/$name-proof2.txt" | grep -q 'CurrentHorizontalResolution *: *3840' || fail "guest desktop is not 3840 wide"
  tr -d '\r' < "$R/$name-proof2.txt" | grep -qi 'VirtIO' || fail "no VirtIO GPU display adapter in proof2"
fi
say "proof2 at $(el): elevated, Secure Boot, TPM 2.0, autologon$([ -n "$ZIP" ] && echo ', GPU driver bound at 3840x2160 200 %')"
"$D" "$name" shot "$R/$name-03-postboot.png" >/dev/null 2>&1

say "waiting for the guest shutdown → egg build exit"
for _ in $(seq 120); do balive || break; sleep 3; done
balive && fail "egg build still running 6 min after proof2 (guest did not shut down)"
wait $bpid; rc=$?
[ $rc = 0 ] || fail "egg build exited $rc (see $LOG)"
grep -q '==> Installed' "$LOG" || fail "egg build did not report the install"
say "egg build done at $(el)"
fi   # coldboot_only

# ── 5. headless cold boot ─────────────────────────────────────────────────────
RLOG=$R/$name-coldboot.log
mkdir -p "$EH/eggs/$name.egg/screenshots"
RUST_LOG=info "$EGG" run "$name" --headless >"$RLOG" 2>&1 &
rpid=$!; ralive() { kill -0 $rpid 2>/dev/null; }
say "cold boot (headless)"
S=$EH/eggs/$name.egg/run/egg.sock
for _ in $(seq 60); do [ -S "$S" ] && break; ralive || fail "cold boot exited early (see $RLOG)"; sleep 2; done
"$D" "$name" settle 120 >/dev/null 2>&1; sleep 2
"$D" "$name" shot "$R/$name-04-coldboot.png" >/dev/null || fail "no screenshot from the cold boot"
say "cold boot desktop at $(el): results/$name-04-coldboot.png"
"$D" "$name" raw SHUTDOWN >/dev/null
for _ in $(seq 90); do ralive || break; sleep 2; done
ralive && fail "no clean shutdown within 180 s (stop it by hand; never POWEROFF a Windows egg)"
wait $rpid 2>/dev/null
say "PASS in $(el): $name installs unattended and cold-boots to the desktop"
[ $keep = 1 ] && { say "kept: egg run $name  (this is your golden; see README 'From golden to the hub')"; exit 0; }
"$EGG" rm "$name" 2>&1 | grep -v '^\[20' | tail -1
exit 0
