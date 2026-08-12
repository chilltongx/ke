using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

public static class PortablePeVerifier
{
    private const ushort Amd64Machine = 0x8664;
    private const ushort Pe32PlusMagic = 0x020B;
    private const ushort WindowsGuiSubsystem = 2;
    private const int IconResourceType = 3;
    private const int GroupIconResourceType = 14;
    private const int MaximumIconDimension = 256;
    private const int MaximumDecodedRgbaBytes = 256 * ((256 * 4) + 1);
    private const int MaximumCompressedRgbaBytes = MaximumDecodedRgbaBytes + 65536;
    private const int MaximumExecutableBytes = 768 * 1024 * 1024;
    private const int MaximumBundleEntries = 4096;
    private const int MaximumBundlePathBytes = 1024;
    private const int MaximumDepsJsonBytes = 8 * 1024 * 1024;
    private const int MaximumRuntimeConfigJsonBytes = 1024 * 1024;
    private static readonly byte[] PngSignature =
        { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    private static readonly byte[] IhdrChunkType = Encoding.ASCII.GetBytes("IHDR");
    private static readonly byte[] IdatChunkType = Encoding.ASCII.GetBytes("IDAT");
    private static readonly byte[] IendChunkType = Encoding.ASCII.GetBytes("IEND");
    private static readonly byte[] BundleSignature =
    {
        0x8b, 0x12, 0x02, 0xb9, 0x6a, 0x61, 0x20, 0x38,
        0x72, 0x7b, 0x93, 0x02, 0x14, 0xd7, 0xa0, 0x32,
        0x13, 0xf5, 0xb9, 0xe6, 0xef, 0xae, 0x33, 0x18,
        0xee, 0x3b, 0x2d, 0xce, 0x24, 0xb3, 0x6a, 0xae
    };
    private static readonly int[] ExpectedIconSizes = { 16, 24, 32, 48, 64, 128, 256 };

    public static void Verify(string executable)
    {
        if (string.IsNullOrWhiteSpace(executable))
        {
            throw new InvalidDataException("Executable path is empty");
        }

        var file = new FileInfo(executable);
        if (!file.Exists || file.Length <= 0 || file.Length > MaximumExecutableBytes)
        {
            throw new InvalidDataException("Executable size is outside the portable package bounds");
        }

        VerifyImage(File.ReadAllBytes(executable));
    }

    public static void RunSelfTests()
    {
        var valid = TestPeImage.Create().WithBundle(includeRuntimeAssets: true);
        VerifyImage(valid.Bytes);
        VerifyImage(TestPeImage.Create(splitIdat: true).WithBundle(includeRuntimeAssets: true).Bytes);

        ExpectRejected(
            "framework-dependent single-file bundle has no embedded runtime",
            TestPeImage.Create(includeRuntimeExport: false)
                .WithBundle(includeRuntimeAssets: false).Bytes);

        ExpectRejected(
            "static self-contained runtime export is missing",
            TestPeImage.Create(includeRuntimeExport: false)
                .WithBundle(includeRuntimeAssets: true).Bytes);

        ExpectRejected(
            "export table claims an unbounded name count",
            valid.Mutate(bytes =>
                WriteUInt32(bytes, valid.ExportDirectoryFileOffset + 24, uint.MaxValue)));

        ExpectRejected(
            "DotNetRuntimeInfo is a forwarded export false positive",
            valid.Mutate(bytes =>
                WriteUInt32(
                    bytes,
                    valid.ExportFunctionTableFileOffset,
                    valid.ExportDirectoryRva)));

        ExpectRejected(
            "bundle signature has a zero header offset",
            valid.Mutate(bytes =>
                WriteInt64(bytes, valid.BundleLocatorFileOffset, 0)));

        ExpectRejected(
            "bundle header offset exceeds file bounds",
            valid.Mutate(bytes =>
                WriteInt64(bytes, valid.BundleLocatorFileOffset, long.MaxValue)));

        ExpectRejected(
            "bundle manifest claims an unbounded entry count",
            valid.Mutate(bytes =>
                WriteUInt32(bytes, valid.BundleHeaderFileOffset + 8, uint.MaxValue)));

        ExpectRejected(
            "bundle marker false positive has no manifest",
            TestPeImage.Create().WithFalsePositiveBundleMarker().Bytes);

        ExpectRejected(
            "RT_ICON PNG zlib stream has a duplicate Adler-32 trailer",
            TestPeImage.Create(duplicateAdler: true).WithBundle(includeRuntimeAssets: true).Bytes);

        ExpectRejected("declared optional-header boundary", valid.Mutate(bytes =>
            WriteUInt16(bytes, valid.CoffHeaderOffset + 16, 70)));

        ExpectRejected("data-directory count exceeds optional header", valid.Mutate(bytes =>
            WriteUInt32(bytes, valid.DataDirectoryCountOffset, uint.MaxValue)));

        ExpectRejected("resource RVA outside raw section bounds", valid.Mutate(bytes =>
            WriteUInt32(bytes, valid.ResourceDirectoryEntryOffset, 0x1FF0)));

        ExpectRejected("group icon references a missing RT_ICON id", valid.Mutate(bytes =>
            WriteUInt16(bytes, valid.GroupDataFileOffset + 6 + (6 * 14) + 12, 99)));

        ExpectRejected("group icon byte count disagrees with RT_ICON", valid.Mutate(bytes =>
            WriteUInt32(bytes, valid.GroupDataFileOffset + 6 + 8, 999)));

        ExpectRejected("RT_ICON PNG IHDR dimensions disagree with group icon", valid.Mutate(bytes =>
            WriteBigEndianUInt32(bytes, valid.FirstPngFileOffset + 16, 17)));

        ExpectRejected("RT_ICON PNG IHDR bit depth is not 8", valid.Mutate(bytes =>
        {
            bytes[valid.FirstPngFileOffset + 24] = 0;
            RewritePngChunkCrc(bytes, valid.FirstPngFileOffset + 12, 13);
        }));

        ExpectRejected("RT_ICON PNG has a bad IHDR CRC", valid.Mutate(bytes =>
            bytes[valid.FirstPngFileOffset + 29] ^= 0x01));

        ExpectRejected("RT_ICON PNG IDAT zlib stream is invalid", valid.Mutate(bytes =>
        {
            Array.Clear(
                bytes,
                valid.FirstPngIdatDataFileOffset,
                valid.FirstPngIdatDataLength);
            RewritePngChunkCrc(
                bytes,
                valid.FirstPngIdatDataFileOffset - 4,
                valid.FirstPngIdatDataLength);
        }));

        ExpectRejected("RT_ICON PNG zlib footer is truncated", valid.Mutate(bytes =>
        {
            var shortenedIdatLength = valid.FirstPngIdatDataLength - 1;
            var removedByteOffset = valid.FirstPngIdatDataFileOffset + shortenedIdatLength;
            var pngEnd = valid.FirstPngFileOffset + valid.FirstPngLength;
            Buffer.BlockCopy(
                bytes,
                removedByteOffset + 1,
                bytes,
                removedByteOffset,
                pngEnd - removedByteOffset - 1);
            WriteBigEndianUInt32(
                bytes,
                valid.FirstPngIdatDataFileOffset - 8,
                checked((uint)shortenedIdatLength));
            RewritePngChunkCrc(
                bytes,
                valid.FirstPngIdatDataFileOffset - 4,
                shortenedIdatLength);
            var shortenedPngLength = checked((uint)(valid.FirstPngLength - 1));
            WriteUInt32(bytes, valid.GroupDataFileOffset + 6 + 8, shortenedPngLength);
            WriteUInt32(
                bytes,
                valid.FirstIconDataEntryFileOffset + 4,
                shortenedPngLength);
        }));

        ExpectRejected("RT_ICON PNG zlib header is invalid", valid.Mutate(bytes =>
        {
            bytes[valid.FirstPngIdatDataFileOffset] = 0;
            RewritePngChunkCrc(
                bytes,
                valid.FirstPngIdatDataFileOffset - 4,
                valid.FirstPngIdatDataLength);
        }));

        ExpectRejected("RT_ICON PNG zlib Adler-32 is invalid", valid.Mutate(bytes =>
        {
            bytes[
                valid.FirstPngIdatDataFileOffset +
                valid.FirstPngIdatDataLength -
                1] ^= 0x01;
            RewritePngChunkCrc(
                bytes,
                valid.FirstPngIdatDataFileOffset - 4,
                valid.FirstPngIdatDataLength);
        }));

        ExpectRejected("RT_ICON PNG is missing IEND", valid.Mutate(bytes =>
        {
            var lengthWithoutIend = checked((uint)(
                valid.FirstPngIendFileOffset - valid.FirstPngFileOffset));
            WriteUInt32(bytes, valid.GroupDataFileOffset + 6 + 8, lengthWithoutIend);
            WriteUInt32(bytes, valid.FirstIconDataEntryFileOffset + 4, lengthWithoutIend);
        }));

        ExpectRejected("RT_ICON PNG has a truncated IEND chunk", valid.Mutate(bytes =>
            WriteBigEndianUInt32(bytes, valid.FirstPngIendFileOffset, 1)));

        ExpectRejected("RT_ICON PNG has bytes after IEND", valid.Mutate(bytes =>
        {
            var lengthWithTrailingByte = checked((uint)(valid.FirstPngLength + 1));
            WriteUInt32(bytes, valid.GroupDataFileOffset + 6 + 8, lengthWithTrailingByte);
            WriteUInt32(bytes, valid.FirstIconDataEntryFileOffset + 4, lengthWithTrailingByte);
        }));

        ExpectRejected("RT_ICON data entry points outside resource raw data", valid.Mutate(bytes =>
            WriteUInt32(bytes, valid.FirstIconDataEntryFileOffset, 0x1FF0)));
    }

    private static void VerifyImage(byte[] bytes)
    {
        if (bytes.Length == 0 || bytes.Length > MaximumExecutableBytes)
        {
            throw new InvalidDataException("Executable size is outside the portable package bounds");
        }

        var reader = new ByteReader(bytes);
        reader.Require(0, 0x40, "DOS header");
        if (reader.ReadUInt16(0) != 0x5A4D)
        {
            throw new InvalidDataException("Not a PE executable");
        }

        var peOffset = reader.ReadInt32(0x3C);
        if (peOffset < 0x40)
        {
            throw new InvalidDataException("Invalid PE header offset");
        }

        reader.Require(peOffset, 24, "PE and COFF headers");
        if (reader.ReadUInt32(peOffset) != 0x00004550)
        {
            throw new InvalidDataException("Invalid PE signature");
        }

        var coffOffset = checked(peOffset + 4);
        if (reader.ReadUInt16(coffOffset) != Amd64Machine)
        {
            throw new InvalidDataException("Executable machine must be x64 (0x8664)");
        }

        var sectionCount = reader.ReadUInt16(coffOffset + 2);
        if (sectionCount == 0 || sectionCount > 96)
        {
            throw new InvalidDataException("Invalid PE section count");
        }

        var optionalSize = reader.ReadUInt16(coffOffset + 16);
        var optionalOffset = checked(coffOffset + 20);
        var optionalEnd = checked(optionalOffset + optionalSize);
        reader.Require(optionalOffset, optionalSize, "declared optional header");
        var magicOffset = GetOptionalFieldOffset(
            optionalOffset,
            optionalEnd,
            0,
            2,
            "optional-header magic");
        if (reader.ReadUInt16(magicOffset) != Pe32PlusMagic)
        {
            throw new InvalidDataException("Executable must use a PE32+ optional header");
        }

        var subsystemOffset = GetOptionalFieldOffset(
            optionalOffset,
            optionalEnd,
            68,
            2,
            "subsystem");
        if (reader.ReadUInt16(subsystemOffset) != WindowsGuiSubsystem)
        {
            throw new InvalidDataException("Executable subsystem must be Windows GUI (2)");
        }

        var dataDirectoryCountOffset = GetOptionalFieldOffset(
            optionalOffset,
            optionalEnd,
            108,
            4,
            "data-directory count");
        var dataDirectoryCount = reader.ReadUInt32(dataDirectoryCountOffset);
        if (dataDirectoryCount <= 2)
        {
            throw new InvalidDataException("PE resource data directory is missing");
        }

        var declaredDataDirectoryEnd = 112UL + ((ulong)dataDirectoryCount * 8UL);
        var declaredOptionalSize = checked((ulong)(optionalEnd - optionalOffset));
        if (declaredDataDirectoryEnd > declaredOptionalSize)
        {
            throw new InvalidDataException(
                "PE data-directory count exceeds declared optional-header boundary");
        }

        var resourceDirectoryEntry = GetOptionalFieldOffset(
            optionalOffset,
            optionalEnd,
            112 + (2 * 8),
            8,
            "resource data directory");
        var exportDirectoryEntry = GetOptionalFieldOffset(
            optionalOffset,
            optionalEnd,
            112,
            8,
            "export data directory");
        var exportRva = reader.ReadUInt32(exportDirectoryEntry);
        var exportSize = reader.ReadUInt32(exportDirectoryEntry + 4);
        if (exportRva == 0 || exportSize == 0)
        {
            throw new InvalidDataException(
                "Self-contained static runtime export directory is missing");
        }

        var resourceRva = reader.ReadUInt32(resourceDirectoryEntry);
        var resourceSize = reader.ReadUInt32(resourceDirectoryEntry + 4);
        if (resourceRva == 0 || resourceSize == 0)
        {
            throw new InvalidDataException("PE resource data directory is empty");
        }

        var sectionTableOffset = optionalEnd;
        var sectionTableBytes = checked(sectionCount * 40);
        reader.Require(sectionTableOffset, sectionTableBytes, "section table");
        var sections = new List<Section>(sectionCount);
        var peImageEnd = checked(sectionTableOffset + sectionTableBytes);
        for (var index = 0; index < sectionCount; index++)
        {
            var offset = checked(sectionTableOffset + (index * 40));
            var section = new Section(
                reader.ReadUInt32(offset + 8),
                reader.ReadUInt32(offset + 12),
                reader.ReadUInt32(offset + 16),
                reader.ReadUInt32(offset + 20));
            sections.Add(section);
            if (section.RawSize != 0)
            {
                if (section.RawPointer == 0 ||
                    (ulong)section.RawPointer + section.RawSize > (ulong)bytes.Length)
                {
                    throw new InvalidDataException("PE section exceeds file raw-data bounds");
                }

                peImageEnd = Math.Max(
                    peImageEnd,
                    checked((int)((ulong)section.RawPointer + section.RawSize)));
            }
        }

        var mapper = new RvaMapper(reader, sections);
        VerifyStaticRuntimeExport(reader, mapper, exportRva, exportSize);
        mapper.Map(resourceRva, resourceSize, "resource directory");
        var resources = new ResourceReader(reader, mapper, resourceRva, resourceSize);
        VerifyIconResources(resources);
        VerifySingleFileBundle(reader, sections, peImageEnd);
    }

    private static void VerifyStaticRuntimeExport(
        ByteReader reader,
        RvaMapper mapper,
        uint exportRva,
        uint exportSize)
    {
        const int exportDirectoryBytes = 40;
        const uint maximumExportBytes = 4 * 1024 * 1024;
        const uint maximumExports = 4096;
        if (exportSize < exportDirectoryBytes || exportSize > maximumExportBytes ||
            (ulong)exportRva + exportSize > uint.MaxValue)
        {
            throw new InvalidDataException("PE export directory size is invalid");
        }

        var directoryOffset = mapper.Map(
            exportRva,
            exportDirectoryBytes,
            "export directory");
        var functionCount = reader.ReadUInt32(directoryOffset + 20);
        var nameCount = reader.ReadUInt32(directoryOffset + 24);
        var functionsRva = reader.ReadUInt32(directoryOffset + 28);
        var namesRva = reader.ReadUInt32(directoryOffset + 32);
        var ordinalsRva = reader.ReadUInt32(directoryOffset + 36);
        if (functionCount == 0 || functionCount > maximumExports ||
            nameCount == 0 || nameCount > functionCount || nameCount > maximumExports)
        {
            throw new InvalidDataException("PE export counts are invalid");
        }

        var functionTableBytes = checked(functionCount * 4);
        var nameTableBytes = checked(nameCount * 4);
        var ordinalTableBytes = checked(nameCount * 2);
        RequireExportRange(exportRva, exportSize, functionsRva, functionTableBytes, "functions");
        RequireExportRange(exportRva, exportSize, namesRva, nameTableBytes, "names");
        RequireExportRange(exportRva, exportSize, ordinalsRva, ordinalTableBytes, "ordinals");
        var functionsOffset = mapper.Map(functionsRva, functionTableBytes, "export functions");
        var namesOffset = mapper.Map(namesRva, nameTableBytes, "export names");
        var ordinalsOffset = mapper.Map(ordinalsRva, ordinalTableBytes, "export ordinals");

        var foundRuntimeInfo = false;
        for (var index = 0u; index < nameCount; index++)
        {
            var nameRva = reader.ReadUInt32(checked(namesOffset + (int)(index * 4)));
            var name = ReadExportName(reader, mapper, exportRva, exportSize, nameRva);
            var ordinal = reader.ReadUInt16(checked(ordinalsOffset + (int)(index * 2)));
            if (ordinal >= functionCount)
            {
                throw new InvalidDataException("PE export ordinal exceeds function table");
            }

            if (!string.Equals(name, "DotNetRuntimeInfo", StringComparison.Ordinal))
            {
                continue;
            }

            if (foundRuntimeInfo)
            {
                throw new InvalidDataException("DotNetRuntimeInfo export is duplicated");
            }

            var functionRva = reader.ReadUInt32(
                checked(functionsOffset + (ordinal * 4)));
            var exportEnd = (ulong)exportRva + exportSize;
            if (functionRva == 0 ||
                ((ulong)functionRva >= exportRva && (ulong)functionRva < exportEnd))
            {
                throw new InvalidDataException(
                    "DotNetRuntimeInfo must be a concrete static runtime data export");
            }

            mapper.Map(functionRva, 1, "DotNetRuntimeInfo export target");
            foundRuntimeInfo = true;
        }

        if (!foundRuntimeInfo)
        {
            throw new InvalidDataException(
                "DotNetRuntimeInfo static self-contained runtime export is missing");
        }
    }

    private static void RequireExportRange(
        uint exportRva,
        uint exportSize,
        uint valueRva,
        uint valueSize,
        string field)
    {
        var exportEnd = (ulong)exportRva + exportSize;
        if (valueSize == 0 || valueRva < exportRva ||
            (ulong)valueRva + valueSize > exportEnd)
        {
            throw new InvalidDataException($"PE export {field} table exceeds export bounds");
        }
    }

    private static string ReadExportName(
        ByteReader reader,
        RvaMapper mapper,
        uint exportRva,
        uint exportSize,
        uint nameRva)
    {
        const int maximumNameBytes = 256;
        var exportEnd = (ulong)exportRva + exportSize;
        if (nameRva < exportRva || nameRva >= exportEnd)
        {
            throw new InvalidDataException("PE export name RVA exceeds export bounds");
        }

        var bytes = new byte[maximumNameBytes];
        for (var index = 0; index < bytes.Length; index++)
        {
            var currentRva = (ulong)nameRva + (uint)index;
            if (currentRva >= exportEnd)
            {
                throw new InvalidDataException("PE export name is unterminated");
            }

            var value = reader.ReadByte(mapper.Map((uint)currentRva, 1, "export name"));
            if (value == 0)
            {
                if (index == 0)
                {
                    throw new InvalidDataException("PE export name is empty");
                }

                return Encoding.ASCII.GetString(bytes, 0, index);
            }

            if (value < 0x21 || value > 0x7E)
            {
                throw new InvalidDataException("PE export name is not printable ASCII");
            }

            bytes[index] = value;
        }

        throw new InvalidDataException("PE export name exceeds bounds");
    }

    private static void VerifySingleFileBundle(
        ByteReader reader,
        IReadOnlyList<Section> sections,
        int peImageEnd)
    {
        if (peImageEnd < 40 || peImageEnd > reader.Bytes.Length)
        {
            throw new InvalidDataException("PE image boundary is invalid");
        }

        var search = reader.Bytes.AsSpan(8, peImageEnd - 8);
        var relativeSignatureOffset = search.IndexOf(BundleSignature);
        if (relativeSignatureOffset < 0)
        {
            throw new InvalidDataException(".NET single-file bundle marker is missing");
        }

        var signatureOffset = checked(8 + relativeSignatureOffset);
        var remaining = search[(relativeSignatureOffset + 1)..];
        if (remaining.IndexOf(BundleSignature) >= 0)
        {
            throw new InvalidDataException(".NET single-file bundle marker is ambiguous");
        }

        var locatorOffset = checked(signatureOffset - 8);
        var markerIsMapped = sections.Any(section =>
            section.RawSize != 0 &&
            (ulong)locatorOffset >= section.RawPointer &&
            (ulong)locatorOffset + 40 <= (ulong)section.RawPointer + section.RawSize);
        if (!markerIsMapped)
        {
            throw new InvalidDataException(".NET single-file bundle marker is not PE-mapped data");
        }

        var headerOffset64 = reader.ReadInt64(locatorOffset);
        if (headerOffset64 <= peImageEnd || headerOffset64 > reader.Bytes.Length - 12)
        {
            throw new InvalidDataException(".NET single-file bundle header offset is invalid");
        }

        var headerOffset = checked((int)headerOffset64);
        var bundle = new BundleReader(reader, headerOffset);
        var majorVersion = bundle.ReadUInt32("bundle major version");
        var minorVersion = bundle.ReadUInt32("bundle minor version");
        if (majorVersion != 6 || minorVersion != 0)
        {
            throw new InvalidDataException(".NET 10 bundle manifest must use format 6.0");
        }

        var fileCount = bundle.ReadInt32("bundle entry count");
        if (fileCount <= 0 || fileCount > MaximumBundleEntries)
        {
            throw new InvalidDataException("Bundle entry count is outside bounds");
        }

        var bundleId = bundle.ReadString("bundle ID", 12);
        if (bundleId.Length != 12 || bundleId.Any(value =>
                !((value >= 'A' && value <= 'Z') ||
                  (value >= 'a' && value <= 'z') ||
                  (value >= '0' && value <= '9') ||
                  value == '-' || value == '_')))
        {
            throw new InvalidDataException("Bundle ID is invalid");
        }

        var depsOffset = bundle.ReadInt64("deps.json offset");
        var depsSize = bundle.ReadInt64("deps.json size");
        var runtimeConfigOffset = bundle.ReadInt64("runtimeconfig.json offset");
        var runtimeConfigSize = bundle.ReadInt64("runtimeconfig.json size");
        var flags = bundle.ReadUInt64("bundle flags");
        if (flags != 0)
        {
            throw new InvalidDataException("Bundle flags do not match the portable package contract");
        }

        var entries = new List<BundleEntry>(fileCount);
        var ordinalPaths = new HashSet<string>(StringComparer.Ordinal);
        var foldedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < fileCount; index++)
        {
            var offset = bundle.ReadInt64("bundle entry offset");
            var size = bundle.ReadInt64("bundle entry size");
            var compressedSize = bundle.ReadInt64("bundle entry compressed size");
            var type = bundle.ReadByte("bundle entry type");
            var relativePath = bundle.ReadString("bundle entry path", MaximumBundlePathBytes);

            if (offset < peImageEnd || size <= 0 || compressedSize < 0 ||
                compressedSize >= size || type > 5)
            {
                throw new InvalidDataException("Bundle entry metadata is invalid");
            }

            ValidateBundlePath(relativePath);
            if (!ordinalPaths.Add(relativePath) || !foldedPaths.Add(relativePath))
            {
                throw new InvalidDataException("Bundle entry path is duplicated or case-colliding");
            }

            var storedSize = compressedSize == 0 ? size : compressedSize;
            if (offset > headerOffset64 || storedSize > headerOffset64 - offset)
            {
                throw new InvalidDataException("Bundle entry data exceeds the manifest boundary");
            }

            entries.Add(new BundleEntry(offset, size, compressedSize, type, relativePath));
        }

        if (bundle.Position != reader.Bytes.Length)
        {
            throw new InvalidDataException("Bundle manifest does not end at end of file");
        }

        var orderedEntries = entries.OrderBy(entry => entry.Offset).ToArray();
        long previousEnd = peImageEnd;
        foreach (var entry in orderedEntries)
        {
            if (entry.Offset < previousEnd)
            {
                throw new InvalidDataException("Bundle entry data overlaps another entry");
            }

            previousEnd = checked(entry.Offset + entry.StoredSize);
        }

        var deps = GetUniqueBundleEntry(entries, 3, "deps.json");
        var runtimeConfig = GetUniqueBundleEntry(entries, 4, "runtimeconfig.json");
        if (deps.Offset != depsOffset || deps.Size != depsSize || deps.CompressedSize != 0 ||
            runtimeConfig.Offset != runtimeConfigOffset ||
            runtimeConfig.Size != runtimeConfigSize ||
            runtimeConfig.CompressedSize != 0)
        {
            throw new InvalidDataException("Bundle configuration locations disagree with manifest entries");
        }

        RequireRuntimeAsset(entries, "System.Private.CoreLib.dll", 1);
        VerifyDepsJson(reader, deps);
        VerifyRuntimeConfigJson(reader, runtimeConfig);
    }

