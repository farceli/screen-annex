using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace HosMirror.Windows;

internal static class ApkManifest
{
    public static async Task<string> PackageNameAsync(string path, CancellationToken token)
    {
        using var zip = ZipFile.OpenRead(path);
        var entry = zip.GetEntry("AndroidManifest.xml");
        if (entry is null || entry.Length is < 8 or > 16 * 1024 * 1024) throw new IOException("APK 应用声明缺失或过大");
        byte[] bytes = new byte[(int)entry.Length];
        await using var input = entry.Open();
        await input.ReadExactlyAsync(bytes, token);
        return Parse(bytes);
    }

    internal static string Parse(byte[] bytes)
    {
        static IOException Invalid() => new("APK 应用声明格式无效");
        int U16(int offset) => BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset, 2));
        int I32(int offset) => BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(offset, 4));
        string[] strings = [];
        try
        {
            if (U16(0) != 3 || U16(2) != 8 || I32(4) != bytes.Length) throw Invalid();
            for (int pos = 8; pos <= bytes.Length - 8;)
            {
                int type = U16(pos), header = U16(pos + 2), size = I32(pos + 4);
                if (header < 8 || size < header || size > bytes.Length - pos) throw Invalid();
                int end = pos + size;
                if (type == 1)
                {
                    if (strings.Length != 0 || header < 28) throw Invalid();
                    int count = I32(pos + 8), offset = I32(pos + 20);
                    bool utf8 = (I32(pos + 16) & 0x100) != 0;
                    if (count is < 0 or > 100_000 || offset < header + count * 4 || offset > size) throw Invalid();
                    strings = new string[count];
                    long budget = 16 * 1024 * 1024;
                    for (int i = 0; i < count; i++)
                    {
                        int relative = I32(pos + header + i * 4);
                        if (relative < 0 || relative >= size - offset) throw Invalid();
                        int cursor = pos + offset + relative;
                        int Length(bool wide)
                        {
                            int width = wide ? 2 : 1, mask = wide ? 0x8000 : 0x80;
                            if (cursor > end - width) throw Invalid();
                            int first = wide ? U16(cursor) : bytes[cursor];
                            cursor += width;
                            if ((first & mask) == 0) return first;
                            if (cursor > end - width) throw Invalid();
                            int second = wide ? U16(cursor) : bytes[cursor];
                            cursor += width;
                            return ((first & (mask - 1)) << (width * 8)) | second;
                        }
                        if (utf8) _ = Length(false); // UTF-8 字符池先存 UTF-16 字符数，再存字节数。
                        long length = utf8 ? Length(false) : 2L * Length(true);
                        budget -= length;
                        if (length > end - cursor || budget < 0) throw Invalid();
                        strings[i] = (utf8 ? Encoding.UTF8 : Encoding.Unicode).GetString(bytes, cursor, (int)length);
                    }
                }
                else if (type == 0x102)
                {
                    int node = pos + header;
                    if (end - node < 20) throw Invalid();
                    int element = I32(node + 4);
                    if ((uint)element < (uint)strings.Length && strings[element] == "manifest")
                    {
                        int offset = U16(node + 8), width = U16(node + 10), count = U16(node + 12);
                        if (offset < 20 || width < 20 || (long)offset + (long)width * count > end - node) throw Invalid();
                        for (int i = 0; i < count; i++)
                        {
                            int attribute = node + offset + i * width;
                            int name = I32(attribute + 4), raw = I32(attribute + 8);
                            if ((uint)name >= (uint)strings.Length || strings[name] != "package") continue;
                            int value = (uint)raw < (uint)strings.Length ? raw : bytes[attribute + 15] == 3 ? I32(attribute + 16) : -1;
                            if ((uint)value >= (uint)strings.Length || !Regex.IsMatch(strings[value], @"\A[A-Za-z0-9_.]+\z")) throw Invalid();
                            return strings[value];
                        }
                    }
                }
                pos = end;
            }
        }
        catch (ArgumentOutOfRangeException) { throw Invalid(); }
        throw Invalid();
    }
}
