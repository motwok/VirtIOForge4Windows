# Shared functions of the VirtIOForge scripts.
# Must parse and run on Windows PowerShell 2.0 (Windows 7 / Server 2008 R2): no [pscustomobject],
# no -in/-notin, no ConvertFrom-Json, no Invoke-WebRequest, no Get-CimInstance.

$script:Product = 'VirtIOForge'
$script:BaseUrl = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/'
# storage and network: enough for Windows Setup, WinPE and WinRE
$script:BootDrivers = @('viostor', 'vioscsi', 'NetKVM')
$script:Signed = @{}
# INF path -> signer certificate of the packages taken with -AllowTestSigned
$script:TestSigned = @{}
$script:AllowTestSigned = $false
# certificate (with key) that signs the new catalogs of this run
$script:OwnCert = $null
$script:OwnCertName = 'CN=VirtIOForge local driver signing'
$script:CertStore = 'LocalMachine'
$script:RootStore = 'Root'

function Get-VfBootDrivers { $script:BootDrivers }

# ---------------------------------------------------------------- log, run

function Get-VfDataDir {
    $base = $env:ProgramData
    if (-not $base) { $base = Join-Path $env:ALLUSERSPROFILE 'Application Data' }
    $d = Join-Path $base $script:Product
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $d
}

function Write-VfLog {
    param([string]$Message)
    Write-Host $Message
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath (Join-Path (Get-VfDataDir) 'VirtIOForge.log') -Value $line -Encoding ASCII } catch { }
}

function Invoke-VfNative {
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$ArgumentList = @())
    # native tools write progress to stderr; with 'Stop' that would be an error
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& $FilePath $ArgumentList 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $eap }
    New-Object PSObject -Property @{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Get-VfWindowsDir { $env:windir }

function Get-VfFreeSpace {
    param([Parameter(Mandatory = $true)][string]$Path)
    (New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)))).AvailableFreeSpace
}

function Test-VfAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-VfAdmin {
    if (-not (Test-VfAdmin)) { throw 'Run this script as administrator.' }
}

# ---------------------------------------------------------------- Windows version -> virtio-win folder

function Get-VfWindowsFolder {
    param([Parameter(Mandatory = $true)][version]$Version, [Parameter(Mandatory = $true)][bool]$Server)
    $v = '{0}.{1}' -f $Version.Major, $Version.Minor
    $b = $Version.Build
    switch ($v) {
        '6.0' { return '2k8' }
        '6.1' { if ($Server) { return '2k8R2' } else { return 'w7' } }
        '6.2' { if ($Server) { return '2k12' } else { return 'w8' } }
        '6.3' { if ($Server) { return '2k12R2' } else { return 'w8.1' } }
        '10.0' {
            if (-not $Server) { if ($b -ge 22000) { return 'w11' } else { return 'w10' } }
            if ($b -ge 26100) { return '2k25' }
            if ($b -ge 20348) { return '2k22' }
            if ($b -ge 17763) { return '2k19' }
            return '2k16'
        }
    }
    throw "Windows version $Version is not supported."
}

function Get-VfArch {
    param([Parameter(Mandatory = $true)]$Value)
    switch ("$Value") {
        '0' { return 'x86' }
        'x86' { return 'x86' }
        '9' { return 'amd64' }
        'amd64' { return 'amd64' }
        'x64' { return 'amd64' }
    }
    throw "Architecture $Value is not supported."
}

function Get-VfOsInfo {
    $os = Get-WmiObject Win32_OperatingSystem
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    New-Object PSObject -Property @{
        Version = [version]$os.Version
        Server  = ([int]$os.ProductType -ne 1)
        Arch    = (Get-VfArch $arch)
    }
}

# ---------------------------------------------------------------- virtio-win source

function Get-VfVersionFromText {
    param([string]$Text)
    if ($Text -match 'virtio-win-(\d+\.\d+\.\d+)') { return $Matches[1] }
    $null
}

function Test-VfVirtioRoot {
    param([string]$Path)
    (Test-Path -LiteralPath (Join-Path $Path 'viostor')) -and (Test-Path -LiteralPath (Join-Path $Path 'NetKVM'))
}

function Get-VfVolumeLabel {
    param([string]$Root)
    if ($Root -notmatch '^([A-Za-z]:)\\?$') { return $null }
    $d = Get-WmiObject Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $Matches[1].ToUpper())
    if ($d) { return $d.VolumeName }
    $null
}

function Test-VfCanMountIso { [bool](Get-Command Mount-DiskImage -ErrorAction SilentlyContinue) }

function Mount-VfIso {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-VfCanMountIso)) {
        throw 'This Windows version cannot mount ISO files. Insert the ISO as a CD drive and pass the drive, for example D:\.'
    }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $d = Mount-DiskImage -ImagePath $full -Access ReadOnly -StorageType ISO -PassThru
    $v = $d | Get-Volume
    $root = '{0}:\' -f $v.DriveLetter
    Wait-VfDrive $root
    New-Object PSObject -Property @{ Root = $root; Label = $v.FileSystemLabel; ImagePath = $full }
}

function Wait-VfDrive {
    # the drive of a just mounted ISO, also for the PowerShell cmdlets (Server 2016)
    param([Parameter(Mandatory = $true)][string]$Root)
    for ($n = 0; $n -lt 60 -and -not [IO.Directory]::Exists($Root); $n++) { Start-Sleep -Milliseconds 500 }
    # Join-Path fails on a drive PowerShell has not seen yet; Get-PSDrive adds it
    Get-PSDrive -PSProvider FileSystem | Out-Null
}

function Dismount-VfIso {
    param($Iso)
    if ($Iso -and $Iso.ImagePath) { Dismount-DiskImage -ImagePath $Iso.ImagePath | Out-Null }
}

function Add-VfTls12 { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 }

function Enable-VfTls12 {
    try { Add-VfTls12 }
    catch { throw 'TLS 1.2 is not available in this .NET version; download the virtio-win ISO elsewhere and pass it with -VirtioPath.' }
}

function Get-VfWebText {
    param([Parameter(Mandatory = $true)][string]$Url)
    $wc = New-Object Net.WebClient
    try { $wc.DownloadString($Url) } finally { $wc.Dispose() }
}

function Save-VfWebFile {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Path)
    $tmp = "$Path.part"
    $wc = New-Object Net.WebClient
    try { $wc.DownloadFile($Url, $tmp) } finally { $wc.Dispose() }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path
}

function Get-VfLinks {
    param([string]$Html)
    $r = @()
    foreach ($m in [regex]::Matches($Html, 'href="([^"?]+)"')) { $r += $m.Groups[1].Value }
    $r
}

