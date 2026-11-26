<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-header-dark.svg">
  <img align="right" src="assets/logo-header.svg" alt="VirtIOForge logo" width="140">
</picture>

<h1>VirtIOForge for Windows</h1>

[![Build](https://github.com/motwok/VirtIOForge4Windows/actions/workflows/build.yml/badge.svg?branch=master)](https://github.com/motwok/VirtIOForge4Windows/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/motwok/VirtIOForge4Windows)](https://github.com/motwok/VirtIOForge4Windows/releases/latest)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Server%20Core-blue)
![Coverage](https://img.shields.io/badge/coverage-100%25-brightgreen)
![PowerShell](https://img.shields.io/badge/PowerShell-2.0%20%7C%205.1-blue)
![Hypervisor](https://img.shields.io/badge/hypervisor-KVM%20%7C%20QEMU%20%7C%20libvirt-blueviolet)
[![License](https://img.shields.io/github/license/motwok/VirtIOForge4Windows)](LICENSE)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20Me-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/motwok)

PowerShell scripts that prepare Windows for KVM/QEMU/libvirt with the
[virtio-win](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/) drivers and guest tools:

| Mode | What |
|---|---|
| Prepare a Windows ISO | add all virtio-win drivers to `boot.wim`, `install.wim` and WinRE, install the guest tools during Setup, build a new bootable ISO (BIOS + UEFI) |
| Add drivers to a running Windows | install the virtio-win drivers, update WinRE, install the guest tools |
| Update a running Windows | install a newer virtio-win version of drivers and guest tools, update WinRE |

**Status:** in development, no release yet.

## Supported Windows versions

| Mode | Windows versions | Runs on |
|---|---|---|
| Prepare a Windows ISO | Windows 7 / Server 2008 R2 up to Windows 11 / Server 2025 | Windows 10 / Server 2016 or later with Desktop Experience (PowerShell 5.1) |
| Add or update drivers in a running Windows | Windows 7 / Server 2008 R2 up to Windows 11 / Server 2025 | the Windows itself (PowerShell 2.0 or later) |

For Windows 7 / Server 2008 R2 and older, virtio-win ships older driver versions that are no longer
updated, and its guest tools need Windows 10 / Server 2016 or later: for older Windows only the
drivers are installed. Windows Vista / Server 2008 images cannot be prepared: the DISM of current
Windows no longer services them. Windows XP and Server 2003 are not supported; support for them may
come in a version 2.0 if there is interest.

Drivers that virtio-win signs only with its development certificate are left out: they need test
signing. Currently these are `smbus` and all drivers for Windows 8 / 8.1 and Server 2012 / 2012 R2.
For these Windows versions use `-VirtioVersion 0.1.215`: its drivers for them are release-signed by
Red Hat. Without `-VirtioPath` or a version number the scripts stop there with this hint; in a
running Windows, `-AllowTestSigned` installs the current development-signed drivers instead (see
below). Only the drivers listed in `data\info.json` of the virtio-win ISO are used.

Packages whose INF names a file that is missing from their virtio-win folder are skipped (for example
`fwcfg` of 0.1.215 for Windows 8 / Server 2012 and `viofs` of 0.1.189 for Server 2012 R2).
Windows 8 / Server 2012 (not 8.1 / 2012 R2) does not get to the logon with a virtio display (QEMU
`virtio-vga`), with or without the virtio GPU driver (`viogpudo`): give these VMs a VGA display.
With 0.1.215 the "QEMU FwCfg Device" shows code 10 unless the VM has the `vmcoreinfo` device
(libvirt: `<vmcoreinfo state='on'/>` under `<features>`); it is only used for guest memory dumps
on the host, so the error is harmless.

## Requirements

- Built-in components only (Windows PowerShell, DISM, pnputil, IMAPI2); no Windows ADK, no
  third-party tools. Adding and updating drivers also runs on Windows Server Core; preparing an ISO
  needs a Windows with Desktop Experience (Server Core has no IMAPI2).
- Administrator rights.
- **No Windows or virtio-win files are included in this repository or the release.** The virtio-win
  ISO is downloaded from the Fedora project or taken from a file you provide.

## virtio-win source

All scripts take the same two parameters:

| Parameter | Meaning |
|---|---|
| `-VirtioPath` | a virtio-win ISO, a folder with `virtio-win-<version>.iso` files, or the root of a virtio-win drive (for example `D:\` with the ISO inserted as CD) |
| `-VirtioVersion` | `stable` (default), `latest` or a version such as `0.1.271`: what to download without `-VirtioPath`, or which ISO to take from a folder |

The version is read from the volume label of the ISO. Downloads go to `%ProgramData%\VirtIOForge\download`.

## Prepare a Windows ISO

Run as administrator on Windows 10 / Server 2016 or later with Desktop Experience:

```powershell
.\New-VirtIOMedia.ps1 -WindowsIso D:\Win11.iso -OutputIso D:\Win11-virtio.iso [-VirtioPath D:\virtio-win.iso] [-NoGuestTools]
```

- Storage and network drivers (viostor, vioscsi, NetKVM) go into both images of `boot.wim`, so
  Setup sees a virtio disk without "Load driver". All drivers of the matching virtio-win folder go
  into every edition of `install.wim`, the storage and network drivers into its WinRE.
- The guest tools are installed by `SetupComplete.cmd` at the end of Setup. Setup skips that file
  when Windows is installed with an OEM product key; then they are installed at the first logon
  (`autounattend.xml` with only this command, the Setup dialogs stay as they are). Media that
  already has an `autounattend.xml` or `SetupComplete.cmd` needs `-NoGuestTools`.
- `install.esd` is converted to `install.wim`. The Windows ISO stays unchanged. The working folder
  (`-WorkPath`, default `%TEMP%`) needs about three times the size of the ISO.
- Windows 11 needs TPM 2.0 and Secure Boot in the VM, as on real hardware.

## Add drivers to a running Windows

Run as administrator in the VM:

```powershell
powershell -ExecutionPolicy Bypass -File Install-VirtIO.ps1 [-VirtioPath D:\] [-NoGuestTools] [-NoWinRE] [-AsTask] [-AllowTestSigned [-Force]]
```

Installs every driver of the matching virtio-win folder with `pnputil`, adds the storage and
network drivers to WinRE (`reagentc` and DISM) and installs the guest tools. Exit code 3010: restart
needed.

Drivers not signed by Microsoft (the Windows 7 / 8 folders) would stop at "Install this device
software?". The script adds their signer (Red Hat) to the trusted publishers of the computer, as
"Always trust software from Red Hat" does; it stays there.

**Development-signed drivers (current virtio-win for Windows 8 / 8.1, Server 2012 / 2012 R2):**
`-AllowTestSigned` installs them as well. Prefer `-VirtioVersion 0.1.215`, which needs none of this.
After a detailed warning and a confirmation (`-Force` skips only the question) the
script adds the virtio-win development certificate to the trusted root certification authorities
and turns on test signing mode (`bcdedit /set testsigning on`); the drivers load after a restart.
Windows then loads every test-signed driver and shows "Test Mode". Secure Boot must be off; WinRE
gets no test-signed drivers. Turning test signing off later stops these drivers; with the system
disk on virtio, Windows then no longer starts.

virtio-win ships these INFs with LF line ends while their catalogs cover the CRLF files; the script
installs them from a CRLF copy. That works for storage (viostor, vioscsi), network (NetKVM) and display
(viogpudo). The INFs of the other drivers (Balloon, vioserial, viorng, vioinput, pvpanic, fwcfg,
viofs) differ from what was signed. For these the script writes a new catalog over the package
files and signs it with a code signing certificate it creates on the computer, adds that
certificate to the trusted root certification authorities and trusted publishers, and deletes its
private key after signing (the warning says so too). Such certificates of earlier runs are removed
again once no driver package in the driver store is signed with them.

**Switching the system disk to virtio:** `pnputil` only stages viostor and vioscsi; Windows creates
the boot service when it sees such a device once. Attach a small extra virtio disk, boot once, then
switch the system disk. Otherwise Windows stops with `INACCESSIBLE_BOOT_DEVICE`. With the
development-signed viostor of Server 2012 R2 the system disk must be the first virtio disk: as the
second one, Windows hangs at boot (a driver issue; 0.1.215 does not have it).

On Windows 7 / Server 2008 R2 an ISO file cannot be mounted: insert the virtio-win ISO as CD and pass
the drive. Downloading needs TLS 1.2, which Windows 7 has only with updates.

## Update a running Windows

```powershell
powershell -ExecutionPolicy Bypass -File Update-VirtIO.ps1 [-VirtioPath D:\] [-RemoveOld] [-AsTask] [-AllowTestSigned [-Force]]
```

Windows replaces a driver only with a newer one and never downgrades. `-RemoveOld` removes older
virtio-win driver packages from the driver store that no device uses. The NetKVM update interrupts
the network briefly: over RDP or WinRM use `-AsTask`, which runs the update as a scheduled task
(SYSTEM). viostor and vioscsi of the system disk are usually active after a restart.

Log: `%ProgramData%\VirtIOForge\VirtIOForge.log`.

## Disclaimer

Use at your own risk. A new ISO built from your Windows media contains Microsoft files: keep it to
yourself. Not affiliated with or endorsed by Microsoft, Red Hat or the Fedora Project.

## Help and contributing

- Questions and problems: [SUPPORT.md](SUPPORT.md)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md), [Code of Conduct](CODE_OF_CONDUCT.md)
- Security issues: [SECURITY.md](SECURITY.md) (private reporting)

## License

Copyright (c) Emmo Emminghaus. Licensed under the [GNU AGPL v3](LICENSE); see also [NOTICE](NOTICE).

## Support Me

VirtIOForge is free and open source. If it saves you some trouble, you can support it:
[Buy Me a Coffee](https://ko-fi.com/motwok)
