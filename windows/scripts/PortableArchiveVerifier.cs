using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

public static class PortableArchiveVerifier
{
    private const long MaximumArchiveBytes = 600L * 1024 * 1024;
    private const long MaximumExecutableBytes = 512L * 1024 * 1024;
    private const long MaximumDocumentBytes = 4L * 1024 * 1024;
    private const long MaximumManifestBytes = 4096;
    private const long MaximumTotalUncompressedBytes = 521L * 1024 * 1024;
    private const double MaximumCompressionRatio = 200.0;
    private const int CopyBufferBytes = 81920;
    private static readonly UTF8Encoding Utf8NoBom = new(false, true);
    private static readonly uint[] Crc32Table = CreateCrc32Table();
    private static readonly string[] ExpectedNames =
        { "可.exe", "README.md", "LICENSE", "SHA256SUMS.txt" };

    public static void VerifyAndExtract(string archivePath, string destinationDirectory)
    {
        if (string.IsNullOrWhiteSpace(archivePath) ||
            string.IsNullOrWhiteSpace(destinationDirectory))
        {
            throw new InvalidDataException("Archive and extraction paths must not be empty");
        }

        var archiveFile = new FileInfo(Path.GetFullPath(archivePath));
        if (!archiveFile.Exists || archiveFile.Length <= 0 ||
            archiveFile.Length > MaximumArchiveBytes)
        {
            throw new InvalidDataException("Portable ZIP size is outside bounds");
        }

        var destination = new DirectoryInfo(Path.GetFullPath(destinationDirectory));
        if (!destination.Exists ||
            (destination.Attributes & FileAttributes.ReparsePoint) != 0 ||
            destination.EnumerateFileSystemInfos().Any())
        {
            throw new InvalidDataException(
                "Archive extraction directory must be empty and must not be a reparse point");
        }

        using var archiveStream = new FileStream(
            archiveFile.FullName,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            CopyBufferBytes,
            FileOptions.SequentialScan);
        using var archive = new ZipArchive(
            archiveStream,
            ZipArchiveMode.Read,
            leaveOpen: false,
            entryNameEncoding: Utf8NoBom);
        if (archive.Entries.Count != ExpectedNames.Length)
        {
            throw new InvalidDataException("Portable ZIP must contain exactly four entries");
        }

        var exactNames = new HashSet<string>(StringComparer.Ordinal);
        var foldedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long totalUncompressed = 0;
        foreach (var entry in archive.Entries)
        {
            ValidateEntryName(entry);
            if (!exactNames.Add(entry.FullName))
            {
                throw new InvalidDataException("Portable ZIP contains a duplicate entry");
            }

            if (!foldedNames.Add(entry.FullName))
            {
                throw new InvalidDataException("Portable ZIP contains a case-colliding entry");
            }

            if (!ExpectedNames.Contains(entry.FullName, StringComparer.Ordinal))
            {
                throw new InvalidDataException("Portable ZIP contains an unexpected root entry");
            }

            ValidateEntryAttributes(entry);
            var maximumLength = entry.FullName switch
            {
                "可.exe" => MaximumExecutableBytes,
                "SHA256SUMS.txt" => MaximumManifestBytes,
                _ => MaximumDocumentBytes
            };
            if (entry.Length <= 0 || entry.Length > maximumLength ||
                entry.CompressedLength <= 0 ||
                entry.CompressedLength > archiveFile.Length ||
                (double)entry.Length / entry.CompressedLength > MaximumCompressionRatio)
            {
                throw new InvalidDataException(
                    $"Portable ZIP entry size or compression ratio is unsafe: {entry.FullName}");
            }

            totalUncompressed = checked(totalUncompressed + entry.Length);
            if (totalUncompressed > MaximumTotalUncompressedBytes)
            {
                throw new InvalidDataException("Portable ZIP uncompressed size exceeds bounds");
            }
        }

        if (!exactNames.SetEquals(ExpectedNames))
        {
            throw new InvalidDataException("Portable ZIP root inventory is incorrect");
        }

        foreach (var entry in archive.Entries)
        {
            ExtractEntry(entry, destination.FullName);
        }

        VerifyExtractedHash(destination.FullName);
    }

