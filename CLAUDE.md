# windows-install — notes for Claude

This repo is the Windows egg builder: a Windows 11 ISO in, an installed autologged-on egg
out, on a Mac (`install.sh`, ARM64, `egg build`) or a Linux x86_64 KVM host
(`x86/install.sh`, x64, `egg run` of a bundle the script writes). README.md is the user's
document; this file is how to operate it and what not to do.

## Running a build

- The ISO is `iso/windows.iso`; nothing else is assumed. Check it exists and its arch
  matches the lane before anything (`file iso/windows.iso`; an ARM64 ISO on the x86 lane
  installs nothing and the failure looks like a boot hang).
- Mac: `./install.sh <name> --keep` from the repo root; `EGG=` names the runner when `egg`
  is not on PATH (a dev tree's `egg-osx/target/release/egg` must be signed, run `sign.sh`).
  The egg window opens; do not type in it. ~15 min.
- Linux x86_64: `sudo x86/install.sh <name> --keep` as root (KVM, `/root/.egg`). `EGG=` for a
  runner not on PATH. ~30-45 min. Needs 7z (p7zip-full), wimlib-imagex, mtools, dosfstools, python3, curl; the
  virtio-win ISO is fetched into `out/` on first use.
- Port 8766 is the drop box; one build at a time per host, or set `EGG_DROPBOX_PORT`.
- A build is judged by `results/<name>-proof1.txt` and `-proof2.txt`, uploaded by the guest.
  A screenshot is for the human reading a failure, never the evidence.

## Making a golden

1. `install.sh <name> --keep` (either lane). The egg stays in `$EGG_HOME/eggs/<name>.egg`.
2. For software, use `x86/guest/provision.cmd` (x86 lane); it runs once at first logon.
   Test the installer by hand in a running egg first to learn its silent switches, then
   write them in. Every `echo x=%ERRORLEVEL%>> file` must be parenthesised in cmd.
3. Boot it once more by hand (`egg run <name>`), look, then shut it down FROM INSIDE Windows
   (`tools/drive.sh <name> type "shutdown /s /t 0"` into an elevated prompt, or the Start
   menu) and wait for the runner to exit. On x86 the socket's SHUTDOWN and `egg stop` are
   hard cuts; a cut Windows comes back in Automatic Repair.
4. The x86 lane with `--keep` already made the bundle: cold snapshot `snapshots/<name>-build.egg`
   (`egg snapshot --egg <name> --snapshot <name>-build --cold`, egg stopped), metadata.toml,
   `egg card <name> logo <png>` (+ `add <screenshot>`), which signs. The directory name
   `<name>-build.egg` is what the signature covers; keep it. Then README section 5 for the
   carton import or the push. A bundle pulled from another hub must be re-signed the same
   way before an import.

## Rules

- Never commit an ISO, a repacked image, `out/`, `results/` or `guest/in/` (gitignored).
- The user's ISO is read-only input; the lanes copy, never modify it.
- `@DROPBOX@` in a guest script is rewritten to the host URL at staging time; never
  hardcode a host address in `guest/` or `x86/guest/`.
- Keep the two answer files separate: `autounattend.xml` is arm64 components,
  `x86/autounattend.xml` is amd64. A component of the wrong arch is silently ignored by
  Setup and its page comes back as a question in the egg window.
- A build that "hangs" at a question is a wrong
  or missing answer-file entry; look at the screenshot, fix the XML, rebuild.
- The x86 lane writes the egg bundle itself because the x86 runner has no Windows build
  lane; when `egg build` learns `FROM windows:11` on x86, replace that block, keep the media
  and proof logic.
