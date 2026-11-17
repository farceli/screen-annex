using System.Buffers.Binary;
using System.Text;

namespace HosMirror.Windows;

// 将设备已经编码的 Annex-B H.264 封装为 MP4，保留原始码流，不采集声音。
internal sealed class H264Recording
{
    private readonly string _temporary;
    private readonly BinaryWriter _output;
    private readonly int _width, _height;
    private readonly List<(uint Size, bool Sync, long Time)> _samples = new();
    private readonly long _mdat;
    private byte[]? _sps, _pps;
    public string Path { get; }

    public H264Recording(string path, int width, int height)
    {
        if (width is < 1 or > ushort.MaxValue || height is < 1 or > ushort.MaxValue)
            throw new IOException("视频尺寸不可用于录制");
        Path = path;
        _width = width;
        _height = height;
        _temporary = path + ".part";
        _output = new BinaryWriter(new FileStream(_temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None));
        try
        {
            Box(_output, "ftyp", box => { Tag(box, "isom"); U32(box, 512); Tag(box, "isomiso2avc1mp41"); });
            _mdat = _output.BaseStream.Position;
            U32(_output, 1); Tag(_output, "mdat"); U64(_output, 0); // 64 位大小允许录制超过 4 GiB。
        }
        catch { _output.Dispose(); File.Delete(_temporary); throw; }
    }

    public static List<ReadOnlyMemory<byte>> Split(byte[] data)
    {
        var units = new List<ReadOnlyMemory<byte>>();
        int start = -1;
        for (int i = 0; i + 2 < data.Length; i++)
        {
            if (data[i] != 0 || data[i + 1] != 0) continue;
            int marker = data[i + 2] == 1 ? 3 : i + 3 < data.Length && data[i + 2] == 0 && data[i + 3] == 1 ? 4 : 0;
            if (marker == 0) continue;
            if (start >= 0 && i > start) units.Add(data.AsMemory(start, i - start));
            start = i + marker;
            i = start - 1;
        }
        if (start >= 0 && data.Length > start) units.Add(data.AsMemory(start));
        return units;
    }

    public void Append(IReadOnlyList<ReadOnlyMemory<byte>> units, byte[]? sps, byte[]? pps, long time)
    {
        bool key = units.Any(nal => (nal.Span[0] & 31) == 5);
        if (!key && !units.Any(nal => (nal.Span[0] & 31) == 1)) return;
        if (_samples.Count == 0)
        {
            if (!key || sps is not { Length: >= 4 and <= ushort.MaxValue } || pps is not { Length: > 0 and <= ushort.MaxValue }) return;
            _sps = sps; _pps = pps; // 保留首个 IDR 使用的解码配置。
        }
        else if (sps is null || pps is null || !_sps.AsSpan().SequenceEqual(sps) || !_pps.AsSpan().SequenceEqual(pps))
            throw new IOException("视频配置已改变，录制在上一帧结束");

        long start = _output.BaseStream.Position;
        foreach (var nal in units)
        {
            if ((nal.Span[0] & 31) is 7 or 8 or 9) continue; // 参数集由 avcC 保存。
            U32(_output, (uint)nal.Length);
            _output.Write(nal.Span);
        }
        _samples.Add((checked((uint)(_output.BaseStream.Position - start)), key, time));
    }

    public bool Finish()
    {
        bool saved = false;
        try
        {
            using (_output)
            {
                if (_samples.Count == 0) return false;
                long end = _output.BaseStream.Position;
                _output.BaseStream.Position = _mdat + 8;
                U64(_output, (ulong)(end - _mdat));
                _output.BaseStream.Position = end;
                var durations = new uint[_samples.Count];
                for (int i = 0; i + 1 < durations.Length; i++)
                    durations[i] = (uint)Math.Clamp(_samples[i + 1].Time - _samples[i].Time, 1, uint.MaxValue);
                durations[^1] = (uint)Math.Clamp(Environment.TickCount64 - _samples[^1].Time, 1, uint.MaxValue);
                ulong duration = durations.Aggregate(0UL, (sum, value) => sum + value);
                WriteMovie(_output, durations, duration);
            }
            File.Move(_temporary, Path);
            saved = true;
            return true;
        }
        finally
        {
            if (!saved) File.Delete(_temporary);
        }
    }

