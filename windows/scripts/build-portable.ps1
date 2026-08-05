[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-Condition (-not [string]::IsNullOrWhiteSpace($Path)) 'Path must not be empty'
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $root, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }

    return $fullPath.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-NotReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        Assert-Condition (
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
        ) "Refusing reparse-point path: $Path"
    }
}

function Assert-SafeDistChild {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-FullPath $Path
    $prefix = $script:distRoot + [IO.Path]::DirectorySeparatorChar
    Assert-Condition (
        $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    ) "Target is not strictly inside windows/dist: $fullPath"
    Assert-Condition (
        [string]::Equals(
            [IO.Path]::GetDirectoryName($fullPath),
            $script:distRoot,
            [StringComparison]::OrdinalIgnoreCase)
    ) "Target must be a direct child of windows/dist: $fullPath"

    $forbidden = @(
        [IO.Path]::GetPathRoot($fullPath),
        $script:repositoryRoot,
        $script:windowsRoot,
        $script:distRoot,
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($forbiddenPath in $forbidden) {
        Assert-Condition (
            -not [string]::Equals(
                $fullPath,
                (Get-FullPath $forbiddenPath),
                [StringComparison]::OrdinalIgnoreCase)
        ) "Refusing forbidden deletion target: $fullPath"
    }

    Assert-NotReparsePoint $fullPath
    return $fullPath
}

function Remove-SafeDistChild {
    param([Parameter(Mandatory = $true)][string]$Path)

    $safePath = Assert-SafeDistChild $Path
    if (Test-Path -LiteralPath $safePath) {
        Remove-Item -LiteralPath $safePath -Recurse -Force
    }
}

function Invoke-DotNet {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet failed with exit code $LASTEXITCODE"
    }
}

Assert-Condition $IsWindows 'Windows is required'
Assert-Condition ([Environment]::Is64BitOperatingSystem) 'Windows x64 required'
Assert-Condition ([Environment]::OSVersion.Version.Build -ge 22000) 'Windows 11 required'

$sdk = (& dotnet --version)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query the .NET SDK'
}
Assert-Condition ($sdk -match '^10\.') '.NET 10 SDK required'

$script:repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$script:windowsRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$script:distRoot = Get-FullPath (Join-Path $script:windowsRoot 'dist')

$expectedDistRoot = Get-FullPath (Join-Path $script:windowsRoot 'dist')
Assert-Condition (
    [string]::Equals($script:distRoot, $expectedDistRoot, [StringComparison]::OrdinalIgnoreCase)
) 'Unable to resolve windows/dist safely'
Assert-Condition (
    $script:distRoot.StartsWith(
        $script:windowsRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)
) 'windows/dist must be strictly inside the windows directory'

Assert-NotReparsePoint $script:windowsRoot
Assert-NotReparsePoint $script:distRoot
if (-not (Test-Path -LiteralPath $script:distRoot)) {
    [IO.Directory]::CreateDirectory($script:distRoot) | Out-Null
}
Assert-Condition (Test-Path -LiteralPath $script:distRoot -PathType Container) `
    'windows/dist is not a directory'

$publishDirectory = Assert-SafeDistChild (Join-Path $script:distRoot 'publish-win-x64')
$stageDirectory = Assert-SafeDistChild (Join-Path $script:distRoot '可-windows-x64')
$zipPath = Assert-SafeDistChild (Join-Path $script:distRoot '可-windows-x64.zip')

Push-Location $script:repositoryRoot
try {
    Invoke-DotNet test 'windows/Ke.Windows.slnx' '-c' 'Release'

    Remove-SafeDistChild $publishDirectory
    Invoke-DotNet publish 'windows/src/Ke.Windows.App/Ke.Windows.App.csproj' `
        '-c' 'Release' `
        '-r' 'win-x64' `
        '--self-contained' 'true' `
        '-p:PublishSingleFile=true' `
        '-p:PublishTrimmed=false' `
        '-p:IncludeNativeLibrariesForSelfExtract=true' `
        '-p:EnableCompressionInSingleFile=true' `
        '-p:DebugType=None' `
        '-o' $publishDirectory

    $publishedExecutable = Join-Path $publishDirectory 'Ke.Windows.exe'
    Assert-Condition (Test-Path -LiteralPath $publishedExecutable -PathType Leaf) `
        'Published single-file executable missing'

    Remove-SafeDistChild $stageDirectory
    [IO.Directory]::CreateDirectory($stageDirectory) | Out-Null
    Copy-Item -LiteralPath $publishedExecutable -Destination (Join-Path $stageDirectory '可.exe')
    Copy-Item -LiteralPath (Join-Path $script:windowsRoot 'README.md') `
        -Destination (Join-Path $stageDirectory 'README.md')
    Copy-Item -LiteralPath (Join-Path $script:repositoryRoot 'LICENSE') `
        -Destination (Join-Path $stageDirectory 'LICENSE')

    $stagedExecutable = Join-Path $stageDirectory '可.exe'
    $hash = (Get-FileHash -LiteralPath $stagedExecutable -Algorithm SHA256).Hash
    $manifestText = "$hash  可.exe`n"
    [IO.File]::WriteAllText(
        (Join-Path $stageDirectory 'SHA256SUMS.txt'),
        $manifestText,
        [Text.UTF8Encoding]::new($false))

    Remove-SafeDistChild $publishDirectory
    Remove-SafeDistChild $zipPath
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stageDirectory,
        $zipPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false)

    & (Join-Path $PSScriptRoot 'verify-portable.ps1') -ArchivePath $zipPath

    Write-Host "Portable package: $zipPath"
    Write-Host "SHA-256: $hash"
}
finally {
    Pop-Location
    Remove-SafeDistChild $publishDirectory
}