function Resolve-VfDownloadUrl {
    param([Parameter(Mandatory = $true)][string]$Version)
    if ($Version -eq 'stable' -or $Version -eq 'latest') { return '{0}{1}-virtio/virtio-win.iso' -f $script:BaseUrl, $Version }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid virtio-win version: $Version (stable, latest or for example 0.1.271)." }
    $archive = $script:BaseUrl + 'archive-virtio/'
    $esc = [regex]::Escape($Version)
    $dirs = @(Get-VfLinks (Get-VfWebText $archive) | Where-Object { $_ -match "virtio-win-$esc(-[^/]*)?/$" } | Sort-Object)
    if (-not $dirs) { throw "virtio-win $Version not found in $archive" }
    $dir = Resolve-VfLink $archive $dirs[-1]
    $isos = @(Get-VfLinks (Get-VfWebText $dir) | Where-Object { $_ -match '\.iso$' })
    $iso = @($isos | Where-Object { $_ -match "virtio-win-$esc\.iso$" })
    if (-not $iso) { $iso = @($isos | Where-Object { $_ -match '(^|/)virtio-win\.iso$' }) }
    if (-not $iso) { throw "No virtio-win ISO found in $dir" }
    Resolve-VfLink $dir $iso[0]
}

function Resolve-VfLink {
    param([Parameter(Mandatory = $true)][string]$Base, [Parameter(Mandatory = $true)][string]$Link)
    (New-Object Uri((New-Object Uri($Base)), $Link)).AbsoluteUri
}

function Find-VfIsoInFolder {
    param([Parameter(Mandatory = $true)][string]$Folder, [string]$Version)
    $all = @(Get-ChildItem -LiteralPath $Folder -Filter 'virtio-win-*.iso' | Where-Object { Get-VfVersionFromText $_.Name })
    if (-not $all) { throw "No virtio-win-<version>.iso in $Folder" }
    if ($Version -and $Version -ne 'stable' -and $Version -ne 'latest') {
        $hit = @($all | Where-Object { (Get-VfVersionFromText $_.Name) -eq $Version })
        if (-not $hit) { throw "virtio-win-$Version.iso not found in $Folder" }
        return $hit[0].FullName
    }
    ($all | Sort-Object { [version](Get-VfVersionFromText $_.Name) } | Select-Object -Last 1).FullName
}

function Open-VfVirtio {
    # -Path: ISO file, folder with virtio-win-<version>.iso files, or the root of a virtio-win
    # drive/folder. Without -Path the ISO is downloaded (-Version stable, latest or 0.1.xxx).
    param([string]$Path, [string]$Version = 'stable')
    $iso = $null
    $root = $null
    $label = $null
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Not found: $Path" }
        if (Test-Path -LiteralPath $Path -PathType Leaf) { $iso = $Path }
        elseif (Test-VfVirtioRoot $Path) { $root = $Path; $label = Get-VfVolumeLabel $Path }
        else { $iso = Find-VfIsoInFolder $Path $Version }
    } else {
        Enable-VfTls12
        $url = Resolve-VfDownloadUrl $Version
        $dl = Join-Path (Get-VfDataDir) 'download'
        if (-not (Test-Path -LiteralPath $dl)) { New-Item -ItemType Directory -Force -Path $dl | Out-Null }
        $name = $url.Split('/')[-1]
        if ($name -eq 'virtio-win.iso') { $name = "virtio-win-$Version.iso" }
        $iso = Join-Path $dl $name
        Write-VfLog "Downloading $url"
        Save-VfWebFile $url $iso
        # stable and latest are called virtio-win.iso: name the file after its version
        $m = Mount-VfIso $iso
        $v = Get-VfVersionFromText $m.Label
        Dismount-VfIso $m
        if ($v) {
            $final = Join-Path $dl "virtio-win-$v.iso"
            if ($final -ne $iso) {
                try {
                    if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Force -ErrorAction Stop }
                    Move-Item -LiteralPath $iso -Destination $final -ErrorAction Stop
                    $iso = $final
                } catch {
                    # the older file can still be mounted
                    Write-VfLog "  kept $(Split-Path $iso -Leaf): $(Split-Path $final -Leaf) is in use"
                }
            }
        }
    }
    $mounted = $null
    if ($iso) {
        $mounted = Mount-VfIso $iso
        $root = $mounted.Root
        $label = $mounted.Label
        if (-not (Test-VfVirtioRoot $root)) { Dismount-VfIso $mounted; throw "Not a virtio-win ISO: $iso" }
    }
    $ver = Get-VfVersionFromText $label
    if (-not $ver -and $iso) { $ver = Get-VfVersionFromText (Split-Path $iso -Leaf) }
    if (-not $ver) { $ver = 'unknown' }
    Write-VfLog "virtio-win $ver from $root"
    New-Object PSObject -Property @{ Root = $root; Version = $ver; Mounted = $mounted }
}

function Close-VfVirtio {
    param($Virtio)
    if ($Virtio) { Dismount-VfIso $Virtio.Mounted }
}

function Get-VfInfoList {
    # INF paths (driver/windows/arch/name.inf, lower case) from data\info.json; $null without it.
    # Folders such as qemupciserial or sriov exist on the ISO but are not listed there.
    param([Parameter(Mandatory = $true)][string]$Root)
    $f = Join-Path $Root 'data\info.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $r = @()
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f), '"inf_path"\s*:\s*"([^"]+)"')) { $r += $m.Groups[1].Value.Replace('\\', '/').Replace('\', '/').ToLower() }
    , $r
}

function Test-VfSignedInf {
    # some packages are signed only with the virtio-win development certificate; they need test
    # signing, so they are skipped unless -AllowTestSigned
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($script:Signed.ContainsKey($Path)) { return $script:Signed[$Path] }
    $script:Signed[$Path] = Test-VfSignedInfOnce $Path
    $script:Signed[$Path]
}

function Get-VfCatalogSignature {
    param([Parameter(Mandatory = $true)][string]$Path)
    Get-AuthenticodeSignature -FilePath $Path
}

function Test-VfSignedInfOnce {
    param([Parameter(Mandatory = $true)][string]$Path)
    $i = Get-VfInfInfo $Path
    $miss = @(Get-VfMissingFiles $Path)
    if ($miss) { Write-VfLog "  skipped $($i.Name): virtio-win lacks $($miss -join ', ')"; return $false }
    $cat = $null
    if ($i.Catalog) { $cat = Join-Path (Split-Path $Path -Parent) $i.Catalog }
    if (-not $cat -or -not (Test-Path -LiteralPath $cat)) { Write-VfLog "  skipped $($i.Name): no catalog"; return $false }
    $s = Get-VfCatalogSignature $cat
    $st = "$($s.Status)"
    # the development certificate is self-signed; once trusted as root (-AllowTestSigned) it is Valid
    if ($s.SignerCertificate.Subject -and $s.SignerCertificate.Subject -eq $s.SignerCertificate.Issuer) { $st = 'self-signed' }
    if ($st -eq 'Valid') { return $true }
    if ($script:AllowTestSigned -and $s.SignerCertificate) {
        $script:TestSigned[$Path] = $s.SignerCertificate
        Write-VfLog "  test-signed $($i.Name): $($s.SignerCertificate.Subject)"
        return $true
    }
    Write-VfLog "  skipped $($i.Name): catalog signature $st ($($s.SignerCertificate.Subject))"
    $false
}

function Get-VfMissingFiles {
    # files of [SourceDisksFiles] missing next to the INF (fwcfg of 0.1.215 for Windows 8 / Server 2012)
    param([Parameter(Mandatory = $true)][string]$Path)
    $dir = Split-Path $Path -Parent
    $in = $false
    $r = @()
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        $l = ($l -replace ';.*$', '').Trim()
        if ($l -match '^\[(.+)\]$') { $in = $Matches[1] -match '^SourceDisksFiles(\..+)?$'; continue }
        if ($in -and $l -match '^([^=\s]+)\s*=' -and -not (Test-Path -LiteralPath (Join-Path $dir $Matches[1]))) { $r += $Matches[1] }
    }
    $r
}

