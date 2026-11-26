#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a copy of a Windows ISO with the virtio-win drivers built in and the guest tools
    installed at the end of Windows Setup.
.DESCRIPTION
    Adds the storage and network drivers to boot.wim (WinPE and Setup), all drivers to every
    edition of install.wim and the storage and network drivers to their WinRE. The guest tools are
    installed by SetupComplete.cmd, or at the first logon when Setup skips it (OEM product key).
    The Windows ISO stays unchanged. Uses DISM and IMAPI2 from Windows, no ADK needed; runs on
    Windows 10 / Server 2016 or later with Desktop Experience (Server Core has no IMAPI2).
.PARAMETER WindowsIso
    Windows ISO (Windows 7 / Server 2008 R2 up to Windows 11 / Server 2025, x86 or x64; Windows 8 /
    8.1 and Server 2012 / 2012 R2 need -VirtioVersion 0.1.215).
.PARAMETER OutputIso
    New ISO; must not exist.
.PARAMETER VirtioPath
    virtio-win ISO, folder with virtio-win-<version>.iso files, or the root of a virtio-win drive.
    Without it the ISO is downloaded from the Fedora project.
.PARAMETER VirtioVersion
    stable (default), latest or a version such as 0.1.271: what to download, or which ISO to take
    from a folder (stable and latest: the highest version there). Windows 8 / 8.1 and Server
    2012 / 2012 R2: 0.1.215.
.PARAMETER WorkPath
    Working folder; needs about three times the size of the Windows ISO. Default: %TEMP%.
.PARAMETER NoGuestTools
    Only the drivers, no guest tools.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WindowsIso,
    [Parameter(Mandatory = $true)][string]$OutputIso,
    [string]$VirtioPath,
    [string]$VirtioVersion = 'stable',
    [string]$WorkPath = $env:TEMP,
    [switch]$NoGuestTools
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'VirtIOForge.psm1')

$win = $null; $vio = $null; $iso = $null; $writing = $false
$work = Join-Path $WorkPath ('VirtIOForge-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
try {
    Write-VfLog "--- New-VirtIOMedia $WindowsIso -> $OutputIso"
    if (-not (Test-Path -LiteralPath $WindowsIso -PathType Leaf)) { throw "File not found: $WindowsIso" }
    if (Test-Path -LiteralPath $OutputIso) { throw "Output exists: $OutputIso" }
    $out = [IO.Path]::GetFullPath($OutputIso)
    if (-not (Test-Path -LiteralPath (Split-Path $out -Parent))) { throw "Folder not found: $(Split-Path $out -Parent)" }

    $need = 3 * (Get-Item -LiteralPath $WindowsIso).Length
    $free = Get-VfFreeSpace $WorkPath
    if ($free -lt $need) { throw ('Not enough space in {0}: {1:N1} GB free, {2:N1} GB needed.' -f $WorkPath, ($free / 1GB), ($need / 1GB)) }

    $vio = Open-VfVirtio $VirtioPath $VirtioVersion
    $win = Mount-VfIso $WindowsIso
    $media = Join-Path $work 'media'
    if ((Test-Path -LiteralPath (Join-Path $win.Root 'x86')) -and (Test-Path -LiteralPath (Join-Path $win.Root 'x64'))) {
        throw 'Media with both x86 and x64 is not supported; use a single-architecture ISO.'
    }
    if (-not $NoGuestTools) {
        foreach ($f in 'autounattend.xml', 'sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd') {
            if (Test-Path -LiteralPath (Join-Path $win.Root $f)) { throw "The Windows media already contains $f; use -NoGuestTools." }
        }
    }

    Write-VfLog "Copying $($win.Root) to $media"
    New-Item -ItemType Directory -Force -Path $media | Out-Null
    $r = Invoke-VfNative 'robocopy.exe' @($win.Root, $media, '/E', '/A-:R', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($r.ExitCode -ge 8) { throw "robocopy failed ($($r.ExitCode)): $($r.Output -join ' ')" }
    Dismount-VfIso $win
    $label = $win.Label
    $win = $null

    $sources = Join-Path $media 'sources'
    $wim = Join-Path $sources 'install.wim'
    $esd = Join-Path $sources 'install.esd'
    if (Test-Path -LiteralPath $esd) {
        Write-VfLog 'Converting install.esd to install.wim'
        foreach ($i in Get-WindowsImage -ImagePath $esd) {
            Export-WindowsImage -SourceImagePath $esd -SourceIndex $i.ImageIndex -DestinationImagePath $wim -CompressionType Max | Out-Null
        }
        Remove-Item -LiteralPath $esd -Force
    }
    if (-not (Test-Path -LiteralPath $wim)) { throw "No install.wim or install.esd in $sources" }

    $first = Get-WindowsImage -ImagePath $wim -Index 1
    # DISM of current Windows needs SSShim.dll of the old WAIK for 6.0 images
    if ([version]$first.Version -lt [version]'6.1') { throw "Windows $($first.Version) (Vista / Server 2008) cannot be serviced with the DISM of current Windows; Windows 7 / Server 2008 R2 or later needed." }
    $server = Test-VfServerImage $first
    $arch = Get-VfArch $first.Architecture
    $root = $vio.Root
    $select = { param($info) Find-VfDriverDirs $root (Get-VfWindowsFolder ([version]$info.Version) (Test-VfServerImage $info)) (Get-VfArch $info.Architecture) }
    $selectBoot = { param($info) Find-VfDriverDirs $root (Get-VfWindowsFolder ([version]$info.Version) $server) (Get-VfArch $info.Architecture) (Get-VfBootDrivers) }
    # Windows Setup does not load test-signed drivers
    $storage = @()
    try { $storage = @(& $selectBoot $first | Where-Object { @('viostor', 'vioscsi') -contains $_.Name }) } catch { }
    if (-not $storage) { throw 'virtio-win has no release-signed storage driver for this Windows (Windows 8 / 8.1, Server 2012 / 2012 R2: development-signed only), so Setup would not see a virtio disk. Use -VirtioVersion 0.1.215 (release-signed drivers for these versions).' }

    Write-VfLog 'install.wim: all drivers, WinRE: storage and network'
    Update-VfWim -Path $wim -Select $select -WorkPath $work -WinRE
    Write-VfLog 'boot.wim: storage and network'
    Update-VfWim -Path (Join-Path $sources 'boot.wim') -Select $selectBoot -WorkPath $work

    if (-not $NoGuestTools -and (Test-VfGuestToolsSupported ([version]$first.Version))) { New-VfGuestToolsFiles $media $root $arch }

    Write-VfLog "Building $out"
    $iso = New-VfIsoImage $media $label
    $writing = $true
    $n = Save-VfIso $iso $out
    $writing = $false
    Write-VfLog ('ISO written: {0} ({1:N1} GB), virtio-win {2}' -f $out, ($n / 1GB), $vio.Version)
    exit 0
} catch {
    Write-VfLog "ERROR: $($_.Exception.Message)"
    exit 1
} finally {
    # IMAPI2 keeps the added files open until the image object is released
    $iso = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    foreach ($m in Get-WindowsImage -Mounted | Where-Object { $_.Path -like "$work\*" }) {
        Dismount-WindowsImage -Path $m.Path -Discard | Out-Null
    }
    if ($win) { Dismount-VfIso $win }
    Close-VfVirtio $vio
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    if ($writing -and (Test-Path -LiteralPath $OutputIso)) { Remove-Item -LiteralPath $OutputIso -Force }
}
