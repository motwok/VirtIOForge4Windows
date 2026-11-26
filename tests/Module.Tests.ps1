#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }
BeforeAll { . (Join-Path $PSScriptRoot 'TestSetup.ps1') }
AfterAll { Restore-VfTestEnv }

Describe 'Basics' {
    BeforeEach { Reset-VfTest }

    It 'Get-VfDataDir creates the folder under ProgramData' {
        $d = Get-VfDataDir
        $d | Should -Be (Join-Path $env:ProgramData 'VirtIOForge')
        Test-Path $d | Should -BeTrue
    }
    It 'Get-VfDataDir falls back to ALLUSERSPROFILE' {
        $a = $env:ALLUSERSPROFILE
        try {
            $env:ALLUSERSPROFILE = $TestDrive
            Remove-Item Env:ProgramData
            Get-VfDataDir | Should -Be (Join-Path $TestDrive 'Application Data\VirtIOForge')
        } finally { $env:ALLUSERSPROFILE = $a }
    }
    It 'Write-VfLog writes the log file' {
        Write-VfLog 'hello log'
        Get-VfTestLog | Should -Match 'hello log'
    }
    It 'Invoke-VfNative returns exit code and output' {
        $r = Invoke-VfNative 'cmd.exe' @('/c', 'echo hi& exit 3')
        $r.ExitCode | Should -Be 3
        ($r.Output -join '') | Should -Match 'hi'
    }
    It 'Test-VfAdmin returns a bool' { Test-VfAdmin | Should -BeOfType [bool] }
    It 'Assert-VfAdmin throws without administrator rights' {
        Mock -ModuleName VirtIOForge Test-VfAdmin { $false }
        Get-VfTestError { Assert-VfAdmin } | Should -BeLike '*administrator*'
    }
    It 'Assert-VfAdmin passes as administrator' {
        Mock -ModuleName VirtIOForge Test-VfAdmin { $true }
        { Assert-VfAdmin } | Should -Not -Throw
    }
    It 'Get-VfWindowsDir is the Windows folder' { Get-VfWindowsDir | Should -Be $env:windir }
    It 'Get-VfFreeSpace returns the free bytes' { Get-VfFreeSpace $TestDrive | Should -BeGreaterThan 0 }
    It 'Get-VfBootDrivers lists storage and network' { Get-VfBootDrivers | Should -Be @('viostor', 'vioscsi', 'NetKVM') }
}

Describe 'Windows version and architecture' {
    It 'Get-VfWindowsFolder <v> server=<s> -> <f>' -ForEach @(
        @{ v = '6.0.6002'; s = $false; f = '2k8' }
        @{ v = '6.0.6001'; s = $true; f = '2k8' }
        @{ v = '6.1.7601'; s = $false; f = 'w7' }
        @{ v = '6.1.7600'; s = $true; f = '2k8R2' }
        @{ v = '6.2.9200'; s = $false; f = 'w8' }
        @{ v = '6.2.9200'; s = $true; f = '2k12' }
        @{ v = '6.3.9600'; s = $false; f = 'w8.1' }
        @{ v = '6.3.9600'; s = $true; f = '2k12R2' }
        @{ v = '10.0.19045'; s = $false; f = 'w10' }
        @{ v = '10.0.22631'; s = $false; f = 'w11' }
        @{ v = '10.0.14393'; s = $true; f = '2k16' }
        @{ v = '10.0.17763'; s = $true; f = '2k19' }
        @{ v = '10.0.20348'; s = $true; f = '2k22' }
        @{ v = '10.0.26100'; s = $true; f = '2k25' }
    ) { Get-VfWindowsFolder ([version]$v) $s | Should -Be $f }
    It 'Get-VfWindowsFolder rejects XP' { Get-VfTestError { Get-VfWindowsFolder ([version]'5.1.2600') $false } | Should -BeLike '*not supported*' }
    It 'Get-VfArch <a> -> <r>' -ForEach @(
        @{ a = 0; r = 'x86' }, @{ a = 'x86'; r = 'x86' }, @{ a = 9; r = 'amd64' }, @{ a = 'AMD64'; r = 'amd64' }, @{ a = 'x64'; r = 'amd64' }
    ) { Get-VfArch $a | Should -Be $r }
    It 'Get-VfArch rejects ARM64' { Get-VfTestError { Get-VfArch 12 } | Should -BeLike '*not supported*' }
    It 'Get-VfOsInfo reads WMI and the architecture' {
        Mock -ModuleName VirtIOForge Get-WmiObject { [pscustomobject]@{ Version = '10.0.22631'; ProductType = 1 } }
        $w = $env:PROCESSOR_ARCHITEW6432
        try {
            $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
            $o = Get-VfOsInfo
            $o.Version | Should -Be ([version]'10.0.22631')
            $o.Server | Should -BeFalse
            $o.Arch | Should -Be 'amd64'
            Remove-Item Env:PROCESSOR_ARCHITEW6432
            (Get-VfOsInfo).Arch | Should -Be (Get-VfArch $env:PROCESSOR_ARCHITECTURE)
        } finally { $env:PROCESSOR_ARCHITEW6432 = $w }
    }
}

