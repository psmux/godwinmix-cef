# godwinmix-cef

Builds of the Chromium Embedded Framework (CEF) that play H.264 and AAC, and
the scripts that make them.

The official CEF builds at cef-builds.spotifycdn.com leave out the patent
encumbered codecs, so a page whose video is H.264 or whose sound is AAC (a
YouTube live stream, most news sites, most video players) says "Your browser
can't play this video". GodwinMix renders web pages through CEF for its web
page source, and needs those pages to play. This repository builds the same
CEF versions with Chromium's own codec flags turned on:

```
is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome
```

Nothing else changes. No patches of ours, no extra libraries: H.264 and AAC
come from the copy of FFmpeg that Chromium carries inside libcef, the same one
Google Chrome uses.

## Using a release

Each CEF version has one release, tagged `cef-<number>` (for example
`cef-150.0.10`). It holds a minimal distribution per platform, named exactly
like the official one,

```
cef_binary_150.0.10+g8042e43+chromium-150.0.7871.101_windows64_minimal.tar.bz2
cef_binary_150.0.10+g8042e43+chromium-150.0.7871.101_windows64_minimal.tar.bz2.sha1
cef_binary_150.0.10+g8042e43+chromium-150.0.7871.101_windows64_minimal.tar.bz2.sha256
```

and an `index.json` in the format of the official index. The platforms are
`windows64`, `windowsarm64`, `macosarm64`, `macosx64`, `linux64` and
`linuxarm64`; a release
lists the ones built so far.

The `cef` crate takes these unchanged. Point its downloader at the release,
with a `CEF_PATH` that does not already hold the official build of the same
version (the crate reuses whatever it finds there):

```sh
export CEF_PATH=$HOME/.cache/cef-codecs
export CEF_DOWNLOAD_URL=https://github.com/psmux/godwinmix-cef/releases/download/cef-150.0.10
cargo build --release
```

The crate checks the archive against the SHA1 in `index.json`. Anything else
that takes an official CEF archive takes these too.

## Building a version

One input pins a build: the CEF version string, as it appears in the official
archive names and in the `cef` crate's `+metadata`. The CEF branch (Chromium's
build number), the CEF commit and the Chromium tag all come from it.

```sh
git clone https://github.com/psmux/godwinmix-cef.git
cd godwinmix-cef
./build.sh 150.0.10+g8042e43+chromium-150.0.7871.101
./publish.sh 150.0.10+g8042e43+chromium-150.0.7871.101
```

`./build.sh 150.0.10` works too; it looks the full string up in the official
index. To find the version a `cef` crate binds, read its `+metadata`
(`cef-dll-sys = "150.0.0+150.0.10"` binds 150.0.10).

`build.sh` wraps CEF's own `automate-git.py`, fetched from the CEF branch being
built. It runs three phases and leaves a marker in
`$WORK/state/<number>-<platform>/` as each one finishes:

1. sync: depot_tools, CEF at the pinned commit, Chromium at the tag CEF names,
   without Chromium's git history, then Chromium's hooks.
2. build: the release libcef, and on Windows and macOS the separate sandbox
   library an official build makes. No debug build.
3. distrib: the minimal distribution archive, copied to `$WORK/out/cef-<number>/`
   with its `.sha1` and `.sha256`.

Run it again after anything stops it (a dropped connection, a reboot, a full
disk) and it carries on. Finished phases are skipped, a Chromium sync that
stopped halfway is completed with gclient, and the build picks up where ninja
left off. Its log is `$WORK/state/<number>-<platform>/build.log`.

The settings, all optional:

| Variable | Default | What it does |
|---|---|---|
| `WORK` | `C:/cef-build` on Windows, `~/cef-build` elsewhere | Everything goes here. Keep the path short on Windows |
| `PLATFORM` | this machine | `windows64`, `windowsarm64` (cross built on x64 Windows), `macosarm64`, `macosx64`, `linux64` or `linuxarm64` |
| `JOBS` | every thread | Hardware threads the build may use. It also runs at lower priority |
| `MIN_FREE_GB` | 25 | The build stops when free disk falls below this. Run it again once there is room |
| `EXTRA_GN_DEFINES` | `symbol_level=0` | Added to the GN arguments. No debug symbols: the minimal distribution does not carry them, and they double the disk |

