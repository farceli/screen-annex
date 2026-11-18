using HosMirror.Windows; // 直接访问同程序集中的真实生产后端。
using System.IO.Compression;

static void Require(bool condition, string message) // 任何失败都让验证进程非零退出。
{
    if (!condition) throw new InvalidOperationException(message); // 不使用仅在 Debug 生效的断言。
}

var devices = AndroidBackend.ParseDevices("List of devices attached\r\n* daemon started successfully\nready\tdevice model:Pixel_9\nlocked\tunauthorized\noff\toffline\nready\tdevice model:duplicate\n").ToArray(); // 包含日志、重复、授权和离线状态。
Require(devices.Length == 3, "设备解析没有正确过滤日志或重复项"); // 同型号和同序列号不能出现错误重复。
Require(devices[0].Model == "Pixel 9" && devices[0].CanConnect, "已授权设备型号或状态错误"); // 真实 ready 才允许启动。
Require(!devices[1].CanConnect && !devices[2].CanConnect, "未授权或离线设备被当作可连接"); // 必须保留手机系统授权。
var policy = new ReconnectPolicy(); // 验证收到启动包不能恢复重连预算。
for (int attempt = 0; attempt < 5; attempt++)
{
    policy.Opened(0);
    Require(policy.NextDelay(40_000) is not null, "应允许最多五次重连");
}
Require(policy.NextDelay(40_000) is null, "未显示画面时不能因连接时长重置预算");
policy.Opened(0);
policy.Displayed();
Require(policy.NextDelay(29_999) is null, "短命画面不能重置预算");
policy.Opened(0);
policy.Displayed();
Require(policy.NextDelay(30_000) == TimeSpan.FromSeconds(1.5), "稳定会话断开后应恢复预算");
Require(DeviceTools.Address(" [::1]:12345 ") == "[::1]:12345", "无线地址应支持括号包围的 IPv6");
Require(DeviceTools.DirectoryPath(" /sdcard//Download/HosMirror/ ") == "/sdcard/Download/HosMirror", "保存目录未规范化");
var sample = await File.ReadAllBytesAsync(Path.Combine(AppContext.BaseDirectory, "sample.h264"));
var units = H264Recording.Split(sample); // 复用 Swift 协议测试的现成 H.264 码流。
Require(units.Select(unit => unit.Span[0] & 31).SequenceEqual(new[] { 7, 8, 5, 1, 1, 1, 1 }), "Annex-B NAL 切分错误");
string recordingPath = Path.Combine(Path.GetTempPath(), $"hosmirror-fixture-{Guid.NewGuid():N}.mp4");
try
{
    var recording = new H264Recording(recordingPath, 128, 256); // 与合成样本的编码尺寸一致。
    long time = Environment.TickCount64 - 200;
    for (int i = 2; i < units.Count; i++)
        recording.Append([units[i]], units[0].ToArray(), units[1].ToArray(), time + i * 33);
    Require(recording.Finish(), "录制应当包含关键帧");
    if (Environment.GetEnvironmentVariable("HOSMIRROR_RECORDING_TEST_OUTPUT") is string verificationOutput)
        File.Copy(recordingPath, verificationOutput, overwrite: true); // 可选地交给系统播放器独立验证。
    byte[] output = await File.ReadAllBytesAsync(recordingPath);
    string[] boxes = ["ftyp", "mdat", "moov", "avcC", "stss"];
    Require(boxes.All(box => output.AsSpan().IndexOf(System.Text.Encoding.ASCII.GetBytes(box)) >= 0), "MP4 缺少必要容器字段");
}
finally { File.Delete(recordingPath); }