Describe 'virtio-win source' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
    }

    It 'Get-VfVersionFromText' {
        Get-VfVersionFromText 'virtio-win-0.1.302' | Should -Be '0.1.302'
        Get-VfVersionFromText 'CDROM' | Should -BeNullOrEmpty
    }
    It 'Test-VfVirtioRoot' {
        Test-VfVirtioRoot $vio | Should -BeTrue
        Test-VfVirtioRoot $TestDrive | Should -BeFalse
    }
    # one Mock per command and test: mocking a command twice in one test breaks later mocks in Pester 6
    It 'Get-VfVolumeLabel of a drive' {
        Get-VfVolumeLabel $TestDrive | Should -BeNullOrEmpty
        Mock -ModuleName VirtIOForge Get-WmiObject { [pscustomobject]@{ VolumeName = 'virtio-win-0.1.302' } }
        Get-VfVolumeLabel 'd:\' | Should -Be 'virtio-win-0.1.302'
        Should -Invoke -ModuleName VirtIOForge Get-WmiObject -ParameterFilter { $Filter -eq "DeviceID='D:'" }
    }
    It 'Get-VfVolumeLabel of a missing drive' {
        Mock -ModuleName VirtIOForge Get-WmiObject { }
        Get-VfVolumeLabel 'Q:' | Should -BeNullOrEmpty
    }
    It 'Test-VfCanMountIso' { Test-VfCanMountIso | Should -BeOfType [bool] }
    It 'Wait-VfDrive waits until the drive is there' {
        Mock -ModuleName VirtIOForge Start-Sleep { }
        Wait-VfDrive $TestDrive
        Should -Invoke -ModuleName VirtIOForge Start-Sleep -Times 0 -Exactly
        Wait-VfDrive (Join-Path $TestDrive 'none')
        Should -Invoke -ModuleName VirtIOForge Start-Sleep -Times 60 -Exactly
    }
    It 'Mount-VfIso refuses without Mount-DiskImage' {
        Mock -ModuleName VirtIOForge Test-VfCanMountIso { $false }
        Get-VfTestError { Mount-VfIso 'x.iso' } | Should -BeLike '*CD drive*'
    }
    It 'Dismount-VfIso only for a mounted ISO' {
        Mock -ModuleName VirtIOForge Dismount-DiskImage { }
        Dismount-VfIso $null
        Dismount-VfIso ([pscustomobject]@{ ImagePath = $null })
        Should -Invoke -ModuleName VirtIOForge Dismount-DiskImage -Times 0 -Exactly
        Dismount-VfIso ([pscustomobject]@{ ImagePath = 'x.iso' })
        Should -Invoke -ModuleName VirtIOForge Dismount-DiskImage -Times 1 -Exactly
    }
    It 'Enable-VfTls12 sets TLS 1.2' {
        Enable-VfTls12
        ([int][Net.ServicePointManager]::SecurityProtocol -band 3072) | Should -Be 3072
    }
    It 'Enable-VfTls12 explains a missing TLS 1.2' {
        Mock -ModuleName VirtIOForge Add-VfTls12 { throw 'no' }
        Get-VfTestError { Enable-VfTls12 } | Should -BeLike '*TLS 1.2*'
    }
    It 'Get-VfWebText and Save-VfWebFile read file URLs' {
        $src = Join-Path $TestDrive 'page.html'
        Set-Content $src 'hello web'
        $url = ([Uri]$src).AbsoluteUri
        Get-VfWebText $url | Should -Match 'hello web'
        $dst = Join-Path $TestDrive 'dl.bin'
        Set-Content $dst 'old'
        Save-VfWebFile $url $dst
        Get-Content $dst -Raw | Should -Match 'hello web'
        Test-Path "$dst.part" | Should -BeFalse
    }
    It 'Get-VfLinks' {
        Get-VfLinks '<a href="a/">a</a> <a href="?C=M">s</a> <a href="b.iso">b</a>' | Should -Be @('a/', 'b.iso')
    }
    It 'Resolve-VfLink' {
        Resolve-VfLink 'https://h/x/archive/' 'v-1/' | Should -Be 'https://h/x/archive/v-1/'
        Resolve-VfLink 'https://h/x/archive/' '/y/z.iso' | Should -Be 'https://h/y/z.iso'
    }
    It 'Resolve-VfDownloadUrl stable and latest' {
        Resolve-VfDownloadUrl 'stable' | Should -Match 'stable-virtio/virtio-win\.iso$'
        Resolve-VfDownloadUrl 'latest' | Should -Match 'latest-virtio/virtio-win\.iso$'
    }
    It 'Resolve-VfDownloadUrl rejects a bad version' { Get-VfTestError { Resolve-VfDownloadUrl 'new' } | Should -BeLike '*Invalid*' }
    It 'Resolve-VfDownloadUrl finds a version in the archive' {
        Mock -ModuleName VirtIOForge Get-VfWebText {
            if ($Url -match 'archive-virtio/$') { '<a href="virtio-win-0.1.271-1/">x</a><a href="virtio-win-0.1.285-1/">y</a>' }
            else { '<a href="virtio-win-0.1.271.iso">i</a><a href="virtio-win.iso">j</a>' }
        }
        Resolve-VfDownloadUrl '0.1.271' | Should -Match 'archive-virtio/virtio-win-0\.1\.271-1/virtio-win-0\.1\.271\.iso$'
    }
    It 'Resolve-VfDownloadUrl falls back to virtio-win.iso' {
        Mock -ModuleName VirtIOForge Get-VfWebText {
            if ($Url -match 'archive-virtio/$') { '<a href="virtio-win-0.1.271-1/">x</a>' } else { '<a href="virtio-win.iso">j</a>' }
        }
        Resolve-VfDownloadUrl '0.1.271' | Should -Match '0\.1\.271-1/virtio-win\.iso$'
    }
    It 'Resolve-VfDownloadUrl without the version' {
        Mock -ModuleName VirtIOForge Get-VfWebText { '<a href="virtio-win-0.1.285-1/">y</a>' }
        Get-VfTestError { Resolve-VfDownloadUrl '0.1.271' } | Should -BeLike '*not found*'
    }
    It 'Resolve-VfDownloadUrl without an ISO' {
        Mock -ModuleName VirtIOForge Get-VfWebText { if ($Url -match 'archive-virtio/$') { '<a href="virtio-win-0.1.271-1/">x</a>' } else { '<a href="a.txt">t</a>' } }
        Get-VfTestError { Resolve-VfDownloadUrl '0.1.271' } | Should -BeLike '*No virtio-win ISO*'
    }
    It 'Find-VfIsoInFolder' {
        $d = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $d | Out-Null
        Get-VfTestError { Find-VfIsoInFolder $d } | Should -BeLike '*No virtio-win*'
        foreach ($v in '0.1.9', '0.1.285', '0.1.30') { Set-Content (Join-Path $d "virtio-win-$v.iso") 'x' }
        Set-Content (Join-Path $d 'virtio-win-stable.iso') 'x'
        Find-VfIsoInFolder $d 'stable' | Should -Be (Join-Path $d 'virtio-win-0.1.285.iso')
        Find-VfIsoInFolder $d '0.1.30' | Should -Be (Join-Path $d 'virtio-win-0.1.30.iso')
        Get-VfTestError { Find-VfIsoInFolder $d '0.1.1' } | Should -BeLike '*not found*'
    }
    It 'Open-VfVirtio: missing path' { Get-VfTestError { Open-VfVirtio (Join-Path $TestDrive 'nope') } | Should -BeLike '*Not found*' }
    It 'Open-VfVirtio: ISO file' {
        $f = Join-Path $TestDrive 'any.iso'
        Set-Content $f 'x'
        Mock -ModuleName VirtIOForge Mount-VfIso { [pscustomobject]@{ Root = $vio; Label = 'virtio-win-0.1.302'; ImagePath = $Path } }
        $o = Open-VfVirtio $f
        $o.Root | Should -Be $vio
        $o.Version | Should -Be '0.1.302'
        $o.Mounted.ImagePath | Should -Be $f
    }
    It 'Open-VfVirtio: not a virtio-win ISO' {
        $f = Join-Path $TestDrive 'other.iso'
        Set-Content $f 'x'
        Mock -ModuleName VirtIOForge Mount-VfIso { [pscustomobject]@{ Root = $TestDrive; Label = 'X'; ImagePath = $Path } }
        Mock -ModuleName VirtIOForge Dismount-VfIso { }
        Get-VfTestError { Open-VfVirtio $f } | Should -BeLike '*Not a virtio-win ISO*'
        Should -Invoke -ModuleName VirtIOForge Dismount-VfIso -Times 1 -Exactly
    }
    It 'Open-VfVirtio: virtio-win drive' {
        Mock -ModuleName VirtIOForge Get-VfVolumeLabel { 'virtio-win-0.1.285' }
        $o = Open-VfVirtio $vio
        $o.Root | Should -Be $vio
        $o.Version | Should -Be '0.1.285'
        $o.Mounted | Should -BeNullOrEmpty
    }
    It 'Open-VfVirtio: folder with ISOs, version from the file name' {
        $d = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $d | Out-Null
        Set-Content (Join-Path $d 'virtio-win-0.1.271.iso') 'x'
        Mock -ModuleName VirtIOForge Mount-VfIso { [pscustomobject]@{ Root = $vio; Label = 'CDROM'; ImagePath = $Path } }
        (Open-VfVirtio $d).Version | Should -Be '0.1.271'
    }
    It 'Open-VfVirtio: download of stable, named after the version' {
        $dl = Join-Path (Get-VfDataDir) 'download'
        New-Item -ItemType Directory -Force $dl | Out-Null
        Set-Content (Join-Path $dl 'virtio-win-0.1.302.iso') 'old'
        Mock -ModuleName VirtIOForge Enable-VfTls12 { }
        Mock -ModuleName VirtIOForge Resolve-VfDownloadUrl { 'https://h/stable-virtio/virtio-win.iso' }
        Mock -ModuleName VirtIOForge Save-VfWebFile { Set-Content $Path 'new' }
        Mock -ModuleName VirtIOForge Mount-VfIso { [pscustomobject]@{ Root = $vio; Label = 'virtio-win-0.1.302'; ImagePath = $Path } }
        Mock -ModuleName VirtIOForge Dismount-VfIso { }
        $o = Open-VfVirtio -Version 'stable'
        $o.Version | Should -Be '0.1.302'
        $o.Mounted.ImagePath | Should -Be (Join-Path $dl 'virtio-win-0.1.302.iso')
        Get-Content (Join-Path $dl 'virtio-win-0.1.302.iso') | Should -Be 'new'
        Test-Path (Join-Path $dl 'virtio-win-stable.iso') | Should -BeFalse
    }
    It 'Open-VfVirtio: download keeps its name while the older file is in use' {
        $dl = Join-Path (Get-VfDataDir) 'download'
        New-Item -ItemType Directory -Force $dl | Out-Null
        $old = Join-Path $dl 'virtio-win-0.1.302.iso'
        Set-Content $old 'old'
        Mock -ModuleName VirtIOForge Enable-VfTls12 { }
        Mock -ModuleName VirtIOForge Resolve-VfDownloadUrl { 'https://h/latest-virtio/virtio-win.iso' }
        Mock -ModuleName VirtIOForge Save-VfWebFile { Set-Content $Path 'new' }
        Mock -ModuleName VirtIOForge Mount-VfIso { [pscustomobject]@{ Root = $vio; Label = 'virtio-win-0.1.302'; ImagePath = $Path } }
        Mock -ModuleName VirtIOForge Dismount-VfIso { }
        $lock = [IO.File]::Open($old, 'Open', 'Read', 'None')
        try { $o = Open-VfVirtio -Version 'latest' } finally { $lock.Close() }
        $o.Mounted.ImagePath | Should -Be (Join-Path $dl 'virtio-win-latest.iso')
        $o.Version | Should -Be '0.1.302'
        Get-Content $old | Should -Be 'old'
        Get-VfTestLog | Should -Match 'kept virtio-win-latest.iso: virtio-win-0.1.302.iso is in use'
    }
    It 'Open-VfVirtio: download of a version, unknown label' {
        Mock -ModuleName VirtIOForge Enable-VfTls12 { }
        Mock -ModuleName VirtIOForge Resolve-VfDownloadUrl { 'https://h/a/virtio-win-0.1.271.iso' }
        Mock -ModuleName VirtIOForge Save-VfWebFile { Set-Content $Path 'new' }
        Mock -ModuleName VirtIOForge Mount-VfIso { [pscustomobject]@{ Root = $vio; Label = 'CDROM'; ImagePath = $Path } }
        Mock -ModuleName VirtIOForge Dismount-VfIso { }
        (Open-VfVirtio -Version '0.1.271').Version | Should -Be '0.1.271'
    }
    It 'Open-VfVirtio: download already named after its version' {
        Mock -ModuleName VirtIOForge Enable-VfTls12 { }
        Mock -ModuleName VirtIOForge Resolve-VfDownloadUrl { 'https://h/a/virtio-win-0.1.271.iso' }
        Mock -ModuleName VirtIOForge Save-VfWebFile { Set-Content $Path 'new' }
        Mock -ModuleName VirtIOForge Mount-VfIso { [pscustomobject]@{ Root = $vio; Label = 'virtio-win-0.1.271'; ImagePath = $Path } }
        Mock -ModuleName VirtIOForge Dismount-VfIso { }
        (Open-VfVirtio -Version '0.1.271').Mounted.ImagePath | Should -Match 'virtio-win-0\.1\.271\.iso$'
    }
    It 'Open-VfVirtio: unknown version' {
        Mock -ModuleName VirtIOForge Enable-VfTls12 { }
        Mock -ModuleName VirtIOForge Resolve-VfDownloadUrl { 'https://h/stable-virtio/virtio-win.iso' }
        Mock -ModuleName VirtIOForge Save-VfWebFile { Set-Content $Path 'new' }
        Mock -ModuleName VirtIOForge Mount-VfIso { [pscustomobject]@{ Root = $vio; Label = 'CDROM'; ImagePath = $Path } }
        Mock -ModuleName VirtIOForge Dismount-VfIso { }
        (Open-VfVirtio).Version | Should -Be 'unknown'
    }
    It 'Close-VfVirtio' {
        Mock -ModuleName VirtIOForge Dismount-VfIso { }
        Close-VfVirtio $null
        Close-VfVirtio ([pscustomobject]@{ Mounted = 'm' })
        Should -Invoke -ModuleName VirtIOForge Dismount-VfIso -Times 1 -Exactly
    }
}