function Find-VfDriverDirs {
    # every driver of virtio-win for <windows>\<arch>: as listed in data\info.json, or (older ISOs)
    # every folder <driver>\<windows>\<arch> with an INF
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][string]$Arch, [string[]]$Only)
    $list = Get-VfInfoList $Root
    $r = @()
    foreach ($d in Get-ChildItem -LiteralPath $Root | Where-Object { $_.PSIsContainer } | Sort-Object Name) {
        if ($Only -and -not ($Only -contains $d.Name)) { continue }
        $p = Join-Path $d.FullName (Join-Path $Folder $Arch)
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $infs = @(Get-ChildItem -LiteralPath $p -Filter '*.inf')
        if ($null -ne $list) { $infs = @($infs | Where-Object { $list -contains ('{0}/{1}/{2}/{3}' -f $d.Name, $Folder, $Arch, $_.Name).ToLower() }) }
        $infs = @($infs | Where-Object { Test-VfSignedInf $_.FullName })
        if ($infs) { $r += New-Object PSObject -Property @{ Name = $d.Name; Path = $p; Infs = $infs } }
    }
    if (-not $r) { throw "virtio-win has no drivers for $Folder $Arch." }
    $r
}

function Select-VfReleaseSigned {
    # the driver folders without the test-signed packages
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$Dirs)
    $r = @()
    foreach ($d in $Dirs) {
        $infs = @($d.Infs | Where-Object { -not $script:TestSigned.ContainsKey($_.FullName) })
        if ($infs) { $r += New-Object PSObject -Property @{ Name = $d.Name; Path = $d.Path; Infs = $infs } }
    }
    $r
}

function Test-VfGuestToolsSupported {
    # virtio-win-gt*.msi refuses older Windows ("OS must be Windows 10 or higher"), the guest agent
    # service does not start on Windows 7
    param([Parameter(Mandatory = $true)][version]$Version)
    if ($Version.Major -ge 10) { return $true }
    Write-VfLog "Guest tools of virtio-win need Windows 10 / Server 2016 or later, skipped for $Version."
    $false
}

function Get-VfGuestTools {
    # installer of the guest tools for the architecture; $null if the ISO has none
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Arch)
    $names = @{ amd64 = @('virtio-win-guest-tools.exe'); x86 = @('virtio-win-gt-x86.msi', 'guest-agent\qemu-ga-i386.msi') }
    $r = @()
    foreach ($n in $names[$Arch]) {
        $p = Join-Path $Root $n
        if (Test-Path -LiteralPath $p) { $r += (Get-Item -LiteralPath $p) }
    }
    $r
}

# ---------------------------------------------------------------- running Windows

function Test-VfNewPnputil {
    param([Parameter(Mandatory = $true)][version]$Version)
    # /add-driver and /delete-driver exist from Windows 10 1607 on
    $Version.Major -ge 10 -and $Version.Build -ge 14393
}

function Add-VfDriverOnline {
    param([Parameter(Mandatory = $true)][string]$Inf, [Parameter(Mandatory = $true)][version]$Version)
    if (Test-VfNewPnputil $Version) { $a = @('/add-driver', $Inf, '/install') } else { $a = @('-i', '-a', $Inf) }
    $r = Invoke-VfNative 'pnputil.exe' $a
    # 259: added, but no device uses it
    $ok = @(0, 259, 3010) -contains $r.ExitCode
    if (-not $ok) { Write-VfLog ($r.Output -join "`r`n") }
    New-Object PSObject -Property @{ Inf = $Inf; ExitCode = $r.ExitCode; Ok = $ok; Reboot = ($r.ExitCode -eq 3010) }
}

function Test-VfInCatalog {
    # flat file hash (SHA1 or SHA256) of the file in a catalog of its folder
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][byte[]]$Bytes)
    $h = @()
    foreach ($a in @([Security.Cryptography.SHA1]::Create(), [Security.Cryptography.SHA256]::Create())) { $h += [BitConverter]::ToString($a.ComputeHash($Bytes)) }
    foreach ($c in Get-ChildItem -Path (Split-Path $Path -Parent) -Filter '*.cat') {
        $t = [BitConverter]::ToString([IO.File]::ReadAllBytes($c.FullName))
        foreach ($x in $h) { if ($t.Contains($x)) { return $true } }
    }
    $false
}

