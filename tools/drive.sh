#!/bin/bash
# drive.sh — drive a running egg's guest over its control socket.
#
#   drive.sh <egg> click X Y        # left click at framebuffer pixel (800x600 coords)
#   drive.sh <egg> key <code>       # tap a Linux keycode (28=Enter, 15=Tab, 1=Esc, 125=Meta)
#   drive.sh <egg> combo meta r     # named-key chord (press in order, release in reverse)
#   drive.sh <egg> type "text"      # paced typing (~80 chars/s)
#   drive.sh <egg> runbox "cmd"     # Esc, release Shift/Win, Win+R, type, Enter (Windows)
#   drive.sh <egg> shot [out.png]   # SCREENSHOT via the socket (works while egg is re-signed)
#   drive.sh <egg> settle [max_s]   # wait until two captures 3 s apart match, then save shot
#   drive.sh <egg> raw "STATUS"     # any control-socket command, response on stdout
#
# Coordinates are 800x600 regardless of the guest mode: the MOUSE_MOVE command
# takes 0..32767 absolute units, so scale from whatever screenshot size you
# measured on (x*800/W, y*600/H).
#
# TWO-SHOT RULE: a single `shot` can hand back the PREVIOUS frame (the capture
# races the scanout copy). Always take two shots ~2 s apart and trust the
# SECOND. It doubles as the freeze test: if the two are byte-identical on a
# moving scene the guest really is stuck, and one shot could never tell you.
#   ./drive.sh W11-2 shot /tmp/a.png; sleep 2; ./drive.sh W11-2 shot /tmp/b.png
#
# Never hardcode the Mac's LAN IP in a guest command — it moves with the
# network. Use `@DROPBOX@` inside served .cmd/.ps1/.html files (dropbox.py
# rewrites it), or `HOSTIP=$(ipconfig getifaddr en0)` on the Mac side.
#
# Known quirk (Windows guests): input sometimes stops landing after a while.
# Click an empty taskbar spot first (`click 625 582`), then retry. Verify a
# navigation by its side effect (a log line, a drop-box upload), never by a
# screenshot alone — a page still loading looks like a page that failed.
set -u
name="$1"; shift
S=${EGG_HOME:-$HOME/.egg}/eggs/$name.egg/run/egg.sock
T=${TMPDIR:-/tmp}
# netcat-openbsd (Ubuntu's nc) keeps the connection open after the reply and hangs the caller;
# -q 1 closes it a second after EOF on stdin. nmap's ncat (Fedora) closes by itself and has no -q.
NCQ=""; nc -h 2>&1 | grep -q -- '-q' && NCQ="-q 1"
send() { printf '%s\n' "$1" | timeout 10 nc -U $NCQ "$S" 2>/dev/null; }
case "${1:-}" in
  click) x=$(( $2 * 32767 / 800 )); y=$(( $3 * 32767 / 600 )); send "MOUSE_MOVE $x $y" >/dev/null; sleep 0.25; send "MOUSE_BTN left 1" >/dev/null; sleep 0.08; send "MOUSE_BTN left 0" >/dev/null;;
  key) send "KEY $2 1" >/dev/null; sleep 0.05; send "KEY $2 0" >/dev/null;;   # on the x86 runner a bare KEY 28 did not register; use `combo enter`
  combo) send "KEY_COMBO $2 $3" >/dev/null;;
  type) send "TYPE $2" >/dev/null;;
  # Win+R → type → Enter. Esc first closes whatever overlay is up; Shift and Win are
  # released before the chord because TYPE leaves Shift held after a string that ends
  # in a shifted character (`"`, `%`, `\`), and the next Win+R then lands as
  # Win+Shift+R — the Snipping Tool's record overlay swallowed the command
  # (w11-gate-e2e, 2026-10-31). Released again after Enter for the next caller.
  runbox) send "KEY 1 1" >/dev/null; sleep 0.05; send "KEY 1 0" >/dev/null; sleep 0.5
    send "KEY 42 0" >/dev/null; send "KEY 54 0" >/dev/null; send "KEY 125 0" >/dev/null; sleep 0.3
    send "KEY_COMBO meta r" >/dev/null; sleep 2; send "TYPE $2" >/dev/null; sleep $(( ${#2} / 60 + 1 ))
    send "KEY_COMBO enter" >/dev/null; sleep 0.2; send "KEY 42 0" >/dev/null;;
  raw) send "$2";;
  # The previous capture is removed first: a dead egg (stale socket file, runner gone) must fail
  # loudly instead of handing back the last frame it ever produced.
  shot) out=${2:-$T/$name-shot.png}; p=${EGG_HOME:-$HOME/.egg}/eggs/$name.egg/screenshots/shot.png; rm -f "$p"
    if [ ! -S "$S" ]; then echo "drive.sh: $name is not running (no socket at $S)" >&2; exit 2; fi
    send "SCREENSHOT $p" >/dev/null; sleep 0.5
    if [ ! -s "$p" ]; then echo "drive.sh: $name produced no screenshot (runner dead or busy)" >&2; exit 3; fi
    cp "$p" "$out" && echo "$out";;
  settle) max=${2:-40}; t=0; prev=""; p=${EGG_HOME:-$HOME/.egg}/eggs/$name.egg/screenshots/shot.png
    while [ $t -lt $max ]; do rm -f "$p"; send "SCREENSHOT $p" >/dev/null; sleep 0.5; cur=$(md5 -q "$p" 2>/dev/null)
      if [ -z "$cur" ]; then echo "drive.sh: $name produced no screenshot (not running?)" >&2; exit 3; fi
      if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then cp "$p" "$T/$name-shot.png"; echo "settled at ${t}s"; exit 0; fi
      prev=$cur; sleep 3; t=$((t+3)); done
    cp "$p" "$T/$name-shot.png" 2>/dev/null; echo "not settled after ${max}s";;
  *) sed -n 2,29p "$0"; exit 1;;
esac