Describe 'Driver selection' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
    }

    It 'Get-VfInfoList reads info.json' {
        $l = Get-VfInfoList $vio
        $l | Should -Contain 'viostor/w11/amd64/viostor.inf'
        $l | Should -Not -Contain 'qemupciserial/w11/amd64/qemupciserial.inf'
        Get-VfInfoList $TestDrive | Should -BeNullOrEmpty
    }
    It 'Get-VfInfInfo reads catalog and version' {
        $i = Get-VfInfInfo (Join-Path $vio 'viostor\w11\amd64\viostor.inf')
        $i.Catalog | Should -Be 'viostor.cat'
        $i.Version | Should -Be ([version]'100.103.104.30200')
        $i.Name | Should -Be 'viostor.inf'
    }
    It 'Test-VfSignedInf checks each catalog once' {
        $inf = Join-Path $vio 'viostor\w11\amd64\viostor.inf'
        Test-VfSignedInf $inf | Should -BeTrue
        Test-VfSignedInf $inf | Should -BeTrue
        Should -Invoke -ModuleName VirtIOForge Get-VfCatalogSignature -Times 1 -Exactly
    }
    It 'Get-VfCatalogSignature reads the Authenticode signature' {
        "$((Get-VfCatalogSignature (Join-Path $vio 'viostor\w11\amd64\viostor.cat')).Status)" | Should -Not -Be 'Valid'
    }
    It 'Test-VfSignedInfOnce skips an invalid signature' {
        Test-VfSignedInfOnce (Join-Path $vio 'smbus\w11\amd64\smbus.inf') | Should -BeFalse
        Get-VfTestLog | Should -Match 'skipped smbus.inf: catalog signature UnknownError'
    }
    It 'Test-VfSignedInfOnce takes a test-signed package with -AllowTestSigned' {
        $m = Get-Module VirtIOForge
        & $m { $script:AllowTestSigned = $true; $script:TestSigned = @{} }
        try {
            $inf = Join-Path $vio 'smbus\w11\amd64\smbus.inf'
            Test-VfSignedInfOnce $inf | Should -BeTrue
            (& $m { $script:TestSigned }).ContainsKey($inf) | Should -BeTrue
            Get-VfTestLog | Should -Match 'test-signed smbus.inf: CN=Test'
        } finally { & $m { $script:AllowTestSigned = $false; $script:TestSigned = @{} } }
    }
    It 'Test-VfSignedInfOnce treats a trusted self-signed catalog as test-signed' {
        $m = Get-Module VirtIOForge
        Mock -ModuleName VirtIOForge Get-VfCatalogSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Dev'; Issuer = 'CN=Dev'; Thumbprint = 'AB12' } }
        }
        $inf = Join-Path $vio 'smbus\w11\amd64\smbus.inf'
        Test-VfSignedInfOnce $inf | Should -BeFalse
        Get-VfTestLog | Should -Match 'skipped smbus.inf: catalog signature self-signed \(CN=Dev\)'
        & $m { $script:AllowTestSigned = $true; $script:TestSigned = @{} }
        try {
            Test-VfSignedInfOnce $inf | Should -BeTrue
            (& $m { $script:TestSigned }).ContainsKey($inf) | Should -BeTrue
        } finally { & $m { $script:AllowTestSigned = $false; $script:TestSigned = @{} } }
    }
    It 'Select-VfReleaseSigned leaves out test-signed packages' {
        $m = Get-Module VirtIOForge
        $dirs = @(Find-VfDriverDirs $vio 'w11' 'amd64' (Get-VfBootDrivers))
        $viostor = ($dirs | Where-Object { $_.Name -eq 'viostor' }).Infs[0].FullName
        & $m { param($p) $script:TestSigned = @{ $p = 'cert' } } $viostor
        try {
            (Select-VfReleaseSigned $dirs).Name | Should -Be @('NetKVM', 'vioscsi')
            @(Select-VfReleaseSigned @()).Count | Should -Be 0
        } finally { & $m { $script:TestSigned = @{} } }
    }
    It 'Test-VfSignedInfOnce skips a package without catalog' {
        $a = Join-Path $TestDrive 'nocat\a.inf'
        New-VfTestInf $a
        Test-VfSignedInfOnce $a | Should -BeFalse
        $b = Join-Path $TestDrive 'nocat\b.inf'
        New-VfTestInf $b
        Add-Content $b 'CatalogFile = missing.cat'
        Test-VfSignedInfOnce $b | Should -BeFalse
        Get-VfTestLog | Should -Match 'skipped b.inf: no catalog'
    }
    It 'Get-VfMissingFiles lists the source files missing next to the INF' {
        $a = Join-Path $TestDrive 'miss\a.inf'
        New-VfTestInf $a
        Add-Content $a '[SourceDisksFiles]', 'a.sys = 1,,', '[SourceDisksFiles.amd64]', 'WdfCoInstaller01011.dll=1 ; co', '[a.CopyFiles]', 'c.sys'
        Set-Content (Join-Path $TestDrive 'miss\a.sys') 'sys'
        @(Get-VfMissingFiles $a) | Should -Be @('WdfCoInstaller01011.dll')
        Test-VfSignedInfOnce $a | Should -BeFalse
        Get-VfTestLog | Should -Match 'skipped a.inf: virtio-win lacks WdfCoInstaller01011.dll'
    }
    It 'Find-VfDriverDirs follows info.json and the signatures' {
        $r = @(Find-VfDriverDirs $vio 'w11' 'amd64')
        $r.Name | Should -Be @('Balloon', 'NetKVM', 'vioscsi', 'viostor')
        $r[0].Infs[0].Name | Should -Be 'balloon.inf'
        $r[0].Path | Should -Be (Join-Path $vio 'Balloon\w11\amd64')
    }
    It 'Find-VfDriverDirs without info.json takes every folder' {
        Remove-Item (Join-Path $vio 'data\info.json')
        (Find-VfDriverDirs $vio 'w7' 'x86').Name | Should -Contain 'qemupciserial'
    }
    It 'Find-VfDriverDirs -Only' {
        (Find-VfDriverDirs $vio 'w7' 'amd64' (Get-VfBootDrivers)).Name | Should -Be @('NetKVM', 'vioscsi', 'viostor')
    }
    It 'Find-VfDriverDirs without drivers' { Get-VfTestError { Find-VfDriverDirs $vio '2k25' 'amd64' } | Should -BeLike '*no drivers for 2k25 amd64*' }
    It 'Test-VfGuestToolsSupported from Windows 10 on' {
        Test-VfGuestToolsSupported ([version]'10.0.14393') | Should -BeTrue
        Test-VfGuestToolsSupported ([version]'6.1.7601') | Should -BeFalse
        Get-VfTestLog | Should -Match 'need Windows 10 / Server 2016 or later, skipped for 6.1.7601'
    }
    It 'Get-VfGuestTools' {
        (Get-VfGuestTools $vio 'amd64').Name | Should -Be 'virtio-win-guest-tools.exe'
        (Get-VfGuestTools $vio 'x86').Name | Should -Be @('virtio-win-gt-x86.msi', 'qemu-ga-i386.msi')
        Get-VfGuestTools $TestDrive 'amd64' | Should -BeNullOrEmpty
    }
}

