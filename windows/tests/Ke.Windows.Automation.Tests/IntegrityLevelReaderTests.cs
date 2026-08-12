using System.Runtime.InteropServices;
using Ke.Windows.Automation;
using Ke.Windows.Core;
using Xunit;

namespace Ke.Windows.Automation.Tests;

public sealed class IntegrityLevelReaderTests
{
    [Theory]
    [InlineData(0)]
    [InlineData(27)]
    [InlineData(65537)]
    [InlineData(uint.MaxValue)]
    public void Probe_length_outside_safe_bounds_fails_closed(uint length)
    {
        AssertUnavailable(() => IntegrityBufferParser.ValidateProbeLength(length));
    }

    [Theory]
    [InlineData(28)]
    [InlineData(65536)]
    public void Probe_length_at_safe_bounds_is_accepted(uint length)
    {
        Assert.Equal(checked((int)length), IntegrityBufferParser.ValidateProbeLength(length));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(27)]
    [InlineData(65)]
    [InlineData(65537)]
    [InlineData(uint.MaxValue)]
    public void Second_return_length_outside_allocation_fails_closed(uint returnedLength)
    {
        using var buffer = UnmanagedBuffer.Allocate(64);

        AssertUnavailable(
            () => IntegrityBufferParser.Create(
                buffer.Pointer,
                allocatedLength: 64,
                returnedLength));
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(64)]
    public void SID_pointer_outside_returned_buffer_fails_closed(int offset)
    {
        using var buffer = UnmanagedBuffer.Allocate(64);
        Marshal.WriteIntPtr(buffer.Pointer, buffer.Pointer + offset);
        var parser = IntegrityBufferParser.Create(buffer.Pointer, 64, 64);

        AssertUnavailable(() => _ = parser.ReadSidPointer());
    }

    [Fact]
    public void Null_information_pointer_fails_closed()
    {
        AssertUnavailable(() => IntegrityBufferParser.Create(0, 64, 64));
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(64)]
    public void Count_pointer_outside_returned_buffer_fails_closed(int offset)
    {
        using var fixture = IntegrityBufferFixture.Create();

        AssertUnavailable(
            () => fixture.Parser.ReadSubAuthorityCount(
                fixture.Sid,
                fixture.Buffer.Pointer + offset));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(16)]
    public void Invalid_SID_subauthority_count_fails_closed(byte count)
    {
        using var fixture = IntegrityBufferFixture.Create();
        Marshal.WriteByte(fixture.Sid + 1, count);

        AssertUnavailable(
            () => fixture.Parser.ReadSubAuthorityCount(
                fixture.Sid,
                fixture.Sid + 1));
    }

    [Fact]
    public void SID_extent_outside_returned_buffer_fails_closed()
    {
        using var fixture = IntegrityBufferFixture.Create(sidOffset: 52);
        Marshal.WriteByte(fixture.Sid + 1, 2);

        AssertUnavailable(
            () => fixture.Parser.ReadSubAuthorityCount(
                fixture.Sid,
                fixture.Sid + 1));
    }

    [Fact]
    public void SID_extent_uses_second_return_length_not_allocation_length()
    {
        using var buffer = UnmanagedBuffer.Allocate(64);
        var sid = buffer.Pointer + 32;
        Marshal.WriteIntPtr(buffer.Pointer, sid);
        Marshal.WriteByte(sid + 1, 1);
        var parser = IntegrityBufferParser.Create(buffer.Pointer, 64, 40);

        AssertUnavailable(
            () => parser.ReadSubAuthorityCount(sid, sid + 1));
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(12)]
    [InlineData(64)]
    public void RID_pointer_outside_valid_SID_fails_closed(int offset)
    {
        using var fixture = IntegrityBufferFixture.Create();
        var count = fixture.Parser.ReadSubAuthorityCount(
            fixture.Sid,
            fixture.Sid + 1);

        AssertUnavailable(
            () => fixture.Parser.ReadRid(
                fixture.Sid,
                count,
                fixture.Buffer.Pointer + offset));
    }

    [Fact]
    public void Valid_buffer_returns_last_integrity_RID()
    {
        using var fixture = IntegrityBufferFixture.Create();
        var sid = fixture.Parser.ReadSidPointer();
        var count = fixture.Parser.ReadSubAuthorityCount(sid, sid + 1);

        var rid = fixture.Parser.ReadRid(sid, count, sid + 8);

        Assert.Equal(0x2000, rid);
    }

    private static void AssertUnavailable(Action action)
    {
        var exception = Assert.Throws<AutomationCaptureException>(action);
        Assert.Equal(SendErrorCode.AutomationUnavailable, exception.Error);
    }

    private sealed class IntegrityBufferFixture : IDisposable
    {
        private IntegrityBufferFixture(UnmanagedBuffer buffer, nint sid)
        {
            Buffer = buffer;
            Sid = sid;
            Parser = IntegrityBufferParser.Create(
                buffer.Pointer,
                buffer.Length,
                checked((uint)buffer.Length));
        }

        public UnmanagedBuffer Buffer { get; }

        public nint Sid { get; }

        public IntegrityBufferParser Parser { get; }

        public static IntegrityBufferFixture Create(int sidOffset = 32)
        {
            var buffer = UnmanagedBuffer.Allocate(64);
            var sid = buffer.Pointer + sidOffset;
            Marshal.WriteIntPtr(buffer.Pointer, sid);
            Marshal.WriteByte(sid, 1);
            Marshal.WriteByte(sid + 1, 1);
            Marshal.WriteInt32(sid + 8, 0x2000);
            return new(buffer, sid);
        }

        public void Dispose() => Buffer.Dispose();
    }

    private sealed class UnmanagedBuffer : IDisposable
    {
        private UnmanagedBuffer(nint pointer, int length)
        {
            Pointer = pointer;
            Length = length;
        }

        public nint Pointer { get; }

        public int Length { get; }

        public static UnmanagedBuffer Allocate(int length)
        {
            var pointer = Marshal.AllocHGlobal(length);
            var zeros = new byte[length];
            Marshal.Copy(zeros, 0, pointer, length);
            return new(pointer, length);
        }

        public void Dispose() => Marshal.FreeHGlobal(Pointer);
    }
}
