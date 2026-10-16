using System.Buffers.Binary;

namespace GoProTimelapser;

/// <summary>
/// Reads recording time and duration straight from the MP4 'moov/mvhd' box,
/// so no ffprobe is needed and adding many clips stays instant.
/// </summary>
public static class Mp4Metadata
{
    private static readonly DateTime Mp4Epoch = new(1904, 1, 1, 0, 0, 0, DateTimeKind.Unspecified);

    public sealed record Info(DateTime? CreationTime, TimeSpan? Duration);

    public static Info Read(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var moov = FindBox(fs, 0, fs.Length, "moov");
            if (moov is null) return new Info(null, null);
            var mvhd = FindBox(fs, moov.Value.dataStart, moov.Value.end, "mvhd");
            if (mvhd is null) return new Info(null, null);
            return ParseMvhd(fs, mvhd.Value.dataStart);
        }
        catch
        {
            return new Info(null, null);
        }
    }

    private static Info ParseMvhd(FileStream fs, long start)
    {
        fs.Position = start;
        Span<byte> buf = stackalloc byte[32];
        ReadExactly(fs, buf[..4]);
        int version = buf[0];

        ulong created;
        uint timescale;
        ulong duration;
        if (version == 1)
        {
            ReadExactly(fs, buf[..28]);
            created = BinaryPrimitives.ReadUInt64BigEndian(buf[0..8]);
            timescale = BinaryPrimitives.ReadUInt32BigEndian(buf[16..20]);
            duration = BinaryPrimitives.ReadUInt64BigEndian(buf[20..28]);
        }
        else
        {
            ReadExactly(fs, buf[..16]);
            created = BinaryPrimitives.ReadUInt32BigEndian(buf[0..4]);
            timescale = BinaryPrimitives.ReadUInt32BigEndian(buf[8..12]);
            duration = BinaryPrimitives.ReadUInt32BigEndian(buf[12..16]);
        }

        DateTime? createdAt = null;
        // GoPro writes the camera's local clock here (labelled UTC), so show it as-is.
        if (created > 0 && created < 0x1_0000_0000UL * 4)
        {
            var dt = Mp4Epoch.AddSeconds(created);
            if (dt.Year >= 2000 && dt.Year <= 2100) createdAt = dt;
        }

        TimeSpan? dur = null;
        if (timescale > 0 && duration > 0 && duration != uint.MaxValue && duration != ulong.MaxValue)
            dur = TimeSpan.FromSeconds((double)duration / timescale);

        return new Info(createdAt, dur);
    }

    private static (long dataStart, long end)? FindBox(FileStream fs, long start, long end, string type)
    {
        Span<byte> header = stackalloc byte[16];
        long pos = start;
        while (pos + 8 <= end)
        {
            fs.Position = pos;
            ReadExactly(fs, header[..8]);
            ulong size = BinaryPrimitives.ReadUInt32BigEndian(header[0..4]);
            string boxType = System.Text.Encoding.ASCII.GetString(header[4..8]);
            long headerLen = 8;
            if (size == 1)
            {
                ReadExactly(fs, header[8..16]);
                size = BinaryPrimitives.ReadUInt64BigEndian(header[8..16]);
                headerLen = 16;
            }
            else if (size == 0)
            {
                size = (ulong)(end - pos);
            }
            if (size < (ulong)headerLen) return null;
            long boxEnd = pos + (long)size;
            if (boxType == type) return (pos + headerLen, Math.Min(boxEnd, end));
            pos = boxEnd;
        }
        return null;
    }

    private static void ReadExactly(Stream s, Span<byte> buf)
    {
        int read = 0;
        while (read < buf.Length)
        {
            int n = s.Read(buf[read..]);
            if (n <= 0) throw new EndOfStreamException();
            read += n;
        }
    }
}