Describe 'Running Windows' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $win = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force (Join-Path $win 'System32\Recovery'), (Join-Path $win 'INF') | Out-Null
        Mock -ModuleName VirtIOForge Get-VfWindowsDir { $win }
    }

    It 'Test-VfNewPnputil' {
        Test-VfNewPnputil ([version]'10.0.14393') | Should -BeTrue
        Test-VfNewPnputil ([version]'10.0.10586') | Should -BeFalse
        Test-VfNewPnputil ([version]'6.1.7601') | Should -BeFalse
    }
    It 'Add-VfDriverOnline with the new syntax' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 3010; Output = @() } }
        $r = Add-VfDriverOnline 'a.inf' ([version]'10.0.26100')
        $r.Ok | Should -BeTrue
        $r.Reboot | Should -BeTrue
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $ArgumentList[0] -eq '/add-driver' -and $ArgumentList[2] -eq '/install' }
    }
    It 'Add-VfDriverOnline with the old syntax and an error' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 5; Output = @('access denied') } }
        $r = Add-VfDriverOnline 'a.inf' ([version]'6.1.7601')
        $r.Ok | Should -BeFalse
        $r.Reboot | Should -BeFalse
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $ArgumentList -join ' ' -eq '-i -a a.inf' }
        Get-VfTestLog | Should -Match 'access denied'
    }
    It 'Get-VfInstallInf keeps CRLF and UTF-16 INFs' {
        $d = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $d | Out-Null
        $crlf = Join-Path $d 'a.inf'
        [IO.File]::WriteAllBytes($crlf, [Text.Encoding]::ASCII.GetBytes("[Version]`r`nx=1`r`n"))
        Get-VfInstallInf $crlf | Should -Be $crlf
        $u16 = Join-Path $d 'b.inf'
        [IO.File]::WriteAllText($u16, "[Version]`nx=1`n", [Text.Encoding]::Unicode)
        Get-VfInstallInf $u16 | Should -Be $u16
    }
    It 'Get-VfInstallInf keeps an LF INF its catalog covers as it is' {
        $d = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $d | Out-Null
        $inf = Join-Path $d 'fwcfg.inf'
        $b = [Text.Encoding]::ASCII.GetBytes("[Version]`r`nx=1`n")
        [IO.File]::WriteAllBytes($inf, $b)
        [IO.File]::WriteAllBytes((Join-Path $d 'other.cat'), [byte[]](1, 2, 3))
        $h = [Security.Cryptography.SHA256]::Create().ComputeHash($b)
        [IO.File]::WriteAllBytes((Join-Path $d 'fwcfg.cat'), [byte[]](@(48, 130) + $h + @(5)))
        Get-VfInstallInf $inf | Should -Be $inf
    }
    It 'Get-VfInstallInf installs an LF INF from a CRLF copy of the package' {
        $d = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $d | Out-Null
        $inf = Join-Path $d 'viostor.inf'
        [IO.File]::WriteAllBytes($inf, [Text.Encoding]::ASCII.GetBytes("`n[Version]`nx=1`r`n"))
        Set-Content (Join-Path $d 'viostor.sys') 'sys'
        $h = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes("`r`n[Version]`r`nx=1`r`n"))
        [IO.File]::WriteAllBytes((Join-Path $d 'viostor.cat'), [byte[]](@(48) + $h))
        (Get-Item $inf).Attributes = 'ReadOnly'
        $new = Get-VfInstallInf $inf
        $new | Should -BeLike "$(Get-VfDataDir)\inf\*\viostor.inf"
        [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($new)) | Should -Be "`r`n[Version]`r`nx=1`r`n"
        Test-Path (Join-Path (Split-Path $new -Parent) 'viostor.sys') | Should -BeTrue
        Get-VfTestLog | Should -Match 'viostor.inf: LF line ends, installed from a CRLF copy'
    }
    It 'Get-VfInstallInf keeps an INF that matches in no form, unless the package is test-signed' {
        $d = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $d | Out-Null
        $inf = Join-Path $d 'balloon.inf'
        [IO.File]::WriteAllBytes($inf, [Text.Encoding]::ASCII.GetBytes("[Version]`nx=2`n"))
        Set-Content (Join-Path $d 'balloon.cat') 'cat'
        Mock -ModuleName VirtIOForge Get-VfOwnCert { 'cert' }
        Mock -ModuleName VirtIOForge New-VfPackageCatalog { }
        Get-VfInstallInf $inf | Should -Be $inf
        $m = Get-Module VirtIOForge
        & $m { param($p) $script:TestSigned = @{ $p = 'dev' } } $inf
        try { $new = Get-VfInstallInf $inf } finally { & $m { $script:TestSigned = @{} } }
        $new | Should -BeLike "$(Get-VfDataDir)\inf\*\balloon.inf"
        Should -Invoke -ModuleName VirtIOForge New-VfPackageCatalog -ParameterFilter { $Inf -eq $new -and $Certificate -eq 'cert' } -Times 1 -Exactly
        Get-VfTestLog | Should -Match 'balloon.inf: does not match its catalog, installed with a new catalog signed by the local certificate'
    }
    It 'Get-VfReAgentState' {
        $x = Join-Path $win 'System32\Recovery\ReAgent.xml'
        Get-VfReAgentState | Should -BeNullOrEmpty
        Set-Content $x '<?xml version="1.0"?><WindowsRE version="2.0"></WindowsRE>'
        Get-VfReAgentState | Should -BeNullOrEmpty
        Set-Content $x '<?xml version="1.0"?><WindowsRE version="2.0"><InstallState state="1"/></WindowsRE>'
        Get-VfReAgentState | Should -BeTrue
        Set-Content $x '<?xml version="1.0"?><WindowsRE version="2.0"><InstallState state="0"/></WindowsRE>'
        Get-VfReAgentState | Should -BeFalse
    }
    It 'Invoke-VfDism' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Invoke-VfDism @('/Get-WimInfo')
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $FilePath -eq 'dism.exe' -and $ArgumentList[0] -eq '/English' }
    }
    It 'Invoke-VfDism throws on an error' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 2; Output = @('a', 'b') } }
        Get-VfTestError { Invoke-VfDism @('/Get-WimInfo') } | Should -BeLike '*failed (2)*'
    }


    It 'Install-VfGuestTools without tools' {
        Install-VfGuestTools $TestDrive 'amd64' | Should -BeFalse
    }
    It 'Install-VfGuestTools runs the installers' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = $(if ($FilePath -eq 'msiexec.exe') { 3010 } else { 0 }); Output = @() } }
        Install-VfGuestTools $vio 'amd64' | Should -BeFalse
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $FilePath -like '*virtio-win-guest-tools.exe' -and $ArgumentList[0] -eq '/install' }
        Install-VfGuestTools $vio 'x86' | Should -BeTrue
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $FilePath -eq 'msiexec.exe' } -Times 2 -Exactly
    }
    It 'Install-VfGuestTools stops on an error' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 1603; Output = @() } }
        Get-VfTestError { Install-VfGuestTools $vio 'x86' } | Should -BeLike '*virtio-win-gt-x86.msi failed (1603)*'
    }
    It 'Get-VfOldDriverPackages keeps the newest and used ones' {
        $inf = Join-Path $win 'INF'
        New-VfTestInf (Join-Path $inf 'oem1.inf') 'viostor.cat' '100.2.0.0'
        New-VfTestInf (Join-Path $inf 'oem2.inf') 'viostor.cat' '100.1.0.0'
        New-VfTestInf (Join-Path $inf 'oem3.inf') 'viostor.cat' '100.0.0.0'
        New-VfTestInf (Join-Path $inf 'oem4.inf') 'other.cat' '1.0.0.0'
        New-VfTestInf (Join-Path $inf 'oem5.inf')
        Mock -ModuleName VirtIOForge Get-WmiObject { [pscustomobject]@{ InfName = 'OEM3.inf' }; [pscustomobject]@{ InfName = $null } }
        (Get-VfOldDriverPackages @('viostor.cat')).Name | Should -Be 'oem2.inf'
    }
    It 'Remove-VfDriverPackage with the new syntax' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Remove-VfDriverPackage 'oem2.inf' ([version]'10.0.26100') | Should -BeTrue
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $ArgumentList[0] -eq '/delete-driver' }
    }
    It 'Remove-VfDriverPackage with the old syntax' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 2; Output = @() } }
        Remove-VfDriverPackage 'oem2.inf' ([version]'6.1.7601') | Should -BeFalse
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $ArgumentList[0] -eq '-d' }
    }


}

