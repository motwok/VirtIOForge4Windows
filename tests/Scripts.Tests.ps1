#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }
# Runs the scripts with DISM, mounting and the online installation mocked; IMAPI2 and robocopy run for real.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
    function Invoke-VfScript {
        param([Parameter(Mandatory)][string]$Name, [hashtable]$Arguments = @{})
        $global:LASTEXITCODE = 0
        & (Join-Path $Scripts $Name) @Arguments | Out-Null
        $global:LASTEXITCODE
    }
}
AfterAll { Restore-VfTestEnv }

Describe 'New-VirtIOMedia.ps1' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $work = Join-Path $TestDrive ([guid]::NewGuid())
        $media = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force $work, (Join-Path $media 'boot'), (Join-Path $media 'efi\microsoft\boot'), (Join-Path $media 'sources') | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $media 'boot\etfsboot.com'), (New-Object byte[] 2048))
        [IO.File]::WriteAllBytes((Join-Path $media 'efi\microsoft\boot\efisys.bin'), (New-Object byte[] 4096))
        Set-Content (Join-Path $media 'sources\boot.wim') 'boot'
        Set-Content (Join-Path $media 'sources\install.wim') 'wim'
        $iso = Join-Path $TestDrive 'win.iso'
        Set-Content $iso 'iso'
        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.iso')
        $global:VfTest = @{ Media = $media; Work = $work; Vio = $vio; Arch = 9; Type = 'Client'; Version = '10.0.26100.1742' }

        Mock Open-VfVirtio { [pscustomobject]@{ Root = $global:VfTest.Vio; Version = '0.1.302'; Mounted = $null } }
        Mock Close-VfVirtio { }
        Mock Mount-VfIso { [pscustomobject]@{ Root = $global:VfTest.Media + '\'; Label = 'WIN_ISO'; ImagePath = $Path } }
        Mock Dismount-VfIso { }
        Mock Get-WindowsImage {
            if ($Mounted) { [pscustomobject]@{ Path = (Get-ChildItem $global:VfTest.Work -Filter 'VirtIOForge-*' | Select-Object -First 1).FullName + '\mount' }; return }
            if ($ImagePath -like '*.esd') { [pscustomobject]@{ ImageIndex = 1 }; [pscustomobject]@{ ImageIndex = 2 }; return }
            [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Pro'; Version = $global:VfTest.Version; Architecture = $global:VfTest.Arch; InstallationType = $global:VfTest.Type }
        }
        Mock Export-WindowsImage { Add-Content $DestinationImagePath "index $SourceIndex" }
        Mock Dismount-WindowsImage { }
        Mock Update-VfWim {
            $info = [pscustomobject]@{ ImageIndex = 1; Version = '10.0.26100.1742'; Architecture = 9; InstallationType = 'Client' }
            $global:VfTest[(Split-Path $Path -Leaf)] = @(& $Select $info).Name
        }
    }

    It 'builds the ISO with drivers and guest tools' {
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 0
        Test-Path $out | Should -BeTrue
        $global:VfTest['install.wim'] | Should -Be @('Balloon', 'NetKVM', 'vioscsi', 'viostor')
        $global:VfTest['boot.wim'] | Should -Be @('NetKVM', 'vioscsi', 'viostor')
        Should -Invoke Update-VfWim -ParameterFilter { $WinRE } -Times 1 -Exactly
        Should -Invoke Dismount-WindowsImage -ParameterFilter { $Discard } -Times 1 -Exactly
        @(Get-ChildItem $work).Count | Should -Be 0
        Get-VfTestLog | Should -Match 'Guest tools: virtio-win-guest-tools.exe'
        Get-VfTestLog | Should -Match 'ISO written'
    }
    It 'converts install.esd and leaves out the guest tools' {
        Remove-Item (Join-Path $media 'sources\install.wim')
        Set-Content (Join-Path $media 'sources\install.esd') 'esd'
        Set-Content (Join-Path $media 'autounattend.xml') 'own'
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work; NoGuestTools = $true } | Should -Be 0
        Should -Invoke Export-WindowsImage -Times 2 -Exactly
        Get-VfTestLog | Should -Not -Match 'Guest tools'
    }
    It 'leaves out the guest tools for Windows 7' {
        $global:VfTest.Version = '6.1.7601.17514'
        $global:VfTest.Arch = 0
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 0
        Get-VfTestLog | Should -Match 'skipped for 6.1.7601.17514'
        Get-VfTestLog | Should -Not -Match 'Guest tools:'
    }
    It 'stops on Windows Vista / Server 2008' {
        $global:VfTest.Version = '6.0.6002.18005'
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 1
        Get-VfTestLog | Should -Match 'Windows 6.0.6002.18005 \(Vista / Server 2008\) cannot be serviced'
        Should -Invoke Update-VfWim -Times 0 -Exactly
    }
    It 'stops on Windows 8.1 / Server 2012 R2 without release-signed storage drivers' {
        $global:VfTest.Version = '6.3.9600.16384'
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 1
        Get-VfTestLog | Should -Match 'no release-signed storage driver for this Windows'
        Should -Invoke Update-VfWim -Times 0 -Exactly
    }
    It 'stops without install image' {
        Remove-Item (Join-Path $media 'sources\install.wim')
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 1
        Get-VfTestLog | Should -Match 'No install.wim or install.esd'
    }
    It 'refuses media with its own autounattend.xml' {
        Set-Content (Join-Path $media 'autounattend.xml') 'own'
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 1
        Get-VfTestLog | Should -Match 'already contains autounattend.xml'
    }
    It 'refuses dual-architecture media' {
        New-Item -ItemType Directory (Join-Path $media 'x86'), (Join-Path $media 'x64') | Out-Null
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 1
        Get-VfTestLog | Should -Match 'both x86 and x64'
    }
    It 'stops when robocopy fails' {
        Mock Invoke-VfNative { [pscustomobject]@{ ExitCode = 16; Output = @('fatal') } }
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 1
        Get-VfTestLog | Should -Match 'robocopy failed \(16\)'
    }
    It 'checks the free space' {
        Mock Get-VfFreeSpace { 1 }
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 1
        Get-VfTestLog | Should -Match 'Not enough space'
    }
    It 'checks the parameters' -ForEach @(
        @{ case = 'missing ISO'; a = @{ WindowsIso = 'C:\nope\x.iso' }; m = 'File not found' }
        @{ case = 'output exists'; a = @{ OutputIso = 'iso' }; m = 'Output exists' }
        @{ case = 'output folder missing'; a = @{ OutputIso = 'C:\nope\x.iso' }; m = 'Folder not found' }
    ) {
        $p = @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work }
        foreach ($k in $a.Keys) { $p[$k] = $a[$k] }
        if ($p.OutputIso -eq 'iso') { $p.OutputIso = $iso }
        Invoke-VfScript 'New-VirtIOMedia.ps1' $p | Should -Be 1
        Get-VfTestLog | Should -Match $m
    }
    It 'removes a partly written ISO' {
        Mock Save-VfIso { Set-Content $Path 'part'; throw 'disk full' }
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 1
        Test-Path $out | Should -BeFalse
        Get-VfTestLog | Should -Match 'disk full'
    }
    It 'dismounts the Windows ISO after an early error' {
        Mock Get-WindowsImage { if ($Mounted) { return }; throw 'no image' }
        Mock Invoke-VfNative { throw 'copy error' }
        Invoke-VfScript 'New-VirtIOMedia.ps1' @{ WindowsIso = $iso; OutputIso = $out; WorkPath = $work } | Should -Be 1
        Should -Invoke Dismount-VfIso -Times 1 -Exactly
    }
}

