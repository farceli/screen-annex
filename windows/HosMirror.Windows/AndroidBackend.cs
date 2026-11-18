using System.Diagnostics; // Android 通过自有 scrcpy 进程投屏，保留上游窗口。
using System.Text; // 为诊断输出提供有界尾部缓冲。

namespace HosMirror.Windows; // 与 WinUI 主程序共享命名空间。

internal sealed record DeviceChoice(string Serial, string Platform, string Model, string State, string? HardwareKey = null) // 后端随设备保存，不根据序列号猜测系统。
{
    public string Key => HardwareKey ?? Platform + ":" + Serial; // 只有读到同一硬件身份时才合并 USB 与无线。
    public bool IsAndroid => Platform == "Android"; // 防止 Android 设备进入鸿蒙 Rust 内核。
    public bool CanConnect => !IsAndroid || State == "device"; // 系统授权完成前不能启动 Android 投屏。
    public override string ToString() => $"{Platform} · {Model} · {Serial}" + (CanConnect ? "" : $" ({State})"); // 同型号设备仍显示独立序列号。
}

internal sealed class AndroidBackend : IDisposable // 主窗口关闭时回收其拥有的 Android 进程。
{
    private readonly string _directory; // 固定为随 App 交付的 Windows x64 目录。
    private readonly Dictionary<string, Process> _processes = new();
    private readonly HashSet<string> _stopping = new(); // 只保存本应用启动的进程。
    public Action<string>? Report { get; set; } // 调用者负责把通知派发回 WinUI 主线程。
    public AndroidBackend(string resources) => _directory = Path.Combine(resources, "scrcpy", "windows-x86_64"); // scrcpy 客户端来自 App 运行目录。