Describe 'Windows media' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $work = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force $work | Out-Null
    }

    It 'Test-VfServerImage' {
        Test-VfServerImage ([pscustomobject]@{ InstallationType = 'Server Core' }) | Should -BeTrue
        Test-VfServerImage ([pscustomobject]@{ InstallationType = 'Client' }) | Should -BeFalse
        Test-VfServerImage ([pscustomobject]@{ EditionId = 'ServerStandard' }) | Should -BeTrue
        Test-VfServerImage ([pscustomobject]@{ ImageName = 'Windows Server 2008 R2 SERVERWEB' }) | Should -BeTrue
        Test-VfServerImage ([pscustomobject]@{ ImageName = 'Windows 7 ULTIMATE' }) | Should -BeFalse
    }
    It 'builds a bootable ISO with IMAPI2' {
        $m = Join-Path $work 'media'
        New-Item -ItemType Directory -Force (Join-Path $m 'boot'), (Join-Path $m 'efi\microsoft\boot'), (Join-Path $m 'sources') | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $m 'boot\etfsboot.com'), (New-Object byte[] 2048))
        [IO.File]::WriteAllBytes((Join-Path $m 'efi\microsoft\boot\efisys.bin'), (New-Object byte[] 4096))
        Set-Content (Join-Path $m 'sources\install.wim') 'wim'
        Initialize-VfNative
        $img = New-VfIsoImage $m 'TEST_ISO'
        $out = Join-Path $work 'out.iso'
        $n = Save-VfIso $img $out
        $n | Should -Be (Get-Item $out).Length
        $img = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        # mount the new ISO for real
        $iso = Mount-VfIso $out
        try {
            $iso.Label | Should -Be 'TEST_ISO'
            Test-Path (Join-Path $iso.Root 'sources\install.wim') | Should -BeTrue
            $iso.ImagePath | Should -Be $out
        } finally { Dismount-VfIso $iso }
    }
    It 'builds a BIOS-only ISO without efisys.bin' {
        $m = Join-Path $work 'media'
        New-Item -ItemType Directory -Force (Join-Path $m 'boot') | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $m 'boot\etfsboot.com'), (New-Object byte[] 2048))
        $img = New-VfIsoImage $m 'BIOS'
        Get-VfTestLog | Should -Match 'BIOS boot only'
        $img = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    It 'refuses media without etfsboot.com' { Get-VfTestError { New-VfIsoImage $work 'X' } | Should -BeLike '*Boot image missing*' }
    It 'Open-VfComStream loads a file' {
        $f = Join-Path $work 'a.bin'
        [IO.File]::WriteAllBytes($f, [byte[]](1, 2, 3))
        (Open-VfComStream $f).Size | Should -Be 3
    }
    It 'Add-VfImageDrivers adds every INF with dism.exe' {
        Mock -ModuleName VirtIOForge Invoke-VfDism { }
        Add-VfImageDrivers 'C:\m' @(Find-VfDriverDirs $vio 'w11' 'amd64')
        Should -Invoke -ModuleName VirtIOForge Invoke-VfDism -ParameterFilter { $ArgumentList[0] -eq '/Image:C:\m' -and $ArgumentList[1] -eq '/Add-Driver' } -Times 4 -Exactly
    }
    It 'Get-VfImages returns the details of every index' {
        Mock -ModuleName VirtIOForge Get-WindowsImage { if ($Index) { [pscustomobject]@{ ImageIndex = $Index; Detail = $true } } else { [pscustomobject]@{ ImageIndex = 1 }; [pscustomobject]@{ ImageIndex = 2 } } }
        $r = @(Get-VfImages 'x.wim')
        $r.ImageIndex | Should -Be @(1, 2)
        $r[1].Detail | Should -BeTrue
    }
    It 'Clear-VfMountDir empties the folder' {
        $d = Join-Path $work 'mnt'
        Clear-VfMountDir $d
        Set-Content (Join-Path $d 'f') 'x'
        Clear-VfMountDir $d
        @(Get-ChildItem $d).Count | Should -Be 0
    }



    It 'New-VfGuestToolsFiles without tools' {
        New-VfGuestToolsFiles $work $TestDrive 'amd64'
        Test-Path (Join-Path $work 'autounattend.xml') | Should -BeFalse
    }
    It 'New-VfGuestToolsFiles for amd64' {
        New-VfGuestToolsFiles $work $vio 'amd64'
        $dir = Join-Path $work 'sources\$OEM$\$1\ProgramData\VirtIOForge\Media'
        Test-Path (Join-Path $dir 'virtio-win-guest-tools.exe') | Should -BeTrue
        Get-Content (Join-Path $dir 'Install.cmd') -Raw | Should -Match '"%D%virtio-win-guest-tools.exe" /install /quiet /norestart'
        Get-Content (Join-Path $work 'sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd') -Raw | Should -Match 'Install.cmd'
        ([xml](Get-Content (Join-Path $work 'autounattend.xml') -Raw)).unattend.settings.component.processorArchitecture | Should -Be 'amd64'
    }
    It 'New-VfGuestToolsFiles for x86' {
        New-VfGuestToolsFiles $work $vio 'x86'
        $cmd = Get-Content (Join-Path $work 'sources\$OEM$\$1\ProgramData\VirtIOForge\Media\Install.cmd') -Raw
        $cmd | Should -Match 'msiexec.exe /i "%D%virtio-win-gt-x86.msi"'
        $cmd | Should -Match 'msiexec.exe /i "%D%qemu-ga-i386.msi"'
        ([xml](Get-Content (Join-Path $work 'autounattend.xml') -Raw)).unattend.settings.component.processorArchitecture | Should -Be 'x86'
    }
}

Describe 'Update-VfWinRE' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $win = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force (Join-Path $win 'System32\Recovery'), (Join-Path $win 'INF') | Out-Null
        Mock -ModuleName VirtIOForge Get-VfWindowsDir { $win }
        $dirs = @(Find-VfDriverDirs $vio 'w11' 'amd64' (Get-VfBootDrivers))
        $wim = Join-Path $win 'System32\Recovery\Winre.wim'
        Mock -ModuleName VirtIOForge Get-VfDismError { }
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 0; Output = @() } }
    }
    It 'skips without WinRE configuration' {
        Mock -ModuleName VirtIOForge Get-VfReAgentState { $null }
        Update-VfWinRE $dirs
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -Times 0 -Exactly
    }
    It 'stops when reagentc /disable fails' {
        Mock -ModuleName VirtIOForge Get-VfReAgentState { $true }
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 2; Output = @() } }
        Get-VfTestError { Update-VfWinRE $dirs } | Should -BeLike '*reagentc /disable*'
    }
    It 'skips a missing image and enables WinRE again' {
        Mock -ModuleName VirtIOForge Get-VfReAgentState { $true }
        Update-VfWinRE $dirs
        Get-VfTestLog | Should -Match 'WinRE image not found'
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $ArgumentList[0] -eq '/enable' } -Times 1 -Exactly
    }
    It 'adds the drivers and keeps the attributes' {
        Mock -ModuleName VirtIOForge Get-VfReAgentState { $true }
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = $(if ($ArgumentList[0] -eq '/enable') { 5 } else { 0 }); Output = @() } }
        Set-Content $wim 'wim'
        (Get-Item $wim).Attributes = 'Hidden, System'
        New-Item -ItemType Directory -Force (Join-Path (Get-VfDataDir) 'winre-mount') | Out-Null
        Update-VfWinRE $dirs
        Should -Invoke -ModuleName VirtIOForge Get-VfDismError -ParameterFilter { $ArgumentList[0] -eq '/Mount-Wim' } -Times 1 -Exactly
        Should -Invoke -ModuleName VirtIOForge Get-VfDismError -ParameterFilter { $ArgumentList[1] -eq '/Add-Driver' } -Times 3 -Exactly
        Should -Invoke -ModuleName VirtIOForge Get-VfDismError -ParameterFilter { $ArgumentList[2] -eq '/Commit' } -Times 1 -Exactly
        (Get-Item $wim -Force).Attributes | Should -Be ([IO.FileAttributes]'Hidden, System')
        Get-VfTestLog | Should -Match 'reagentc /enable failed'
    }
}

# Without Pester's Mock: on this path (module mock calls around a DISM error in nested try/catch)
# Pester 6.2 on Windows PowerShell 5.1 overflows the call depth; the code itself works.
Describe 'Update-VfWinRE on a DISM error' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $dirs = @(Find-VfDriverDirs $vio 'w11' 'amd64' (Get-VfBootDrivers))
        $win = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force (Join-Path $win 'System32\Recovery') | Out-Null
        Set-Content (Join-Path $win 'System32\Recovery\Winre.wim') 'wim'
        $global:VfCalls = New-Object Collections.ArrayList
        $global:VfFailArg = '/Add-Driver'
        $saved = @(
            Set-VfTestFunction Get-VfWindowsDir ([scriptblock]::Create("'$win'"))
            Set-VfTestFunction Invoke-VfNative {
                param($FilePath, $ArgumentList)
                [void]$global:VfCalls.Add("$FilePath $($ArgumentList -join ' ')")
                New-Object PSObject -Property @{ ExitCode = $(if ($ArgumentList -contains $global:VfFailArg) { 50 } else { 0 }); Output = @('bad driver') }
            }
        )
    }
    It 'reports a failed commit' {
        $global:VfFailArg = '/Commit'
        $saved += Set-VfTestFunction Get-VfReAgentState { $false }
        Get-VfTestError { Update-VfWinRE $dirs } | Should -BeLike '*/Commit failed (50)*'
        @($global:VfCalls | Where-Object { $_ -like '*/Discard' }).Count | Should -Be 0
    }
    It 'does not discard when mounting fails' {
        $global:VfFailArg = '/Mount-Wim'
        $saved += Set-VfTestFunction Get-VfReAgentState { $false }
        Get-VfTestError { Update-VfWinRE $dirs } | Should -BeLike '*failed (50)*'
        @($global:VfCalls | Where-Object { $_ -like '*/Discard' }).Count | Should -Be 0
        (Get-Item (Join-Path $win 'System32\Recovery\Winre.wim')).Attributes | Should -Be ([IO.FileAttributes]::Archive)
    }
    AfterEach { Restore-VfTestFunction $saved }
    It 'discards and leaves a disabled WinRE disabled' {
        $saved += Set-VfTestFunction Get-VfReAgentState { $false }
        Get-VfTestError { Update-VfWinRE $dirs } | Should -BeLike '*failed (50)*'
        @($global:VfCalls | Where-Object { $_ -like '*/Discard' }).Count | Should -Be 1
        @($global:VfCalls | Where-Object { $_ -like 'reagentc.exe*' }).Count | Should -Be 0
    }
    It 'enables an enabled WinRE again' {
        $saved += Set-VfTestFunction Get-VfReAgentState { $true }
        Get-VfTestError { Update-VfWinRE $dirs } | Should -BeLike '*failed (50)*'
        @($global:VfCalls | Where-Object { $_ -eq 'reagentc.exe /enable' }).Count | Should -Be 1
    }
}