    private void WriteMovie(BinaryWriter output, uint[] durations, ulong duration)
    {
        Box(output, "moov", movie =>
        {
            Box(movie, "mvhd", box =>
            {
                U32(box, 0x01000000); U64(box, 0); U64(box, 0); U32(box, 1000); U64(box, duration);
                U32(box, 0x00010000); U16(box, 0x0100); Zero(box, 10); Matrix(box); Zero(box, 24); U32(box, 2);
            });
            Box(movie, "trak", track =>
            {
                Box(track, "tkhd", box =>
                {
                    U32(box, 0x01000007); U64(box, 0); U64(box, 0); U32(box, 1); U32(box, 0);
                    U64(box, duration); Zero(box, 16); Matrix(box); U32(box, (uint)_width << 16); U32(box, (uint)_height << 16);
                });
                Box(track, "mdia", media =>
                {
                    Box(media, "mdhd", box =>
                    {
                        U32(box, 0x01000000); U64(box, 0); U64(box, 0); U32(box, 1000);
                        U64(box, duration); U16(box, 0x55c4); U16(box, 0);
                    });
                    Box(media, "hdlr", box => { Zero(box, 8); Tag(box, "vide"); Zero(box, 12); Tag(box, "HosMirror\0"); });
                    Box(media, "minf", info =>
                    {
                        Box(info, "vmhd", box => { U32(box, 1); Zero(box, 8); });
                        Box(info, "dinf", box => Box(box, "dref", entries =>
                        {
                            U32(entries, 0); U32(entries, 1);
                            Box(entries, "url ", url => U32(url, 1)); // 自包含媒体数据。
                        }));
                        Box(info, "stbl", table => WriteSamples(table, durations));
                    });
                });
            });
        });
    }

    private void WriteSamples(BinaryWriter table, uint[] durations)
    {
        Box(table, "stsd", box =>
        {
            U32(box, 0); U32(box, 1);
            Box(box, "avc1", entry =>
            {
                Zero(entry, 6); U16(entry, 1); Zero(entry, 16);
                U16(entry, (ushort)_width); U16(entry, (ushort)_height);
                U32(entry, 0x00480000); U32(entry, 0x00480000); U32(entry, 0); U16(entry, 1);
                Zero(entry, 32); U16(entry, 24); U16(entry, 0xffff);
                Box(entry, "avcC", config =>
                {
                    var sps = _sps!;
                    var pps = _pps!;
                    config.Write(new byte[] { 1, sps[1], sps[2], sps[3], 0xff, 0xe1 });
                    U16(config, (ushort)sps.Length); config.Write(sps);
                    config.Write((byte)1); U16(config, (ushort)pps.Length); config.Write(pps);
                });
            });
        });
        Box(table, "stts", box =>
        {
            U32(box, 0); U32(box, (uint)durations.Length);
            foreach (uint duration in durations) { U32(box, 1); U32(box, duration); }
        });
        Box(table, "stsc", box => { U32(box, 0); U32(box, 1); U32(box, 1); U32(box, (uint)_samples.Count); U32(box, 1); });
        Box(table, "stsz", box =>
        {
            U32(box, 0); U32(box, 0); U32(box, (uint)_samples.Count);
            foreach (var sample in _samples) U32(box, sample.Size);
        });
        Box(table, "co64", box => { U32(box, 0); U32(box, 1); U64(box, (ulong)_mdat + 16); });
        Box(table, "stss", box =>
        {
            U32(box, 0); U32(box, (uint)_samples.Count(sample => sample.Sync));
            for (int i = 0; i < _samples.Count; i++) if (_samples[i].Sync) U32(box, (uint)i + 1);
        });
    }

    private static void Box(BinaryWriter output, string name, Action<BinaryWriter> write)
    {
        long start = output.BaseStream.Position;
        U32(output, 0); Tag(output, name);
        write(output);
        long end = output.BaseStream.Position;
        output.BaseStream.Position = start;
        U32(output, checked((uint)(end - start)));
        output.BaseStream.Position = end;
    }

    private static void Tag(BinaryWriter output, string name) => output.Write(Encoding.ASCII.GetBytes(name));
    private static void Zero(BinaryWriter output, int count) => output.Write(new byte[count]);
    private static void U16(BinaryWriter output, ushort value) => output.Write(BinaryPrimitives.ReverseEndianness(value));
    private static void U32(BinaryWriter output, uint value) => output.Write(BinaryPrimitives.ReverseEndianness(value));
    private static void U64(BinaryWriter output, ulong value) => output.Write(BinaryPrimitives.ReverseEndianness(value));
    private static void Matrix(BinaryWriter output)
    {
        U32(output, 0x10000); Zero(output, 12); U32(output, 0x10000); Zero(output, 12); U32(output, 0x40000000);
    }
}
