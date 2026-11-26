# Builds the release asset into -Out:
#   VirtIOForge-<Version>-scripts.zip  src\scripts, README, LICENSE, NOTICE
# tools\ is repo-only and is not shipped.
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Out = 'dist'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid version: $Version" }
if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Force $Out | Out-Null
$scripts = Join-Path $root 'src\scripts'
if (-not (Get-ChildItem $scripts -Recurse -File -ErrorAction SilentlyContinue)) { 'no scripts yet, nothing built'; return }

$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$stage = Join-Path $tmp "virtioforge-$Version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $scripts (Join-Path $stage 'scripts') -Recurse
Copy-Item README.md, LICENSE, NOTICE $stage
$zip = Join-Path $Out "VirtIOForge-$Version-scripts.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item $stage -Recurse -Force

# smoke test: every script, nothing from tools\, no Windows or virtio-win binary
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $zip))
try {
    $names = $z.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }
    foreach ($s in Get-ChildItem $scripts -Recurse -File) {
        $rel = 'scripts/' + ($s.FullName.Substring($scripts.Length + 1) -replace '\\', '/')
        if ($names -notcontains $rel) { throw "missing in archive: $rel" }
    }
    $repoOnly = Get-ChildItem tools -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object Name
    $leak = $names | Where-Object { $repoOnly -contains (Split-Path $_ -Leaf) }
    if ($leak) { throw "repo-only file in archive: $($leak -join ', ')" }
    $bad = $names | Where-Object { $_ -match '\.(sys|cat|inf|mum|cab|wim|esd|iso|dll|exe|msi)$' }
    if ($bad) { throw "binary in archive: $($bad -join ', ')" }
} finally { $z.Dispose() }
"built $zip"