Describe 'Trusted publishers' {
    BeforeAll {
        $m = Get-Module VirtIOForge
        & $m { $script:CertStore = 'CurrentUser' }
        $global:VfCert = New-SelfSignedCertificate -Subject 'CN=VfTest Publisher' -CertStoreLocation Cert:\CurrentUser\My
        $global:VfMsCert = New-SelfSignedCertificate -Subject 'CN=VfTest, O=Microsoft Corporation' -CertStoreLocation Cert:\CurrentUser\My
    }
    AfterAll {
        & $m { $script:CertStore = 'LocalMachine' }
        foreach ($c in $global:VfCert, $global:VfMsCert) {
            Remove-Item "Cert:\CurrentUser\My\$($c.Thumbprint)", "Cert:\CurrentUser\TrustedPublisher\$($c.Thumbprint)" -ErrorAction SilentlyContinue
        }
        Restore-VfTestEnv
    }
    It 'adds each publisher once, not Microsoft' {
        $env:ProgramData = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force $env:ProgramData | Out-Null
        $d = Join-Path $TestDrive 'pub'
        foreach ($n in 'viostor', 'vioscsi', 'netkvm', 'balloon') { New-VfTestInf (Join-Path $d "$n.inf") "$n.cat" }
        New-VfTestInf (Join-Path $d 'nocat.inf')
        Mock -ModuleName VirtIOForge Get-VfCatalogSignature {
            $c = if ($Path -match 'netkvm') { $global:VfMsCert } elseif ($Path -match 'balloon') { $null } else { $global:VfCert }
            New-Object PSObject -Property @{ Status = 'Valid'; SignerCertificate = $c }
        }
        $infs = @(Get-ChildItem $d -Filter '*.inf')
        $store = "Cert:\CurrentUser\TrustedPublisher\$($global:VfCert.Thumbprint)"
        Add-VfTrustedPublishers $infs
        Add-VfTrustedPublishers $infs
        Test-Path $store | Should -BeTrue
        Test-Path "Cert:\CurrentUser\TrustedPublisher\$($global:VfMsCert.Thumbprint)" | Should -BeFalse
        @((Get-VfTestLog) -split "`n" | Where-Object { $_ -match 'Trusted publisher added: CN=VfTest Publisher' }).Count | Should -Be 1
    }
}

Describe 'Secure Boot and test signing state' {
    It 'Test-VfSecureBoot and Test-VfTestSigningActive read the registry' {
        Test-VfSecureBoot | Should -BeOfType [bool]
        Test-VfTestSigningActive | Should -BeOfType [bool]
        Mock -ModuleName VirtIOForge Get-ItemProperty { [pscustomobject]@{ UEFISecureBootEnabled = 1; SystemStartOptions = ' NOEXECUTE=OPTIN  TESTSIGNING' } }
        Test-VfSecureBoot | Should -BeTrue
        Test-VfTestSigningActive | Should -BeTrue
    }
}

Describe 'Test signing' {
    BeforeAll {
        $m = Get-Module VirtIOForge
        & $m { $script:CertStore = 'CurrentUser'; $script:RootStore = 'TrustedPeople' }
        $global:VfDevCert = New-SelfSignedCertificate -Subject 'CN=VfTest Dev' -CertStoreLocation Cert:\CurrentUser\My
    }
    AfterAll {
        & $m { $script:CertStore = 'LocalMachine'; $script:RootStore = 'Root' }
        Remove-Item "Cert:\CurrentUser\My\$($global:VfDevCert.Thumbprint)", "Cert:\CurrentUser\TrustedPeople\$($global:VfDevCert.Thumbprint)" -ErrorAction SilentlyContinue
        Restore-VfTestEnv
    }
    BeforeEach {
        Reset-VfTest
        Mock -ModuleName VirtIOForge Write-Host { }
        Mock -ModuleName VirtIOForge Test-VfSecureBoot { $false }
        Mock -ModuleName VirtIOForge Test-VfTestSigningActive { $false }
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 0; Output = @() } }
    }
    It 'Read-VfHost reads the answer' {
        Mock -ModuleName VirtIOForge Read-Host { 'answer' }
        Read-VfHost 'Question' | Should -Be 'answer'
    }
    It 'Confirm-VfTestSigning warns and asks for YES' {
        Mock -ModuleName VirtIOForge Read-VfHost { 'YES' }
        Confirm-VfTestSigning | Should -BeTrue
        Should -Invoke -ModuleName VirtIOForge Write-Host -ParameterFilter { "$Object" -match 'bcdedit /set testsigning on' }
        Get-VfTestLog | Should -Match 'Test signing accepted\.'
        Mock -ModuleName VirtIOForge Read-VfHost { 'yes' }
        Confirm-VfTestSigning | Should -BeFalse
    }
    It 'Confirm-VfTestSigning -Force does not ask' {
        Mock -ModuleName VirtIOForge Read-VfHost { 'no' }
        Confirm-VfTestSigning -Force | Should -BeTrue
        Should -Invoke -ModuleName VirtIOForge Read-VfHost -Times 0 -Exactly
        Get-VfTestLog | Should -Match 'accepted with -Force'
    }
    It 'Enable-VfTestSigning stops with Secure Boot on' {
        Mock -ModuleName VirtIOForge Test-VfSecureBoot { $true }
        Get-VfTestError { Enable-VfTestSigning @($global:VfDevCert) } | Should -BeLike 'Secure Boot is on*'
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -Times 0 -Exactly
    }
    It 'Enable-VfTestSigning trusts the certificate once and turns on test signing' {
        Enable-VfTestSigning @($global:VfDevCert, $global:VfDevCert) | Should -BeTrue
        Test-Path "Cert:\CurrentUser\TrustedPeople\$($global:VfDevCert.Thumbprint)" | Should -BeTrue
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $FilePath -eq 'bcdedit.exe' -and ($ArgumentList -join ' ') -eq '/set testsigning on' } -Times 1 -Exactly
        Get-VfTestLog | Should -Match 'load after a restart'
        Mock -ModuleName VirtIOForge Test-VfTestSigningActive { $true }
        Enable-VfTestSigning @($global:VfDevCert) | Should -BeFalse
        @((Get-VfTestLog) -split "`n" | Where-Object { $_ -match 'Trusted root added: CN=VfTest Dev' }).Count | Should -Be 1
    }
    It 'Enable-VfTestSigning reports a bcdedit error' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 1; Output = @('denied') } }
        Get-VfTestError { Enable-VfTestSigning @($global:VfDevCert) } | Should -Be 'bcdedit /set testsigning on failed (1): denied'
    }
    It 'New-VfSigningCert creates the certificate with certreq' {
        $c = New-SelfSignedCertificate -Subject 'CN=VfTest Sign' -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My
        try {
            Set-Content (Join-Path (Get-VfDataDir) 'sign.cer') 'old'
            Mock -ModuleName VirtIOForge Invoke-VfNative {
                Get-Content $ArgumentList[2] | Should -Contain 'OID = 1.3.6.1.5.5.7.3.3'
                [IO.File]::WriteAllBytes($ArgumentList[3], $c.RawData)
                [pscustomobject]@{ ExitCode = 0; Output = @() }
            }
            (New-VfSigningCert).Thumbprint | Should -Be $c.Thumbprint
            Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $FilePath -eq 'certreq.exe' -and $ArgumentList[1] -eq '-q' } -Times 1 -Exactly
            Test-Path (Join-Path (Get-VfDataDir) 'sign.inf') | Should -BeFalse
            Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 5; Output = @('no') } }
            Get-VfTestError { New-VfSigningCert } | Should -Be 'certreq failed (5): no'
        } finally { Remove-Item "Cert:\CurrentUser\My\$($c.Thumbprint)" }
    }
    It 'Get-VfOwnCert trusts one certificate per run, Remove-VfOwnKey deletes its key' {
        $c = New-SelfSignedCertificate -Subject 'CN=VfTest Own' -Type CodeSigningCert -KeySpec Signature -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' -CertStoreLocation Cert:\CurrentUser\My
        $t = $c.Thumbprint
        Mock -ModuleName VirtIOForge New-VfSigningCert { $c }
        try {
            Remove-VfOwnKey
            (Get-VfOwnCert).Thumbprint | Should -Be $t
            (Get-VfOwnCert).Thumbprint | Should -Be $t
            Should -Invoke -ModuleName VirtIOForge New-VfSigningCert -Times 1 -Exactly
            Test-Path "Cert:\CurrentUser\TrustedPeople\$t" | Should -BeTrue
            Test-Path "Cert:\CurrentUser\TrustedPublisher\$t" | Should -BeTrue
            (Get-Item "Cert:\CurrentUser\TrustedPeople\$t").HasPrivateKey | Should -BeFalse
            Remove-VfOwnKey
            Test-Path "Cert:\CurrentUser\My\$t" | Should -BeFalse
            Get-VfTestLog | Should -Match 'Private key of the local signing certificate deleted'
            & (Get-Module VirtIOForge) { $script:OwnCert } | Should -BeNullOrEmpty
        } finally {
            Remove-Item "Cert:\CurrentUser\My\$t", "Cert:\CurrentUser\TrustedPeople\$t", "Cert:\CurrentUser\TrustedPublisher\$t" -ErrorAction SilentlyContinue
        }
    }
    It 'Get-VfDriverStoreCatalogs lists the catalogs of the driver store' {
        @(Get-VfDriverStoreCatalogs | Where-Object { $_ -like '*\FileRepository\*.cat' }).Count | Should -BeGreaterThan 0
    }
    It 'Remove-VfUnusedOwnCerts removes local signing certificates no package uses' {
        $a = New-SelfSignedCertificate -Subject 'CN=VirtIOForge local driver signing A' -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My
        $b = New-SelfSignedCertificate -Subject 'CN=VirtIOForge local driver signing B' -Type CodeSigningCert -CertStoreLocation Cert:\CurrentUser\My
        $stores = @('TrustedPeople', 'TrustedPublisher')
        try {
            foreach ($n in $stores) {
                $s = New-Object Security.Cryptography.X509Certificates.X509Store($n, 'CurrentUser')
                $s.Open('ReadWrite')
                foreach ($c in @($a, $b)) { $s.Add((New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $c.RawData))) }
                $s.Close()
            }
            Mock -ModuleName VirtIOForge Get-VfDriverStoreCatalogs { 'a.cat', 'none.cat' }
            Mock -ModuleName VirtIOForge Get-VfCatalogSignature {
                if ($Path -eq 'a.cat') { [pscustomobject]@{ SignerCertificate = $a } } else { [pscustomobject]@{ SignerCertificate = $null } }
            }
            Remove-VfUnusedOwnCerts
            foreach ($n in $stores) {
                Test-Path "Cert:\CurrentUser\$n\$($a.Thumbprint)" | Should -BeTrue
                Test-Path "Cert:\CurrentUser\$n\$($b.Thumbprint)" | Should -BeFalse
            }
            Should -Invoke -ModuleName VirtIOForge Get-VfDriverStoreCatalogs -Times 1 -Exactly
            Get-VfTestLog | Should -Match 'Unused local signing certificate removed from TrustedPublisher: CN=VirtIOForge local driver signing B'
        } finally {
            foreach ($n in @('My') + $stores) { Remove-Item "Cert:\CurrentUser\$n\$($a.Thumbprint)", "Cert:\CurrentUser\$n\$($b.Thumbprint)" -ErrorAction SilentlyContinue }
        }
    }
    It 'New-VfPackageCatalog writes and signs a catalog over the package' {
        $d = Join-Path $TestDrive ([guid]::NewGuid())
        New-VfTestInf (Join-Path $d 'balloon.inf') 'balloon.cat'
        Set-Content (Join-Path $d 'balloon.sys') 'sys'
        New-Item -ItemType Directory (Join-Path $d 'sub') | Out-Null
        Mock -ModuleName VirtIOForge Set-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; StatusMessage = '' } }
        New-VfPackageCatalog (Join-Path $d 'balloon.inf') $global:VfDevCert
        Should -Invoke -ModuleName VirtIOForge Set-AuthenticodeSignature -ParameterFilter { $FilePath -eq (Join-Path $d 'balloon.cat') -and $Certificate.Thumbprint -eq $global:VfDevCert.Thumbprint } -Times 1 -Exactly
        $b = [IO.File]::ReadAllBytes((Join-Path $d 'balloon.inf'))
        Test-VfInCatalog (Join-Path $d 'balloon.inf') $b | Should -BeTrue
        Test-Path "$d.cdf" | Should -BeFalse
        Mock -ModuleName VirtIOForge Set-AuthenticodeSignature { [pscustomobject]@{ Status = 'UnknownError'; StatusMessage = 'untrusted' } }
        Get-VfTestError { New-VfPackageCatalog (Join-Path $d 'balloon.inf') $global:VfDevCert } | Should -Be 'Signing balloon.cat failed: UnknownError untrusted'
    }
    It 'New-VfPackageCatalog reports a missing catalog name and catalog errors' {
        $d = Join-Path $TestDrive ([guid]::NewGuid())
        New-VfTestInf (Join-Path $d 'a.inf')
        Get-VfTestError { New-VfPackageCatalog (Join-Path $d 'a.inf') 'cert' } | Should -Be 'a.inf names no catalog file.'
        New-VfTestInf (Join-Path $d 'b.inf') 'b.cat'
        Remove-Item (Join-Path $d 'b.cat')
        Set-Content (Join-Path $d 'x=y.sys') 'sys'
        Get-VfTestError { New-VfPackageCatalog (Join-Path $d 'b.inf') 'cert' } | Should -BeLike 'Catalog b.cat not created: *'
    }
}