`publish.sh` creates the release if it is missing, uploads every archive it
finds for that version with its checksums (or the archives you name, for ones
built on another machine), and rewrites `index.json` from everything the
release now holds. It needs `gh`, logged in with write access. It is safe to
run again.

### How long, and how much disk

This is a full Chromium build. Measured on the machines these releases came
from:

| Platform | Machine | Sync | Build | Peak disk |
|---|---|---|---|---|
| windows64 (150.0.10) | Intel Core Ultra 9 285H, 16 threads, 32 GB, building on 14 | 72 minutes | 14 hours 41 minutes, then 7 minutes for the archive | about 15 GB of objects on top of the checkout |
| macosx64 (154.0.34) | iMac, Intel Core i9-10910, 20 threads, 128 GB, building on 18 | 77 minutes, with three restarts after googlesource answered 429 | about 5 hours 20 minutes, then 2 minutes for the archive | 46 GB in all: a 32 GB checkout and 14 GB of objects |

Plan on 100 GB free before starting and 16 GB of memory at the very least; the
link of libcef is the step that needs the memory.

### Windows

Visual Studio 2022 or 2026 (the Build Tools are enough) with the "Desktop
development with C++" workload and ATL, and the Windows SDK the Chromium
version asks for (10.0.26100 for CEF 150, 10.0.28000 for CEF 154) with its
Debugging Tools. Git for Windows provides the bash `build.sh` runs in, and any
Python 3 on `PATH` runs `automate-git.py`; depot_tools brings everything else.
From an elevated prompt, with no Visual Studio tools running:

```bat
"C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify ^
  --installPath "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools" ^
  --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.ATL ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.28000 --quiet --norestart
```

The Debugging Tools are an optional feature of the SDK. Add them through the
SDK's entry in Apps, Installed apps, Modify, or with the SDK installer:

```bat
winsdksetup.exe /features OptionId.WindowsDesktopDebuggers /quiet /norestart
```

`build.sh` finds Visual Studio wherever it is installed and tells Chromium,
and sets the git options Chromium needs (no line ending conversion, long
paths) for its own processes only. Build in Git Bash:

```sh
JOBS=14 ./build.sh 150.0.10+g8042e43+chromium-150.0.7871.101
```

### macOS

Xcode, the full app and not only the command line tools, with
`xcode-select` pointing at it and its licence accepted. Until someone with
an admin password accepts it, every tool in `/usr/bin` (git, python3, clang)
exits with status 69:

```sh
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
```

Each Mac builds its own platform natively: an Apple silicon Mac makes
`macosarm64` and an Intel Mac makes `macosx64`. An Apple silicon Mac can also
cross build `macosx64` from the same checkout with
`PLATFORM=macosx64 ./build.sh <version>`, at the cost of a second build but
not a second sync.

```sh
git clone https://github.com/psmux/godwinmix-cef.git ~/cef-build/godwinmix-cef
cd ~/cef-build/godwinmix-cef
JOBS=12 MIN_FREE_GB=40 caffeinate -i ./build.sh 154.0.34+g14c5a08+chromium-154.0.8037.98
./publish.sh 154.0.34+g14c5a08+chromium-154.0.8037.98
```

`caffeinate -i` keeps the Mac from sleeping for as long as the build runs,
and changes no setting. macOS cannot pin a process to some of its cores, so
on a Mac `JOBS` goes to the build tool instead: `build.sh` writes
`-local_jobs=JOBS` into the checkout's `build/config/siso/.sisorc`, an
untracked file Siso reads. On a laptop with 24 GB of memory keep `JOBS` a
little under the core count; the link of libcef wants several GB on its own.

Since Xcode 26 the Metal compiler is a separate download, and ANGLE compiles
its Metal shaders during the build, so a Mac without it stops a minute into
the compile with "cannot execute tool 'metal' due to missing Metal
Toolchain". The usual fix is

```sh
xcodebuild -downloadComponent MetalToolchain
```