    private static void ValidateBundlePath(string relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath) ||
            relativePath[0] == '/' ||
            relativePath.Contains('\\') ||
            relativePath.Contains(':') ||
            relativePath.Any(char.IsControl))
        {
            throw new InvalidDataException("Bundle entry path is unsafe");
        }

        var segments = relativePath.Split('/');
        if (segments.Any(segment =>
                segment.Length == 0 || segment == "." || segment == ".."))
        {
            throw new InvalidDataException("Bundle entry path contains an unsafe segment");
        }
    }

    private static BundleEntry GetUniqueBundleEntry(
        IReadOnlyList<BundleEntry> entries,
        byte type,
        string field)
    {
        var matches = entries.Where(entry => entry.Type == type).ToArray();
        if (matches.Length != 1)
        {
            throw new InvalidDataException($"Bundle must contain one {field} entry");
        }

        return matches[0];
    }

    private static void RequireRuntimeAsset(
        IReadOnlyList<BundleEntry> entries,
        string path,
        byte type)
    {
        if (entries.Count(entry =>
                entry.Type == type &&
                string.Equals(entry.RelativePath, path, StringComparison.Ordinal)) != 1)
        {
            throw new InvalidDataException($"Self-contained runtime asset is missing: {path}");
        }
    }

    private static void VerifyDepsJson(ByteReader reader, BundleEntry entry)
    {
        using var document = ParseBundleJson(reader, entry, MaximumDepsJsonBytes, "deps.json");
        if (!document.RootElement.TryGetProperty("runtimeTarget", out var runtimeTarget) ||
            runtimeTarget.ValueKind != JsonValueKind.Object ||
            !runtimeTarget.TryGetProperty("name", out var name) ||
            name.ValueKind != JsonValueKind.String ||
            name.GetString() is not string targetName ||
            !targetName.EndsWith("/win-x64", StringComparison.Ordinal))
        {
            throw new InvalidDataException("deps.json runtime target must be win-x64");
        }
    }

    private static void VerifyRuntimeConfigJson(ByteReader reader, BundleEntry entry)
    {
        using var document = ParseBundleJson(
            reader,
            entry,
            MaximumRuntimeConfigJsonBytes,
            "runtimeconfig.json");
        if (!document.RootElement.TryGetProperty("runtimeOptions", out var options) ||
            options.ValueKind != JsonValueKind.Object ||
            !options.TryGetProperty("tfm", out var tfm) ||
            tfm.ValueKind != JsonValueKind.String ||
            !string.Equals(tfm.GetString(), "net10.0", StringComparison.Ordinal) ||
            options.TryGetProperty("framework", out _) ||
            options.TryGetProperty("frameworks", out _) ||
            !options.TryGetProperty("includedFrameworks", out var frameworks) ||
            frameworks.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException(
                "runtimeconfig.json must describe a self-contained net10.0 app");
        }

        var hasCore = false;
        var hasDesktop = false;
        foreach (var framework in frameworks.EnumerateArray())
        {
            if (framework.ValueKind != JsonValueKind.Object ||
                !framework.TryGetProperty("name", out var name) ||
                name.ValueKind != JsonValueKind.String ||
                !framework.TryGetProperty("version", out var version) ||
                version.ValueKind != JsonValueKind.String ||
                !Version.TryParse(version.GetString(), out var parsedVersion) ||
                parsedVersion.Major != 10)
            {
                throw new InvalidDataException("runtimeconfig.json included framework is invalid");
            }

            hasCore |= string.Equals(
                name.GetString(),
                "Microsoft.NETCore.App",
                StringComparison.Ordinal);
            hasDesktop |= string.Equals(
                name.GetString(),
                "Microsoft.WindowsDesktop.App",
                StringComparison.Ordinal);
        }

        if (!hasCore || !hasDesktop)
        {
            throw new InvalidDataException(
                "runtimeconfig.json omits required .NET 10 desktop frameworks");
        }
    }

    private static JsonDocument ParseBundleJson(
        ByteReader reader,
        BundleEntry entry,
        int maximumBytes,
        string field)
    {
        if (entry.CompressedSize != 0 || entry.Size > maximumBytes)
        {
            throw new InvalidDataException($"Bundle {field} is compressed or exceeds bounds");
        }

        reader.Require(checked((int)entry.Offset), checked((int)entry.Size), field);
        try
        {
            return JsonDocument.Parse(
                new ReadOnlyMemory<byte>(
                    reader.Bytes,
                    checked((int)entry.Offset),
                    checked((int)entry.Size)),
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 64
                });
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException($"Bundle {field} is invalid JSON", exception);
        }
    }

    private static void VerifyIconResources(ResourceReader resources)
    {
        var icons = resources.ReadType(IconResourceType);
        var groups = resources.ReadType(GroupIconResourceType);
        if (groups.Count == 0)
        {
            throw new InvalidDataException("Executable group icon resource is missing");
        }

        foreach (var groupResource in groups.Values.SelectMany(value => value))
        {
            var group = groupResource.Bytes;
            if (group.Length < 6 ||
                ReadUInt16(group, 0) != 0 ||
                ReadUInt16(group, 2) != 1 ||
                ReadUInt16(group, 4) != ExpectedIconSizes.Length)
            {
                throw new InvalidDataException("Invalid GRPICONDIR header");
            }

            var expectedLength = checked(6 + (ExpectedIconSizes.Length * 14));
            if (group.Length != expectedLength)
            {
                throw new InvalidDataException("GRPICONDIR length is incorrect");
            }

            var dimensions = new HashSet<int>();
            var resourceIds = new HashSet<ushort>();
            for (var index = 0; index < ExpectedIconSizes.Length; index++)
            {
                var entryOffset = 6 + (index * 14);
                var widthByte = group[entryOffset];
                var heightByte = group[entryOffset + 1];
                var width = widthByte == 0 ? 256 : widthByte;
                var height = heightByte == 0 ? 256 : heightByte;
                if (width != height || !dimensions.Add(width))
                {
                    throw new InvalidDataException("Group icon dimensions are invalid or duplicated");
                }

                if (group[entryOffset + 2] != 0 || group[entryOffset + 3] != 0)
                {
                    throw new InvalidDataException("Group icon color/reserved fields are invalid");
                }

                if (ReadUInt16(group, entryOffset + 4) != 1 ||
                    ReadUInt16(group, entryOffset + 6) != 32)
                {
                    throw new InvalidDataException("Group icon planes/bit count must be 1/32");
                }

                var declaredBytes = ReadUInt32(group, entryOffset + 8);
                var resourceId = ReadUInt16(group, entryOffset + 12);
                if (declaredBytes == 0 || resourceId == 0 || !resourceIds.Add(resourceId))
                {
                    throw new InvalidDataException("Group icon size/id fields are invalid or duplicated");
                }

                if (!icons.TryGetValue(resourceId, out var iconLanguages) || iconLanguages.Count == 0)
                {
                    throw new InvalidDataException("Group icon references a missing RT_ICON resource");
                }

                foreach (var iconResource in iconLanguages)
                {
                    if (iconResource.Bytes.Length != declaredBytes)
                    {
                        throw new InvalidDataException("RT_ICON length does not match GRPICONDIRENTRY");
                    }

                    VerifyPng(iconResource.Bytes, width, height);
                }
            }

            if (!dimensions.OrderBy(value => value).SequenceEqual(ExpectedIconSizes))
            {
                throw new InvalidDataException("Group icon dimensions must be 16/24/32/48/64/128/256");
            }
        }
    }

    private static void VerifyPng(byte[] data, int expectedWidth, int expectedHeight)
    {
        if (data.Length < PngSignature.Length + 12 ||
            !data.AsSpan(0, PngSignature.Length).SequenceEqual(PngSignature))
        {
            throw new InvalidDataException("RT_ICON must contain nonempty PNG data");
        }

        var offset = PngSignature.Length;
        var chunkIndex = 0;
        var sawIhdr = false;
        var sawIdat = false;
        var idatSequenceEnded = false;
        var sawIend = false;
        using var idatPayload = new MemoryStream();
        while (offset < data.Length)
        {
            if (data.Length - offset < 12)
            {
                throw new InvalidDataException("RT_ICON PNG chunk is truncated");
            }

            var dataLength = ReadBigEndianUInt32(data, offset);
            var chunkTotal = 12UL + dataLength;
            if ((ulong)offset + chunkTotal > (ulong)data.Length || dataLength > int.MaxValue)
            {
                throw new InvalidDataException("RT_ICON PNG chunk exceeds data bounds");
            }

            var chunkDataLength = checked((int)dataLength);
            var typeOffset = checked(offset + 4);
            var chunkDataOffset = checked(offset + 8);
            var crcOffset = checked(chunkDataOffset + chunkDataLength);
            var type = data.AsSpan(typeOffset, 4);
            if (!type.ToArray().All(value =>
                    (value >= (byte)'A' && value <= (byte)'Z') ||
                    (value >= (byte)'a' && value <= (byte)'z')))
            {
                throw new InvalidDataException("RT_ICON PNG chunk type is invalid");
            }

            var expectedCrc = ReadBigEndianUInt32(data, crcOffset);
            var actualCrc = ComputePngCrc(data.AsSpan(typeOffset, 4 + chunkDataLength));
            if (actualCrc != expectedCrc)
            {
                throw new InvalidDataException("RT_ICON PNG chunk CRC is incorrect");
            }

            var isIhdr = type.SequenceEqual(IhdrChunkType);
            var isIdat = type.SequenceEqual(IdatChunkType);
            var isIend = type.SequenceEqual(IendChunkType);
            if (chunkIndex == 0 && !isIhdr)
            {
                throw new InvalidDataException("RT_ICON PNG IHDR must be the first chunk");
            }

            if (isIhdr)
            {
                if (sawIhdr || chunkIndex != 0 || dataLength != 13)
                {
                    throw new InvalidDataException("RT_ICON PNG must contain one leading IHDR");
                }

                if (ReadBigEndianUInt32(data, chunkDataOffset) != expectedWidth ||
                    ReadBigEndianUInt32(data, chunkDataOffset + 4) != expectedHeight)
                {
                    throw new InvalidDataException("RT_ICON PNG IHDR dimensions are incorrect");
                }

                if (data[chunkDataOffset + 8] != 8 ||
                    data[chunkDataOffset + 9] != 6 ||
                    data[chunkDataOffset + 10] != 0 ||
                    data[chunkDataOffset + 11] != 0 ||
                    data[chunkDataOffset + 12] != 0)
                {
                    throw new InvalidDataException(
                        "RT_ICON PNG must be 8-bit RGBA with standard methods and no interlace");
                }

                sawIhdr = true;
            }
            else if (!sawIhdr)
            {
                throw new InvalidDataException("RT_ICON PNG data precedes IHDR");
            }

            if (isIdat)
            {
                if (idatSequenceEnded)
                {
                    throw new InvalidDataException("RT_ICON PNG IDAT chunks must be consecutive");
                }

                if (idatPayload.Length + chunkDataLength > MaximumCompressedRgbaBytes)
                {
                    throw new InvalidDataException("RT_ICON PNG compressed IDAT data is too large");
                }

                idatPayload.Write(data, chunkDataOffset, chunkDataLength);

                sawIdat = true;
            }
            else if (sawIdat && !isIend)
            {
                idatSequenceEnded = true;
            }

            offset = checked(offset + (int)chunkTotal);
            chunkIndex++;
            if (isIend)
            {
                if (sawIend || dataLength != 0 || !sawIhdr || !sawIdat)
                {
                    throw new InvalidDataException("RT_ICON PNG IEND is invalid");
                }

                sawIend = true;
                if (offset != data.Length)
                {
                    throw new InvalidDataException("RT_ICON PNG contains data after IEND");
                }

                break;
            }
        }

        if (!sawIhdr || !sawIdat || !sawIend)
        {
            throw new InvalidDataException("RT_ICON PNG chunk stream is incomplete");
        }

        VerifyDecodedRgba(idatPayload.ToArray(), expectedWidth, expectedHeight);
    }

    private static void VerifyDecodedRgba(byte[] compressed, int width, int height)
    {
        if (width <= 0 || height <= 0 ||
            width > MaximumIconDimension || height > MaximumIconDimension)
        {
            throw new InvalidDataException("RT_ICON PNG dimensions exceed the icon contract");
        }

        if (compressed.Length < 8 || compressed.Length > MaximumCompressedRgbaBytes)
        {
            throw new InvalidDataException("RT_ICON PNG compressed IDAT data is invalid");
        }

        var cmf = compressed[0];
        var flg = compressed[1];
        var compressionMethod = cmf & 0x0F;
        var compressionInfo = cmf >> 4;
        var header = (cmf << 8) | flg;
        if (compressionMethod != 8 ||
            compressionInfo > 7 ||
            header % 31 != 0 ||
            (flg & 0x20) != 0)
        {
            throw new InvalidDataException("RT_ICON PNG zlib header is invalid");
        }

        var expectedAdler = ReadBigEndianUInt32(compressed, compressed.Length - 4);

        var scanlineLength = checked(1 + (width * 4));
        var expectedLength = checked(height * scanlineLength);
        if (expectedLength > MaximumDecodedRgbaBytes)
        {
            throw new InvalidDataException("RT_ICON PNG decoded RGBA data is too large");
        }

        var decoded = new byte[checked(expectedLength + 1)];
        var decodedLength = 0;
        using var input = new NonPrefetchingReadStream(compressed);
        using (var zlib = new System.IO.Compression.ZLibStream(
                   input,
                   System.IO.Compression.CompressionMode.Decompress,
                   leaveOpen: true))
        {
            while (decodedLength < decoded.Length)
            {
                var read = zlib.Read(decoded, decodedLength, decoded.Length - decodedLength);
                if (read == 0)
                {
                    break;
                }

                decodedLength += read;
            }
        }

        if (input.Consumed != compressed.Length)
        {
            throw new InvalidDataException("RT_ICON PNG zlib stream has trailing compressed data");
        }

        if (decodedLength != expectedLength)
        {
            throw new InvalidDataException(
                "RT_ICON PNG decoded RGBA length does not match its dimensions");
        }

        var actualAdler = ComputeAdler32(decoded.AsSpan(0, decodedLength));
        if (actualAdler != expectedAdler)
        {
            throw new InvalidDataException("RT_ICON PNG zlib Adler-32 is incorrect");
        }

        for (var row = 0; row < height; row++)
        {
            if (decoded[row * scanlineLength] > 4)
            {
                throw new InvalidDataException("RT_ICON PNG scanline filter is invalid");
            }
        }
    }

    private static uint ComputeAdler32(ReadOnlySpan<byte> bytes)
    {
        const uint modulus = 65521;
        uint first = 1;
        uint second = 0;
        foreach (var value in bytes)
        {
            first = (first + value) % modulus;
            second = (second + first) % modulus;
        }

        return (second << 16) | first;
    }

    private static uint ComputePngCrc(ReadOnlySpan<byte> bytes)
    {
        var crc = uint.MaxValue;
        foreach (var value in bytes)
        {
            crc ^= value;
            for (var bit = 0; bit < 8; bit++)
            {
                crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xEDB88320);
            }
        }

        return ~crc;
    }

    private static void RewritePngChunkCrc(byte[] bytes, int typeOffset, int dataLength)
    {
        var crc = ComputePngCrc(bytes.AsSpan(typeOffset, checked(4 + dataLength)));
        WriteBigEndianUInt32(bytes, checked(typeOffset + 4 + dataLength), crc);
    }

    private static int GetOptionalFieldOffset(
        int optionalStart,
        int optionalEnd,
        int relativeOffset,
        int length,
        string field)
    {
        var offset = (long)optionalStart + relativeOffset;
        if (relativeOffset < 0 || length < 0 ||
            offset < optionalStart || offset + length > optionalEnd || offset > int.MaxValue)
        {
            throw new InvalidDataException($"{field} exceeds declared optional-header boundary");
        }

        return (int)offset;
    }

    private static void ExpectRejected(string name, byte[] bytes)
    {
        try
        {
            VerifyImage(bytes);
        }
        catch (InvalidDataException)
        {
            return;
        }

        throw new InvalidOperationException($"Malformed PE mutant was accepted: {name}");
    }

    private static ushort ReadUInt16(byte[] bytes, int offset) =>
        BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset, 2));

    private static uint ReadUInt32(byte[] bytes, int offset) =>
        BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));

    private static uint ReadBigEndianUInt32(byte[] bytes, int offset) =>
        BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(offset, 4));

    private static void WriteUInt16(byte[] bytes, int offset, ushort value) =>
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(offset, 2), value);

    private static void WriteUInt32(byte[] bytes, int offset, uint value) =>
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(offset, 4), value);

    private static void WriteInt64(byte[] bytes, int offset, long value) =>
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(offset, 8), value);

    private static void WriteBigEndianUInt32(byte[] bytes, int offset, uint value) =>
        BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(offset, 4), value);

    private sealed record BundleEntry(
        long Offset,
        long Size,
        long CompressedSize,
        byte Type,
        string RelativePath)
    {
        public long StoredSize => CompressedSize == 0 ? Size : CompressedSize;
    }

    private sealed class BundleReader
    {
        private static readonly UTF8Encoding StrictUtf8 = new(false, true);
        private readonly ByteReader _reader;

        public BundleReader(ByteReader reader, int offset)
        {
            _reader = reader;
            Position = offset;
        }

        public int Position { get; private set; }

        public byte ReadByte(string field)
        {
            _reader.Require(Position, 1, field);
            return _reader.Bytes[Position++];
        }

        public int ReadInt32(string field)
        {
            _reader.Require(Position, 4, field);
            var value = BinaryPrimitives.ReadInt32LittleEndian(
                _reader.Bytes.AsSpan(Position, 4));
            Position = checked(Position + 4);
            return value;
        }

        public uint ReadUInt32(string field)
        {
            _reader.Require(Position, 4, field);
            var value = BinaryPrimitives.ReadUInt32LittleEndian(
                _reader.Bytes.AsSpan(Position, 4));
            Position = checked(Position + 4);
            return value;
        }

        public long ReadInt64(string field)
        {
            _reader.Require(Position, 8, field);
            var value = BinaryPrimitives.ReadInt64LittleEndian(
                _reader.Bytes.AsSpan(Position, 8));
            Position = checked(Position + 8);
            return value;
        }

        public ulong ReadUInt64(string field)
        {
            _reader.Require(Position, 8, field);
            var value = BinaryPrimitives.ReadUInt64LittleEndian(
                _reader.Bytes.AsSpan(Position, 8));
            Position = checked(Position + 8);
            return value;
        }

        public string ReadString(string field, int maximumBytes)
        {
            if (maximumBytes <= 0 || maximumBytes > 16383)
            {
                throw new ArgumentOutOfRangeException(nameof(maximumBytes));
            }

            var first = ReadByte($"{field} length");
            int byteLength;
            if ((first & 0x80) == 0)
            {
                byteLength = first;
            }
            else
            {
                var second = ReadByte($"{field} length");
                if ((second & 0x80) != 0)
                {
                    throw new InvalidDataException($"{field} length prefix exceeds bounds");
                }

                byteLength = (first & 0x7F) | (second << 7);
                if (byteLength < 128)
                {
                    throw new InvalidDataException($"{field} length prefix is not canonical");
                }
            }

            if (byteLength <= 0 || byteLength > maximumBytes)
            {
                throw new InvalidDataException($"{field} length exceeds bounds");
            }

            _reader.Require(Position, byteLength, field);
            try
            {
                var value = StrictUtf8.GetString(_reader.Bytes, Position, byteLength);
                Position = checked(Position + byteLength);
                return value;
            }
            catch (DecoderFallbackException exception)
            {
                throw new InvalidDataException($"{field} is not valid UTF-8", exception);
            }
        }
    }

    private sealed class ByteReader
    {
        public ByteReader(byte[] bytes) => Bytes = bytes ?? throw new ArgumentNullException(nameof(bytes));

        public byte[] Bytes { get; }

        public void Require(int offset, int length, string field)
        {
            if (offset < 0 || length < 0 || (long)offset + length > Bytes.Length)
            {
                throw new InvalidDataException($"{field} exceeds file bounds");
            }
        }

        public ushort ReadUInt16(int offset)
        {
            Require(offset, 2, "UInt16");
            return BinaryPrimitives.ReadUInt16LittleEndian(Bytes.AsSpan(offset, 2));
        }

        public byte ReadByte(int offset)
        {
            Require(offset, 1, "Byte");
            return Bytes[offset];
        }

        public int ReadInt32(int offset)
        {
            Require(offset, 4, "Int32");
            return BinaryPrimitives.ReadInt32LittleEndian(Bytes.AsSpan(offset, 4));
        }

        public long ReadInt64(int offset)
        {
            Require(offset, 8, "Int64");
            return BinaryPrimitives.ReadInt64LittleEndian(Bytes.AsSpan(offset, 8));
        }

        public uint ReadUInt32(int offset)
        {
            Require(offset, 4, "UInt32");
            return BinaryPrimitives.ReadUInt32LittleEndian(Bytes.AsSpan(offset, 4));
        }
    }

    private sealed class NonPrefetchingReadStream : Stream
    {
        private readonly byte[] _bytes;
        private int _consumed;

        public NonPrefetchingReadStream(byte[] bytes) =>
            _bytes = bytes ?? throw new ArgumentNullException(nameof(bytes));

        public int Consumed => _consumed;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush()
        {
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            ArgumentNullException.ThrowIfNull(buffer);
            if (offset < 0 || count < 0 || offset > buffer.Length - count)
            {
                throw new ArgumentOutOfRangeException(nameof(offset));
            }

            return Read(buffer.AsSpan(offset, count));
        }

        public override int Read(Span<byte> buffer)
        {
            if (buffer.IsEmpty || _consumed == _bytes.Length)
            {
                return 0;
            }

            buffer[0] = _bytes[_consumed++];
            return 1;
        }

        public override int ReadByte()
        {
            if (_consumed == _bytes.Length)
            {
                return -1;
            }

            return _bytes[_consumed++];
        }

        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();
    }

    private sealed record Section(
        uint VirtualSize,
        uint VirtualAddress,
        uint RawSize,
        uint RawPointer);

    private sealed class RvaMapper
    {
        private readonly ByteReader _reader;
        private readonly IReadOnlyList<Section> _sections;

        public RvaMapper(ByteReader reader, IReadOnlyList<Section> sections)
        {
            _reader = reader;
            _sections = sections;
        }

        public int Map(uint rva, uint size, string field)
        {
            if (size == 0)
            {
                throw new InvalidDataException($"{field} is empty");
            }

            var rvaEnd = (ulong)rva + size;
            foreach (var section in _sections)
            {
                var sectionStart = (ulong)section.VirtualAddress;
                var sectionSpan = Math.Max((ulong)section.VirtualSize, section.RawSize);
                var sectionEnd = sectionStart + sectionSpan;
                if ((ulong)rva < sectionStart || rvaEnd > sectionEnd)
                {
                    continue;
                }

                var delta = (ulong)rva - sectionStart;
                if (delta + size > section.RawSize)
                {
                    throw new InvalidDataException($"{field} exceeds section raw-data bounds");
                }

                var rawOffset = (ulong)section.RawPointer + delta;
                if (rawOffset > int.MaxValue || rawOffset + size > (ulong)_reader.Bytes.Length)
                {
                    throw new InvalidDataException($"{field} exceeds file raw-data bounds");
                }

                return checked((int)rawOffset);
            }

            throw new InvalidDataException($"{field} RVA is not backed by a PE section");
        }
    }

    private sealed class ResourceReader
    {
        private readonly ByteReader _reader;
        private readonly RvaMapper _mapper;
        private readonly uint _resourceRva;
        private readonly uint _resourceSize;

        public ResourceReader(
            ByteReader reader,
            RvaMapper mapper,
            uint resourceRva,
            uint resourceSize)
        {
            _reader = reader;
            _mapper = mapper;
            _resourceRva = resourceRva;
            _resourceSize = resourceSize;
        }

        public Dictionary<ushort, List<ResourceData>> ReadType(ushort typeId)
        {
            var roots = ReadDirectory(0, "resource root");
            var typeEntries = roots.Where(entry => !entry.HasNamedId && entry.Id == typeId).ToArray();
            if (typeEntries.Length != 1 || !typeEntries[0].PointsToDirectory)
            {
                throw new InvalidDataException($"RT_{typeId} directory is missing or ambiguous");
            }

            var result = new Dictionary<ushort, List<ResourceData>>();
            foreach (var resourceEntry in ReadDirectory(typeEntries[0].Target, $"RT_{typeId}"))
            {
                if (resourceEntry.HasNamedId || resourceEntry.Id == 0 || !resourceEntry.PointsToDirectory)
                {
                    throw new InvalidDataException($"RT_{typeId} resource id entry is invalid");
                }

                if (result.ContainsKey(resourceEntry.Id))
                {
                    throw new InvalidDataException($"RT_{typeId} resource id is duplicated");
                }

                var languageData = new List<ResourceData>();
                foreach (var languageEntry in ReadDirectory(
                    resourceEntry.Target,
                    $"RT_{typeId}/{resourceEntry.Id}"))
                {
                    if (languageEntry.HasNamedId || languageEntry.PointsToDirectory)
                    {
                        throw new InvalidDataException($"RT_{typeId} language entry is invalid");
                    }

                    languageData.Add(ReadDataEntry(languageEntry.Target));
                }

                if (languageData.Count == 0)
                {
                    throw new InvalidDataException($"RT_{typeId} resource has no language data");
                }

                result.Add(resourceEntry.Id, languageData);
            }

            return result;
        }

        private IReadOnlyList<ResourceEntry> ReadDirectory(uint relativeOffset, string field)
        {
            var directoryOffset = ResolveRelative(relativeOffset, 16, field);
            var namedCount = _reader.ReadUInt16(directoryOffset + 12);
            var idCount = _reader.ReadUInt16(directoryOffset + 14);
            var totalCount = checked(namedCount + idCount);
            if (totalCount == 0 || totalCount > 4096)
            {
                throw new InvalidDataException($"{field} has an invalid entry count");
            }

            ResolveRelative(relativeOffset + 16, checked(totalCount * 8), $"{field} entries");
            var entries = new List<ResourceEntry>(totalCount);
            for (var index = 0; index < totalCount; index++)
            {
                var offset = checked(directoryOffset + 16 + (index * 8));
                var name = _reader.ReadUInt32(offset);
                var target = _reader.ReadUInt32(offset + 4);
                var hasNamedId = (name & 0x80000000) != 0;
                if (!hasNamedId && name > ushort.MaxValue)
                {
                    throw new InvalidDataException($"{field} numeric resource id exceeds UInt16");
                }

                entries.Add(new ResourceEntry(
                    hasNamedId,
                    checked((ushort)(name & 0xFFFF)),
                    (target & 0x80000000) != 0,
                    target & 0x7FFFFFFF));
            }

            return entries;
        }

        private ResourceData ReadDataEntry(uint relativeOffset)
        {
            var offset = ResolveRelative(relativeOffset, 16, "resource data entry");
            var dataRva = _reader.ReadUInt32(offset);
            var size = _reader.ReadUInt32(offset + 4);
            var reserved = _reader.ReadUInt32(offset + 12);
            if (size == 0 || reserved != 0)
            {
                throw new InvalidDataException("Resource data entry is empty or reserved field is nonzero");
            }

            var resourceEnd = (ulong)_resourceRva + _resourceSize;
            if ((ulong)dataRva < _resourceRva || (ulong)dataRva + size > resourceEnd)
            {
                throw new InvalidDataException("Resource data RVA exceeds declared resource directory");
            }

            var dataOffset = _mapper.Map(dataRva, size, "resource data");
            var data = new byte[checked((int)size)];
            Buffer.BlockCopy(_reader.Bytes, dataOffset, data, 0, data.Length);
            return new ResourceData(data);
        }

        private int ResolveRelative(uint relativeOffset, int length, string field)
        {
            if (length < 0 || (ulong)relativeOffset + (uint)length > _resourceSize)
            {
                throw new InvalidDataException($"{field} exceeds declared resource directory");
            }

            var rva = (ulong)_resourceRva + relativeOffset;
            if (rva > uint.MaxValue)
            {
                throw new InvalidDataException($"{field} RVA overflows");
            }

            return _mapper.Map((uint)rva, checked((uint)length), field);
        }
    }

    private sealed record ResourceEntry(
        bool HasNamedId,
        ushort Id,
        bool PointsToDirectory,
        uint Target);

    private sealed record ResourceData(byte[] Bytes);

    private sealed class TestPeImage
    {
        private const int PeOffset = 0x80;
        private const int OptionalHeaderSize = 0xF0;
        private const int ResourceRawOffset = 0x200;
        private const uint ResourceRva = 0x1000;
        private static readonly byte[] BundleSignature =
        {
            0x8b, 0x12, 0x02, 0xb9, 0x6a, 0x61, 0x20, 0x38,
            0x72, 0x7b, 0x93, 0x02, 0x14, 0xd7, 0xa0, 0x32,
            0x13, 0xf5, 0xb9, 0xe6, 0xef, 0xae, 0x33, 0x18,
            0xee, 0x3b, 0x2d, 0xce, 0x24, 0xb3, 0x6a, 0xae
        };

        private TestPeImage(
            byte[] bytes,
            int groupDataFileOffset,
            int firstPngFileOffset,
            int firstPngIendFileOffset,
            int firstPngLength,
            int firstPngIdatDataFileOffset,
            int firstPngIdatDataLength,
            int firstIconDataEntryFileOffset,
            int bundleLocatorFileOffset = -1,
            int bundleHeaderFileOffset = -1,
            int exportDirectoryFileOffset = -1,
            int exportFunctionTableFileOffset = -1,
            uint exportDirectoryRva = 0)
        {
            Bytes = bytes;
            GroupDataFileOffset = groupDataFileOffset;
            FirstPngFileOffset = firstPngFileOffset;
            FirstPngIendFileOffset = firstPngIendFileOffset;
            FirstPngLength = firstPngLength;
            FirstPngIdatDataFileOffset = firstPngIdatDataFileOffset;
            FirstPngIdatDataLength = firstPngIdatDataLength;
            FirstIconDataEntryFileOffset = firstIconDataEntryFileOffset;
            BundleLocatorFileOffset = bundleLocatorFileOffset;
            BundleHeaderFileOffset = bundleHeaderFileOffset;
            ExportDirectoryFileOffset = exportDirectoryFileOffset;
            ExportFunctionTableFileOffset = exportFunctionTableFileOffset;
            ExportDirectoryRva = exportDirectoryRva;
        }

        public byte[] Bytes { get; }
        public int CoffHeaderOffset => PeOffset + 4;
        public int DataDirectoryCountOffset => CoffHeaderOffset + 20 + 108;
        public int ResourceDirectoryEntryOffset => CoffHeaderOffset + 20 + 112 + (2 * 8);
        public int GroupDataFileOffset { get; }
        public int FirstPngFileOffset { get; }
        public int FirstPngIendFileOffset { get; }
        public int FirstPngLength { get; }
        public int FirstPngIdatDataFileOffset { get; }
        public int FirstPngIdatDataLength { get; }
        public int FirstIconDataEntryFileOffset { get; }
        public int BundleLocatorFileOffset { get; }
        public int BundleHeaderFileOffset { get; }
        public int ExportDirectoryFileOffset { get; }
        public int ExportFunctionTableFileOffset { get; }
        public uint ExportDirectoryRva { get; }

        public byte[] Mutate(Action<byte[]> mutation)
        {
            var copy = (byte[])Bytes.Clone();
            mutation(copy);
            return copy;
        }

        public TestPeImage WithBundle(bool includeRuntimeAssets)
        {
            var bundleEntries = new List<BundleTestEntry>
            {
                new("Ke.Windows.dll", 1, Encoding.UTF8.GetBytes("managed app")),
                new(
                    "Ke.Windows.deps.json",
                    3,
                    Encoding.UTF8.GetBytes(
                        "{\"runtimeTarget\":{\"name\":\".NETCoreApp,Version=v10.0/win-x64\"}}")),
                new(
                    "Ke.Windows.runtimeconfig.json",
                    4,
                    Encoding.UTF8.GetBytes(includeRuntimeAssets
                        ? "{\"runtimeOptions\":{\"tfm\":\"net10.0\",\"includedFrameworks\":[{\"name\":\"Microsoft.NETCore.App\",\"version\":\"10.0.0\"},{\"name\":\"Microsoft.WindowsDesktop.App\",\"version\":\"10.0.0\"}]}}"
                        : "{\"runtimeOptions\":{\"tfm\":\"net10.0\",\"frameworks\":[{\"name\":\"Microsoft.NETCore.App\",\"version\":\"10.0.0\"}]}}"))
            };
            if (includeRuntimeAssets)
            {
                bundleEntries.Add(new BundleTestEntry(
                    "System.Private.CoreLib.dll",
                    1,
                    Encoding.UTF8.GetBytes("runtime assembly")));
                bundleEntries.Add(new BundleTestEntry(
                    "coreclr.dll",
                    2,
                    Encoding.UTF8.GetBytes("runtime native binary")));
                bundleEntries.Add(new BundleTestEntry(
                    "clrjit.dll",
                    2,
                    Encoding.UTF8.GetBytes("runtime JIT")));
            }

            var image = new List<byte>(Bytes);
            foreach (var entry in bundleEntries)
            {
                entry.Offset = image.Count;
                image.AddRange(entry.Data);
            }

            var headerOffset = image.Count;
            using (var header = new MemoryStream())
            using (var writer = new BinaryWriter(header, Encoding.UTF8, leaveOpen: true))
            {
                writer.Write(6u);
                writer.Write(0u);
                writer.Write(bundleEntries.Count);
                writer.Write("FixtureId123");

                var deps = bundleEntries.Single(entry => entry.Type == 3);
                var runtimeConfig = bundleEntries.Single(entry => entry.Type == 4);
                writer.Write((long)deps.Offset);
                writer.Write((long)deps.Data.Length);
                writer.Write((long)runtimeConfig.Offset);
                writer.Write((long)runtimeConfig.Data.Length);
                writer.Write(0UL);

                foreach (var entry in bundleEntries)
                {
                    writer.Write((long)entry.Offset);
                    writer.Write((long)entry.Data.Length);
                    writer.Write(0L);
                    writer.Write(entry.Type);
                    writer.Write(entry.Path);
                }

                writer.Flush();
                image.AddRange(header.ToArray());
            }

            var result = image.ToArray();
            var locatorOffset = Bytes.Length - 64;
            WriteInt64(result, locatorOffset, headerOffset);
            BundleSignature.CopyTo(result, locatorOffset + 8);
            return CopyWithBundle(result, locatorOffset, headerOffset);
        }

        public TestPeImage WithFalsePositiveBundleMarker()
        {
            var result = (byte[])Bytes.Clone();
            var locatorOffset = result.Length - 64;
            BundleSignature.CopyTo(result, locatorOffset + 8);
            return CopyWithBundle(result, locatorOffset, -1);
        }

        private TestPeImage CopyWithBundle(
            byte[] bytes,
            int locatorOffset,
            int headerOffset) =>
            new(
                bytes,
                GroupDataFileOffset,
                FirstPngFileOffset,
                FirstPngIendFileOffset,
                FirstPngLength,
                FirstPngIdatDataFileOffset,
                FirstPngIdatDataLength,
                FirstIconDataEntryFileOffset,
                locatorOffset,
                headerOffset,
                ExportDirectoryFileOffset,
                ExportFunctionTableFileOffset,
                ExportDirectoryRva);

        public static TestPeImage Create(
            bool splitIdat = false,
            bool duplicateAdler = false,
            bool includeRuntimeExport = true)
        {
            var resource = new ResourceFixtureBuilder(
                ResourceRva,
                splitIdat,
                duplicateAdler);
            var fixture = resource.Build();
            var exportRelativeOffset = Align(fixture.Bytes.Length, 4);
            var exportContentLength = includeRuntimeExport
                ? GetExportContentLength(exportRelativeOffset)
                : fixture.Bytes.Length;
            var rawSize = Align(checked(exportContentLength + 128), 0x200);
            var bytes = new byte[checked(ResourceRawOffset + rawSize)];

            WriteUInt16(bytes, 0, 0x5A4D);
            WriteUInt32(bytes, 0x3C, PeOffset);
            WriteUInt32(bytes, PeOffset, 0x00004550);

            var coff = PeOffset + 4;
            WriteUInt16(bytes, coff, Amd64Machine);
            WriteUInt16(bytes, coff + 2, 1);
            WriteUInt16(bytes, coff + 16, OptionalHeaderSize);

            var optional = coff + 20;
            WriteUInt16(bytes, optional, Pe32PlusMagic);
            WriteUInt16(bytes, optional + 68, WindowsGuiSubsystem);
            WriteUInt32(bytes, optional + 108, 16);
            if (includeRuntimeExport)
            {
                var exportRva = checked(ResourceRva + (uint)exportRelativeOffset);
                WriteUInt32(bytes, optional + 112, exportRva);
                WriteUInt32(
                    bytes,
                    optional + 112 + 4,
                    checked((uint)(exportContentLength - exportRelativeOffset - 1)));
            }
            WriteUInt32(bytes, optional + 112 + (2 * 8), ResourceRva);
            WriteUInt32(bytes, optional + 112 + (2 * 8) + 4, (uint)fixture.Bytes.Length);

            var section = optional + OptionalHeaderSize;
            Encoding.ASCII.GetBytes(".rsrc\0\0\0").CopyTo(bytes, section);
            WriteUInt32(bytes, section + 8, (uint)fixture.Bytes.Length);
            WriteUInt32(bytes, section + 12, ResourceRva);
            WriteUInt32(bytes, section + 16, (uint)rawSize);
            WriteUInt32(bytes, section + 20, ResourceRawOffset);

            fixture.Bytes.CopyTo(bytes, ResourceRawOffset);
            if (includeRuntimeExport)
            {
                WriteRuntimeExport(bytes, exportRelativeOffset);
            }
            return new TestPeImage(
                bytes,
                ResourceRawOffset + fixture.GroupDataOffset,
                ResourceRawOffset + fixture.FirstPngOffset,
                ResourceRawOffset + fixture.FirstPngIendOffset,
                fixture.FirstPngLength,
                ResourceRawOffset + fixture.FirstPngIdatDataOffset,
                fixture.FirstPngIdatDataLength,
                ResourceRawOffset + fixture.FirstIconDataEntryOffset,
                exportDirectoryFileOffset: includeRuntimeExport
                    ? ResourceRawOffset + exportRelativeOffset
                    : -1,
                exportFunctionTableFileOffset: includeRuntimeExport
                    ? ResourceRawOffset + exportRelativeOffset + 40
                    : -1,
                exportDirectoryRva: includeRuntimeExport
                    ? checked(ResourceRva + (uint)exportRelativeOffset)
                    : 0);
        }

        private static int Align(int value, int alignment) =>
            checked(((value + alignment - 1) / alignment) * alignment);

        private static int GetExportContentLength(int exportRelativeOffset)
        {
            var dllNameLength = Encoding.ASCII.GetByteCount("Ke.Windows.exe") + 1;
            var exportNameLength = Encoding.ASCII.GetByteCount("DotNetRuntimeInfo") + 1;
            var dataRelativeOffset = Align(
                checked(exportRelativeOffset + 50 + dllNameLength + exportNameLength),
                4);
            return checked(dataRelativeOffset + 1);
        }

        private static void WriteRuntimeExport(byte[] bytes, int exportRelativeOffset)
        {
            var exportFileOffset = checked(ResourceRawOffset + exportRelativeOffset);
            var functionsRelativeOffset = checked(exportRelativeOffset + 40);
            var namesRelativeOffset = checked(exportRelativeOffset + 44);
            var ordinalsRelativeOffset = checked(exportRelativeOffset + 48);
            var dllNameRelativeOffset = checked(exportRelativeOffset + 50);
            var dllName = Encoding.ASCII.GetBytes("Ke.Windows.exe\0");
            var exportNameRelativeOffset = checked(dllNameRelativeOffset + dllName.Length);
            var exportName = Encoding.ASCII.GetBytes("DotNetRuntimeInfo\0");
            var dataRelativeOffset = Align(
                checked(exportNameRelativeOffset + exportName.Length),
                4);

            WriteUInt32(
                bytes,
                exportFileOffset + 12,
                checked(ResourceRva + (uint)dllNameRelativeOffset));
            WriteUInt32(bytes, exportFileOffset + 16, 1);
            WriteUInt32(bytes, exportFileOffset + 20, 1);
            WriteUInt32(bytes, exportFileOffset + 24, 1);
            WriteUInt32(
                bytes,
                exportFileOffset + 28,
                checked(ResourceRva + (uint)functionsRelativeOffset));
            WriteUInt32(
                bytes,
                exportFileOffset + 32,
                checked(ResourceRva + (uint)namesRelativeOffset));
            WriteUInt32(
                bytes,
                exportFileOffset + 36,
                checked(ResourceRva + (uint)ordinalsRelativeOffset));
            WriteUInt32(
                bytes,
                ResourceRawOffset + functionsRelativeOffset,
                checked(ResourceRva + (uint)dataRelativeOffset));
            WriteUInt32(
                bytes,
                ResourceRawOffset + namesRelativeOffset,
                checked(ResourceRva + (uint)exportNameRelativeOffset));
            WriteUInt16(bytes, ResourceRawOffset + ordinalsRelativeOffset, 0);
            dllName.CopyTo(bytes, ResourceRawOffset + dllNameRelativeOffset);
            exportName.CopyTo(bytes, ResourceRawOffset + exportNameRelativeOffset);
            bytes[ResourceRawOffset + dataRelativeOffset] = 1;
        }

        private sealed class BundleTestEntry
        {
            public BundleTestEntry(string path, byte type, byte[] data)
            {
                Path = path;
                Type = type;
                Data = data;
            }

            public string Path { get; }
            public byte Type { get; }
            public byte[] Data { get; }
            public int Offset { get; set; }
        }
    }

    private sealed class ResourceFixtureBuilder
    {
        private readonly uint _resourceRva;
        private readonly bool _splitIdat;
        private readonly bool _duplicateAdler;
        private readonly List<byte> _bytes = new();

        public ResourceFixtureBuilder(
            uint resourceRva,
            bool splitIdat,
            bool duplicateAdler)
        {
            _resourceRva = resourceRva;
            _splitIdat = splitIdat;
            _duplicateAdler = duplicateAdler;
        }

        public ResourceFixture Build()
        {
            var root = Allocate(32);
            var iconType = Allocate(16 + (ExpectedIconSizes.Length * 8));
            var groupType = Allocate(24);
            var iconLanguages = ExpectedIconSizes.Select(_ => Allocate(24)).ToArray();
            var groupLanguage = Allocate(24);
            var iconDataEntries = ExpectedIconSizes.Select(_ => Allocate(16)).ToArray();
            var groupDataEntry = Allocate(16);

            var pngs = ExpectedIconSizes.Select(CreatePng).ToArray();
            var pngOffsets = pngs.Select(png => AddData(png.Bytes)).ToArray();
            var pngBytes = pngs.Select(png => png.Bytes).ToArray();
            var groupBytes = CreateGroupIcon(pngBytes);
            var groupOffset = AddData(groupBytes);

            WriteDirectoryHeader(root, 0, 2);
            WriteDirectoryEntry(root + 16, IconResourceType, iconType, true);
            WriteDirectoryEntry(root + 24, GroupIconResourceType, groupType, true);

            WriteDirectoryHeader(iconType, 0, (ushort)ExpectedIconSizes.Length);
            for (var index = 0; index < ExpectedIconSizes.Length; index++)
            {
                var id = checked((ushort)(index + 1));
                WriteDirectoryEntry(iconType + 16 + (index * 8), id, iconLanguages[index], true);
                WriteDirectoryHeader(iconLanguages[index], 0, 1);
                WriteDirectoryEntry(iconLanguages[index] + 16, 1033, iconDataEntries[index], false);
                WriteDataEntry(iconDataEntries[index], pngOffsets[index], pngs[index].Bytes.Length);
            }

            WriteDirectoryHeader(groupType, 0, 1);
            WriteDirectoryEntry(groupType + 16, 1, groupLanguage, true);
            WriteDirectoryHeader(groupLanguage, 0, 1);
            WriteDirectoryEntry(groupLanguage + 16, 1033, groupDataEntry, false);
            WriteDataEntry(groupDataEntry, groupOffset, groupBytes.Length);

            return new ResourceFixture(
                _bytes.ToArray(),
                groupOffset,
                pngOffsets[0],
                pngOffsets[0] + pngs[0].IendOffset,
                pngs[0].Bytes.Length,
                pngOffsets[0] + pngs[0].IdatDataOffset,
                pngs[0].IdatDataLength,
                iconDataEntries[0]);
        }

        private int Allocate(int length)
        {
            var offset = _bytes.Count;
            _bytes.AddRange(new byte[length]);
            return offset;
        }

        private int AddData(byte[] data)
        {
            while ((_bytes.Count & 3) != 0)
            {
                _bytes.Add(0);
            }

            var offset = _bytes.Count;
            _bytes.AddRange(data);
            return offset;
        }

        private void WriteDirectoryHeader(int offset, ushort named, ushort ids)
        {
            WriteUInt16(_bytes, offset + 12, named);
            WriteUInt16(_bytes, offset + 14, ids);
        }

        private void WriteDirectoryEntry(int offset, int id, int target, bool directory)
        {
            WriteUInt32(_bytes, offset, checked((uint)id));
            WriteUInt32(
                _bytes,
                offset + 4,
                checked((uint)target) | (directory ? 0x80000000 : 0));
        }

        private void WriteDataEntry(int offset, int dataOffset, int size)
        {
            WriteUInt32(_bytes, offset, checked(_resourceRva + (uint)dataOffset));
            WriteUInt32(_bytes, offset + 4, checked((uint)size));
        }

        private PngFixture CreatePng(int size)
        {
            var ihdr = new byte[13];
            WriteBigEndianUInt32(ihdr, 0, checked((uint)size));
            WriteBigEndianUInt32(ihdr, 4, checked((uint)size));
            ihdr[8] = 8;
            ihdr[9] = 6;

            var scanlines = new byte[checked(size * ((size * 4) + 1))];
            using var compressed = new MemoryStream();
            using (var zlib = new System.IO.Compression.ZLibStream(
                       compressed,
                       System.IO.Compression.CompressionLevel.SmallestSize,
                       leaveOpen: true))
            {
                zlib.Write(scanlines);
            }

            using var png = new MemoryStream();
            png.Write(PngSignature);
            WritePngChunk(png, IhdrChunkType, ihdr);
            var idatChunkOffset = checked((int)png.Position);
            var compressedBytes = compressed.ToArray();
            if (_duplicateAdler)
            {
                var duplicated = new byte[checked(compressedBytes.Length + 4)];
                compressedBytes.CopyTo(duplicated, 0);
                compressedBytes.AsSpan(compressedBytes.Length - 4, 4).CopyTo(
                    duplicated.AsSpan(compressedBytes.Length, 4));
                compressedBytes = duplicated;
            }

            var firstIdatLength = compressedBytes.Length;
            if (_splitIdat)
            {
                firstIdatLength = compressedBytes.Length / 2;
                WritePngChunk(png, IdatChunkType, compressedBytes[..firstIdatLength]);
                WritePngChunk(png, IdatChunkType, compressedBytes[firstIdatLength..]);
            }
            else
            {
                WritePngChunk(png, IdatChunkType, compressedBytes);
            }

            var iendOffset = checked((int)png.Position);
            WritePngChunk(png, IendChunkType, Array.Empty<byte>());
            return new PngFixture(
                png.ToArray(),
                iendOffset,
                idatChunkOffset + 8,
                firstIdatLength);
        }

        private static void WritePngChunk(MemoryStream stream, byte[] type, byte[] data)
        {
            var length = new byte[4];
            WriteBigEndianUInt32(length, 0, checked((uint)data.Length));
            stream.Write(length);
            stream.Write(type);
            stream.Write(data);
            var crcInput = new byte[type.Length + data.Length];
            type.CopyTo(crcInput, 0);
            data.CopyTo(crcInput, type.Length);
            var crc = new byte[4];
            WriteBigEndianUInt32(crc, 0, ComputePngCrc(crcInput));
            stream.Write(crc);
        }

        private static byte[] CreateGroupIcon(IReadOnlyList<byte[]> pngs)
        {
            var group = new byte[6 + (ExpectedIconSizes.Length * 14)];
            PortablePeVerifier.WriteUInt16(group, 2, 1);
            PortablePeVerifier.WriteUInt16(
                group,
                4,
                checked((ushort)ExpectedIconSizes.Length));
            for (var index = 0; index < ExpectedIconSizes.Length; index++)
            {
                var size = ExpectedIconSizes[index];
                var offset = 6 + (index * 14);
                group[offset] = size == 256 ? (byte)0 : checked((byte)size);
                group[offset + 1] = group[offset];
                PortablePeVerifier.WriteUInt16(group, offset + 4, 1);
                PortablePeVerifier.WriteUInt16(group, offset + 6, 32);
                PortablePeVerifier.WriteUInt32(
                    group,
                    offset + 8,
                    checked((uint)pngs[index].Length));
                PortablePeVerifier.WriteUInt16(
                    group,
                    offset + 12,
                    checked((ushort)(index + 1)));
            }

            return group;
        }

        private static void WriteUInt16(List<byte> bytes, int offset, ushort value)
        {
            var data = new byte[2];
            BinaryPrimitives.WriteUInt16LittleEndian(data, value);
            for (var index = 0; index < data.Length; index++)
            {
                bytes[offset + index] = data[index];
            }
        }

        private static void WriteUInt32(List<byte> bytes, int offset, uint value)
        {
            var data = new byte[4];
            BinaryPrimitives.WriteUInt32LittleEndian(data, value);
            for (var index = 0; index < data.Length; index++)
            {
                bytes[offset + index] = data[index];
            }
        }
    }

    private sealed record ResourceFixture(
        byte[] Bytes,
        int GroupDataOffset,
        int FirstPngOffset,
        int FirstPngIendOffset,
        int FirstPngLength,
        int FirstPngIdatDataOffset,
        int FirstPngIdatDataLength,
        int FirstIconDataEntryOffset);

    private sealed record PngFixture(
        byte[] Bytes,
        int IendOffset,
        int IdatDataOffset,
        int IdatDataLength);
}