Describe 'Invoke-VfOnline' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $win = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force (Join-Path $win 'System32\Recovery'), (Join-Path $win 'INF') | Out-Null
        Mock -ModuleName VirtIOForge Get-VfWindowsDir { $win }
        Mock -ModuleName VirtIOForge Get-VfOsInfo { [pscustomobject]@{ Version = [version]'10.0.26100'; Server = $false; Arch = 'amd64' } }
        Mock -ModuleName VirtIOForge Open-VfVirtio { [pscustomobject]@{ Root = $vio; Version = '0.1.302'; Mounted = $null } }
        Mock -ModuleName VirtIOForge Close-VfVirtio { }
        Mock -ModuleName VirtIOForge Add-VfDriverOnline { [pscustomobject]@{ Inf = $Inf; ExitCode = 0; Ok = $true; Reboot = $false } }
        Mock -ModuleName VirtIOForge Update-VfWinRE { }
        Mock -ModuleName VirtIOForge Install-VfGuestTools { $false }
        Mock -ModuleName VirtIOForge Get-VfOldDriverPackages { }
        Mock -ModuleName VirtIOForge Remove-VfDriverPackage { $true }
        Mock -ModuleName VirtIOForge Add-VfTrustedPublishers { }
        Mock -ModuleName VirtIOForge Enable-VfTestSigning { $true }
        Mock -ModuleName VirtIOForge Get-VfOwnCert { 'cert' }
        Mock -ModuleName VirtIOForge New-VfPackageCatalog { }
    }
    It 'installs drivers, WinRE and guest tools' {
        Invoke-VfOnline | Should -Be 0
        Should -Invoke -ModuleName VirtIOForge Enable-VfTestSigning -Times 0 -Exactly
        Should -Invoke -ModuleName VirtIOForge Add-VfTrustedPublishers -ParameterFilter { @($Infs).Count -eq 4 } -Times 1 -Exactly
        Should -Invoke -ModuleName VirtIOForge Add-VfDriverOnline -Times 4 -Exactly
        Should -Invoke -ModuleName VirtIOForge Update-VfWinRE -ParameterFilter { @($DriverDirs).Count -eq 3 } -Times 1 -Exactly
        Should -Invoke -ModuleName VirtIOForge Install-VfGuestTools -Times 1 -Exactly
        Should -Invoke -ModuleName VirtIOForge Get-VfOldDriverPackages -Times 0 -Exactly
        Should -Invoke -ModuleName VirtIOForge Close-VfVirtio -Times 1 -Exactly
    }
    It 'returns 3010 when a driver needs a restart, removes old packages' {
        Mock -ModuleName VirtIOForge Add-VfDriverOnline { [pscustomobject]@{ Inf = $Inf; ExitCode = 3010; Ok = $true; Reboot = $true } }
        Mock -ModuleName VirtIOForge Get-VfOldDriverPackages {
            [pscustomobject]@{ Name = 'oem1.inf'; Catalog = 'viostor.cat'; Version = [version]'1.0' }
            [pscustomobject]@{ Name = 'oem2.inf'; Catalog = 'netkvm.cat'; Version = [version]'1.0' }
        }
        Mock -ModuleName VirtIOForge Remove-VfDriverPackage { $Name -eq 'oem1.inf' }
        Invoke-VfOnline -RemoveOld | Should -Be 3010
        Should -Invoke -ModuleName VirtIOForge Get-VfOldDriverPackages -ParameterFilter { $Catalogs -contains 'viostor.cat' }
        Get-VfTestLog | Should -Match 'Removed oem1.inf'
        Get-VfTestLog | Should -Match 'Could not remove oem2.inf'
    }
    It 'turns on test signing for test-signed drivers, WinRE without them' {
        Mock -ModuleName VirtIOForge Get-VfCatalogSignature {
            $s = if ($Path -match 'smbus|viostor') { 'UnknownError' } else { 'Valid' }
            [pscustomobject]@{ Status = $s; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Dev'; Thumbprint = 'AB12' } }
        }
        $lf = Join-Path $vio 'viostor\w11\amd64\viostor.inf'
        [IO.File]::WriteAllBytes($lf, [Text.Encoding]::ASCII.GetBytes("[Version]`nCatalogFile = viostor.cat`nDriverVer = 07/22/2026,100.103.104.30200`n"))
        Invoke-VfOnline -AllowTestSigned | Should -Be 3010
        Should -Invoke -ModuleName VirtIOForge Add-VfDriverOnline -ParameterFilter { $Inf -like '*\inf\*\viostor.inf' } -Times 1 -Exactly
        Should -Invoke -ModuleName VirtIOForge New-VfPackageCatalog -ParameterFilter { $Inf -like '*\inf\*\viostor.inf' } -Times 1 -Exactly
        Test-Path (Join-Path (Get-VfDataDir) 'inf') | Should -BeFalse
        Should -Invoke -ModuleName VirtIOForge Enable-VfTestSigning -ParameterFilter { @($Certificates).Count -eq 1 } -Times 1 -Exactly
        Should -Invoke -ModuleName VirtIOForge Add-VfDriverOnline -Times 5 -Exactly
        Should -Invoke -ModuleName VirtIOForge Update-VfWinRE -ParameterFilter { @($DriverDirs).Name -join ',' -eq 'NetKVM,vioscsi' } -Times 1 -Exactly
    }
    It 'skips WinRE without release-signed storage and network drivers' {
        Mock -ModuleName VirtIOForge Get-VfCatalogSignature {
            [pscustomobject]@{ Status = 'UnknownError'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Dev'; Thumbprint = 'AB12' } }
        }
        Mock -ModuleName VirtIOForge Enable-VfTestSigning { $false }
        Invoke-VfOnline -AllowTestSigned | Should -Be 0
        Should -Invoke -ModuleName VirtIOForge Update-VfWinRE -Times 0 -Exactly
        Get-VfTestLog | Should -Match 'WinRE: no release-signed storage or network drivers, skipped'
    }
    It 'stops on Windows 8.1 / Server 2012 R2 without a virtio-win version, unless one is given' {
        Mock -ModuleName VirtIOForge Get-VfOsInfo { [pscustomobject]@{ Version = [version]'6.3.9600'; Server = $true; Arch = 'amd64' } }
        Mock -ModuleName VirtIOForge Find-VfDriverDirs { }
        Get-VfTestError { Invoke-VfOnline } | Should -BeLike '*-VirtioVersion 0.1.215*'
        Should -Invoke -ModuleName VirtIOForge Open-VfVirtio -Times 0 -Exactly
        Invoke-VfOnline -VirtioVersion '0.1.215' | Should -Be 0
        Should -Invoke -ModuleName VirtIOForge Open-VfVirtio -ParameterFilter { $Version -eq '0.1.215' } -Times 1 -Exactly
    }
    It 'skips the guest tools before Windows 10' {
        Mock -ModuleName VirtIOForge Get-VfOsInfo { [pscustomobject]@{ Version = [version]'6.1.7601'; Server = $false; Arch = 'x86' } }
        Invoke-VfOnline | Should -Be 0
        Should -Invoke -ModuleName VirtIOForge Install-VfGuestTools -Times 0 -Exactly
    }
    It 'returns 3010 when the guest tools need a restart' {
        Mock -ModuleName VirtIOForge Install-VfGuestTools { $true }
        Invoke-VfOnline | Should -Be 3010
    }
    It 'returns 1 when a driver fails, without WinRE and guest tools' {
        New-VfTestInf (Join-Path $vio 'viostor\w11\amd64\nocat.inf')
        Mock -ModuleName VirtIOForge Find-VfDriverDirs { [pscustomobject]@{ Name = 'viostor'; Path = 'p'; Infs = @(Get-Item (Join-Path $vio 'viostor\w11\amd64\nocat.inf')) } }
        Mock -ModuleName VirtIOForge Add-VfDriverOnline { [pscustomobject]@{ Inf = $Inf; ExitCode = 5; Ok = $false; Reboot = $false } }
        Invoke-VfOnline -NoWinRE -NoGuestTools | Should -Be 1
        Should -Invoke -ModuleName VirtIOForge Update-VfWinRE -Times 0 -Exactly
        Should -Invoke -ModuleName VirtIOForge Install-VfGuestTools -Times 0 -Exactly
        Get-VfTestLog | Should -Match 'nocat.inf FAILED'
    }
}

Describe 'Scheduled task' {
    BeforeEach { Reset-VfTest }
    It 'Register-VfTask creates and starts the task' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Register-VfTask 'C:\s\Update-VirtIO.ps1' @('-RemoveOld')
        Get-Content (Join-Path (Get-VfDataDir) 'RunTask.cmd') -Raw | Should -Match 'Update-VirtIO.ps1" -RemoveOld -FromTask'
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $ArgumentList[0] -eq '/run' } -Times 1 -Exactly
    }
    It 'Register-VfTask: create fails' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 1; Output = @('denied') } }
        Get-VfTestError { Register-VfTask 'C:\s\a.ps1' } | Should -BeLike '*schtasks /create failed (1): denied*'
    }
    It 'Register-VfTask: run fails' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = $(if ($ArgumentList[0] -eq '/run') { 1 } else { 0 }); Output = @() } }
        Get-VfTestError { Register-VfTask 'C:\s\a.ps1' } | Should -BeLike '*schtasks /run failed*'
    }
    It 'Unregister-VfTask' {
        Mock -ModuleName VirtIOForge Invoke-VfNative { }
        Unregister-VfTask
        Should -Invoke -ModuleName VirtIOForge Invoke-VfNative -ParameterFilter { $ArgumentList[0] -eq '/delete' } -Times 1 -Exactly
    }
    It 'ConvertTo-VfArgs' {
        $b = [ordered]@{ AsTask = [switch]$true; VirtioPath = 'D:\'; RemoveOld = [switch]$true; NoWinRE = [switch]$false; FromTask = [switch]$true }
        ConvertTo-VfArgs $b | Should -Be @('-VirtioPath', '"D:\\"', '-RemoveOld')
        # what powershell.exe receives from the task's command line
        $echo = Join-Path $TestDrive 'echo.ps1'
        Set-Content $echo 'param($p) $p'
        & cmd.exe /c ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $echo, (ConvertTo-VfArgs @{ VirtioPath = 'D:\' })[1]) | Should -Be 'D:\'
    }
}

Describe 'Update-VfImageWinRE' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $work = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force $work | Out-Null
        $mnt = Join-Path $work 'img'
        $re = Join-Path $mnt 'Windows\System32\Recovery\winre.wim'
        $dirs = @(Find-VfDriverDirs $vio 'w11' 'amd64' (Get-VfBootDrivers))
        Mock -ModuleName VirtIOForge Mount-WindowsImage { }
        Mock -ModuleName VirtIOForge Dismount-WindowsImage { }
        Mock -ModuleName VirtIOForge Add-VfImageDrivers { Set-Content (Join-Path $work 'winre-0.wim') 'patched' }
    }
    It 'skips an image without WinRE' {
        Update-VfImageWinRE $mnt $dirs $work @{}
        Get-VfTestLog | Should -Match 'no WinRE'
    }
    It 'processes identical WinRE images once' {
        New-Item -ItemType Directory -Force (Split-Path $re -Parent) | Out-Null
        Set-Content $re 'winre'
        (Get-Item $re).Attributes = 'Hidden, System'
        $cache = @{}
        Update-VfImageWinRE $mnt $dirs $work $cache
        Get-Content $re | Should -Be 'patched'
        (Get-Item $re -Force).Attributes | Should -Be ([IO.FileAttributes]'Hidden, System')
        Set-Content $re 'winre' -Force
        Update-VfImageWinRE $mnt $dirs $work $cache
        Get-VfTestLog | Should -Match 'WinRE as before'
        Should -Invoke -ModuleName VirtIOForge Mount-WindowsImage -Times 1 -Exactly
        Should -Invoke -ModuleName VirtIOForge Dismount-WindowsImage -ParameterFilter { $Save } -Times 1 -Exactly
    }
}