    private static void ValidateEntryName(ZipArchiveEntry entry)
    {
        var name = entry.FullName;
        if (string.IsNullOrWhiteSpace(name) || name.Length > 64 ||
            name[0] == '/' || name[0] == '\\' ||
            name.EndsWith("/", StringComparison.Ordinal) ||
            name.EndsWith("\\", StringComparison.Ordinal) ||
            name.Contains('/') || name.Contains('\\') || name.Contains(':') ||
            name.Any(char.IsControl) ||
            !string.Equals(entry.Name, name, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Portable ZIP entry is not a safe root file name");
        }

        if (Path.IsPathRooted(name) ||
            name.Split('/', '\\').Any(segment =>
                segment.Length == 0 || segment == "." || segment == ".."))
        {
            throw new InvalidDataException("Portable ZIP entry path is unsafe");
        }
    }

    private static void ValidateEntryAttributes(ZipArchiveEntry entry)
    {
        var attributes = entry.ExternalAttributes;
        var forbiddenWindowsAttributes =
            (int)(FileAttributes.Directory | FileAttributes.ReparsePoint);
        if ((attributes & forbiddenWindowsAttributes) != 0)
        {
            throw new InvalidDataException("Portable ZIP entry is a directory or reparse point");
        }

        var unixFileType = (attributes >> 16) & 0xF000;
        if (unixFileType != 0 && unixFileType != 0x8000)
        {
            throw new InvalidDataException("Portable ZIP entry is not a regular file");
        }
    }

    private static void ExtractEntry(ZipArchiveEntry entry, string destinationDirectory)
    {
        var destinationPath = Path.GetFullPath(
            Path.Combine(destinationDirectory, entry.FullName));
        if (!string.Equals(
                Path.GetDirectoryName(destinationPath),
                destinationDirectory,
                StringComparison.OrdinalIgnoreCase) ||
            File.Exists(destinationPath) || Directory.Exists(destinationPath))
        {
            throw new InvalidDataException("Portable ZIP extraction target is unsafe");
        }

        using var input = entry.Open();
        using var output = new FileStream(
            destinationPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            CopyBufferBytes,
            FileOptions.SequentialScan);
        var buffer = new byte[CopyBufferBytes];
        long written = 0;
        var crc32 = uint.MaxValue;
        while (true)
        {
            var read = input.Read(buffer, 0, buffer.Length);
            if (read == 0)
            {
                break;
            }

            written = checked(written + read);
            if (written > entry.Length)
            {
                throw new InvalidDataException("Portable ZIP entry expanded beyond declared size");
            }

            output.Write(buffer, 0, read);
            crc32 = UpdateCrc32(crc32, buffer, read);
        }

        if (written != entry.Length)
        {
            throw new InvalidDataException("Portable ZIP entry length disagrees with central directory");
        }

        if (~crc32 != entry.Crc32)
        {
            throw new InvalidDataException(
                $"Portable ZIP entry CRC-32 mismatch: {entry.FullName}");
        }
    }

    private static uint UpdateCrc32(uint crc32, byte[] buffer, int count)
    {
        for (var index = 0; index < count; index++)
        {
            crc32 = Crc32Table[(crc32 ^ buffer[index]) & 0xFF] ^ (crc32 >> 8);
        }

        return crc32;
    }

    private static uint[] CreateCrc32Table()
    {
        const uint polynomial = 0xEDB88320;
        var table = new uint[256];
        for (var index = 0; index < table.Length; index++)
        {
            var value = (uint)index;
            for (var bit = 0; bit < 8; bit++)
            {
                value = (value >> 1) ^ ((value & 1) == 0 ? 0 : polynomial);
            }

            table[index] = value;
        }

        return table;
    }

    private static void VerifyExtractedHash(string destinationDirectory)
    {
        var executablePath = Path.Combine(destinationDirectory, "可.exe");
        var manifestPath = Path.Combine(destinationDirectory, "SHA256SUMS.txt");
        var manifestBytes = File.ReadAllBytes(manifestPath);
        if (manifestBytes.Length <= 0 || manifestBytes.Length > MaximumManifestBytes)
        {
            throw new InvalidDataException("Extracted SHA256SUMS.txt size is invalid");
        }

        string manifest;
        try
        {
            manifest = Utf8NoBom.GetString(manifestBytes);
        }
        catch (DecoderFallbackException exception)
        {
            throw new InvalidDataException("SHA256SUMS.txt is not valid UTF-8", exception);
        }

        const string suffix = "  可.exe\n";
        if (manifest.Length != 64 + suffix.Length ||
            !manifest.EndsWith(suffix, StringComparison.Ordinal) ||
            !manifest.AsSpan(0, 64).ToArray().All(value =>
                (value >= '0' && value <= '9') ||
                (value >= 'A' && value <= 'F') ||
                (value >= 'a' && value <= 'f')))
        {
            throw new InvalidDataException("SHA256SUMS.txt has an invalid format");
        }

        using var executable = File.OpenRead(executablePath);
        var actualHash = Convert.ToHexString(SHA256.HashData(executable));
        if (!string.Equals(
                actualHash,
                manifest.Substring(0, 64),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("SHA-256 mismatch for extracted 可.exe");
        }
    }

    public static void RunSelfTests()
    {
        var temporaryParent = Path.GetFullPath(Path.GetTempPath())
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var root = Path.Combine(
            temporaryParent,
            $"ke-portable-archive-selftest-{Guid.NewGuid():N}");
        if (!string.Equals(
                Path.GetDirectoryName(root),
                temporaryParent,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Archive self-test root escaped the temp directory");
        }

        Directory.CreateDirectory(root);
        try
        {
            var validEntries = CreateValidEntries();
            var validArchive = Path.Combine(root, "有效-可.zip");
            WriteArchive(validArchive, validEntries);
            var validDestination = CreateEmptyDestination(root, "valid");
            VerifyAndExtract(validArchive, validDestination);
            var extractedNames = Directory.GetFiles(validDestination)
                .Select(Path.GetFileName)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToArray();
            var expectedNames = validEntries
                .Select(entry => entry.Name)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToArray();
            if (!extractedNames.SequenceEqual(expectedNames, StringComparer.Ordinal))
            {
                throw new InvalidOperationException("Valid Unicode archive extracted incorrectly");
            }

            ExpectRejected(
                root,
                "extra file",
                validEntries.Append(new ArchiveTestEntry("extra.txt", "extra"u8.ToArray())));
            ExpectRejected(
                root,
                "traversal path",
                validEntries.Append(new ArchiveTestEntry("../escape.txt", "escape"u8.ToArray())));
            ExpectRejected(
                root,
                "absolute path",
                validEntries.Append(new ArchiveTestEntry("/absolute.txt", "absolute"u8.ToArray())));
            ExpectRejected(
                root,
                "alternate data stream",
                validEntries.Append(new ArchiveTestEntry("可.exe:payload", "ads"u8.ToArray())));
            ExpectRejected(
                root,
                "directory entry",
                validEntries.Append(new ArchiveTestEntry("folder/", Array.Empty<byte>())));
            ExpectRejected(
                root,
                "exact duplicate",
                validEntries.Append(validEntries.Single(entry => entry.Name == "可.exe")));
            ExpectRejected(
                root,
                "case collision",
                validEntries.Append(new ArchiveTestEntry("readme.md", "collision"u8.ToArray())));
            ExpectRejected(
                root,
                "zero-length file",
                validEntries.Select(entry => entry.Name == "LICENSE"
                    ? new ArchiveTestEntry(entry.Name, Array.Empty<byte>())
                    : entry));
            ExpectRejected(
                root,
                "unsafe compression ratio",
                validEntries.Select(entry => entry.Name == "LICENSE"
                    ? new ArchiveTestEntry(entry.Name, new byte[2 * 1024 * 1024])
                    : entry));
            ExpectRejected(
                root,
                "SHA-256 mismatch",
                validEntries.Select(entry => entry.Name == "SHA256SUMS.txt"
                    ? new ArchiveTestEntry(
                        entry.Name,
                        Utf8NoBom.GetBytes($"{new string('0', 64)}  可.exe\n"))
                    : entry));

            var payloadCorruptArchive = Path.Combine(root, "payload-corrupt.zip");
            WriteArchive(
                payloadCorruptArchive,
                validEntries,
                CompressionLevel.NoCompression);
            FlipStoredEntryPayloadBit(payloadCorruptArchive, "README.md");
            ExpectRejectedArchive(
                root,
                "stored entry payload CRC mismatch",
                payloadCorruptArchive);

            var corruptArchive = Path.Combine(root, "corrupt.zip");
            File.Copy(validArchive, corruptArchive);
            using (var stream = new FileStream(
                       corruptArchive,
                       FileMode.Open,
                       FileAccess.Write,
                       FileShare.None))
            {
                stream.SetLength(stream.Length - 8);
            }

            ExpectRejectedArchive(root, "truncated central directory", corruptArchive);
        }
        finally
        {
            if (Directory.Exists(root))
            {
                if (!string.Equals(
                        Path.GetDirectoryName(Path.GetFullPath(root)),
                        temporaryParent,
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        "Refusing unsafe archive self-test cleanup target");
                }

                Directory.Delete(root, recursive: true);
            }
        }
    }

    private static IReadOnlyList<ArchiveTestEntry> CreateValidEntries()
    {
        var executable = "fixture 可 executable"u8.ToArray();
        var hash = Convert.ToHexString(SHA256.HashData(executable));
        return new[]
        {
            new ArchiveTestEntry("可.exe", executable),
            new ArchiveTestEntry("README.md", "readme"u8.ToArray()),
            new ArchiveTestEntry("LICENSE", "license"u8.ToArray()),
            new ArchiveTestEntry(
                "SHA256SUMS.txt",
                Utf8NoBom.GetBytes($"{hash}  可.exe\n"))
        };
    }

    private static string CreateEmptyDestination(string root, string name)
    {
        var destination = Path.Combine(root, $"extract-{name}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(destination);
        return destination;
    }

    private static void ExpectRejected(
        string root,
        string name,
        IEnumerable<ArchiveTestEntry> entries)
    {
        var archive = Path.Combine(root, $"mutant-{Guid.NewGuid():N}.zip");
        WriteArchive(archive, entries);
        ExpectRejectedArchive(root, name, archive);
    }

    private static void ExpectRejectedArchive(string root, string name, string archive)
    {
        var destination = CreateEmptyDestination(root, "mutant");
        try
        {
            VerifyAndExtract(archive, destination);
        }
        catch (InvalidDataException)
        {
            return;
        }

        throw new InvalidOperationException($"Malformed ZIP mutant was accepted: {name}");
    }

    private static void WriteArchive(
        string archivePath,
        IEnumerable<ArchiveTestEntry> entries,
        CompressionLevel compressionLevel = CompressionLevel.Optimal)
    {
        using var archive = ZipFile.Open(archivePath, ZipArchiveMode.Create, Utf8NoBom);
        foreach (var fixture in entries)
        {
            var entry = archive.CreateEntry(fixture.Name, compressionLevel);
            using var output = entry.Open();
            output.Write(fixture.Data);
        }
    }

    private static void FlipStoredEntryPayloadBit(string archivePath, string entryName)
    {
        const uint localHeaderSignature = 0x04034B50;
        using var stream = new FileStream(
            archivePath,
            FileMode.Open,
            FileAccess.ReadWrite,
            FileShare.None);
        using var reader = new BinaryReader(stream, Utf8NoBom, leaveOpen: true);
        while (stream.Position <= stream.Length - 30)
        {
            if (reader.ReadUInt32() != localHeaderSignature)
            {
                break;
            }

            _ = reader.ReadUInt16();
            var flags = reader.ReadUInt16();
            var compressionMethod = reader.ReadUInt16();
            _ = reader.ReadUInt16();
            _ = reader.ReadUInt16();
            _ = reader.ReadUInt32();
            var compressedSize = reader.ReadUInt32();
            var uncompressedSize = reader.ReadUInt32();
            var nameLength = reader.ReadUInt16();
            var extraLength = reader.ReadUInt16();
            var nameBytes = reader.ReadBytes(nameLength);
            if (nameBytes.Length != nameLength ||
                stream.Position > stream.Length - extraLength)
            {
                throw new InvalidOperationException("ZIP self-test local header is truncated");
            }

            var name = Utf8NoBom.GetString(nameBytes);
            stream.Position = checked(stream.Position + extraLength);
            var dataOffset = stream.Position;
            if ((flags & 0x0008) != 0 ||
                dataOffset > stream.Length - compressedSize)
            {
                throw new InvalidOperationException(
                    "ZIP self-test requires bounded local entry sizes");
            }

            if (string.Equals(name, entryName, StringComparison.Ordinal))
            {
                if (compressionMethod != 0 || compressedSize == 0 ||
                    compressedSize != uncompressedSize)
                {
                    throw new InvalidOperationException(
                        "ZIP self-test target must be a nonempty stored entry");
                }

                var value = stream.ReadByte();
                if (value < 0)
                {
                    throw new InvalidOperationException(
                        "ZIP self-test target payload is truncated");
                }

                stream.Position = dataOffset;
                stream.WriteByte((byte)(value ^ 0x01));
                return;
            }

            stream.Position = checked(dataOffset + compressedSize);
        }

        throw new InvalidOperationException("ZIP self-test target entry was not found");
    }

    private sealed record ArchiveTestEntry(string Name, byte[] Data);
}
