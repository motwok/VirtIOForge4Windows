# Runs every *.Tests.ps1 in its own Windows PowerShell process and merges the code coverage: a
# command counts as covered if any file covers it. One process per file because in a shared Pester
# 6.2 run on Windows PowerShell 5.1 the mocks of a later file overflow the call depth after the
# module tests. Returns Passed, Failed, Ok, Coverage and the missed commands.
param(
    [string]$Path = $PSScriptRoot,
    [string]$CoveragePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\scripts'),
    [string]$PesterVersion = '6.2.0'
)
$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('vf-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force $tmp | Out-Null
$worker = Join-Path $tmp 'worker.ps1'
Set-Content $worker -Encoding ASCII -Value @'
param([string]$File, [string]$CoveragePath, [string]$Out, [string]$PesterVersion)
Import-Module Pester -RequiredVersion $PesterVersion
$c = New-PesterConfiguration
$c.Run.Path = $File
$c.Run.PassThru = $true
$c.Output.Verbosity = 'Normal'
$c.CodeCoverage.Enabled = $true
$c.CodeCoverage.Path = $CoveragePath
$c.CodeCoverage.UseBreakpoints = $false
$r = Invoke-Pester -Configuration $c
@{
    Passed   = $r.PassedCount
    Failed   = $r.FailedCount
    Result   = $r.Result
    Analyzed = $r.CodeCoverage.CommandsAnalyzedCount
    Missed   = @($r.CodeCoverage.CommandsMissed | ForEach-Object { '{0}|{1}|{2}' -f $_.File, $_.Line, $_.Command })
} | Export-Clixml $Out
'@
try {
    $passed = 0; $failed = 0; $ok = $true; $analyzed = 0; $missed = $null
    foreach ($f in Get-ChildItem $Path -Filter *.Tests.ps1 | Sort-Object Name) {
        $out = Join-Path $tmp "$($f.BaseName).xml"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -File $f.FullName -CoveragePath $CoveragePath -Out $out -PesterVersion $PesterVersion | Out-Host
        if (-not (Test-Path $out)) { $ok = $false; Write-Host "no result from $($f.Name)"; continue }
        $r = Import-Clixml $out
        $passed += $r.Passed
        $failed += $r.Failed
        if ($r.Result -ne 'Passed') { $ok = $false }
        if ($r.Analyzed -gt $analyzed) { $analyzed = $r.Analyzed }
        $these = @($r.Missed)
        if ($null -eq $missed) { $missed = $these } else { $missed = @($missed | Where-Object { $these -contains $_ }) }
    }
    if ($null -eq $missed) { $missed = @() }
    $coverage = if ($analyzed) { 100 * ($analyzed - $missed.Count) / $analyzed } else { 0 }
    New-Object PSObject -Property @{
        Passed   = $passed
        Failed   = $failed
        Ok       = ($ok -and $failed -eq 0)
        Coverage = [math]::Round($coverage, 2)
        Missed   = @($missed | ForEach-Object { $p = $_.Split('|'); New-Object PSObject -Property @{ File = $p[0]; Line = $p[1]; Command = $p[2] } })
    }
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
