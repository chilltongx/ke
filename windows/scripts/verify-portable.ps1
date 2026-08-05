[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DistDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedDescription = '向当前空聊天输入框安全发送“可”'
$allowedNames = @('LICENSE', 'README.md', 'SHA256SUMS.txt', '可.exe')

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

    $bytes = [IO.File]::ReadAllBytes($Executable)
    Assert-Condition ($bytes.Length -ge 256) 'Not a PE executable'
    Assert-Condition ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) 'Not a PE executable'

    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    Assert-Condition ($peOffset -ge 0x40 -and ($peOffset + 0x100) -le $bytes.Length) `
        'Invalid PE header offset'
    Assert-Condition (
        $bytes[$peOffset] -eq 0x50 -and
        $bytes[$peOffset + 1] -eq 0x45 -and
        $bytes[$peOffset + 2] -eq 0x00 -and
        $bytes[$peOffset + 3] -eq 0x00
    ) 'Invalid PE signature'

    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    Assert-Condition ($machine -eq 0x8664) 'Executable machine must be x64 (0x8664)'

    $optionalHeader = $peOffset + 24
    $optionalMagic = [BitConverter]::ToUInt16($bytes, $optionalHeader)
    Assert-Condition ($optionalMagic -eq 0x20B) 'Executable must use a PE32+ optional header'

    $subsystem = [BitConverter]::ToUInt16($bytes, $optionalHeader + 68)
    Assert-Condition ($subsystem -eq 2) 'Executable subsystem must be Windows GUI (2)'

    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($Executable)
    Assert-Condition ($version.ProductName -ceq '可') 'ProductName resource must be 可'
    Assert-Condition ($version.FileDescription -ceq $expectedDescription) `
        'FileDescription resource is incorrect'
    Assert-Condition ($version.ProductVersion -match '^1\.0\.0(?:\.0)?(?:\+.*)?$') `
        'ProductVersion resource must be 1.0.0'
    Assert-Condition ($version.FileVersion -match '^1\.0\.0\.0(?:\s.*)?$') `
        'FileVersion resource must be 1.0.0.0'

    if ($null -eq ('PortableResourceReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PortableResourceReader
{
    private const uint LoadLibraryAsDataFile = 0x00000002;
    private const uint LoadLibraryAsImageResource = 0x00000020;
    private static readonly IntPtr GroupIconType = new IntPtr(14);

    private delegate bool EnumResourceNameCallback(
        IntPtr module,
        IntPtr type,
        IntPtr name,
        IntPtr parameter);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryEx(
        string fileName,
        IntPtr file,
        uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumResourceNames(
        IntPtr module,
        IntPtr type,
        EnumResourceNameCallback callback,
        IntPtr parameter);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindResource(
        IntPtr module,
        IntPtr name,
        IntPtr type);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LockResource(IntPtr resourceData);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SizeofResource(IntPtr module, IntPtr resource);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeLibrary(IntPtr module);

    public static int GetMaximumGroupIconFrameCount(string executable)
    {
        var module = LoadLibraryEx(
            executable,
            IntPtr.Zero,
            LoadLibraryAsDataFile | LoadLibraryAsImageResource);
        if (module == IntPtr.Zero)
        {
            return 0;
        }

        try
        {
            var maximum = 0;
            EnumResourceNameCallback callback = (loadedModule, type, name, parameter) =>
            {
                var resource = FindResource(loadedModule, name, GroupIconType);
                if (resource == IntPtr.Zero || SizeofResource(loadedModule, resource) < 6)
                {
                    return true;
                }

                var data = LoadResource(loadedModule, resource);
                var pointer = data == IntPtr.Zero ? IntPtr.Zero : LockResource(data);
                if (pointer != IntPtr.Zero)
                {
                    maximum = Math.Max(maximum, (ushort)Marshal.ReadInt16(pointer, 4));
                }

                return true;
            };

            EnumResourceNames(module, GroupIconType, callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return maximum;
        }
        finally
        {
            FreeLibrary(module);
        }
    }
}
'@
    }

    $iconFrameCount = [PortableResourceReader]::GetMaximumGroupIconFrameCount($Executable)
    Assert-Condition ($iconFrameCount -eq 7) `
        'Executable group icon must contain exactly 7 image frames'
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

        $first.Refresh()
        Assert-Condition (-not $first.HasExited) 'First app instance exited unexpectedly'
        Assert-Condition $first.CloseMainWindow() 'First app did not expose a closable main window'
        Assert-Condition ($first.WaitForExit(5000)) 'First app did not exit cleanly'
    }
    finally {
        Stop-ExactProcess $second
        Stop-ExactProcess $first
    }
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
