<#
.SYNOPSIS
    Installs the virtio-win drivers and guest tools into the running Windows and adds the storage
    and network drivers to its WinRE.
.DESCRIPTION
    Runs on Windows PowerShell 2.0 and later (Windows 7 / Server 2008 R2 up to Windows 11 /
    Server 2025). Exit code 0, 3010 (restart needed) or 1.
    Before switching the system disk from IDE/SATA to virtio: pnputil only stages viostor and
    vioscsi; Windows creates the boot service when it sees the device once. Attach a small extra
    virtio disk, boot once, then switch the system disk. Otherwise: INACCESSIBLE_BOOT_DEVICE.
.PARAMETER VirtioPath
    Root of a virtio-win drive (for example D:\ with the ISO inserted as CD), a virtio-win ISO file
    (Windows 8 / Server 2012 and later) or a folder with virtio-win-<version>.iso files.
    Without it the ISO is downloaded from the Fedora project (needs TLS 1.2).
.PARAMETER VirtioVersion
    stable (default), latest or a version such as 0.1.271. Windows 8 / 8.1 and Server 2012 /
    2012 R2: 0.1.215 (current versions are development-signed for them).
.PARAMETER NoGuestTools
    Only the drivers.
.PARAMETER NoWinRE
    Leave WinRE unchanged.
.PARAMETER AllowTestSigned
    Also install the drivers that virtio-win signs only with its development certificate (Windows 8 /
    8.1 and Server 2012 / 2012 R2: all of them): trusts that certificate and turns on test signing
    mode. Packages whose files do not match their catalog get a new catalog, signed with a
    certificate created and trusted on this computer (its private key is deleted afterwards). Needs
    Secure Boot off. Shows a detailed warning and asks before changing anything.
.PARAMETER Force
    With -AllowTestSigned: do not ask (unattended use); the warning is still shown.
.PARAMETER AsTask
    Run as a scheduled task (SYSTEM), so that the network interruption of the NetKVM installation
    does not stop it when started over RDP or WinRM. Output goes to the log.
#>
param(
    [string]$VirtioPath,
    [string]$VirtioVersion = 'stable',
    [switch]$NoGuestTools,
    [switch]$NoWinRE,
    [switch]$AllowTestSigned,
    [switch]$Force,
    [switch]$AsTask,
    [switch]$FromTask
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'VirtIOForge.psm1')

$rc = 1
try {
    Assert-VfAdmin
    if ($AllowTestSigned -and -not $FromTask -and -not (Confirm-VfTestSigning -Force:$Force)) { throw 'Test signing not confirmed, nothing changed.' }
    if ($AsTask) {
        Register-VfTask $MyInvocation.MyCommand.Path (ConvertTo-VfArgs $PSBoundParameters)
        exit 0
    }
    Write-VfLog '--- Install-VirtIO'
    $rc = Invoke-VfOnline -VirtioPath $VirtioPath -VirtioVersion $VirtioVersion -NoGuestTools:$NoGuestTools -NoWinRE:$NoWinRE -AllowTestSigned:$AllowTestSigned
} catch {
    Write-VfLog "ERROR: $($_.Exception.Message)"
    $rc = 1
} finally {
    if ($FromTask) { Unregister-VfTask }
}
exit $rc
