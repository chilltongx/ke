[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'VerifyDirectory')]
    [ValidateNotNullOrEmpty()]
    [string]$DistDirectory,

    [Parameter(Mandatory = $true, ParameterSetName = 'VerifyArchive')]
    [ValidateNotNullOrEmpty()]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true, ParameterSetName = 'VerifyExecutable')]
    [ValidateNotNullOrEmpty()]
    [string]$Executable,

    [Parameter(Mandatory = $true, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedDescription = '向当前空聊天输入框安全发送“可”'
$allowedNames = @('LICENSE', 'README.md', 'SHA256SUMS.txt', '可.exe')
$verifierSources = @(
    (Join-Path $PSScriptRoot 'PortablePeVerifier.cs'),
    (Join-Path $PSScriptRoot 'PortableArchiveVerifier.cs'),
    (Join-Path $PSScriptRoot 'PortableWindowVerifier.cs')
)
Add-Type -Path $verifierSources

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-PortableDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Portable directory missing: $Path"
    }

    return (Get-Item -LiteralPath $Path -Force).FullName
}

function Assert-ExactInventory {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $entries = @(Get-ChildItem -LiteralPath $Directory -Force)
    $actualNames = @($entries | ForEach-Object { $_.Name } | Sort-Object)
    $expectedNames = @($allowedNames | Sort-Object)
    $difference = @(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames)

    Assert-Condition ($difference.Count -eq 0) 'Portable contents mismatch'
    Assert-Condition (($entries | Where-Object { -not $_.PSIsContainer }).Count -eq $allowedNames.Count) `
        'Portable contents must be files only'
}

function Assert-PortableHash {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Manifest
    )

    $lines = [IO.File]::ReadAllLines($Manifest)
    Assert-Condition ($lines.Count -eq 1) 'SHA256SUMS.txt must contain exactly one line'

    $match = [regex]::Match($lines[0], '^(?<hash>[0-9A-Fa-f]{64})  可\.exe$')
    Assert-Condition $match.Success 'SHA256SUMS.txt has an invalid format'

    $actualHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
    Assert-Condition ($actualHash -ceq $match.Groups['hash'].Value.ToUpperInvariant()) `
        'SHA-256 mismatch for 可.exe'
}

function Assert-PeMetadata {
    param([Parameter(Mandatory = $true)][string]$Executable)

    [PortablePeVerifier]::Verify($Executable)

    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($Executable)
    Assert-Condition ($version.ProductName -ceq '可') 'ProductName resource must be 可'
    Assert-Condition ($version.FileDescription -ceq $expectedDescription) `
        'FileDescription resource is incorrect'
    Assert-Condition ($version.ProductVersion -match '^1\.0\.0(?:\.0)?(?:\+.*)?$') `
        'ProductVersion resource must be 1.0.0'
    Assert-Condition ($version.FileVersion -match '^1\.0\.0\.0(?:\s.*)?$') `
        'FileVersion resource must be 1.0.0.0'
}

function Stop-ExactProcess {
    param([Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return
    }

    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            $Process.WaitForExit(5000) | Out-Null
        }
    }
    catch [InvalidOperationException] {
        # The exact process has already exited; no broad process-name cleanup is used.
    }
    finally {
        $Process.Dispose()
    }
}

function Assert-SingleInstanceAndCleanExit {
    param([Parameter(Mandatory = $true)][string]$Executable)

    $first = $null
    $second = $null
    $firstWindow = [IntPtr]::Zero
    try {
        $first = Start-Process -FilePath $Executable -PassThru
        $startupDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 100
            $first.Refresh()
            Assert-Condition (-not $first.HasExited) 'First app instance exited during startup'
            $firstWindow = [PortableWindowVerifier]::FindClosableTopLevelWindow($first.Id)
        } while ($firstWindow -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $startupDeadline)

        Assert-Condition ($firstWindow -ne [IntPtr]::Zero) `
            'First app did not expose a closable top-level window during startup'

        $second = Start-Process -FilePath $Executable -PassThru
        Assert-Condition ($second.WaitForExit(5000)) 'Second app instance stayed alive'
        Assert-Condition ($second.ExitCode -eq 0) 'Second app instance did not exit successfully'

        $first.Refresh()
        Assert-Condition (-not $first.HasExited) 'First app instance exited unexpectedly'
        if (-not [PortableWindowVerifier]::IsExactProcessWindow($firstWindow, $first.Id)) {
            $firstWindow = [PortableWindowVerifier]::FindClosableTopLevelWindow($first.Id)
        }
        Assert-Condition (
            [PortableWindowVerifier]::IsExactProcessWindow($firstWindow, $first.Id)
        ) 'First app no longer owns a closable top-level window'
        [PortableWindowVerifier]::PostClose($firstWindow, $first.Id)
        Assert-Condition ($first.WaitForExit(5000)) 'First app did not exit cleanly'
        Assert-Condition ($first.ExitCode -eq 0) 'First app instance did not exit successfully'
    }
    finally {
        Stop-ExactProcess $second
        Stop-ExactProcess $first
    }
}