// 使用合成的双层 JAR 验证本机自动配置及缓存，不执行任何 SDK 二进制。
string sdkFixture = Path.Combine(Path.GetTempPath(), "screen-annex-sdk-" + Guid.NewGuid());
try
{
    string sdkBin = Directory.CreateDirectory(Path.Combine(sdkFixture, "bin")).FullName;
    string sdkTools = Directory.CreateDirectory(Path.Combine(sdkFixture, "tools")).FullName;
    string sdkHdc = Path.Combine(sdkBin, "hdc.exe");
    File.WriteAllText(sdkHdc, "hdc");
    File.WriteAllText(Path.Combine(sdkBin, "libusb.dll"), "usb");
    using (var outer = ZipFile.Open(Path.Combine(sdkTools, "demoWithoutRecord.jar"), ZipArchiveMode.Create))
    using (var inner = new ZipArchive(outer.CreateEntry("lib/hosScrcpy-verified-shaded.jar").Open(), ZipArchiveMode.Create))
    {
        foreach (string name in new[] { "libscrcpy/libscrcpy_server3.z.so", "uitest_agent_1.1.10.so", "unrelated.so" })
        {
            using var entry = new StreamWriter(inner.CreateEntry(name).Open());
            entry.Write(name);
        }
    }
    string cache = Path.Combine(sdkFixture, "cache");
    string imported = HarmonySdk.ImportResources(sdkFixture, cache);
    Require(File.Exists(Path.Combine(imported, "tools", "libusb.dll")), "自动配置未包含 HDC 的 DLL");
    Require(File.Exists(Path.Combine(imported, "devices", "libscrcpy_server3.z.so")), "自动配置未包含采集库");
    Require(Directory.GetFiles(Path.Combine(imported, "agents")).Length == 1, "自动配置包含无关文件");
    Require(HarmonySdk.ImportResources(sdkFixture, cache) == imported, "应复用相同安装版本的缓存");
    File.WriteAllText(sdkHdc, "updated hdc");
    Require(HarmonySdk.ImportResources(sdkFixture, cache) != imported, "HDC 更新后应准备新的缓存");
}
finally { if (Directory.Exists(sdkFixture)) Directory.Delete(sdkFixture, recursive: true); }

if (Environment.GetEnvironmentVariable("SCREEN_ANNEX_TEST_VLC_PACKAGE") is string package)
{
    string directory = Path.Combine(Path.GetTempPath(), "screen-annex-vlc-" + Guid.NewGuid());
    try { LibVlcRuntime.Extract(package, directory); }
    finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
}
if (OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("SCREEN_ANNEX_TEST_VLC_RUNTIME") == "1")
{
    // 使用发布版的下载入口从空缓存开始，再由 Windows 加载原生 DLL。
    string runtime = await LibVlcRuntime.PrepareAsync(CancellationToken.None);
    Require(await LibVlcRuntime.PrepareAsync(CancellationToken.None) == runtime, "播放器缓存未被复用");
    VlcFixture.Verify(runtime);
    Console.WriteLine("LibVLC 官方下载、缓存及 Windows 原生初始化检查通过。");
}

