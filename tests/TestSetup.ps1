# Dot-sourced in BeforeAll: loads the module once and redirects %ProgramData% to TestDrive.
$Scripts = (Resolve-Path (Join-Path $PSScriptRoot '..\src\scripts')).Path
Import-Module (Join-Path $Scripts 'VirtIOForge.psm1') -Force
$global:VfSavedProgramData = $env:ProgramData

$global:VfTestSignature = {
    param($Path)
    $s = if ($Path -match 'smbus') { 'UnknownError' } else { 'Valid' }
    New-Object PSObject -Property @{ Status = $s; SignerCertificate = (New-Object PSObject -Property @{ Subject = 'CN=Test' }) }
}

function Reset-VfTest {
    # each test builds its own virtio-win tree, so the signature cache never hits across tests
    $env:ProgramData = Join-Path $TestDrive ([guid]::NewGuid())
    New-Item -ItemType Directory -Force $env:ProgramData | Out-Null
    Mock -ModuleName VirtIOForge Get-VfCatalogSignature $global:VfTestSignature
}

# message of the error the block throws; $null without error. Not "Should -Throw": in Pester 6.2 on
# Windows PowerShell 5.1, module code that calls a module mock and then throws inside Should -Throw
# overflows the call depth.
function Get-VfTestError {
    param([Parameter(Mandatory)][scriptblock]$Block)
    try { & $Block | Out-Null } catch { return $_.Exception.Message }
    $null
}

# Replaces a module function without Pester's Mock (for error paths where Pester 6.2 overflows the
# call depth); returns the original body for Restore-VfTestFunction.
function Set-VfTestFunction {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    $m = Get-Module VirtIOForge
    $old = & $m { param($n) (Get-Item "function:script:$n").ScriptBlock } $Name
    & $m { param($n, $b) Set-Item "function:script:$n" $b } $Name $Body
    @{ Name = $Name; Body = $old }
}

function Restore-VfTestFunction {
    param([Parameter(Mandatory)][hashtable[]]$Saved)
    $m = Get-Module VirtIOForge
    foreach ($s in $Saved) { & $m { param($n, $b) Set-Item "function:script:$n" $b } $s.Name $s.Body }
}

function Restore-VfTestEnv { $env:ProgramData = $global:VfSavedProgramData }

function Get-VfTestLog { Get-Content (Join-Path (Get-VfDataDir) 'VirtIOForge.log') -Raw }

function New-VfTestInf {
    param([Parameter(Mandatory)][string]$Path, [string]$Catalog, [string]$Version = '100.103.104.30200')
    New-Item -ItemType Directory -Force (Split-Path $Path -Parent) | Out-Null
    $lines = @('[Version]', 'Signature="$Windows NT$"', "DriverVer = 07/22/2026,$Version")
    if ($Catalog) {
        $lines += "CatalogFile = $Catalog"
        Set-Content (Join-Path (Split-Path $Path -Parent) $Catalog) 'cat'
    }
    Set-Content $Path $lines
}

# virtio-win tree: drivers for w11 and w7, info.json without qemupciserial, guest tools
function New-VfTestVirtio {
    param([Parameter(Mandatory)][string]$Root, [switch]$NoInfo)
    $list = @()
    foreach ($w in @(@('w11', 'amd64'), @('w7', 'x86'), @('w7', 'amd64'))) {
        foreach ($d in 'viostor', 'vioscsi', 'NetKVM', 'Balloon', 'smbus', 'qemupciserial') {
            $n = $d.ToLower()
            New-VfTestInf (Join-Path $Root "$d\$($w[0])\$($w[1])\$n.inf") "$n.cat"
            if ($d -ne 'qemupciserial') { $list += '{"inf_path": "' + "$d/$($w[0])/$($w[1])/$n.inf" + '"}' }
        }
    }
    New-Item -ItemType Directory -Force (Join-Path $Root 'data'), (Join-Path $Root 'guest-agent') | Out-Null
    if (-not $NoInfo) { Set-Content (Join-Path $Root 'data\info.json') ('{"drivers": [' + ($list -join ', ') + ']}') }
    foreach ($f in 'virtio-win-guest-tools.exe', 'virtio-win-gt-x86.msi', 'guest-agent\qemu-ga-i386.msi') { Set-Content (Join-Path $Root $f) 'x' }
    $Root
}
