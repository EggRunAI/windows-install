# windows-install — a Windows 11 egg from an ISO, unattended

One script turns a Windows 11 ISO into an installed, autologged-on Windows egg: a
**golden** you clone and run, or push to your Egg hub. Nothing is typed in the egg window;
the answer file does Setup and OOBE, the guest reports back over a tiny drop box on the
host, and the script judges the result.

Two lanes, one per host kind:

| host | script | guest arch | media tooling |
|---|---|---|---|
| Mac, Apple Silicon | `./install.sh` | Windows 11 **ARM64** | hdiutil (built in) |
| Linux x86_64 with KVM (a Carton Host, a `.metal` EC2, a workstation) | `x86/install.sh` | Windows 11 **x64** | 7z, wimlib, mtools, dosfstools |

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
sudo apt install p7zip-full wimtools mtools dosfstools python3 curl
sudo x86/install.sh w11 --keep
```

What you get, in `~/.egg/eggs/w11.egg` (`/root/.egg/...` on Linux): an installed Windows 11
Pro, local administrator `egg` with no password that logs on by itself, no sleep or screen
timeout, Fast Startup off (a hibernate-resume would boot blind), VirtIO drivers in. Proof
files and screenshots land in `results/`. `--keep` leaves the egg; without it the lane
removes the egg after proving it (that is the test mode). On failure the egg is always kept
and `results/<name>-fail.png` shows the last frame.

Options: `--iso <path>` (another ISO), `--ram 16G --cpus 8 --disk 64G` (x86 lane; these are the
floors and the defaults, a Windows egg never gets less; the Mac lane takes the same from
`Eggfile`), `--media-only` (just the repacked ISO, to inspect),
`--gpu-driver <zip>` (Mac lane: the VirtIO GPU 3D driver package, for 3D on the ARM egg).

GPU and streaming (x86 lane): the egg is written with `--gpu virtio-gpu` (default, the 2D
device every host has) or `--gpu nvidia --gpu-address 0000:c1:00.0` (whole-card passthrough;
the card must be bound to vfio-pci on that host, `egg gpu ls` lists them, and the NVIDIA
driver is installed from `provision.cmd`). Either way the egg streams its display
(`--stream ws`, or `webrtc` for H.264 when the host has an encoder), which is what the
Carton console's Open uses.

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

Stop a Windows egg from inside Windows (Start → Power → Shut down, or `shutdown /s /t 0`),
never with a hard stop from outside: on x86 `egg stop` and the socket's SHUTDOWN cut the
machine, and a cut Windows comes back in Automatic Repair.

## 5. From golden to the hub

A hub wants the bundle **signed** and its disk **packed**. The x86 lane does this itself when
you pass `--keep`: a cold (disk-only) snapshot in `snapshots/<name>-build.egg`, a
`metadata.toml` (title from `--title`, the card the hub shows), and `egg card` with a logo
(`--logo <512x512.png>`, a flat placeholder otherwise) and the cold-boot screenshot, which
signs the bundle with this machine's key. The Mac lane's `egg build` produces the build
snapshot itself; `egg card w11 logo <png>` signs it.

Then, on an Egg Carton of your own, import on the control box:

```bash
egg-carton hub import /root/.egg/eggs/w11.egg --as <publisher>/<slug>:<tag> --arch linux-x86_64
egg-carton hub ls
```

or push to eggrun.ai:

```bash
egg push --egg w11 --snapshot w11-build --tag 2026.11.09 --as <publisher>
```

Hosts then `egg pull <publisher>/<slug>:<tag> --name golden` and `egg clone golden w-01` per
machine. A pulled Windows egg cold-boots on first start (30-60 s to the desktop); if the very
first boot of a large egg says "No bootable device", the disk restore was still running: stop
it and start it again.

## What is in here

| path | role |
|---|---|
| `install.sh`, `Eggfile`, `autounattend.xml`, `guest/` | the Mac/ARM64 lane: `egg build` of `FROM windows:11` with repacked media |
| `x86/install.sh`, `x86/autounattend.xml`, `x86/winpeshl.ini`, `x86/deploy.cmd`, `x86/guest/` | the Linux x86_64 lane: FAT32 media image, WinPE deploy with DISM, an egg bundle with an NVMe disk + virtio-gpu, three `egg run` boots |
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
- The Windows ISO is UDF with an install.wim beyond 4 GB; the lane extracts it with 7z in user
  space (no kernel udf module needed, so a CIS-hardened host is fine; a loop mount is the fallback)
  and splits the image into `.swm` parts, which FAT32 can hold and Windows reads as one image.
- Windows Setup on x86 will not take an ISO on a VirtIO disk as install media, and a second
  NVMe controller hangs the x86 guest today, so the lane does not run Setup at all: the media
  is a FAT32 "USB stick" image whose WinPE loads viostor and applies the Pro image with DISM,
  plants the answer file (specialize and OOBE passes still run from it) and powers off. The
  system disk is NVMe (inbox driver); the display is virtio-gpu with ramfb for the boot manager.
- The guest proves itself by uploading files, not by screenshots: `elevated=yes`,
  autologon in the registry, and on the Mac lane TPM 2.0 present and Secure Boot on.

## Known limits

- The x86 lane drives `egg run`, not `egg build`: the EggRun x86 runner has no Windows
  build lane yet, so the egg bundle is written by the script. A RUN-style step for Windows
  is `provision.cmd`.
- A virtio-gpu golden has no GPU acceleration (2D scanout). An `--gpu nvidia` golden is tied to
  a host that has that card bound to vfio-pci; to move it, change `gpu_address` in its egg.toml
  on the new host.
- Clones share the golden's Windows SID and activation state; `egg clone` gives each its own
  machine UUID. Activation for a fleet is your Microsoft agreement.

## License

The installer (the scripts, answer files and helpers in this repository) is licensed under
the Apache License 2.0, see LICENSE. Windows, the VirtIO drivers from virtio-win, and any
software your `provision.cmd` installs are licensed by their own vendors.