function Get-VfInstallInf {
    # virtio-win ships some INFs (Windows 8 / 8.1, Server 2012 / 2012 R2) with LF line ends, but
    # their catalog hashes the CRLF file: pnputil reports "hash not in catalog". A CRLF copy of the
    # package matches again. Others have mixed line ends and are signed as they are. Test-signed
    # packages that match in neither form get a new catalog signed with the local certificate.
    param([Parameter(Mandatory = $true)][string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if (Test-VfInCatalog $Path $b) { return $Path }
    $out = New-Object Collections.Generic.List[byte]
    $lf = $false
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $out.AddRange($b) }
    else {
        for ($i = 0; $i -lt $b.Length; $i++) {
            if ($b[$i] -eq 10 -and ($i -eq 0 -or $b[$i - 1] -ne 13)) { $out.Add(13); $lf = $true }
            $out.Add($b[$i])
        }
    }
    $crlf = $lf -and (Test-VfInCatalog $Path $out.ToArray())
    if (-not $crlf -and -not $script:TestSigned.ContainsKey($Path)) { return $Path }
    $dir = Join-Path (Get-VfDataDir) ('inf\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -Path (Join-Path (Split-Path $Path -Parent) '*') -Destination $dir -Recurse
    $new = Join-Path $dir (Split-Path $Path -Leaf)
    # read-only when copied from a CD
    foreach ($f in Get-ChildItem -LiteralPath $dir -Force) { $f.Attributes = 'Normal' }
    [IO.File]::WriteAllBytes($new, $out.ToArray())
    if ($crlf) { Write-VfLog "  $(Split-Path $Path -Leaf): LF line ends, installed from a CRLF copy" }
    else {
        New-VfPackageCatalog $new (Get-VfOwnCert)
        Write-VfLog "  $(Split-Path $Path -Leaf): does not match its catalog, installed with a new catalog signed by the local certificate"
    }
    $new
}

$script:CatalogApi = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class VfCatalog {
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Unicode)]
    delegate void ParseError(uint area, uint error, string line);
    [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CryptCATCDFOpen(string path, ParseError callback);
    [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CryptCATCDFEnumMembersByCDFTagEx(IntPtr cdf, IntPtr prev, ParseError callback, ref IntPtr member, bool continueOnError, IntPtr reserved);
    [DllImport("wintrust.dll", SetLastError = true)]
    static extern bool CryptCATCDFClose(IntPtr cdf);
    static List<string> errors;
    static void OnError(uint area, uint error, string line) { errors.Add(string.Format("0x{0:X} 0x{1:X} {2}", area, error, line)); }
    // writes the catalog that the CDF file describes; returns the parse errors
    public static string[] Make(string cdfPath) {
        errors = new List<string>();
        ParseError cb = new ParseError(OnError);
        IntPtr cdf = CryptCATCDFOpen(cdfPath, cb);
        if (cdf == IntPtr.Zero) { errors.Add("CryptCATCDFOpen " + Marshal.GetLastWin32Error()); return errors.ToArray(); }
        IntPtr tag = IntPtr.Zero;
        IntPtr member = IntPtr.Zero;
        do { tag = CryptCATCDFEnumMembersByCDFTagEx(cdf, tag, cb, ref member, true, IntPtr.Zero); } while (tag != IntPtr.Zero);
        if (!CryptCATCDFClose(cdf)) { errors.Add("CryptCATCDFClose " + Marshal.GetLastWin32Error()); }
        GC.KeepAlive(cb);
        return errors.ToArray();
    }
}
'@

function New-VfPackageCatalog {
    # replaces the catalog of a package copy with one over all its files, signed with $Certificate
    param([Parameter(Mandatory = $true)][string]$Inf, [Parameter(Mandatory = $true)]$Certificate)
    $dir = Split-Path $Inf -Parent
    $name = (Get-VfInfInfo $Inf).Catalog
    if (-not $name) { throw "$(Split-Path $Inf -Leaf) names no catalog file." }
    $cat = Join-Path $dir $name
    if (Test-Path -LiteralPath $cat) { Remove-Item -LiteralPath $cat -Force }
    $v = [Environment]::OSVersion.Version
    $cdf = @('[CatalogHeader]', "Name=$name", "ResultDir=$dir", 'PublicVersion=0x0000001', 'EncodingType=0x00010001',
        "CATATTR1=0x10010001:OSAttr:2:$($v.Major).$($v.Minor)", '[CatalogFiles]')
    foreach ($f in Get-ChildItem -LiteralPath $dir | Where-Object { -not $_.PSIsContainer }) { $cdf += "<hash>$($f.Name)=$($f.FullName)" }
    $cdfPath = "$dir.cdf"
    Set-Content -LiteralPath $cdfPath -Value $cdf -Encoding ASCII
    try {
        if (-not ('VfCatalog' -as [type])) { Add-Type -TypeDefinition $script:CatalogApi }
        $err = @([VfCatalog]::Make($cdfPath))
    } finally { Remove-Item -LiteralPath $cdfPath -Force }
    if ($err -or -not (Test-Path -LiteralPath $cat)) { throw "Catalog $name not created: $($err -join '; ')" }
    $s = Set-AuthenticodeSignature -FilePath $cat -Certificate $Certificate
    if ("$($s.Status)" -ne 'Valid') { throw "Signing $name failed: $($s.Status) $($s.StatusMessage)" }
}

function New-VfSigningCert {
    # self-signed code signing certificate, key in the machine store (CryptoAPI, so that .NET can
    # delete it again)
    $data = Get-VfDataDir
    $inf = Join-Path $data 'sign.inf'
    $cer = Join-Path $data 'sign.cer'
    $subject = $script:OwnCertName + ' ' + (Get-Date -Format 'yyyy-MM-dd HH-mm-ss')
    Set-Content -LiteralPath $inf -Encoding ASCII -Value @('[Version]', 'Signature="$Windows NT$"', '[NewRequest]',
        "Subject = `"$subject`"", 'RequestType = Cert', 'KeySpec = 2', 'KeyUsage = 0x80', 'KeyLength = 2048',
        'MachineKeySet = True', 'Exportable = False', 'HashAlgorithm = sha256',
        'ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"', 'ProviderType = 24',
        'ValidityPeriod = Years', 'ValidityPeriodUnits = 10', '[EnhancedKeyUsageExtension]', 'OID = 1.3.6.1.5.5.7.3.3')
    try {
        if (Test-Path -LiteralPath $cer) { Remove-Item -LiteralPath $cer -Force }
        $r = Invoke-VfNative 'certreq.exe' @('-new', '-q', $inf, $cer)
        if ($r.ExitCode -ne 0) { throw "certreq failed ($($r.ExitCode)): $($r.Output -join ' ')" }
        $t = (New-Object Security.Cryptography.X509Certificates.X509Certificate2($cer)).Thumbprint
    } finally { Remove-Item -LiteralPath $inf, $cer -Force -ErrorAction SilentlyContinue }
    $s = Open-VfCertStore 'My'
    try { $s.Certificates.Find('FindByThumbprint', $t, $false)[0] } finally { $s.Close() }
}

function Get-VfOwnCert {
    # one certificate per run, trusted as root and publisher; Remove-VfOwnKey deletes its key
    if ($script:OwnCert) { return $script:OwnCert }
    $c = New-VfSigningCert
    $pub = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $c.RawData)
    foreach ($n in @($script:RootStore, 'TrustedPublisher')) {
        $s = Open-VfCertStore $n
        try { $s.Add($pub) } finally { $s.Close() }
    }
    Write-VfLog "Local signing certificate created and trusted: $($c.Subject)"
    $script:OwnCert = $c
    $c
}

function Remove-VfOwnKey {
    # nobody can sign with the trusted certificate afterwards
    if (-not $script:OwnCert) { return }
    $k = $script:OwnCert.PrivateKey
    $k.PersistKeyInCsp = $false
    $k.Clear()
    $s = Open-VfCertStore 'My'
    try { $s.Remove($script:OwnCert) } finally { $s.Close() }
    Write-VfLog 'Private key of the local signing certificate deleted.'
    $script:OwnCert = $null
}

function Get-VfDriverStoreCatalogs {
    Get-ChildItem -Path (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository\*\*.cat') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
}

function Remove-VfUnusedOwnCerts {
    # local signing certificates of earlier runs that no package in the driver store uses any more
    $used = $null
    foreach ($n in @($script:RootStore, 'TrustedPublisher')) {
        $s = Open-VfCertStore $n
        try {
            foreach ($c in @($s.Certificates | Where-Object { $_.Subject -like "$($script:OwnCertName) *" })) {
                if ($null -eq $used) {
                    $used = @{}
                    foreach ($f in Get-VfDriverStoreCatalogs) {
                        $sig = (Get-VfCatalogSignature $f).SignerCertificate
                        if ($sig) { $used[$sig.Thumbprint] = $true }
                    }
                }
                if ($used.ContainsKey($c.Thumbprint)) { continue }
                $s.Remove($c)
                Write-VfLog "Unused local signing certificate removed from ${n}: $($c.Subject)"
            }
        } finally { $s.Close() }
    }
}

function Open-VfCertStore {
    param([string]$Name = 'TrustedPublisher')
    $s = New-Object Security.Cryptography.X509Certificates.X509Store($Name, $script:CertStore)
    $s.Open('ReadWrite')
    $s
}

function Add-VfTrustedPublishers {
    # without a trusted publisher, pnputil waits for "Install this device software?" (Windows 7:
    # virtio-win signs with its own certificate); the certificates stay, as with "Always trust"
    param([Parameter(Mandatory = $true)]$Infs)
    $store = Open-VfCertStore
    try {
        foreach ($inf in $Infs) {
            $i = Get-VfInfInfo $inf.FullName
            if (-not $i.Catalog) { continue }
            $c = (Get-VfCatalogSignature (Join-Path (Split-Path $inf.FullName -Parent) $i.Catalog)).SignerCertificate
            if (-not ($c -is [Security.Cryptography.X509Certificates.X509Certificate2])) { continue }
            if ($c.Subject -match 'O=Microsoft Corporation') { continue }
            if ($store.Certificates.Find('FindByThumbprint', $c.Thumbprint, $false).Count) { continue }
            $store.Add($c)
            Write-VfLog "Trusted publisher added: $($c.Subject)"
        }
    } finally { $store.Close() }
}

# ---------------------------------------------------------------- test signing (-AllowTestSigned)

function Read-VfHost {
    param([string]$Prompt)
    Read-Host $Prompt
}

function Confirm-VfTestSigning {
    param([switch]$Force)
    $text = @(
        '',
        'WARNING: -AllowTestSigned',
        'virtio-win signs some drivers only with its own development certificate (for Windows 8 / 8.1',
        'and Server 2012 / 2012 R2 all of them). Neither Microsoft nor the Red Hat release certificate',
        'vouches for these drivers. To install and load them, this script',
        '  - adds that certificate to the Trusted Root Certification Authorities and the Trusted',
        '    Publishers of this computer: Windows then trusts everything signed with it,',
        '  - turns on test signing mode (bcdedit /set testsigning on): Windows then loads every',
        '    test-signed driver, not only these, and shows "Test Mode" on the desktop,',
        '  - needs Secure Boot off; with Secure Boot on it stops before changing anything,',
        '  - signs packages whose files do not match their virtio-win catalog (for example Balloon,',
        '    vioserial, viorng, vioinput, pvpanic, fwcfg, viofs for Server 2012 R2) with a new catalog:',
        '    it creates a code signing certificate on this computer, adds it to the Trusted Root',
        '    Certification Authorities and the Trusted Publishers, and deletes its private key after',
        '    signing. Their INF files differ from what virtio-win signed; nobody vouches for them.',
        'The drivers load after a restart. WinRE gets no test-signed drivers.',
        'All of this stays; only the local signing certificate is removed by a later run once no',
        'driver package uses it any more.',
        'Turning test signing off later (bcdedit /set testsigning off) stops these',
        'drivers from loading; with the system disk on virtio, Windows then no longer starts',
        '(INACCESSIBLE_BOOT_DEVICE).',
        'Use this only in a virtual machine you control.',
        ''
    )
    foreach ($l in $text) { Write-Host $l -ForegroundColor Yellow }
    if ($Force) { Write-VfLog 'Test signing accepted with -Force.'; return $true }
    $ok = (Read-VfHost 'Type YES to continue') -ceq 'YES'
    if ($ok) { Write-VfLog 'Test signing accepted.' }
    $ok
}

function Test-VfSecureBoot {
    $v = $null
    try { $v = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).UEFISecureBootEnabled } catch { }
    $v -eq 1
}

function Test-VfTestSigningActive {
    # options of the current boot
    $o = $null
    try { $o = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control' -ErrorAction Stop).SystemStartOptions } catch { }
    "$o" -match 'TESTSIGNING'
}

function Enable-VfTestSigning {
    # trusts the signers of the test-signed packages and turns on test signing mode; $true when a
    # restart is needed before the drivers load
    param([Parameter(Mandatory = $true)]$Certificates)
    if (Test-VfSecureBoot) { throw 'Secure Boot is on: Windows does not load test-signed drivers. Turn Secure Boot off in the firmware of the VM, then run the script again.' }
    $store = Open-VfCertStore $script:RootStore
    try {
        foreach ($c in $Certificates) {
            if ($store.Certificates.Find('FindByThumbprint', $c.Thumbprint, $false).Count) { continue }
            $store.Add($c)
            Write-VfLog "Trusted root added: $($c.Subject)"
        }
    } finally { $store.Close() }
    $r = Invoke-VfNative 'bcdedit.exe' @('/set', 'testsigning', 'on')
    if ($r.ExitCode -ne 0) { throw "bcdedit /set testsigning on failed ($($r.ExitCode)): $($r.Output -join ' ')" }
    if (Test-VfTestSigningActive) { return $false }
    Write-VfLog 'Test signing mode turned on; the test-signed drivers load after a restart.'
    $true
}

function Get-VfReAgentState {
    # $null: no WinRE configuration; $true: enabled; $false: disabled
    $x = Join-Path (Get-VfWindowsDir) 'System32\Recovery\ReAgent.xml'
    if (-not (Test-Path -LiteralPath $x)) { return $null }
    $doc = [xml](Get-Content -LiteralPath $x)
    $s = $doc.WindowsRE.InstallState
    if (-not $s) { return $null }
    $s.state -eq '1'
}

function Get-VfDismError {
    # error text of a dism.exe call, $null on success
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)
    $r = Invoke-VfNative 'dism.exe' (@('/English') + $ArgumentList)
    if ($r.ExitCode -ne 0 -and $r.ExitCode -ne 3010) { return "dism $($ArgumentList -join ' ') failed ($($r.ExitCode)): $($r.Output | Select-Object -Last 3)" }
    $null
}

function Invoke-VfDism {
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)
    $e = Get-VfDismError $ArgumentList
    if ($e) { throw $e }
}

function Update-VfWinRE {
    # disables WinRE (reagentc moves winre.wim to System32\Recovery), adds the boot drivers with
    # dism.exe and enables it again
    param([Parameter(Mandatory = $true)]$DriverDirs)
    $enabled = Get-VfReAgentState
    if ($null -eq $enabled) { Write-VfLog 'No WinRE configured, skipped.'; return }
    if ($enabled) {
        $r = Invoke-VfNative 'reagentc.exe' @('/disable')
        if ($r.ExitCode -ne 0) { throw "reagentc /disable failed ($($r.ExitCode))." }
    }
    # error as text, so that no exception is in flight while reagentc runs
    $err = $null
    try { Add-VfWinREDrivers $DriverDirs } catch { $err = $_.Exception.Message }
    if ($enabled) { Enable-VfWinRE }
    if ($err) { throw $err }
}

function Enable-VfWinRE {
    $r = Invoke-VfNative 'reagentc.exe' @('/enable')
    if ($r.ExitCode -ne 0) { Write-VfLog "WARNING: reagentc /enable failed ($($r.ExitCode)); run it again." }
}

function Add-VfWinREDrivers {
    # winre.wim of the running Windows while WinRE is disabled
    param([Parameter(Mandatory = $true)]$DriverDirs)
    $wim = Join-Path (Get-VfWindowsDir) 'System32\Recovery\Winre.wim'
    if (-not (Test-Path -LiteralPath $wim)) { Write-VfLog 'WinRE image not found, skipped.'; return }
    $mnt = Join-Path (Get-VfDataDir) 'winre-mount'
    if (Test-Path -LiteralPath $mnt) { Remove-Item -LiteralPath $mnt -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $mnt | Out-Null
    $f = Get-Item -LiteralPath $wim -Force
    $attr = $f.Attributes
    $f.Attributes = 'Normal'
    # dism errors as text, no exception in flight while discarding and restoring the file
    $err = Get-VfDismError @('/Mount-Wim', "/WimFile:$wim", '/Index:1', "/MountDir:$mnt")
    if (-not $err) {
        foreach ($d in $DriverDirs) { foreach ($inf in $d.Infs) { if (-not $err) { $err = Get-VfDismError @("/Image:$mnt", '/Add-Driver', "/Driver:$($inf.FullName)") } } }
        if ($err) { $null = Get-VfDismError @('/Unmount-Wim', "/MountDir:$mnt", '/Discard') }
        else { $err = Get-VfDismError @('/Unmount-Wim', "/MountDir:$mnt", '/Commit') }
    }
    Remove-Item -LiteralPath $mnt -Recurse -Force -ErrorAction SilentlyContinue
    (Get-Item -LiteralPath $wim -Force).Attributes = $attr
    if ($err) { throw $err }
    Write-VfLog 'WinRE updated.'
}

function Install-VfGuestTools {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Arch)
    $tools = @(Get-VfGuestTools $Root $Arch)
    if (-not $tools) { Write-VfLog "virtio-win has no guest tools for $Arch, skipped."; return $false }
    $reboot = $false
    $log = Get-VfDataDir
    foreach ($t in $tools) {
        Write-VfLog "Installing $($t.Name)"
        if ($t.Extension -eq '.msi') {
            $r = Invoke-VfNative 'msiexec.exe' @('/i', $t.FullName, '/qn', '/norestart', '/l*v', (Join-Path $log "$($t.BaseName).log"))
        } else {
            $r = Invoke-VfNative $t.FullName @('/install', '/quiet', '/norestart', '/log', (Join-Path $log "$($t.BaseName).log"))
        }
        if ($r.ExitCode -eq 3010) { $reboot = $true }
        elseif ($r.ExitCode -ne 0) { throw "$($t.Name) failed ($($r.ExitCode))." }
    }
    $reboot
}

function Get-VfInfInfo {
    param([Parameter(Mandatory = $true)][string]$Path)
    $t = [IO.File]::ReadAllText($Path)
    $cat = $null
    $ver = $null
    if ($t -match '(?im)^\s*CatalogFile[^=]*=\s*([^\s;]+)') { $cat = $Matches[1].ToLower() }
    if ($t -match '(?im)^\s*DriverVer\s*=\s*[^,]*,\s*([0-9.]+)') { $ver = [version]$Matches[1] }
    New-Object PSObject -Property @{ Path = $Path; Name = (Split-Path $Path -Leaf); Catalog = $cat; Version = $ver }
}

function Get-VfOldDriverPackages {
    # oem*.inf of the given virtio-win catalogs that are older than the newest one and unused
    param([Parameter(Mandatory = $true)][string[]]$Catalogs)
    $used = @(Get-WmiObject Win32_PnPSignedDriver | Where-Object { $_.InfName } | ForEach-Object { $_.InfName.ToLower() })
    $pkgs = @(Get-ChildItem -LiteralPath (Join-Path (Get-VfWindowsDir) 'INF') -Filter 'oem*.inf' | ForEach-Object { Get-VfInfInfo $_.FullName } |
        Where-Object { $_.Catalog -and $_.Version -and ($Catalogs -contains $_.Catalog) })
    $r = @()
    foreach ($g in $pkgs | Group-Object Catalog) {
        $max = ($g.Group | Sort-Object Version | Select-Object -Last 1).Version
        foreach ($p in $g.Group) {
            if ($p.Version -lt $max -and -not ($used -contains $p.Name.ToLower())) { $r += $p }
        }
    }
    $r
}

function Remove-VfDriverPackage {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][version]$Version)
    if (Test-VfNewPnputil $Version) { $a = @('/delete-driver', $Name) } else { $a = @('-d', $Name) }
    $r = Invoke-VfNative 'pnputil.exe' $a
    $r.ExitCode -eq 0
}

function Invoke-VfOnline {
    # installs or updates the drivers of the running Windows, its WinRE and the guest tools
    param([string]$VirtioPath, [string]$VirtioVersion = 'stable', [switch]$NoGuestTools, [switch]$NoWinRE, [switch]$RemoveOld, [switch]$AllowTestSigned)
    $script:AllowTestSigned = [bool]$AllowTestSigned
    $script:Signed = @{}
    $script:TestSigned = @{}
    $script:OwnCert = $null
    $os = Get-VfOsInfo
    $folder = Get-VfWindowsFolder $os.Version $os.Server
    Write-VfLog "Windows $($os.Version) $($os.Arch), virtio-win folder $folder"
    if (-not $VirtioPath -and @('stable', 'latest') -contains $VirtioVersion -and -not $AllowTestSigned -and @('w8', 'w8.1', '2k12', '2k12R2') -contains $folder) {
        throw 'Current virtio-win signs the drivers for Windows 8 / 8.1 and Server 2012 / 2012 R2 only with its development certificate. Use -VirtioVersion 0.1.215 (release-signed drivers for these versions) or -AllowTestSigned.'
    }
    $vio = Open-VfVirtio $VirtioPath $VirtioVersion
    $reboot = $false
    $failed = 0
    try {
        $dirs = @(Find-VfDriverDirs $vio.Root $folder $os.Arch)
        $certs = @{}
        foreach ($c in $script:TestSigned.Values) { $certs[$c.Thumbprint] = $c }
        if ($certs.Count -and (Enable-VfTestSigning @($certs.Values))) { $reboot = $true }
        Add-VfTrustedPublishers @($dirs | ForEach-Object { $_.Infs })
        $cats = @()
        foreach ($d in $dirs) {
            foreach ($inf in $d.Infs) {
                $res = Add-VfDriverOnline (Get-VfInstallInf $inf.FullName) $os.Version
                $i = Get-VfInfInfo $inf.FullName
                if ($i.Catalog) { $cats += $i.Catalog }
                if ($res.Reboot) { $reboot = $true }
                if ($res.Ok) { Write-VfLog "  $($d.Name): $($inf.Name) $($i.Version) (exit $($res.ExitCode))" }
                else { Write-VfLog "  $($d.Name): $($inf.Name) FAILED (exit $($res.ExitCode))"; $failed++ }
            }
        }
        if (-not $NoWinRE) {
            # WinRE starts without test signing
            $boot = @(Select-VfReleaseSigned @($dirs | Where-Object { $script:BootDrivers -contains $_.Name }))
            if ($boot) { Update-VfWinRE $boot } else { Write-VfLog 'WinRE: no release-signed storage or network drivers, skipped.' }
        }
        if (-not $NoGuestTools -and (Test-VfGuestToolsSupported $os.Version)) { if (Install-VfGuestTools $vio.Root $os.Arch) { $reboot = $true } }
        if ($RemoveOld) {
            foreach ($p in Get-VfOldDriverPackages $cats) {
                if (Remove-VfDriverPackage $p.Name $os.Version) { Write-VfLog "Removed $($p.Name) ($($p.Catalog) $($p.Version))" }
                else { Write-VfLog "Could not remove $($p.Name) ($($p.Catalog) $($p.Version))" }
            }
        }
    } finally {
        Close-VfVirtio $vio
        Remove-VfOwnKey
        Remove-VfUnusedOwnCerts
        $copies = Join-Path (Get-VfDataDir) 'inf'
        if (Test-Path -LiteralPath $copies) { Remove-Item -LiteralPath $copies -Recurse -Force }
    }
    if ($failed) { Write-VfLog "$failed driver(s) failed."; return 1 }
    if ($reboot) { Write-VfLog 'Restart Windows to complete the installation.'; return 3010 }
    0
}

function Register-VfTask {
    # runs the calling script again as SYSTEM in a scheduled task, so that it survives the network
    # interruption of the NetKVM update (RDP, WinRM)
    param([Parameter(Mandatory = $true)][string]$Script, [string[]]$Arguments = @())
    $d = Get-VfDataDir
    $cmd = Join-Path $d 'RunTask.cmd'
    $line = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" {1} -FromTask >> "{2}" 2>&1' -f $Script, ($Arguments -join ' '), (Join-Path $d 'task.log')
    Set-Content -LiteralPath $cmd -Encoding ASCII -Value @('@echo off', $line)
    $r = Invoke-VfNative 'schtasks.exe' @('/create', '/tn', $script:Product, '/ru', 'SYSTEM', '/sc', 'once', '/st', '00:00', '/rl', 'HIGHEST', '/f', '/tr', "`"$cmd`"")
    if ($r.ExitCode -ne 0) { throw "schtasks /create failed ($($r.ExitCode)): $($r.Output -join ' ')" }
    $r = Invoke-VfNative 'schtasks.exe' @('/run', '/tn', $script:Product)
    if ($r.ExitCode -ne 0) { throw "schtasks /run failed ($($r.ExitCode))." }
    Write-VfLog "Started as scheduled task '$($script:Product)'; log: $(Join-Path $d 'VirtIOForge.log')"
}

function Unregister-VfTask {
    Invoke-VfNative 'schtasks.exe' @('/delete', '/tn', $script:Product, '/f') | Out-Null
}

function ConvertTo-VfArgs {
    # bound parameters back to a command line for Register-VfTask
    param([Parameter(Mandatory = $true)]$Bound)
    $r = @()
    foreach ($k in $Bound.Keys) {
        if ($k -eq 'AsTask' -or $k -eq 'FromTask') { continue }
        $v = $Bound[$k]
        if ($v -is [switch] -or $v -is [bool]) { if ($v) { $r += "-$k" } }
        # trailing backslashes doubled, or "D:\" would escape the closing quote
        else { $r += "-$k"; $r += ('"{0}"' -f ("$v" -replace '(\\+)$', '$1$1')) }
    }
    $r
}

# ---------------------------------------------------------------- Windows media (PowerShell 5.1)

function Test-VfServerImage {
    param([Parameter(Mandatory = $true)]$Info)
    if ("$($Info.InstallationType)" -match 'Server') { return $true }
    if ("$($Info.InstallationType)" -match 'Client') { return $false }
    if ("$($Info.EditionId)" -match '^Server') { return $true }
    "$($Info.ImageName)" -match 'Server'
}

function Initialize-VfNative {
    if ('VirtIOForge.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
namespace VirtIOForge {
public static class Native {
    public static long CopyStream(object comStream, string path) {
        System.Runtime.InteropServices.ComTypes.IStream s = (System.Runtime.InteropServices.ComTypes.IStream)comStream;
        System.Runtime.InteropServices.ComTypes.STATSTG st;
        s.Stat(out st, 1);
        byte[] buf = new byte[1 << 20];
        IntPtr pRead = Marshal.AllocHGlobal(4);
        long total = 0;
        try {
            using (FileStream fs = File.Create(path)) {
                while (total < st.cbSize) {
                    s.Read(buf, buf.Length, pRead);
                    int n = Marshal.ReadInt32(pRead);
                    if (n <= 0) break;
                    fs.Write(buf, 0, n);
                    total += n;
                }
            }
        } finally { Marshal.FreeHGlobal(pRead); }
        if (total != st.cbSize) throw new IOException("Image stream ended after " + total + " of " + st.cbSize + " bytes.");
        return total;
    }
}
}
'@
}

function Open-VfComStream {
    param([Parameter(Mandatory = $true)][string]$Path)
    $s = New-Object -ComObject ADODB.Stream
    $s.Type = 1
    $s.Open()
    $s.LoadFromFile($Path)
    $s
}

function New-VfIsoImage {
    # UDF image of a folder, bootable with BIOS (etfsboot.com) and, if present, UEFI (efisys.bin)
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Label)
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 4
    $fsi.FreeMediaBlocks = 0
    $fsi.VolumeName = $Label
    $boot = @()
    foreach ($b in @(@('boot\etfsboot.com', 0), @('efi\microsoft\boot\efisys.bin', 0xEF))) {
        $f = Join-Path $Root $b[0]
        if (-not (Test-Path -LiteralPath $f)) {
            if ($b[1] -eq 0) { throw "Boot image missing: $f" }
            Write-VfLog 'No efisys.bin on the media: BIOS boot only.'
            continue
        }
        $o = New-Object -ComObject IMAPI2FS.BootOptions
        $o.PlatformId = $b[1]
        $o.Emulation = 0
        $o.AssignBootImage((Open-VfComStream $f))
        $boot += $o.psobject.BaseObject
    }
    # a direct assignment fails with E_NOINTERFACE (PowerShell wraps the array elements)
    [void][System.__ComObject].InvokeMember('BootImageOptionsArray', [Reflection.BindingFlags]::SetProperty, $null, $fsi, @(, [object[]]$boot))
    $fsi.Root.AddTree($Root.TrimEnd('\'), $false)
    $fsi
}

function Save-VfIso {
    param([Parameter(Mandatory = $true)]$Image, [Parameter(Mandatory = $true)][string]$Path)
    Initialize-VfNative
    [VirtIOForge.Native]::CopyStream($Image.CreateResultImage().ImageStream, $Path)
}

function Add-VfImageDrivers {
    param([Parameter(Mandatory = $true)][string]$MountPath, [Parameter(Mandatory = $true)]$DriverDirs)
    # dism.exe, not Add-WindowsDriver: the cmdlet reads the driver list back afterwards, which fails
    # for x86 images before Windows 10 1607 (0x800700C1)
    foreach ($d in $DriverDirs) {
        foreach ($inf in $d.Infs) { Invoke-VfDism @("/Image:$MountPath", '/Add-Driver', "/Driver:$($inf.FullName)") }
        Write-VfLog "    $($d.Name)"
    }
}

function Get-VfImages {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($i in Get-WindowsImage -ImagePath $Path) { Get-WindowsImage -ImagePath $Path -Index $i.ImageIndex }
}

function Clear-VfMountDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Update-VfImageWinRE {
    # winre.wim of a mounted install image; identical WinRE images are processed once
    param([Parameter(Mandatory = $true)][string]$MountPath, [Parameter(Mandatory = $true)]$DriverDirs,
        [Parameter(Mandatory = $true)][string]$WorkPath, [Parameter(Mandatory = $true)][hashtable]$Cache)
    $re = Join-Path $MountPath 'Windows\System32\Recovery\winre.wim'
    if (-not (Test-Path -LiteralPath $re)) { Write-VfLog '    no WinRE'; return }
    $hash = (Get-FileHash -LiteralPath $re -Algorithm SHA256).Hash
    if (-not $Cache.ContainsKey($hash)) {
        $copy = Join-Path $WorkPath ('winre-{0}.wim' -f $Cache.Count)
        Copy-Item -LiteralPath $re -Destination $copy -Force
        (Get-Item -LiteralPath $copy -Force).Attributes = 'Normal'
        $mnt = Join-Path $WorkPath 'mount-re'
        Clear-VfMountDir $mnt
        Mount-WindowsImage -ImagePath $copy -Index 1 -Path $mnt | Out-Null
        try { Add-VfImageDrivers $mnt $DriverDirs }
        catch { Dismount-WindowsImage -Path $mnt -Discard | Out-Null; throw }
        Dismount-WindowsImage -Path $mnt -Save | Out-Null
        $Cache[$hash] = $copy
    } else { Write-VfLog '    WinRE as before' }
    $f = Get-Item -LiteralPath $re -Force
    $attr = $f.Attributes
    $f.Attributes = 'Normal'
    Copy-Item -LiteralPath $Cache[$hash] -Destination $re -Force
    (Get-Item -LiteralPath $re -Force).Attributes = $attr
}

function Update-VfWim {
    # adds drivers to every index of a WIM; $Select returns the driver folders for an image info
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][scriptblock]$Select,
        [Parameter(Mandatory = $true)][string]$WorkPath, [switch]$WinRE)
    $mnt = Join-Path $WorkPath 'mount'
    $cache = @{}
    foreach ($info in @(Get-VfImages $Path)) {
        $dirs = @(& $Select $info)
        Write-VfLog "  $(Split-Path $Path -Leaf) $($info.ImageIndex): $($info.ImageName) ($($info.Version))"
        Clear-VfMountDir $mnt
        Mount-WindowsImage -ImagePath $Path -Index $info.ImageIndex -Path $mnt | Out-Null
        try {
            Add-VfImageDrivers $mnt $dirs
            if ($WinRE) {
                $boot = @($dirs | Where-Object { $script:BootDrivers -contains $_.Name })
                Update-VfImageWinRE $mnt $boot $WorkPath $cache
            }
        } catch { Dismount-WindowsImage -Path $mnt -Discard | Out-Null; throw }
        Dismount-WindowsImage -Path $mnt -Save | Out-Null
    }
}

function New-VfGuestToolsFiles {
    # guest tools on the media: SetupComplete.cmd at the end of Setup; Setup skips it with an
    # OEM product key, so autounattend.xml runs the same Install.cmd at the first logon
    param([Parameter(Mandatory = $true)][string]$Media, [Parameter(Mandatory = $true)][string]$VirtioRoot,
        [Parameter(Mandatory = $true)][string]$Arch)
    $tools = @(Get-VfGuestTools $VirtioRoot $Arch)
    if (-not $tools) { Write-VfLog "virtio-win has no guest tools for $Arch, skipped."; return }
    $dir = Join-Path $Media 'sources\$OEM$\$1\ProgramData\VirtIOForge\Media'
    $scripts = Join-Path $Media 'sources\$OEM$\$$\Setup\Scripts'
    New-Item -ItemType Directory -Force -Path $dir, $scripts | Out-Null
    $run = @()
    foreach ($t in $tools) {
        Copy-Item -LiteralPath $t.FullName -Destination (Join-Path $dir $t.Name)
        if ($t.Extension -eq '.msi') { $run += ('start "" /wait msiexec.exe /i "%D%{0}" /qn /norestart /l*v "%D%{1}.log"' -f $t.Name, $t.BaseName) }
        else { $run += ('start "" /wait "%D%{0}" /install /quiet /norestart /log "%D%{1}.log"' -f $t.Name, $t.BaseName) }
        $run += 'set "E=%ERRORLEVEL%"'
        $run += 'if "%E%"=="3010" (set "REBOOT=1") else if not "%E%"=="0" set "RC=%E%"'
    }
    Set-Content -LiteralPath (Join-Path $dir 'Install.cmd') -Encoding ASCII -Value (@(
            '@echo off'
            'rem VirtIOForge: installs the virtio-win guest tools once, from SetupComplete.cmd or at the first logon.'
            'set "D=%~dp0"'
            'if exist "%D%result.txt" exit /b 0'
            'set "RC=0"'
            'set "REBOOT="') + $run + @(
            '>"%D%result.txt" echo %RC%'
            'if defined REBOOT shutdown.exe /r /t 30 /c "VirtIOForge"'
            'exit /b 0'))
    Set-Content -LiteralPath (Join-Path $scripts 'SetupComplete.cmd') -Encoding ASCII -Value @(
        '@echo off'
        'call "%SystemDrive%\ProgramData\VirtIOForge\Media\Install.cmd"')
    Set-Content -LiteralPath (Join-Path $Media 'autounattend.xml') -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$Arch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd.exe /c "%SystemDrive%\ProgramData\VirtIOForge\Media\Install.cmd"</CommandLine>
          <Description>VirtIOForge</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
    Write-VfLog "Guest tools: $(($tools | ForEach-Object { $_.Name }) -join ', ')"
}

Export-ModuleMember -Function *-Vf*