Describe '<Name>' -ForEach @(@{ Name = 'Install-VirtIO.ps1' }, @{ Name = 'Update-VirtIO.ps1' }) {
    BeforeEach {
        Reset-VfTest
        Mock Assert-VfAdmin { }
        Mock Invoke-VfOnline { 3010 }
        Mock Register-VfTask { }
        Mock Unregister-VfTask { }
    }
    It 'returns the result of the installation' {
        Invoke-VfScript $Name @{ VirtioPath = 'D:\'; NoWinRE = $true } | Should -Be 3010
        Should -Invoke Invoke-VfOnline -ParameterFilter { $VirtioPath -eq 'D:\' -and $NoWinRE } -Times 1 -Exactly
        Should -Invoke Unregister-VfTask -Times 0 -Exactly
    }
    It 'starts itself as a scheduled task' {
        Invoke-VfScript $Name @{ AsTask = $true; VirtioVersion = 'latest' } | Should -Be 0
        Should -Invoke Register-VfTask -ParameterFilter { $Script -like "*\$Name" -and ($Arguments -join ' ') -eq '-VirtioVersion "latest"' } -Times 1 -Exactly
        Should -Invoke Invoke-VfOnline -Times 0 -Exactly
    }
    It 'removes the task when run from it' {
        Invoke-VfScript $Name @{ FromTask = $true } | Should -Be 3010
        Should -Invoke Unregister-VfTask -Times 1 -Exactly
    }
    It 'asks before test signing' {
        Mock Confirm-VfTestSigning { $false }
        Invoke-VfScript $Name @{ AllowTestSigned = $true } | Should -Be 1
        Should -Invoke Invoke-VfOnline -Times 0 -Exactly
        Get-VfTestLog | Should -Match 'Test signing not confirmed, nothing changed'
    }
    It 'installs test-signed drivers after the confirmation' {
        Mock Confirm-VfTestSigning { $true }
        Invoke-VfScript $Name @{ AllowTestSigned = $true; Force = $true } | Should -Be 3010
        Should -Invoke Confirm-VfTestSigning -ParameterFilter { $Force } -Times 1 -Exactly
        Should -Invoke Invoke-VfOnline -ParameterFilter { $AllowTestSigned } -Times 1 -Exactly
    }
    It 'does not ask again in the task' {
        Mock Confirm-VfTestSigning { $false }
        Invoke-VfScript $Name @{ AllowTestSigned = $true; FromTask = $true } | Should -Be 3010
        Should -Invoke Confirm-VfTestSigning -Times 0 -Exactly
    }
    It 'returns 1 on an error' {
        Mock Invoke-VfOnline { throw 'broken' }
        Invoke-VfScript $Name | Should -Be 1
        Get-VfTestLog | Should -Match 'ERROR: broken'
    }
}
