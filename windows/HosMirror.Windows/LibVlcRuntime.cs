using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;

namespace HosMirror.Windows;

internal static class LibVlcRuntime
{
    private const string Version = "3.0.21";
    private const long PackageSize = 89989754;
    private const string PackageHash = "814AC28DE8AB1544E98816388858FBF1FEADD386928742885728959B43C1B0AB";
    private const string PackageUrl = "https://api.nuget.org/v3-flatcontainer/videolan.libvlc.windows/" +
        Version + "/videolan.libvlc.windows." + Version + ".nupkg";
    private static readonly HttpClient Http = new();
    private static readonly SemaphoreSlim Preparation = new(1, 1);

    internal static async Task<string> PrepareAsync(CancellationToken cancellation)
    {
        string cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Screen Annex", "VideoLAN");
        string runtime = Path.Combine(cache, Version + "-" + PackageHash[..12]);
        await Preparation.WaitAsync(cancellation);
        try
        {
            if (IsReady(runtime)) return runtime;
            // 版本和摘要固定。下载与提取在后台完成，窗口关闭时可取消。
            return await Task.Run(async () =>
            {
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                deadline.CancelAfter(TimeSpan.FromMinutes(5));
                string stage = Directory.CreateDirectory(Path.Combine(cache, Guid.NewGuid().ToString("N"))).FullName;
                try
                {
                    string package = Path.Combine(stage, "videolan.nupkg");
                    using var response = await Http.GetAsync(PackageUrl, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
                    response.EnsureSuccessStatusCode();
                    using (var file = File.Create(package))
                    using (var download = await response.Content.ReadAsStreamAsync(deadline.Token))
                    {
                        byte[] buffer = new byte[65536];
                        int read;
                        while ((read = await download.ReadAsync(buffer, deadline.Token)) != 0)
                        {
                            if (file.Position + read > PackageSize) throw new IOException("播放器下载大小与固定版本不符。");
                            await file.WriteAsync(buffer.AsMemory(0, read), deadline.Token);
                        }
                    }
                    using (var file = File.OpenRead(package))
                    {
                        if (file.Length != PackageSize || Convert.ToHexString(await SHA256.HashDataAsync(file, deadline.Token)) != PackageHash)
                            throw new IOException("播放器下载未通过完整性校验。");
                    }
                    string extracted = Path.Combine(stage, "runtime");
                    Extract(package, extracted, deadline.Token);
                    deadline.Token.ThrowIfCancellationRequested();
                    try { Directory.Move(extracted, runtime); }
                    catch (IOException) when (IsReady(runtime)) { /* 另一个实例已准备好相同版本。 */ }
                    return runtime;
                }
                catch (Exception error) when (error is HttpRequestException or IOException ||
                    error is OperationCanceledException && !cancellation.IsCancellationRequested)
                {
                    throw new IOException("无法准备 Windows 播放组件。请检查网络后重试。", error);
                }
                finally { Directory.Delete(stage, recursive: true); }
            }, cancellation);
        }
        finally { Preparation.Release(); }
    }

    internal static void Extract(string package, string directory, CancellationToken cancellation = default)
    {
        const string prefix = "build/x64/";
        string root = Path.GetFullPath(directory) + Path.DirectorySeparatorChar;
        using var archive = ZipFile.OpenRead(package);
        foreach (var entry in archive.Entries)
        {
            cancellation.ThrowIfCancellationRequested();
            if (!entry.FullName.StartsWith(prefix, StringComparison.Ordinal) || entry.Name.Length == 0) continue;
            string relative = entry.FullName[prefix.Length..];
            // 只保留运行时使用的 x64 库与资源，路径始终落在暂存目录内。
            if (relative is not ("libvlc.dll" or "libvlccore.dll") &&
                !relative.StartsWith("plugins/", StringComparison.Ordinal) &&
                !relative.StartsWith("lua/", StringComparison.Ordinal) &&
                !relative.StartsWith("hrtfs/", StringComparison.Ordinal)) continue;
            string destination = Path.GetFullPath(Path.Combine(root, relative));
            if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("播放器归档包含无效路径。");
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            entry.ExtractToFile(destination);
        }
        if (!IsReady(directory)) throw new InvalidDataException("播放器归档缺少 x64 运行组件。");
    }

    private static bool IsReady(string root) =>
        File.Exists(Path.Combine(root, "libvlc.dll")) &&
        File.Exists(Path.Combine(root, "libvlccore.dll")) &&
        File.Exists(Path.Combine(root, "plugins", "demux", "libh26x_plugin.dll"));
}