    private string AdbPath()
    {
        string? configured = Environment.GetEnvironmentVariable("HOSMIRROR_ADB");
        if (!string.IsNullOrWhiteSpace(configured)) return configured; // 尊重用户明确指定的官方工具路径。
        string bundled = Path.Combine(_directory, "adb.exe");
        if (File.Exists(bundled)) return bundled; // 图形界面启动不依赖用户 PATH 或外部 SDK。
        string sdk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Android", "Sdk", "platform-tools", "adb.exe");
        if (File.Exists(sdk)) return sdk; // 支持 Android Studio 的默认安装位置。
        foreach (string directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(directory.Trim('"'), "adb.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return sdk; // 由实际使用入口提示配置方式。
    }

    private string RequireAdb()
    {
        string path = AdbPath();
        if (!File.Exists(path)) throw new IOException("找不到 ADB。请重新安装完整版本，或检查 HOSMIRROR_ADB 指定的路径。");
        return Path.GetFullPath(path); // 子进程工作目录与宿主不同，必须传递绝对路径。
    }

    internal static IEnumerable<DeviceChoice> ParseDevices(string output) // 纯解析方法也供无设备主机测试复用。
    {
        var seen = new HashSet<string>(); // 重复行不能创建重复选择项。
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries)) // 同时接受 Windows CRLF。
        {
            var fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries); // ADB 使用空格和制表符分隔。
            if (fields.Length < 2 || fields[0] is "List" or "*" || !new[] { "device", "unauthorized", "offline", "recovery", "sideload", "bootloader", "no" }.Contains(fields[1]) || !seen.Add(fields[0])) continue; // 排除表头、启动日志和重复项。
            var model = fields.FirstOrDefault(value => value.StartsWith("model:", StringComparison.Ordinal))?[6..].Replace('_', ' ') ?? fields[0]; // 未授权时可能没有型号信息。
            yield return new DeviceChoice(fields[0], "Android", model, fields[1]); // 保留真实授权和在线状态。
        }
    }

    public async Task<IReadOnlyList<DeviceChoice>> DevicesAsync()
    {
        var text = await RunAdbAsync(["devices", "-l"]);
        return await Task.WhenAll(ParseDevices(text).Select(DescribeAsync)); // 设备探测失败时保留原始 ADB 列表。
    }

    private async Task<DeviceChoice> DescribeAsync(DeviceChoice device)
    {
        if (!device.CanConnect) return device;
        const string probe = "echo __HOSMIRROR_DEVICE__; for p in ro.serialno ro.product.marketname ro.vendor.oplus.market.name ro.oplus.market.name ro.product.model; do getprop \"$p\"; done";
        try
        {
            string output = await RunAdbAsync(["-s", device.Serial, "shell", probe], limit: TimeSpan.FromSeconds(3));
            var lines = output.Split('\n').Select(line => line.Trim()).SkipWhile(line => line != "__HOSMIRROR_DEVICE__").Skip(1).ToArray();
            string? serial = lines.ElementAtOrDefault(0);
            string name = lines.Skip(1).FirstOrDefault(line => line.Length > 0) ?? device.Model;
            string? key = serial is null or "" or "unknown" or "0123456789ABCDEF" ? null : DeviceTools.HardwareKey(device.Platform, serial);
            return device with { Model = name, HardwareKey = key };
        }
        catch (Exception) { return device; } // 未上报硬件标识的设备继续以 ADB 连接标识匹配。
    }

    public Task<string> RunAdbAsync(IEnumerable<string> arguments, CancellationToken token = default, TimeSpan? limit = null) =>
        DeviceTools.RunAsync(RequireAdb(), arguments, token, limit ?? TimeSpan.FromSeconds(20));

    public async Task ConnectAsync(string address)
    {
        string target = DeviceTools.Address(address);
        string result = await RunAdbAsync(["connect", target]);
        if (!result.StartsWith("connected to ", StringComparison.OrdinalIgnoreCase) &&
            !result.StartsWith("already connected to ", StringComparison.OrdinalIgnoreCase)) throw new IOException(result);
    }

    public async Task PairAsync(string address, string code)
    {
        string target = DeviceTools.Address(address);
        if (code.Length != 6 || !code.All(char.IsAsciiDigit)) throw new IOException("请输入六位配对码");
        string result;
        try { result = await RunAdbAsync(["pair", target, code]); }
        catch (Exception error) { throw new IOException(error.Message.Replace(code, "[配对码已隐藏]")); }
        if (!result.StartsWith("Successfully paired", StringComparison.OrdinalIgnoreCase))
            throw new IOException(result.Replace(code, "[配对码已隐藏]"));
    }

    public IntPtr HostWindow { private get; set; }
    public Action<DeviceChoice, bool, bool>? Exited { get; set; }
    public Action<DeviceChoice>? FirstFrame { get; set; }
    public Action<DeviceChoice, string[]>? FilesDropped { get; set; }
    public bool IsRunning(DeviceChoice device) => _processes.ContainsKey(device.Key);
    public bool IsStopping(DeviceChoice device) => _stopping.Contains(device.Key);

    public void Start(DeviceChoice device, bool onTop, string pushTarget = "/sdcard/Download/HosMirror") // 参数与对象均来自当前主窗口。
    {
        if (!device.CanConnect) throw new IOException(device.State == "unauthorized" ? "请在 Android 手机上允许 USB 调试，再刷新设备。" : "Android 设备未就绪，请重新连接。"); // 不绕过系统确认。
        if (_processes.ContainsKey(device.Key)) { Report?.Invoke("该 Android 投屏窗口已经启动"); return; } // 连点不重复创建窗口。
        foreach (var file in new[] { "scrcpy.exe", "scrcpy-server" }) // scrcpy 客户端和 server 由安装包提供。
            if (!File.Exists(Path.Combine(_directory, file))) throw new IOException($"安装包缺少 Android 组件：{file}");
        var info = new ProcessStartInfo(Path.Combine(_directory, "scrcpy.exe")) { WorkingDirectory = _directory, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }; // SDL 自行创建投屏窗口。
        foreach (var argument in new[] { $"--serial={device.Serial}", $"--window-title=「Android」{device.Model}", $"--push-target={pushTarget.TrimEnd('/')}/" }) info.ArgumentList.Add(argument); // 参数独立传入，保留上游键鼠、音频、剪贴板与拖放。
        if (onTop) info.ArgumentList.Add("--always-on-top"); // 使用连接时的置顶偏好。
        info.Environment["HOSMIRROR_WINDOWS_EVENTS"] = "1"; // 仅本应用托管的窗口把拖放交给统一文件传输。
        if (HostWindow != IntPtr.Zero) info.Environment["HOSMIRROR_WINDOWS_HOST"] = HostWindow.ToString("x");
        info.Environment["ADB"] = RequireAdb(); // scrcpy 与设备列表使用同一个 ADB。
        info.Environment["SCRCPY_SERVER_PATH"] = Path.Combine(_directory, "scrcpy-server"); // 保证 client/server 版本一致。
        info.Environment["SCRCPY_ICON_PATH"] = Path.Combine(_directory, "scrcpy.png"); // 保留上游图标与来源。
        var tail = new StringBuilder();
        var dropped = new List<string>();
        int displayed = 0;
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stdoutEnded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stderrEnded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var context = SynchronizationContext.Current; // scrcpy 输出事件在后台线程，窗口和队列在 UI 线程。
        void Dispatch(Action action)
        {
            if (context is null) action();
            else context.Post(_ => action(), null);
        } // 每个进程独享诊断尾部。
        var process = new Process { StartInfo = info, EnableRaisingEvents = true }; // 生命周期由后台等待完整收尾。
        void Capture(object _, DataReceivedEventArgs e) // 两条输出事件都只保存有限文本。
        {
            if (e.Data is null) return; // EOF 不追加空行。
            lock (tail) { tail.AppendLine(e.Data); if (tail.Length > 8192) tail.Remove(0, tail.Length - 8192); } // 最多保存 8 KiB 字符，不记录屏幕或剪贴板内容。
        }
        process.OutputDataReceived += (_, args) =>
        {
            const string prefix = "HOSMIRROR_WINDOWS ";
            if (args.Data is not string line) { stdoutEnded.TrySetResult(); return; }
            if (!line.StartsWith(prefix, StringComparison.Ordinal))
            {
                Capture(process, args);
                return;
            }
            var message = line[prefix.Length..];
            if (message == "FIRST_FRAME")
            {
                Interlocked.Exchange(ref displayed, 1);
                ready.TrySetResult();
                Dispatch(() => { if (IsCurrent()) FirstFrame?.Invoke(device); });
            }
            else if (message == "DROP_END")
            {
                string[] files = dropped.ToArray();
                dropped.Clear();
                if (files.Length > 0) Dispatch(() => { if (IsCurrent()) FilesDropped?.Invoke(device, files); });
            }
            else if (message.StartsWith("DROP ", StringComparison.Ordinal) && dropped.Count < 1024)
            {
                try { dropped.Add(Encoding.UTF8.GetString(Convert.FromHexString(message[5..]))); }
                catch (FormatException) { } // 畸形事件不能进入文件传输队列。
            }
        };
        bool IsCurrent() => _processes.TryGetValue(device.Key, out var current) && ReferenceEquals(current, process);
        process.ErrorDataReceived += (_, args) =>
        {
            if (args.Data is null) stderrEnded.TrySetResult();
            else Capture(process, args);
        };
        try { process.Start(); } // 唯一创建窗口进程的地方。
        catch { process.Dispose(); throw; } // 启动失败不遗留句柄。
        _processes.Add(device.Key, process); // 主线程接管自有进程。
        process.BeginOutputReadLine(); // 异步读取不会阻塞用户操作。
        process.BeginErrorReadLine(); // 防止 stderr 写满导致投屏卡死。
        var exit = ObserveExitAsync(device, process, tail, () => Volatile.Read(ref displayed) != 0,
            Task.WhenAll(stdoutEnded.Task, stderrEnded.Task));
        _ = WatchFirstFrameAsync(device, process, ready.Task, exit); // 处理用户关闭上游窗口和异常退出。
        Report?.Invoke("Android 投屏窗口已启动；键鼠操作请在该窗口中使用。"); // 不将进程启动宣称为真机首帧成功。
    }

    private async Task ObserveExitAsync(DeviceChoice device, Process process, StringBuilder tail, Func<bool> displayed, Task outputEnded) // 此方法从 WinUI 线程调用，await 后恢复原同步上下文。
    {
        try
        {
            await process.WaitForExitAsync();
            // 极短命的子进程可能先退出，仍需等已写入的首帧和拖放消息读完。
            try { await outputEnded.WaitAsync(TimeSpan.FromSeconds(2)); }
            catch (TimeoutException) { }
            string message;
            lock (tail) message = tail.ToString();
            if (_processes.TryGetValue(device.Key, out var current) && ReferenceEquals(current, process))
            {
                _processes.Remove(device.Key);
                bool stopped = _stopping.Remove(device.Key);
                bool failed = !stopped && process.ExitCode != 0;
                Exited?.Invoke(device, failed, displayed());
                Report?.Invoke(failed ? $"Android 投屏已结束：{message}" : "Android 投屏已关闭");
            }
        }
        finally { process.Dispose(); }
    }

    private async Task WatchFirstFrameAsync(DeviceChoice device, Process process, Task ready, Task exit)
    {
        using var timer = new CancellationTokenSource();
        var timeout = Task.Delay(TimeSpan.FromSeconds(20), timer.Token);
        var completed = await Task.WhenAny(ready, exit, timeout);
        if (completed != timeout) { timer.Cancel(); return; }
        if (!ready.IsCompleted && _processes.TryGetValue(device.Key, out var current) &&
            ReferenceEquals(current, process) && !_stopping.Contains(device.Key))
        {
            Report?.Invoke("Android 未收到可显示的画面");
            try { process.Kill(); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception error) { Report?.Invoke(error.Message); }
        }
    }

    public IntPtr Handle(DeviceChoice device)
    {
        if (!_processes.TryGetValue(device.Key, out var process) || process.HasExited) return IntPtr.Zero;
        process.Refresh(); // SDL 需要一段时间才会创建原生窗口。
        return process.MainWindowHandle;
    }

    public async Task StopAsync(string key)
    {
        if (!_processes.TryGetValue(key, out var process) || !_stopping.Add(key)) return;
        try
        {
            // 先请求原生窗口正常关闭，允许 scrcpy 清理设备端会话与写完文件。
            if (!process.HasExited && process.CloseMainWindow())
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                try { await process.WaitForExitAsync(timeout.Token); }
                catch (OperationCanceledException) { }
            }
            if (_processes.TryGetValue(key, out var current) && ReferenceEquals(current, process) && !process.HasExited)
                process.Kill(); // 只结束本应用拥有的客户端，ADB 服务可能还被其他工具共享。
        }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception error)
        {
            _stopping.Remove(key);
            Report?.Invoke($"无法停止 Android 投屏：{error.Message}");
        }
    }

    public Task StopAllAsync() => Task.WhenAll(_processes.Keys.ToArray().Select(StopAsync));

    public void Dispose() // 主窗口关闭时终止所有自有 Android 窗口。
    {
        Exited = null;
        FirstFrame = null;
        FilesDropped = null;
        Report = null; // 关闭后不再向销毁的 WinUI 控件投递消息。
        foreach (var process in _processes.Values.ToArray())
        {
            try { if (!process.HasExited) process.Kill(); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }
    }
}
