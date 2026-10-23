using System.Buffers.Binary;

namespace Nearclip.Core;

/// <summary><c>u32 length || payload</c> with 1 ≤ length ≤ 17 MiB (PROTOCOL.md §3).</summary>
public static class Framing
{
    public static byte[] Encode(ReadOnlySpan<byte> payload)
    {
        if (payload.Length is < 1 or > Wire.MaxFrame) throw NearclipException.Protocol($"frame length {payload.Length}");
        var frame = new byte[payload.Length + 4];
        BinaryPrimitives.WriteUInt32BigEndian(frame, (uint)payload.Length);
        payload.CopyTo(frame.AsSpan(4));
        return frame;
    }

    /// <summary>Reads one frame. Returns null on a clean end of stream before a header.</summary>
    public static async Task<byte[]?> ReadAsync(Stream stream, CancellationToken ct)
    {
        var header = new byte[4];
        var got = await ReadAtLeast(stream, header, ct).ConfigureAwait(false);
        if (got == 0) return null;
        if (got < 4) throw NearclipException.Io("short read");
        var length = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (length < 1 || length > Wire.MaxFrame) throw NearclipException.Protocol($"frame length {length}");
        var body = new byte[length];
        if (await ReadAtLeast(stream, body, ct).ConfigureAwait(false) < body.Length) throw NearclipException.Io("short read");
        return body;
    }

    static async Task<int> ReadAtLeast(Stream stream, byte[] buffer, CancellationToken ct)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(total), ct).ConfigureAwait(false);
            if (n == 0) break;
            total += n;
        }
        return total;
    }
}
