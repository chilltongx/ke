[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Verify')]
    [ValidateNotNullOrEmpty()]
    [string]$DistDirectory,

    [Parameter(Mandatory = $true, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedDescription = '向当前空聊天输入框安全发送“可”'
$allowedNames = @('LICENSE', 'README.md', 'SHA256SUMS.txt', '可.exe')
$peVerifierSource = Join-Path $PSScriptRoot 'PortablePeVerifier.cs'
Add-Type -Path $peVerifierSource

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
    try {
        $first = Start-Process -FilePath $Executable -PassThru
        $startupDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 100
            $first.Refresh()
            Assert-Condition (-not $first.HasExited) 'First app instance exited during startup'
        } while ($first.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $startupDeadline)

        Assert-Condition ($first.MainWindowHandle -ne [IntPtr]::Zero) `
            'First app did not expose a main window during startup'

        $second = Start-Process -FilePath $Executable -PassThru
        Assert-Condition ($second.WaitForExit(5000)) 'Second app instance stayed alive'
        Assert-Condition ($second.ExitCode -eq 0) 'Second app instance did not exit successfully'

        $first.Refresh()
        Assert-Condition (-not $first.HasExited) 'First app instance exited unexpectedly'
        Assert-Condition $first.CloseMainWindow() 'First app did not expose a closable main window'
        Assert-Condition ($first.WaitForExit(5000)) 'First app did not exit cleanly'
        Assert-Condition ($first.ExitCode -eq 0) 'First app instance did not exit successfully'
    }
    finally {
        Stop-ExactProcess $second
        Stop-ExactProcess $first
    }
}

if ($SelfTest) {
    [PortablePeVerifier]::RunSelfTests()
    Write-Host 'Portable PE verifier self-tests passed.'
    return
}

$portableDirectory = Get-PortableDirectory $DistDirectory
Assert-ExactInventory $portableDirectory

$executable = Join-Path $portableDirectory '可.exe'
$manifest = Join-Path $portableDirectory 'SHA256SUMS.txt'
Assert-Condition (Test-Path -LiteralPath $executable -PathType Leaf) '可.exe missing'
Assert-PeMetadata $executable
Assert-PortableHash -Executable $executable -Manifest $manifest
Assert-SingleInstanceAndCleanExit $executable

Write-Host 'Portable Windows package verified.'