# real Add-VfImageDrivers and Invoke-VfDism: see 'Update-VfWinRE on a DISM error'
Describe 'Update-VfImageWinRE on a DISM error' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $work = Join-Path $TestDrive ([guid]::NewGuid())
        $mnt = Join-Path $work 'img'
        $re = Join-Path $mnt 'Windows\System32\Recovery\winre.wim'
        New-Item -ItemType Directory -Force (Split-Path $re -Parent) | Out-Null
        Set-Content $re 'winre'
        Mock -ModuleName VirtIOForge Mount-WindowsImage { }
        Mock -ModuleName VirtIOForge Dismount-WindowsImage { }
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 50; Output = @('bad') } }
    }
    It 'discards' {
        Get-VfTestError { Update-VfImageWinRE $mnt @(Find-VfDriverDirs $vio 'w11' 'amd64' (Get-VfBootDrivers)) $work @{} } | Should -BeLike '*failed (50)*'
        Should -Invoke -ModuleName VirtIOForge Dismount-WindowsImage -ParameterFilter { $Discard } -Times 1 -Exactly
    }
}

Describe 'Update-VfWim' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $work = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force $work | Out-Null
        Mock -ModuleName VirtIOForge Get-VfImages { [pscustomobject]@{ ImageIndex = 1; ImageName = 'A'; Version = '10.0.26100.1' }; [pscustomobject]@{ ImageIndex = 2; ImageName = 'B'; Version = '10.0.26100.1' } }
        Mock -ModuleName VirtIOForge Mount-WindowsImage { }
        Mock -ModuleName VirtIOForge Dismount-WindowsImage { }
        Mock -ModuleName VirtIOForge Add-VfImageDrivers { }
        Mock -ModuleName VirtIOForge Update-VfImageWinRE { }
        $sel = { param($info) Find-VfDriverDirs $vio 'w11' 'amd64' }
    }
    It 'adds drivers to every index and WinRE' {
        Update-VfWim -Path 'x.wim' -Select $sel -WorkPath $work -WinRE
        Should -Invoke -ModuleName VirtIOForge Mount-WindowsImage -Times 2 -Exactly
        Should -Invoke -ModuleName VirtIOForge Update-VfImageWinRE -ParameterFilter { @($DriverDirs).Count -eq 3 } -Times 2 -Exactly
        Should -Invoke -ModuleName VirtIOForge Dismount-WindowsImage -ParameterFilter { $Save } -Times 2 -Exactly
    }
}

# real Add-VfImageDrivers and Invoke-VfDism: see 'Update-VfWinRE on a DISM error'
Describe 'Update-VfWim on a DISM error' {
    BeforeEach {
        Reset-VfTest
        $vio = New-VfTestVirtio (Join-Path $TestDrive ([guid]::NewGuid()))
        $work = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force $work | Out-Null
        Mock -ModuleName VirtIOForge Get-VfImages { [pscustomobject]@{ ImageIndex = 1; ImageName = 'A'; Version = '10.0.26100.1' } }
        Mock -ModuleName VirtIOForge Mount-WindowsImage { }
        Mock -ModuleName VirtIOForge Dismount-WindowsImage { }
        Mock -ModuleName VirtIOForge Update-VfImageWinRE { }
        Mock -ModuleName VirtIOForge Invoke-VfNative { [pscustomobject]@{ ExitCode = 50; Output = @('bad') } }
    }
    It 'discards, without WinRE' {
        Get-VfTestError { Update-VfWim -Path 'x.wim' -Select { param($info) Find-VfDriverDirs $vio 'w11' 'amd64' } -WorkPath $work } | Should -BeLike '*failed (50)*'
        Should -Invoke -ModuleName VirtIOForge Update-VfImageWinRE -Times 0 -Exactly
        Should -Invoke -ModuleName VirtIOForge Dismount-WindowsImage -ParameterFilter { $Discard } -Times 1 -Exactly
    }
}
