using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace HosMirror.Windows;

internal static class DeviceTools
{
    // 参数逐项传入，工具本地状态和设备端 shell 状态分别校验。
    public static async Task<string> RunAsync(string executable, IEnumerable<string> args,
        CancellationToken cancellation = default, TimeSpan? limit = null)
    {
        cancellation.ThrowIfCancellationRequested();
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        using var process = Process.Start(info) ?? throw new IOException("无法启动设备工具");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(limit ?? TimeSpan.FromSeconds(15));
        string output;
        try
        {
            await process.WaitForExitAsync(timeout.Token);
            output = (await stdout.WaitAsync(timeout.Token)) + (await stderr.WaitAsync(timeout.Token));
        }
        catch (OperationCanceledException)
        {
            // 取消仅回收本次工具进程，不停止共享的 ADB/HDC 服务。
            try { process.Kill(); } catch (InvalidOperationException) { }
            await process.WaitForExitAsync();
            // 守护进程可能继承输出句柄，超时路径关闭自己的读端。
            process.StandardOutput.Dispose();
            process.StandardError.Dispose();
            try { await Task.WhenAll(stdout, stderr).WaitAsync(TimeSpan.FromSeconds(1)); }
            catch (IOException) { } catch (ObjectDisposedException) { } catch (TimeoutException) { }
            cancellation.ThrowIfCancellationRequested();
            throw new TimeoutException("设备工具超时");
        }
        if (process.ExitCode != 0 || output.StartsWith("[Fail]", StringComparison.OrdinalIgnoreCase)) throw new IOException(string.IsNullOrWhiteSpace(output) ? $"设备工具退出码 {process.ExitCode}" : output.Trim());
        return output.Trim();
    }

    public static string Quote(string text) => "'" + text.Replace("'", "'\"'\"'") + "'";

    public static async Task<string> HarmonyShellAsync(string hdc, string serial, string command,
        CancellationToken cancellation = default, TimeSpan? limit = null)
    {
        // 随机标记避免命令输出里的文本碰巧被当作退出码。
        string marker = $"__HOSMIRROR_{Guid.NewGuid():N}__";
        string output = await RunAsync(hdc, ["-t", serial, "shell", $"( {command} ); printf '\\n{marker}%s\\n' \"$?\""], cancellation, limit);
        int index = output.LastIndexOf(marker, StringComparison.Ordinal);
        if (index < 0) throw new IOException("未收到手机命令完成确认：" + output);
        string message = output[..index].Trim();
        string[] tail = output[(index + marker.Length)..].Split('\n', 2);
        if (tail.Length == 2) message = $"{message}\n{tail[1]}".Trim();
        if (tail[0].Trim() != "0" || message.StartsWith("[Fail]", StringComparison.OrdinalIgnoreCase))
            throw new IOException(string.IsNullOrEmpty(message) ? "手机拒绝执行操作" : message);
        return message;
    }

    public static string Address(string value)
    {
        string address = value.Trim();
        if (!Regex.IsMatch(address, @"\A(?:[a-zA-Z0-9.-]+|\[[0-9a-fA-F:]+\]):[0-9]{1,5}\z")
            || !int.TryParse(address[(address.LastIndexOf(':') + 1)..], out int port) || port is < 1 or > 65535)
            throw new IOException("请输入手机无线调试页面显示的地址和端口");
        return address;
    }

    public static string? HardwareKey(string platform, string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        return platform + ":" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(raw.Trim().ToLowerInvariant())));
    }

    public static string DirectoryPath(string path)
    {
        string[] pieces = path.Trim().Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (!path.Trim().StartsWith('/') || pieces.Length == 0 || pieces.Contains("..") || pieces.Contains(".") || path.Any(char.IsControl))
            throw new IOException("手机保存目录须为绝对路径，且不能包含 .、.. 或控制字符");
        return "/" + string.Join("/", pieces);
    }
}