function Assert-PortableDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $portableDirectory = Get-PortableDirectory $Directory
    Assert-ExactInventory $portableDirectory

    $portableExecutable = Join-Path $portableDirectory '可.exe'
    $manifest = Join-Path $portableDirectory 'SHA256SUMS.txt'
    Assert-Condition (Test-Path -LiteralPath $portableExecutable -PathType Leaf) '可.exe missing'
    Assert-PeMetadata $portableExecutable
    Assert-PortableHash -Executable $portableExecutable -Manifest $manifest
    Assert-SingleInstanceAndCleanExit $portableExecutable
}

function Assert-PortableArchive {
    param([Parameter(Mandatory = $true)][string]$Path)

    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    Assert-Condition (Test-Path -LiteralPath $temporaryParent -PathType Container) `
        'Temporary directory is missing'
    $temporaryParentItem = Get-Item -LiteralPath $temporaryParent -Force
    Assert-Condition (
        ($temporaryParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    ) 'Temporary directory must not be a reparse point'

    $extractionDirectory = [IO.Path]::GetFullPath((Join-Path `
        $temporaryParent `
        "ke-portable-verify-$([Guid]::NewGuid().ToString('N'))"))
    Assert-Condition (
        [string]::Equals(
            [IO.Path]::GetDirectoryName($extractionDirectory),
            $temporaryParent,
            [StringComparison]::OrdinalIgnoreCase)
    ) 'Archive extraction directory escaped the temporary directory'

    [IO.Directory]::CreateDirectory($extractionDirectory) | Out-Null
    try {
        [PortableArchiveVerifier]::VerifyAndExtract($Path, $extractionDirectory)
        Assert-PortableDirectory $extractionDirectory
    }
    finally {
        if (Test-Path -LiteralPath $extractionDirectory) {
            $cleanupPath = [IO.Path]::GetFullPath($extractionDirectory)
            Assert-Condition (
                [string]::Equals(
                    $cleanupPath,
                    $extractionDirectory,
                    [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals(
                    [IO.Path]::GetDirectoryName($cleanupPath),
                    $temporaryParent,
                    [StringComparison]::OrdinalIgnoreCase)
            ) 'Refusing unsafe archive extraction cleanup target'
            $cleanupItem = Get-Item -LiteralPath $cleanupPath -Force
            Assert-Condition (
                ($cleanupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
            ) 'Refusing reparse-point archive extraction cleanup target'
            Remove-Item -LiteralPath $cleanupPath -Recurse -Force
        }
    }
}

if ($SelfTest) {
    [PortablePeVerifier]::RunSelfTests()
    [PortableArchiveVerifier]::RunSelfTests()
    [PortableWindowVerifier]::RunSelfTests()
    Write-Host 'Portable PE, archive, and window verifier self-tests passed.'
    return
}

if ($PSCmdlet.ParameterSetName -eq 'VerifyExecutable') {
    [PortablePeVerifier]::Verify($Executable)
    Write-Host 'Portable Windows executable verified.'
    return
}

if ($PSCmdlet.ParameterSetName -eq 'VerifyArchive') {
    Assert-PortableArchive $ArchivePath
    Write-Host 'Portable Windows ZIP verified.'
    return
}

Assert-PortableDirectory $DistDirectory

Write-Host 'Portable Windows package verified.'
