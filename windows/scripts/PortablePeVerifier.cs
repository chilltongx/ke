using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

public static class PortablePeVerifier
{
    private const ushort Amd64Machine = 0x8664;
    private const ushort Pe32PlusMagic = 0x020B;
    private const ushort WindowsGuiSubsystem = 2;
    private const int IconResourceType = 3;
    private const int GroupIconResourceType = 14;
    private static readonly byte[] PngSignature =
        { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    private static readonly byte[] IhdrChunkType = Encoding.ASCII.GetBytes("IHDR");
    private static readonly byte[] IdatChunkType = Encoding.ASCII.GetBytes("IDAT");
    private static readonly byte[] IendChunkType = Encoding.ASCII.GetBytes("IEND");
    private static readonly int[] ExpectedIconSizes = { 16, 24, 32, 48, 64, 128, 256 };

    public static void Verify(string executable)
    {
        if (string.IsNullOrWhiteSpace(executable))
        {
            throw new InvalidDataException("Executable path is empty");
        }

        VerifyImage(File.ReadAllBytes(executable));
    }

    public static void RunSelfTests()
    {
        var valid = TestPeImage.Create();
        VerifyImage(valid.Bytes);

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

        ExpectRejected("RT_ICON PNG has a bad IHDR CRC", valid.Mutate(bytes =>
            bytes[valid.FirstPngFileOffset + 29] ^= 0x01));

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
        for (var index = 0; index < sectionCount; index++)
        {
            var offset = checked(sectionTableOffset + (index * 40));
            sections.Add(new Section(
                reader.ReadUInt32(offset + 8),
                reader.ReadUInt32(offset + 12),
                reader.ReadUInt32(offset + 16),
                reader.ReadUInt32(offset + 20)));
        }

        var mapper = new RvaMapper(reader, sections);
        mapper.Map(resourceRva, resourceSize, "resource directory");
        var resources = new ResourceReader(reader, mapper, resourceRva, resourceSize);
        VerifyIconResources(resources);
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

                if (data[chunkDataOffset + 10] != 0 ||
                    data[chunkDataOffset + 11] != 0 ||
                    data[chunkDataOffset + 12] > 1)
                {
                    throw new InvalidDataException("RT_ICON PNG IHDR methods are invalid");
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

    private static void WriteBigEndianUInt32(byte[] bytes, int offset, uint value) =>
        BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(offset, 4), value);

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

        public int ReadInt32(int offset)
        {
            Require(offset, 4, "Int32");
            return BinaryPrimitives.ReadInt32LittleEndian(Bytes.AsSpan(offset, 4));
        }

        public uint ReadUInt32(int offset)
        {
            Require(offset, 4, "UInt32");
            return BinaryPrimitives.ReadUInt32LittleEndian(Bytes.AsSpan(offset, 4));
        }
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

        private TestPeImage(
            byte[] bytes,
            int groupDataFileOffset,
            int firstPngFileOffset,
            int firstPngIendFileOffset,
            int firstPngLength,
            int firstIconDataEntryFileOffset)
        {
            Bytes = bytes;
            GroupDataFileOffset = groupDataFileOffset;
            FirstPngFileOffset = firstPngFileOffset;
            FirstPngIendFileOffset = firstPngIendFileOffset;
            FirstPngLength = firstPngLength;
            FirstIconDataEntryFileOffset = firstIconDataEntryFileOffset;
        }

        public byte[] Bytes { get; }
        public int CoffHeaderOffset => PeOffset + 4;
        public int DataDirectoryCountOffset => CoffHeaderOffset + 20 + 108;
        public int ResourceDirectoryEntryOffset => CoffHeaderOffset + 20 + 112 + (2 * 8);
        public int GroupDataFileOffset { get; }
        public int FirstPngFileOffset { get; }
        public int FirstPngIendFileOffset { get; }
        public int FirstPngLength { get; }
        public int FirstIconDataEntryFileOffset { get; }

        public byte[] Mutate(Action<byte[]> mutation)
        {
            var copy = (byte[])Bytes.Clone();
            mutation(copy);
            return copy;
        }

        public static TestPeImage Create()
        {
            var resource = new ResourceFixtureBuilder(ResourceRva);
            var fixture = resource.Build();
            var rawSize = Align(fixture.Bytes.Length, 0x200);
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
            WriteUInt32(bytes, optional + 112 + (2 * 8), ResourceRva);
            WriteUInt32(bytes, optional + 112 + (2 * 8) + 4, (uint)fixture.Bytes.Length);

            var section = optional + OptionalHeaderSize;
            Encoding.ASCII.GetBytes(".rsrc\0\0\0").CopyTo(bytes, section);
            WriteUInt32(bytes, section + 8, (uint)fixture.Bytes.Length);
            WriteUInt32(bytes, section + 12, ResourceRva);
            WriteUInt32(bytes, section + 16, (uint)rawSize);
            WriteUInt32(bytes, section + 20, ResourceRawOffset);

            fixture.Bytes.CopyTo(bytes, ResourceRawOffset);
            return new TestPeImage(
                bytes,
                ResourceRawOffset + fixture.GroupDataOffset,
                ResourceRawOffset + fixture.FirstPngOffset,
                ResourceRawOffset + fixture.FirstPngIendOffset,
                fixture.FirstPngLength,
                ResourceRawOffset + fixture.FirstIconDataEntryOffset);
        }

        private static int Align(int value, int alignment) =>
            checked(((value + alignment - 1) / alignment) * alignment);
    }

    private sealed class ResourceFixtureBuilder
    {
        private readonly uint _resourceRva;
        private readonly List<byte> _bytes = new();

        public ResourceFixtureBuilder(uint resourceRva) => _resourceRva = resourceRva;

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

        private static PngFixture CreatePng(int size)
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
            WritePngChunk(png, IdatChunkType, compressed.ToArray());
            var iendOffset = checked((int)png.Position);
            WritePngChunk(png, IendChunkType, Array.Empty<byte>());
            return new PngFixture(png.ToArray(), iendOffset);
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
        int FirstIconDataEntryOffset);

    private sealed record PngFixture(byte[] Bytes, int IendOffset);
}
