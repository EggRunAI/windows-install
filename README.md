# windows-install — a Windows 11 egg from an ISO, unattended

One script turns a Windows 11 ISO into an installed, autologged-on Windows egg: a
**golden** you clone and run, or push to your Egg hub. Nothing is typed in the egg window;
the answer file does Setup and OOBE, the guest reports back over a tiny drop box on the
host, and the script judges the result.

Two lanes, one per host kind:

| host | script | guest arch | media tooling |
|---|---|---|---|
| Mac, Apple Silicon | `./install.sh` | Windows 11 **ARM64** | hdiutil (built in) |
| Linux x86_64 with KVM (a Carton Host, a `.metal` EC2, a workstation) | `x86/install.sh` | Windows 11 **x64** | xorriso, wimlib, bsdtar |

## 1. Put the ISO in place

Download Windows 11 from Microsoft for the arch your host runs eggs for and save it as

```
iso/windows.iso
```

`iso/` is ignored by git; the ISO is never modified (the lane copies its tree into `out/`
and writes a new image there). Windows is yours: licensing, keys and activation are between
you and Microsoft; the answer file uses Microsoft's published generic Pro key, which picks
the edition and activates nothing.

## 2. Build the golden

Mac:

```bash
./install.sh w11 --keep
```

Linux x86_64, as root, with the EggRun host package installed (`egg` on PATH):

```bash
sudo apt install xorriso wimtools libarchive-tools python3 curl
sudo x86/install.sh w11 --keep
```

What you get, in `~/.egg/eggs/w11.egg` (`/root/.egg/...` on Linux): an installed Windows 11
Pro, local administrator `egg` with no password that logs on by itself, no sleep or screen
timeout, Fast Startup off (a hibernate-resume would boot blind), VirtIO drivers in. Proof
files and screenshots land in `results/`. `--keep` leaves the egg; without it the lane
removes the egg after proving it (that is the test mode). On failure the egg is always kept
and `results/<name>-fail.png` shows the last frame.

Options: `--iso <path>` (another ISO), `--ram 8G --cpus 4 --disk 64G` (x86 lane; the Mac
lane takes them from `Eggfile`), `--media-only` (just the repacked ISO, to inspect),
`--gpu-driver <zip>` (Mac lane: the VirtIO GPU 3D driver package, for 3D on the ARM egg).

## 3. Bake your software in (x86 lane)

Copy `x86/guest/provision.cmd.example` to `x86/guest/provision.cmd` and put your installs in
it. It runs once, elevated, at the first logon with the network up, before the proof is
uploaded and the machine shuts down; its output is in `C:\egg-provision.txt` inside the
egg. The example is Autodesk Fusion through its Admin Install package (the streaming
installer fails inside an egg). Anything you add to `x86/guest/` next to it ends up in
`C:\egg\` on the installed disk.

## 4. Run it

```bash
egg run w11                 # the golden itself
egg clone w11 f-01          # a copy, instant on a reflink filesystem (XFS/APFS)
egg run f-01 -p 7011:3389   # expose a guest port on the host
```

Windows eggs are stopped with a clean shutdown (`SHUTDOWN` over the egg's control socket,
or Stop in the Carton console), never with a hard power-off: a killed Windows egg comes back
in disk repair.

## 5. From golden to the hub

The golden is an egg bundle; a hub wants that bundle **signed** and with its disk packed.

```bash
egg card w11 logo <png>                     # signs the bundle (MANIFEST.json + MANIFEST.sig)
egg push --egg w11 --snapshot <label> --tag 2026.11.09 --as <publisher>   # eggrun.ai, or a carton that speaks push
```

On an Egg Carton of your own, import on the control box instead:

```bash
egg-carton hub import <bundle-dir> --as <publisher>/<slug>:<tag> --arch x86_64
```

Hosts then `egg pull <publisher>/<slug>:<tag> --name golden` and clone from that. A pulled
Windows egg cold-boots on first start (30-60 s to the desktop).

## What is in here

| path | role |
|---|---|
| `install.sh`, `Eggfile`, `autounattend.xml`, `guest/` | the Mac/ARM64 lane: `egg build` of `FROM windows:11` with repacked media |
| `x86/install.sh`, `x86/autounattend.xml`, `x86/winpeshl.ini`, `x86/guest/` | the Linux x86_64 lane: VirtIO drivers into Setup's boot.wim, an egg bundle with an NVMe disk + virtio-gpu, `egg run` |
| `tools/dropbox.py` | the host-side drop box the guest uploads its proofs to (HTTP PUT, port 8766) |
| `tools/drive.sh` | control-socket helper: key, click, screenshot, settle, raw commands |
| `iso/` | your `windows.iso` (ignored by git) |
| `out/`, `results/` | the repacked media and the run's proofs/screenshots (ignored) |

## Facts the lanes depend on

- 25H2 Setup reads `autounattend.xml` only from the root of the media it booted from, so
  the ISO is repacked rather than a second disk added.
- On the Mac the firmware's "Press any key to boot from CD" has to be answered once;
  install.sh taps Enter for the first 40 s of the first boot and never again. The x86 lane
  boots `efisys_noprompt.bin` and needs no key.
- Windows Setup on x86 cannot see a VirtIO disk, nor its own CD when that is a VirtIO
  device, until viostor is loaded; the x86 lane puts the virtio-win drivers into
  `boot.wim` and `winpeshl.ini` loads them before Setup. The system disk is NVMe (inbox
  driver) and the display is virtio-gpu with ramfb, which the Windows boot manager needs.
- The guest proves itself by uploading files, not by screenshots: `elevated=yes`,
  autologon in the registry, and on the Mac lane TPM 2.0 present and Secure Boot on.

## Known limits

- The x86 lane drives `egg run`, not `egg build`: the EggRun x86 runner has no Windows
  build lane yet, so the egg bundle is written by the script. A RUN-style step for Windows
  is `provision.cmd`.
- No GPU acceleration in the x64 golden (virtio-gpu 2D). NVIDIA passthrough is a per-host
  setting (`gpu = "nvidia"`, `gpu_address`) applied to a clone on a host that has a card bound
  to vfio-pci, not something the golden carries.
- Clones share the golden's Windows SID and activation state; `egg clone` gives each its own
  machine UUID. Activation for a fleet is your Microsoft agreement.
