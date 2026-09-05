# BUNNY RAMDISK BUILDER — Linux

Native Linux port of **BUNNY RAMDISK BUILDER** for A12/A13 research devices.

The project keeps the original builder workflow but replaces the macOS-only pieces with Linux-native tooling.

## What changed from macOS

| macOS original | Linux port |
|---|---|
| SwiftUI app | Bash/Python CLI |
| Homebrew | apt/dnf/pacman |
| hdiutil/diskutil | Linux loop mounts + linux-apfs-rw |
| Darwin libirecovery build | libirecovery on Linux |
| bundled Darwin tools | native Linux tools / local `.local` prefix |
| macOS IPSW helpers | blacktop/ipsw + pyimg4 |

## Supported distributions

**Fedora, Debian, Ubuntu and Arch Linux** are supported by `setup_dependencies.sh`.

## Install

```bash
git clone https://github.com/FogboundSloth25/BUNNY-RAMDISK-BUILDER-LINUX.git
cd BUNNY-RAMDISK-BUILDER-LINUX
chmod +x *.sh scripts/*.sh
./setup_dependencies.sh
```

The installer creates a local Python virtualenv, installs the Python dependencies, builds or installs libirecovery, installs blacktop/ipsw, fetches the A12/A13 patchfinders, builds trustcache, builds the experimental Linux APFS module and downloads default A12/A13 IM4M resources.

## Check the device

Put the iPhone into DFU / pwned DFU and run:

```bash
./status.sh
```

The device section comes from `irecovery -q`.

## Build

For firmware selected by version:

```bash
./build.sh --version 18.7.10
```

For a build number:

```bash
./build.sh --build 22H374
```

For a local IPSW:

```bash
./build.sh --ipsw ~/Downloads/iPhone11,2.ipsw --model D321AP
```

For a direct IPSW URL:

```bash
./build.sh --url 'https://example.invalid/file.ipsw' \
  --product iPhone12,1 --model D421AP
```

The remote mode retrieves the BuildManifest and requested IPSW members independently and caches them under `cache/` rather than requiring the whole IPSW first.

Use `--dry-run` to validate the BuildManifest and selected BuildIdentity before patching.

## Output

Bootchains are stored in:

```
bootchain/<board>-<version>-<build>-ramdisk/
```

Typical output:

```
iBEC.patched.img4
iBEC.patched.raw
iBSS.patched.raw          # when --use-ibss
kernelcache.patched.raw
kernelcache.img4.patched
devicetree.img4
trustcache.img4
ramdisk.img4
AOP.img4 / ANE.img4 / ... # when present
chain.info
```

## Boot

```bash
./boot.sh
```

When `usbliter8ctl` is available and a patched iBSS was built, `boot.sh` uses the pwned-DFU path first. Otherwise it falls back to libirecovery/iBEC staging.

The exact boot-chain behavior is device/iOS dependent; a successful build does not mean every IPSW will boot on every A12/A13 board.

## SSH

After the ramdisk starts:

```bash
./ssh.sh
```

Defaults:

- local TCP port: `2222`
- device SSH port: `22`
- user: `root`
- password: `alpine`

For a ramdisk using port 44:

```bash
BUNNY_SSH_DEVICE_PORT=44 ./ssh.sh
```

## Linux APFS backend

Modern iOS restore ramdisks commonly use APFS. macOS provides mature native APFS image tooling; Linux does not.

This fork therefore uses:

- `linux-apfs/linux-apfs-rw` — experimental APFS kernel driver
- `linux-apfs/apfsprogs` — `mkapfs`
- Linux loop devices and ordinary tar/xattr handling

The builder **does not edit the stock ramdisk in place**. It creates a larger APFS image, copies the stock filesystem, injects the SSH payload, then packages the new image.

APFS write support is experimental and must be considered a device-testing stage, not a guarantee of a bootable image.

## Important limitations

- A12/A13 only; patchfinder coverage is tied to upstream usbliter8 research.
- SEP is not bypassed by this project.
- This is a tethered research workflow.
- IM4M resources are firmware/chip specific; replace the downloaded resources with your own valid ticket when required.
- Linux filesystem metadata handling cannot perfectly reproduce every Apple-specific filesystem feature.

## Options

```
--kernel patched|stock
--use-ibss
--no-ssh
--no-fw
--dry-run
```

## Credits

- **bunnyciaa/BUNNY-RAMDISK-BUILDER** — original builder
- **Leeksov/usbliter8ra1n** — A12/A13 patchfinders
- **blacktop/ipsw** — IPSW/IMG4 tooling
- **libimobiledevice/libirecovery** — Linux USB recovery transport
- **CRKatri/trustcache** — trustcache tooling
- **linux-apfs/linux-apfs-rw** — experimental APFS Linux filesystem driver
- **linux-apfs/apfsprogs** — APFS userspace tooling
- **strawhatdev01/Strawhat-Ramdisk** — Linux-independent APFS/ramdisk workflow reference

Use only on devices you own or are authorized to research.