if (OperatingSystem.IsWindows()) { Console.WriteLine("设备解析、重连、路径与录制检查通过。"); return; } // 不在 Windows 上误执行 POSIX 脚本。
var root = Path.Combine(Path.GetTempPath(), "hosmirror-android-" + Guid.NewGuid()); // 不访问真实 ADB 或手机。
var directory = Path.Combine(root, "scrcpy", "windows-x86_64"); // 与生产安装包路径完全一致。
Directory.CreateDirectory(directory); // 所有可执行文件均为本次测试的独占替身。
try
{
    var adb = Path.Combine(directory, "adb.exe"); // macOS 也可以执行带 .exe 名字的 POSIX 替身。
    var commands = Path.Combine(root, "commands.txt");
    await File.WriteAllTextAsync(adb, $$"""
        #!/bin/sh
        case "$1" in
          devices) printf 'List of devices attached\nfixture\tdevice model:Fixture_Phone\n' ;;
          pair) printf 'Successfully paired to %s\n' "$2" ;;
          connect) printf 'connected to %s\n' "$2" ;;
          -s)
            printf '%s\n' "$@" >> '{{commands}}'
            case "$3" in
              push) cp "$4" '{{root}}/received' ;;
              shell)
                case "$4" in
                  'echo __HOSMIRROR_DEVICE__;'*) printf '__HOSMIRROR_DEVICE__\nfixture-hardware\nFixture Phone\n' ;;
                  'stat -c %s '*) wc -c < '{{root}}/received' ;;
                  'pm install -r -d '*) printf 'Success\n' ;; # 仅接受默认请求覆盖和降级的命令。
                  'cmd package resolve-activity'*) printf 'fixture.files/.Documents\n' ;;
                  'am start'*) printf 'Starting: Intent\n' ;;
                esac ;;
            esac ;;
        esac
        """); // 夹具仅输出可控的工具结果。
    File.SetUnixFileMode(adb, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); // 仅夹具获得可执行权限。
    var scrcpy = Path.Combine(directory, "scrcpy.exe"); // 记录生产启动器实际传入的环境与参数。
    var trace = Path.Combine(root, "arguments.txt"); // 不含任何真实设备信息。
    const string droppedPath = "/tmp/截图 测试.txt";
    string encodedPath = Convert.ToHexString(System.Text.Encoding.UTF8.GetBytes(droppedPath));
    await File.WriteAllTextAsync(scrcpy, $"""
        #!/bin/sh
        printf '%s\n' "$ADB" "$SCRCPY_SERVER_PATH" "$@" > '{trace}'
        printf 'HOSMIRROR_WINDOWS FIRST_FRAME\nHOSMIRROR_WINDOWS DROP bad\nHOSMIRROR_WINDOWS DROP {encodedPath}\nHOSMIRROR_WINDOWS DROP_END\n'
        """); // 首帧及一批拖放从真实子进程管道回到宿主。
    File.SetUnixFileMode(scrcpy, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); // 只允许自有测试脚本运行。
    await File.WriteAllTextAsync(Path.Combine(directory, "scrcpy-server"), "test-only"); // 满足生产预检但不会被推送设备。
    using var backend = new AndroidBackend(root); // 真实后端只看到隔离 Resources。
    var found = await backend.DevicesAsync(); // 执行真实异步管道与等待逻辑。
    Require(found.Count == 1 && found[0].Model == "Fixture Phone", "没有使用内置 ADB 解析设备"); // 验证路径与设备模型联通。
    Require(found[0].HardwareKey == DeviceTools.HardwareKey("Android", "fixture-hardware"), "没有保存稳定的 Android 设备标识");
    await backend.PairAsync("127.0.0.1:41359", "123456");
    await backend.ConnectAsync("127.0.0.1:41659");
    string local = Path.Combine(root, "截图 测试.txt");
    await File.WriteAllTextAsync(local, "fixture payload");
    var delivery = new DeviceFileDelivery("unused-hdc", backend);
    var steps = new List<string>();
    string transferred = await delivery.DeliverAsync(found[0], local, "/sdcard/Download/HosMirror", steps.Add, CancellationToken.None);
    Require(transferred == "已发送到 /sdcard/Download/HosMirror/截图 测试.txt", "Android 普通文件未通过真实交付入口完成");
    var issued = await File.ReadAllTextAsync(commands);
    Require(issued.Contains("mv -n") && issued.Contains("am start") && issued.Contains("primary%3ADownload%2FHosMirror"),
        "文件发布或目录打开未使用正确的路径");
    Require(steps.Any(step => step.Contains("正在发送")) && steps.Any(step => step.Contains("正在打开")), "传输状态遗漏");
    string apk = Path.Combine(root, "previous-version.APK");
    await File.WriteAllTextAsync(apk, "fixture package"); // 包管理器由替身模拟，打开失败不影响安装结果。
    string installed = await delivery.DeliverAsync(found[0], apk, "/sdcard/Download/HosMirror", steps.Add, CancellationToken.None);
    Require(installed.StartsWith("已安装 previous-version.APK", StringComparison.Ordinal), "APK 未按默认参数覆盖和降级安装");
    bool rejected = false; // 未授权启动必须在创建进程之前失败。
    try { backend.Start(devices[1], false); } catch (IOException) { rejected = true; } // 使用真实生产入口。
    Require(rejected && !File.Exists(trace), "未授权设备触发了 scrcpy"); // 不绕过用户授权。
    var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); // 避免依赖固定 sleep。
    string[]? dropped = null;
    bool firstFrame = false, displayedOnExit = false;
    backend.FilesDropped = (_, files) => dropped = files;
    backend.FirstFrame = _ => firstFrame = true;
    backend.Exited = (_, failed, displayed) => displayedOnExit = !failed && displayed;
    backend.Report = message => { if (message.Contains("已关闭")) exited.TrySetResult(); }; // 正常退出必须正确回收窗口记录。
    backend.Start(new DeviceChoice("serial ; --no-control", "Android", "Fixture Phone", "device"), true); // 带空格和选项样式字符仍是一个参数值。
    await exited.Task.WaitAsync(TimeSpan.FromSeconds(5)); // 卡住或漏掉退出处理都会失败。
    Require(firstFrame && displayedOnExit && dropped?.SequenceEqual([droppedPath]) == true, "首帧或拖放事件未被正确交付");
    var arguments = await File.ReadAllLinesAsync(trace); // 读取替身接收到的真实参数。
    Require(arguments[0] == adb && arguments[1] == Path.Combine(directory, "scrcpy-server"), "启动错误使用了外部 ADB 或 server"); // 不依赖用户 PATH。
    Require(arguments.Contains("--serial=serial ; --no-control") && arguments.Contains("--always-on-top"), "参数被 shell 拆分或遗漏置顶"); // 参数传递必须无命令解释。
    Console.WriteLine("Windows 可移植回归通过：设备解析、无线配对与连接、启动参数、首帧、拖放、文件交付、重连预算和 MP4 封装。"); // 不宣称通过了 WinUI 或 Windows 真机验收。
}
finally { Directory.Delete(root, true); } // 失败同样清理全部隔离文件。