That needs Xcode's first launch to have finished, which on a fresh Mac
needs an admin (`sudo xcodebuild -runFirstLaunch`). Without admin rights,
unpack the toolchain to `~/cef-build/metal/Metal.xctoolchain` instead, and
`build.sh` points ANGLE at it with `angle_metal_toolchain_dir`. On a Mac whose
`xcodebuild` works, export it without installing anything:

```sh
xcodebuild -downloadComponent MetalToolchain -exportPath ~/cef-build/metal
mkdir ~/cef-build/metal/mnt
hdiutil attach -nobrowse -readonly -mountpoint ~/cef-build/metal/mnt \
  ~/cef-build/metal/MetalToolchain-*.exportedBundle/Restore/*.dmg
cp -R ~/cef-build/metal/mnt/Metal.xctoolchain ~/cef-build/metal/
hdiutil detach ~/cef-build/metal/mnt
```

The toolchain is a universal binary, so one copy serves an Intel Mac and an
Apple silicon one. Set `METAL_TOOLCHAIN` if it lives somewhere else.

### Linux

Ubuntu 22.04 or 24.04 on x86_64, natively or in WSL 2 with the work folder on
the Linux filesystem. `build.sh` adds `use_sysroot=true is_cfi=false` to the
GN arguments on Linux, so the result runs on older systems too. Chromium's
build dependencies come with its source, so sync first, install them once,
then build:

```sh
STOP_AFTER=sync ./build.sh 150.0.10+g8042e43+chromium-150.0.7871.101
sudo ~/cef-build/<branch>/chromium/src/build/install-build-deps.sh --no-prompt --no-chromeos-fonts
sudo apt-get install -y libgtk-3-dev   # cefclient needs it, and the 154 build failed without it
./build.sh 150.0.10+g8042e43+chromium-150.0.7871.101
CLEAN_OUT=1 PLATFORM=linuxarm64 ./build.sh 150.0.10+g8042e43+chromium-150.0.7871.101
```

`linuxarm64` is a cross build from the same checkout, against Chromium's
arm64 sysroot, which `build.sh` has CEF fetch. `CLEAN_OUT=1` deletes a
platform's objects once its archive is made, so two platforms fit where one
checkout does.

In WSL, `df` reports the virtual disk rather than the Windows drive that
holds it, so give `build.sh` a command that asks Windows:

```sh
export FREE_GB_CMD='powershell.exe -NoProfile -Command "[math]::Floor((Get-PSDrive C).Free / 1GB)"'
```

## Where each archive came from

Every archive in this repository's releases was built by `build.sh` from this
repository, on a machine of the maintainer's, from unmodified CEF and Chromium
sources at the pinned version. Releases say which platforms they hold.

Archives built elsewhere are not republished here. Karere
(github.com/tobagin/karere) publishes CEF 150.0.10 for linux64 and linuxarm64
with the same codec flags. We looked at them for the Linux platforms and left
them out. Those builds carry Karere's own patch to Chromium's GLib message
pump (`tools/cef-patches/karere-151-detach-worksource.patch`), so they are not
stock CEF 150.0.10. They are built with other GN arguments too (no PGO, no
ThinLTO), and they come as zip rather than the official tar.bz2. The patch
lives in a GPL 3.0 repository and has no licence of its own, so a libcef
that contains it would bring GPL terms into an Apache licensed program.
Their build script, `tools/build-cef-codecs.sh`, is a useful reference for
the GN arguments a Linux build may need (`use_sysroot=true is_cfi=false`).

## H.264 and AAC licensing

H.264 and AAC are covered by patents that are licensed through patent pools
(Via LA administers both). Building and distributing software that decodes
them may require a patent licence in some countries, depending on how the
software is distributed, how many copies, and whether it is sold. These
builds come with no patent licence of any kind. Whoever ships them in a
product should decide, with their own advice, whether one is needed.

## Licence

The scripts in this repository are under the Apache License 2.0 (`LICENSE`).
CEF is under a BSD licence, and Chromium and everything inside it under their
own licences; each archive carries `LICENSE.txt` and `CREDITS.html`, which
list them all.
