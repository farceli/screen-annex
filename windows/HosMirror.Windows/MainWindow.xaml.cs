using System.Diagnostics;
using System.Text.RegularExpressions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.ApplicationModel.DataTransfer;

namespace HosMirror.Windows;

public sealed partial class MainWindow : Window
{
    private readonly string _resources = Path.Combine(AppContext.BaseDirectory, "Resources");
    // Android 发行版只加载 Android 后端，鸿蒙仍可在开发构建中使用。
#if ANDROID_RELEASE
    private const string _hdc = "";
#else
    private string _harmonyResources;
    private readonly bool _explicitHarmonyResources;
    private string _hdc => Path.Combine(_harmonyResources, "tools", "hdc.exe");
    private readonly Dictionary<string, MirrorWindow> _mirrors = new();
#endif
    private readonly AndroidBackend _android;
    private readonly MirrorPreferences _preferences = MirrorPreferences.Load();
    private readonly HashSet<string> _closingMirrors = new();
    private readonly Dictionary<string, CancellationTokenSource> _androidRetries = new();
    private readonly Dictionary<string, ReconnectPolicy> _androidPolicies = new();
    private readonly HashSet<string> _androidReady = new();
    private readonly WindowGroup _windowGroup = new();
    private readonly DispatcherTimer _groupTimer = new() { Interval = TimeSpan.FromMilliseconds(80) };
    private readonly DispatcherTimer _refreshTimer = new() { Interval = TimeSpan.FromSeconds(3) };
    private readonly List<string> _transfers = new();
    private readonly Dictionary<string, (CancellationTokenSource Cancellation, Queue<string> Files)> _androidTransfers = new();
    private readonly HashSet<Task> _transferTasks = new();
    private readonly Dictionary<string, TransferNotice> _androidNotices = new();
    private readonly HashSet<string> _expanded = new();
    private IReadOnlyList<DeviceChoice> _online = [];
    private readonly WindowNative _native;
    private readonly TrayIcon _tray;
    private bool _refreshing;
    private bool _closing;
    private bool _closed;
    private bool _historyExpanded;
    private bool _dialogOpen;
    private bool? _hostLocked;
    private CancellationTokenSource? _hostAction;

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new(690, 480));
#if !ANDROID_RELEASE
        string? configuredHarmony = Environment.GetEnvironmentVariable("HOSMIRROR_HARMONY_RESOURCES");
        // SDK 单独安装，旧版本地构建仍可使用原有的 Resources 布局。
        _explicitHarmonyResources = !string.IsNullOrWhiteSpace(configuredHarmony);
        _harmonyResources = _explicitHarmonyResources ? configuredHarmony! :
            File.Exists(Path.Combine(_resources, "tools", "hdc.exe")) ? _resources :
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Screen Annex", "HarmonyOS");
#endif
        _android = new AndroidBackend(_resources)
        {
            Report = Report, Exited = AndroidExited,
            FirstFrame = device => { _androidReady.Add(device.Key); RebuildDevices(); },
            FilesDropped = (device, paths) => _ = QueueAndroidFilesAsync(device, paths),
        };
        _native = new WindowNative(this, OnHostLockChanged);
        _tray = new TrayIcon(_native.Handle, ShowDevices, ("设备", ShowDevices), ("连接全部", ConnectAll),
            ("设置…", () => { ShowDevices(); OpenSettings(); }), ("退出 Screen Annex", Exit));
        _android.HostWindow = _native.Handle;
        _native.OnMessage = (message, source, detail) =>
        {
            _tray.ProcessMessage(message, (nuint)detail);
            if (message != 0x8002 || !_preferences.SnapWindows || _closing) return false;
            // SDL 等待处理结果。先返回是否接管，再由 UI 消息循环调整外部窗口。
            var anchor = (IntPtr)source;
            var windows = MirrorHandles().Where(handle => handle != IntPtr.Zero && !WindowNative.IsIconic(handle)).ToArray();
            return windows.Length >= 2 && windows.Contains(anchor) &&
                DispatcherQueue.TryEnqueue(() => FitMirrorGroup(anchor));
        };
        _refreshTimer.Tick += async (_, _) => await RefreshDevices();
        _refreshTimer.Start();
        _groupTimer.Tick += (_, _) => _windowGroup.Update(MirrorHandles());
        if (_preferences.SnapWindows) _groupTimer.Start();
        AppWindow.Closing += (window, args) =>
        {
            if (_closed) return;
            args.Cancel = true; // 保持消息循环，直到每个会话完成原生清理。
            if (_closing) return;
            if (_tray.IsAvailable) AppWindow.Hide();
            else Exit();
        };
        _ = RefreshDevices();
    }

    private void ShowDevices()
    {
        if (_closing) return;
        AppWindow.Show();
        Activate();
        WindowNative.Show(_native.Handle);
    }

    private void Exit()
    {
        if (!_closing) _ = CloseAsync();
    }

    private void OnExit(object sender, RoutedEventArgs e) => Exit();

    private async Task CloseAsync()
    {
        _closing = true;
        _tray.Dispose();
        _hostAction?.Cancel();
        _refreshTimer.Stop();
        _groupTimer.Stop();
        foreach (var retry in _androidRetries.Values) retry.Cancel();
        foreach (var transfer in _androidTransfers.Values) transfer.Cancellation.Cancel();
        foreach (var notice in _androidNotices.Values.ToArray()) notice.Close();
        _androidNotices.Clear();
        try
        {
            var tasks = _transferTasks.ToArray().Append(_android.StopAllAsync());
#if !ANDROID_RELEASE
            tasks = tasks.Concat(_mirrors.Values.ToArray().Select(window => window.CloseAsync()));
#endif
            await Task.WhenAll(tasks);
        }
        finally
        {
            _android.Dispose();
            _native.Dispose();
            _closed = true;
            Close();
        }
    }

    private void Report(string message)
    {
        if (!_closing) StatusText.Text = message;
    }

    private void SavePreferences()
    {
        try { _preferences.Save(); }
        catch (Exception error) { Report($"无法保存设置：{error.Message}"); }
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) => await RefreshDevices();

    private async Task RefreshDevices()
    {
        if (_closing || _refreshing) return;
        _refreshing = true;
        var errors = new List<string>();
        async Task<IReadOnlyList<DeviceChoice>> Read(string platform, Func<Task<IReadOnlyList<DeviceChoice>>> query)
        {
            try { return await query(); }
            catch (Exception error) { errors.Add($"{platform}：{error.Message}"); return []; }
        }
        try
        {
            var android = Read("Android", _android.DevicesAsync);
#if ANDROID_RELEASE
            var groups = new[] { await android };
#else
            var groups = await Task.WhenAll(Read("HarmonyOS", HarmonyDevicesAsync), android);
#endif
            if (_closing) return;
            // 同一设备的 USB 入口优先；两个系统即使序列号相同也保留独立入口。
            var devices = groups.SelectMany(group => group).Select(device =>
            {
                if (device.HardwareKey is not null) return device;
                var known = _preferences.History.Values.FirstOrDefault(item =>
                    item.Platform == device.Platform && item.Serial == device.Serial && item.HardwareKey is not null);
                return known is null ? device : device with { HardwareKey = known.HardwareKey, Model = known.Model };
            }).GroupBy(device => device.Key)
                .Select(group => group.OrderByDescending(device => device.CanConnect)
                    .ThenBy(device => device.Serial.Contains(':')).First()).ToArray();
            bool changed = !_online.SequenceEqual(devices);
            _online = devices;

            bool historyChanged = false;
            foreach (var device in devices.Where(item => item.CanConnect))
            {
                string previousKey = device.Platform + ":" + device.Serial;
                if (device.HardwareKey is not null && _preferences.History.Remove(previousKey))
                {
                    if (_preferences.Aliases.Remove(previousKey, out var alias)) _preferences.Aliases.TryAdd(device.Key, alias);
                    if (_preferences.Pins.Remove(previousKey, out var pin)) _preferences.Pins.TryAdd(device.Key, pin);
                    historyChanged = true;
                }
                if (_preferences.History.GetValueOrDefault(device.Key) == device) continue;
                _preferences.History[device.Key] = device;
                historyChanged = true;
            }
            if (historyChanged) SavePreferences();
            if (changed || historyChanged || DevicesPanel.Children.Count == 0) RebuildDevices();
            if (errors.Count > 0) Report(string.Join("；", errors));
        }
        finally { _refreshing = false; }
    }

#if !ANDROID_RELEASE
    private async Task<bool> PrepareHarmonyAsync()
    {
        if (File.Exists(_hdc)) return true;
        if (_explicitHarmonyResources) return false; // 环境变量指定的开发或测试路径仍优先。
        string configuredRoot = _harmonyResources;
        string? prepared = await Task.Run(() => HarmonySdk.Prepare(configuredRoot));
        if (prepared is null) return false;
        _harmonyResources = prepared;
        return File.Exists(_hdc);
    }

    private async Task<IReadOnlyList<DeviceChoice>> HarmonyDevicesAsync()
    {
        // 正常刷新会在 DevEco Testing 安装完成后自动识别，不占用界面线程。
        if (!await PrepareHarmonyAsync()) return [];
        string hdc = _hdc;
        string output = await DeviceTools.RunAsync(hdc, ["list", "targets"]);
        var serials = output.Split('\n').Select(line => line.Trim()).Where(line =>
            line.Length > 0 && !line.Equals("Empty", StringComparison.OrdinalIgnoreCase) &&
            !line.StartsWith('[') && !line.Any(char.IsWhiteSpace)).Distinct();
        return await Task.WhenAll(serials.Select(async serial =>
        {
            var device = new DeviceChoice(serial, "HarmonyOS", serial, "device");
            const string probe = "echo __NAME__; param get const.product.marketname; echo __PRODUCT__; param get const.product.name; echo __MODEL__; param get const.product.model; echo __UDID__; bm get --udid";
            try
            {
                string value = await DeviceTools.RunAsync(hdc, ["-t", serial, "shell", probe], limit: TimeSpan.FromSeconds(4));
                string? Field(string name)
                {
                    string text = Regex.Match(value, $"(?m)^__{name}__\\r?\\n([^\\r\\n]+)").Groups[1].Value.Trim();
                    return text.Length > 0 && !text.StartsWith("__") && !Regex.IsMatch(text, "(?i)^(error|get parameter|param:|unknown|null)|errnum") ? text : null;
                }
                string udid = Regex.Match(value, @"\b[0-9A-Fa-f]{64}\b").Value;
                return device with { Model = Field("NAME") ?? Field("PRODUCT") ?? Field("MODEL") ?? serial,
                    HardwareKey = DeviceTools.HardwareKey(device.Platform, udid) };
            }
            catch (Exception) { return device; } // 旧设备仍可通过调试标识打开投屏。
        }));
    }
#endif

    private void RebuildDevices()
    {
        if (_closing) return;
        DevicesPanel.Children.Clear();
        var visible = _online.Concat(_preferences.History.Values.Where(item =>
            _online.All(device => device.Key != item.Key) && IsMirroring(item))).ToArray();
        if (visible.Length == 0) DevicesPanel.Children.Add(new TextBlock { Text = "未检测到设备。连接手机并允许调试，或使用无线调试。" });
        foreach (var group in visible.GroupBy(device => device.Platform))
        {
            DevicesPanel.Children.Add(new TextBlock { Text = group.Key, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            foreach (var device in group) AddDevice(device);
        }
        var offline = _preferences.History.Values.Where(item =>
#if ANDROID_RELEASE
            item.IsAndroid &&
#endif
            visible.All(device => device.Key != item.Key)).ToArray();
        if (offline.Length > 0)
        {
            var history = new StackPanel { Spacing = 6 };
            foreach (var device in offline)
                history.Children.Add(new TextBlock { Text = $"「{device.Platform}」{_preferences.Name(device)} · 离线" });
            var expander = new Expander { Header = "离线设备", Content = history, IsExpanded = _historyExpanded };
            expander.Expanding += (_, _) => _historyExpanded = true;
            expander.Collapsed += (_, _) => _historyExpanded = false;
            DevicesPanel.Children.Add(expander);
        }
    }

    private bool IsMirroring(DeviceChoice device) =>
        device.IsAndroid ? _android.IsRunning(device) || _androidRetries.ContainsKey(device.Key)
#if ANDROID_RELEASE
            : false;
#else
            : _mirrors.ContainsKey(device.Key);
#endif

    private void AddDevice(DeviceChoice device)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        bool active = IsMirroring(device);
        bool online = _online.Any(candidate => candidate.Key == device.Key && candidate.CanConnect);
        bool starting = _androidRetries.ContainsKey(device.Key) || device.IsAndroid && !_androidReady.Contains(device.Key);
        bool pinned = _preferences.Pinned(device);
        string? harmonyStatus = null;
#if !ANDROID_RELEASE
        if (_mirrors.TryGetValue(device.Key, out var mirror))
        {
            starting = mirror.IsConnecting;
            pinned = mirror.IsPinned;
            harmonyStatus = mirror.ConnectionLabel;
        }
#endif
        var connect = new Button { Content = active ? (starting ? "取消" : "断开") : "投屏", IsEnabled = active || online };
        connect.Click += async (_, _) =>
        {
            if (IsMirroring(device)) await StopMirrorAsync(device);
            else StartMirror(device);
        };
        row.Children.Add(connect);
        if (active)
        {
            var show = new Button { Content = "显示窗口" };
            show.Click += (_, _) =>
            {
                if (device.IsAndroid) WindowNative.Show(_android.Handle(device));
#if !ANDROID_RELEASE
                else if (_mirrors.TryGetValue(device.Key, out var current)) current.Show();
#endif
            };
            row.Children.Add(show);
        }
        var rename = new Button { Content = "重命名" };
        rename.Click += async (_, _) => await RenameAsync(device);
        row.Children.Add(rename);
        var pin = new ToggleButton { Content = "置顶", IsChecked = pinned };
        pin.Click += (_, _) =>
        {
            bool enabled = pin.IsChecked == true;
            _preferences.Pins[device.Key] = enabled;
#if !ANDROID_RELEASE
            if (_mirrors.TryGetValue(device.Key, out var current)) current.SetPinned(enabled);
#endif
            if (device.IsAndroid) WindowNative.SetPinned(_android.Handle(device), enabled);
            SavePreferences();
        };
        row.Children.Add(pin);
        if (device.IsAndroid)
        {
            var transfer = new Button { Content = "传输文件…", IsEnabled = online };
            transfer.Click += async (_, _) =>
            {
                try { await QueueAndroidFilesAsync(device, await PickFilesAsync(_native.Handle)); }
                catch (Exception error) { Report(error.Message); }
            };
            row.Children.Add(transfer);
            var cancelTransfer = new Button { Content = "取消传输" };
            cancelTransfer.Click += (_, _) => { if (_androidTransfers.TryGetValue(device.Key, out var token)) token.Cancellation.Cancel(); };
            row.Children.Add(cancelTransfer);
        }
        foreach (var action in Enum.GetValues<PhoneAction>())
        {
            var button = new Button { Content = ActionLabel(action), IsEnabled = online };
            button.Click += async (_, _) => await ApplyPhoneActionAsync([device], action, false);
            row.Children.Add(button);
        }
        var card = new Expander
        {
            Header = _preferences.Name(device) + " · " + (
                _android.IsStopping(device) || _closingMirrors.Contains(device.Key) ? "正在断开" :
                harmonyStatus ?? (
                _androidRetries.ContainsKey(device.Key) ? "正在重连" :
                active ? (_androidReady.Contains(device.Key) ? "正在投屏" : "正在连接") :
                device.CanConnect ? "在线" : device.State == "unauthorized" ? "待授权" : "离线")),
            Content = new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, Content = row },
            HorizontalAlignment = HorizontalAlignment.Stretch,
            IsExpanded = _expanded.Contains(device.Key),
        };
        if (device.IsAndroid && online)
        {
            card.AllowDrop = true;
            card.DragOver += (_, e) =>
            {
                if (e.DataView.Contains(StandardDataFormats.StorageItems))
                    e.AcceptedOperation = DataPackageOperation.Copy;
                e.Handled = true;
            };
            card.Drop += async (_, e) =>
            {
                var deferral = e.GetDeferral();
                try
                {
                    if (e.DataView.Contains(StandardDataFormats.StorageItems))
                    {
                        var items = await e.DataView.GetStorageItemsAsync();
                        _ = QueueAndroidFilesAsync(device, items.Select(item => item.Path).Where(path => !string.IsNullOrWhiteSpace(path)).ToArray());
                    }
                }
                catch (Exception error) { Report(error.Message); }
                finally { e.Handled = true; deferral.Complete(); }
            };
        }
        card.Expanding += (_, _) => _expanded.Add(device.Key);
        card.Collapsed += (_, _) => _expanded.Remove(device.Key);
        DevicesPanel.Children.Add(card);
    }

    internal static async Task<string[]> PickFilesAsync(IntPtr hwnd)
    {
        // 使用调用窗口作为系统文件选择器的所有者，两种设备后端可共用。
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        var items = await picker.PickMultipleFilesAsync();
        return items?.Select(item => item.Path).ToArray() ?? [];
    }

    private void StartMirror(DeviceChoice device)
    {
        if (_closing || IsMirroring(device) || _closingMirrors.Contains(device.Key)) return;
        try
        {
            if (device.IsAndroid)
            {
                var policy = new ReconnectPolicy();
                policy.Opened(Environment.TickCount64);
                _androidPolicies[device.Key] = policy;
                StartAndroid(device);
            }
#if !ANDROID_RELEASE
            else
            {
                var mirror = new MirrorWindow(device, _harmonyResources, _hdc, _preferences, SavePreferences, RecordTransfer,
                    () => { ShowDevices(); OpenTransferHistory(); },
                    () => _preferences.SnapWindows && FitMirrorGroup(WindowNative.GetForegroundWindow()),
                    () => _online.FirstOrDefault(candidate => candidate.Key == device.Key && candidate.CanConnect));
                mirror.ConnectionChanged += RebuildDevices;
                _mirrors.Add(device.Key, mirror);
                mirror.Closed += (_, _) => { _mirrors.Remove(device.Key); _closingMirrors.Remove(device.Key); RebuildDevices(); };
                mirror.Activate();
            }
#endif
        }
        catch (Exception error) { _androidPolicies.Remove(device.Key); Report(error.Message); }
        RebuildDevices();
    }

    private void StartAndroid(DeviceChoice device)
    {
        _android.Start(device with { Model = _preferences.Name(device) }, _preferences.Pinned(device), _preferences.AndroidDestination);
    }

    private async void AndroidExited(DeviceChoice device, bool failed, bool displayed)
    {
        _androidReady.Remove(device.Key);
        if (_androidNotices.Remove(device.Key, out var notice)) notice.Close();
        if (_closing) return;
        if (_androidTransfers.TryGetValue(device.Key, out var transfer)) transfer.Cancellation.Cancel();
        if (!failed || !_preferences.AutoReconnect || !_androidPolicies.TryGetValue(device.Key, out var entry))
        {
            _androidPolicies.Remove(device.Key);
            RebuildDevices();
            return;
        }

        if (displayed) entry.Displayed();
        var cancellation = new CancellationTokenSource();
        _androidRetries.Add(device.Key, cancellation);
        RebuildDevices();
        try
        {
            string? error = null;
            while (entry.NextDelay(Environment.TickCount64) is TimeSpan delay)
            {
                Report("Android 投屏断开，等待自动重连");
                await Task.Delay(delay, cancellation.Token);
                var current = _online.FirstOrDefault(candidate => candidate.Key == device.Key && candidate.CanConnect) ?? device;
                try
                {
                    StartAndroid(current);
                    entry.Opened(Environment.TickCount64);
                    return;
                }
                catch (Exception failure) { error = failure.Message; }
            }
            Report(error is null ? "Android 投屏已达到重试上限" : $"Android 投屏重试结束：{error}");
            _androidPolicies.Remove(device.Key);
        }
        catch (OperationCanceledException) { }
        finally { _androidRetries.Remove(device.Key); cancellation.Dispose(); RebuildDevices(); }
    }

    private async Task StopMirrorAsync(DeviceChoice device)
    {
        if (device.IsAndroid)
        {
            if (_androidRetries.TryGetValue(device.Key, out var retry)) retry.Cancel();
            _androidPolicies.Remove(device.Key);
            _androidReady.Remove(device.Key);
            if (_androidNotices.Remove(device.Key, out var notice)) notice.Close();
            if (_androidTransfers.TryGetValue(device.Key, out var transfer)) transfer.Cancellation.Cancel();
            var stop = _android.StopAsync(device.Key);
            RebuildDevices();
            await stop;
            RebuildDevices();
        }
#if !ANDROID_RELEASE
        else if (_mirrors.TryGetValue(device.Key, out var mirror) && _closingMirrors.Add(device.Key)) await mirror.CloseAsync();
#endif
    }

    private IEnumerable<IntPtr> MirrorHandles()
    {
        var android = _preferences.History.Values.Where(device => device.IsAndroid).Select(_android.Handle);
#if ANDROID_RELEASE
        return android;
#else
        return _mirrors.Values.Select(window => window.Handle).Concat(android);
#endif
    }

    private bool FitMirrorGroup(IntPtr anchor)
    {
        if (anchor == IntPtr.Zero) return false;
#if ANDROID_RELEASE
        return _windowGroup.Fit(anchor, MirrorHandles(), _ => 0);
#else
        return _windowGroup.Fit(anchor, MirrorHandles(), handle =>
            _mirrors.Values.FirstOrDefault(window => window.Handle == handle)?.VideoInset ?? 0);
#endif
    }

    private void OnFitGroup(object sender, RoutedEventArgs e)
    {
        var active = MirrorHandles().FirstOrDefault(handle => handle != IntPtr.Zero && !WindowNative.IsIconic(handle));
        if (!FitMirrorGroup(active)) Report("至少打开两个投屏窗口后可放大整组");
        else WindowNative.Show(active);
    }

    private void OnConnectAll(object sender, RoutedEventArgs e) => ConnectAll();

    private void ConnectAll()
    {
        foreach (var device in _online.Where(item => item.CanConnect)) StartMirror(device);
    }

    private async Task RenameAsync(DeviceChoice device)
    {
        var box = new TextBox { Header = "自定义设备名称", Text = _preferences.Aliases.GetValueOrDefault(device.Key) ?? "",
            PlaceholderText = device.Model, MaxLength = 64 };
        if (await ShowDialogAsync("重命名设备", box, "保存") != ContentDialogResult.Primary) return;
        if (string.IsNullOrWhiteSpace(box.Text)) _preferences.Aliases.Remove(device.Key);
        else _preferences.Aliases[device.Key] = box.Text.Trim();
        SavePreferences();
#if !ANDROID_RELEASE
        if (_mirrors.TryGetValue(device.Key, out var mirror)) mirror.RefreshTitle();
#endif
        WindowNative.Rename(_android.Handle(device), $"「Android」{_preferences.Name(device)}");
        RebuildDevices();
    }

    private async void OnWireless(object sender, RoutedEventArgs e)
    {
        string[] operations = ["Android 无线连接", "Android 配对"];
#if !ANDROID_RELEASE
        operations = [.. operations, "HarmonyOS 无线连接"];
#endif
        var kind = new ComboBox { Header = "操作", ItemsSource = operations, SelectedIndex = 0 };
        var address = new TextBox { Header = "手机显示的地址和端口", PlaceholderText = "192.168.1.10:12345" };
        var code = new PasswordBox { Header = "六位配对码", Visibility = Visibility.Collapsed, MaxLength = 6 };
        kind.SelectionChanged += (_, _) => code.Visibility = kind.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
        var fields = new StackPanel { Spacing = 8 };
        fields.Children.Add(kind); fields.Children.Add(address); fields.Children.Add(code);
        if (await ShowDialogAsync("无线调试", fields, "继续") != ContentDialogResult.Primary) return;
        try
        {
            if (kind.SelectedIndex == 1)
            {
                await _android.PairAsync(address.Text, code.Password);
                Report("配对成功。请使用无线调试主页上的连接地址连接。");
            }
            else if (kind.SelectedIndex == 0)
            {
                await _android.ConnectAsync(address.Text);
                Report("Android 无线调试已连接");
            }
#if !ANDROID_RELEASE
            else
            {
                if (!await PrepareHarmonyAsync()) throw new IOException("请先安装华为 DevEco Testing，或检查指定的本机 SDK 目录。");
                string result = await DeviceTools.RunAsync(_hdc, ["tconn", DeviceTools.Address(address.Text)]);
                if (!result.Contains("connect OK", StringComparison.OrdinalIgnoreCase) &&
                    !result.Contains("already connected", StringComparison.OrdinalIgnoreCase))
                    throw new IOException(result);
                Report("HarmonyOS 无线调试已连接");
            }
#endif
            await RefreshDevices();
        }
        catch (Exception error) { Report(error.Message); }
        finally { code.Password = ""; }
    }

    private void OnSettings(object sender, RoutedEventArgs e) => OpenSettings();

    private async void OpenSettings()
    {
#if !ANDROID_RELEASE
        var fps = Options("目标帧率", new[] { 15, 30, 60 }, _preferences.FrameRate);
        var bitrate = Options("目标码率（Mbps）", new[] { 2, 4, 8, 12, 16, 20, 24 }, _preferences.Bitrate);
        var scale = Options("鸿蒙分辨率", new[] { "原始", "50%" }, _preferences.Scale == 0.5 ? "50%" : "原始");
        var theme = Options("鸿蒙投屏窗口外观", new[] { "浅色", "深色", "跟随系统" },
            _preferences.Appearance == "Dark" ? "深色" : _preferences.Appearance == "Default" ? "跟随系统" : "浅色");
        var harmonyPath = new TextBox { Header = "HarmonyOS 手机保存目录", Text = _preferences.HarmonyDestination };
        var balance = new Button { Content = "恢复平衡画质" };
        balance.Click += (_, _) => { fps.SelectedItem = 30; bitrate.SelectedItem = 16; scale.SelectedIndex = 0; };
#endif
        var reconnect = Toggle("自动重连", _preferences.AutoReconnect);
        var pin = Toggle("连接后自动置顶窗口", _preferences.AutoPin);
        var snap = Toggle("投屏窗口磁吸", _preferences.SnapWindows);
        var lockPhones = Toggle("电脑锁屏时锁定在线手机", _preferences.LockPhones);
        var wakePhones = Toggle("电脑解锁时唤醒在线手机", _preferences.WakePhones);
        var androidPath = new TextBox { Header = "Android 手机保存目录", Text = _preferences.AndroidDestination };
        var fields = new StackPanel { Spacing = 8 };
        foreach (var field in new UIElement[] {
#if !ANDROID_RELEASE
            fps, bitrate, scale, balance, theme, harmonyPath,
#endif
            reconnect, pin, snap, lockPhones, wakePhones, androidPath })
            fields.Children.Add(field);
        if (await ShowDialogAsync("设置", new ScrollViewer { MaxHeight = 560, Content = fields }, "保存") != ContentDialogResult.Primary) return;
        try
        {
            var androidDirectory = DeviceTools.DirectoryPath(androidPath.Text);
#if !ANDROID_RELEASE
            var harmonyDirectory = DeviceTools.DirectoryPath(harmonyPath.Text);
            _preferences.FrameRate = fps.SelectedItem is int rate ? rate : 30;
            _preferences.Bitrate = bitrate.SelectedItem is int bits ? bits : 16;
            _preferences.Scale = scale.SelectedIndex == 1 ? 0.5 : 1;
            _preferences.Appearance = theme.SelectedIndex == 1 ? "Dark" : theme.SelectedIndex == 2 ? "Default" : "Light";
            _preferences.HarmonyDestination = harmonyDirectory;
#endif
            _preferences.AutoReconnect = reconnect.IsOn;
            _preferences.AutoPin = pin.IsOn;
            _preferences.SnapWindows = snap.IsOn;
            if (snap.IsOn) _groupTimer.Start();
            else { _groupTimer.Stop(); _windowGroup.Reset(); }
            _preferences.LockPhones = lockPhones.IsOn;
            _preferences.WakePhones = wakePhones.IsOn;
            _preferences.AndroidDestination = androidDirectory;
            SavePreferences();
#if !ANDROID_RELEASE
            foreach (var mirror in _mirrors.Values) mirror.RefreshAppearance();
#endif
            Report("设置已保存。Android 拖放目录在下次连接时生效。");
        }
        catch (Exception error) { Report(error.Message); }
    }

    private static ComboBox Options<T>(string header, T[] items, T value) =>
        new() { Header = header, ItemsSource = items, SelectedItem = value };
    private static ToggleSwitch Toggle(string title, bool enabled) => new() { Header = title, IsOn = enabled };

    private enum PhoneAction { Lock, Wake, Light, Dark }
    private static string ActionLabel(PhoneAction action) => action switch
    {
        PhoneAction.Lock => "锁屏", PhoneAction.Wake => "唤醒", PhoneAction.Light => "浅色模式", _ => "深色模式"
    };

    private async void OnHostLockChanged(bool locked)
    {
        if (_closing || _hostLocked == locked) return;
        _hostLocked = locked;
        _hostAction?.Cancel(); // 锁屏状态变化后，取消上一状态尚未执行的唤醒或解锁步骤。
        if (locked ? !_preferences.LockPhones : !_preferences.WakePhones) return;
        using var cancellation = new CancellationTokenSource();
        _hostAction = cancellation;
        try
        {
            await ApplyPhoneActionAsync(_online.Where(device => device.CanConnect).ToArray(),
                locked ? PhoneAction.Lock : PhoneAction.Wake, true, cancellation.Token);
        }
        finally { if (ReferenceEquals(_hostAction, cancellation)) _hostAction = null; }
    }

    private async void OnBatchPhoneAction(object sender, RoutedEventArgs e)
    {
        if (sender is MenuFlyoutItem { Tag: string tag } && Enum.TryParse<PhoneAction>(tag, out var action))
            await ApplyPhoneActionAsync(_online.Where(device => device.CanConnect).ToArray(), action, false);
    }

    private async Task ApplyPhoneActionAsync(IEnumerable<DeviceChoice> devices, PhoneAction action, bool followHost, CancellationToken token = default)
    {
        var results = await Task.WhenAll(devices.Select(async device =>
        {
            try
            {
                if (device.IsAndroid)
                {
                    var command = action switch
                    {
                        PhoneAction.Lock => "input keyevent KEYCODE_SLEEP",
                        PhoneAction.Wake => "input keyevent KEYCODE_WAKEUP",
                        PhoneAction.Light => "cmd uimode night no",
                        _ => "cmd uimode night yes",
                    };
                    await _android.RunAdbAsync(["-s", device.Serial, "shell", command], token);
                    if (action == PhoneAction.Wake)
                    {
                        await Task.Delay(450, token);
                        await _android.RunAdbAsync(["-s", device.Serial, "shell", "wm", "dismiss-keyguard"], token);
                    }
                    else if (action is PhoneAction.Dark or PhoneAction.Light)
                    {
                        string current = await _android.RunAdbAsync(["-s", device.Serial, "shell", "cmd", "uimode", "night"], token);
                        if (current != "Night mode: " + (action == PhoneAction.Dark ? "yes" : "no"))
                            throw new IOException("手机没有确认系统外观已切换");
                    }
                }
                else
                {
                    string mode = action == PhoneAction.Dark ? "dark" : "light";
                    string command = action switch
                    {
                        PhoneAction.Lock => "power-shell suspend",
                        PhoneAction.Wake => "power-shell wakeup",
                        _ => $"testhelper set-viewmode {mode}",
                    };
                    string result = await DeviceTools.HarmonyShellAsync(_hdc, device.Serial, command, token);
                    if (action is PhoneAction.Light or PhoneAction.Dark && result != $"Set view mode to {mode} successfully."
                        && result != $"Error: View mode is already set to {mode}.") throw new IOException(result);
                    if (followHost && action == PhoneAction.Wake)
                    {
                        await Task.Delay(650, token);
                        string state = await DeviceTools.HarmonyShellAsync(_hdc, device.Serial, "hidumper -s ScreenlockService -a -all", token);
                        if (Regex.IsMatch(state, @"(?m)^\s*\*\s+screenLocked\s+true\b"))
                            await DeviceTools.HarmonyShellAsync(_hdc, device.Serial, "uitest uiInput dircFling 2", token);
                    }
                }
                return $"{_preferences.Name(device)}：{ActionLabel(action)}命令已完成";
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return ""; }
            catch (Exception error) { return $"{_preferences.Name(device)}：{error.Message}"; }
        }));
        if (results.Length > 0 && !token.IsCancellationRequested) Report(string.Join("；", results));
    }

    private async Task QueueAndroidFilesAsync(DeviceChoice device, string[] files)
    {
        if (_closing || files.Length == 0) return;
        if (_androidTransfers.TryGetValue(device.Key, out var existing))
        {
            if (!existing.Cancellation.IsCancellationRequested)
                foreach (string path in files) existing.Files.Enqueue(path);
            return;
        }
        using var cancellation = new CancellationTokenSource();
        var queue = new Queue<string>(files);
        _androidTransfers.Add(device.Key, (cancellation, queue));
        if (_androidNotices.TryGetValue(device.Key, out var notice)) notice.BeginTransfer();
        var task = DeliverAndroidAsync(device, queue, cancellation.Token);
        _transferTasks.Add(task);
        try { await task; }
        finally { _androidTransfers.Remove(device.Key); _transferTasks.Remove(task); }
    }

    private async Task DeliverAndroidAsync(DeviceChoice device, Queue<string> files, CancellationToken token)
    {
        var delivery = new DeviceFileDelivery(_hdc, _android);
        try
        {
            while (files.TryDequeue(out var path))
            {
                token.ThrowIfCancellationRequested();
                string result;
                try { result = await delivery.DeliverAsync(device, path, _preferences.AndroidDestination, text => ShowAndroidTransfer(device, text), token); }
                catch (Exception error) when (error is not OperationCanceledException) { result = $"{path} · {error.Message}"; }
                ShowAndroidTransfer(device, result);
                RecordTransfer($"{_preferences.Name(device)} · {result}");
            }
        }
        catch (OperationCanceledException) { ShowAndroidTransfer(device, "传输已取消"); RecordTransfer($"{_preferences.Name(device)} · 传输已取消"); }
    }

    private void ShowAndroidTransfer(DeviceChoice device, string text)
    {
        Report(text);
        if (_closing || !_android.IsRunning(device)) return;
        try
        {
            if (!_androidNotices.TryGetValue(device.Key, out var notice))
            {
                notice = new TransferNotice(() => _android.Handle(device),
                    () => { if (_androidTransfers.TryGetValue(device.Key, out var token)) token.Cancellation.Cancel(); },
                    () => { ShowDevices(); OpenTransferHistory(); });
                _androidNotices[device.Key] = notice;
            }
            notice.Show(text);
        }
        catch (Exception error) { Debug.WriteLine(error.Message); } // 浮层不可用时仍在主界面保留传输结果。
    }

    private void RecordTransfer(string message)
    {
        _transfers.Insert(0, $"{DateTime.Now:HH:mm:ss} {message}");
        if (_transfers.Count > 100) _transfers.RemoveAt(_transfers.Count - 1);
    }

    private void OnTransferHistory(object sender, RoutedEventArgs e) => OpenTransferHistory();

    private async void OpenTransferHistory() =>
        await ShowDialogAsync("传输记录", ReadableText(_transfers.Count == 0 ? "暂无传输记录" : string.Join("\n\n", _transfers)));

    private static ScrollViewer ReadableText(string text) => new()
    {
        MaxHeight = 500, Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
    };

    private async void OnLicenses(object sender, RoutedEventArgs e)
    {
        string directory = Path.Combine(_resources, "compliance");
        try
        {
            string notice = await File.ReadAllTextAsync(Path.Combine(directory, "THIRD_PARTY_NOTICES.txt"));
            if (await ShowDialogAsync("开源许可与源码", ReadableText(notice), "查看全部许可与源码") == ContentDialogResult.Primary)
                Process.Start(new ProcessStartInfo(directory) { UseShellExecute = true });
        }
        catch (Exception error) { Report($"无法打开开源声明：{error.Message}"); }
    }

    private async Task<ContentDialogResult> ShowDialogAsync(string title, UIElement content, string? primary = null)
    {
        if (_dialogOpen || _closing) return ContentDialogResult.None;
        _dialogOpen = true;
        try
        {
            return await new ContentDialog { Title = title, Content = content, XamlRoot = Content.XamlRoot,
                PrimaryButtonText = primary ?? "", CloseButtonText = "关闭" }.ShowAsync();
        }
        finally { _dialogOpen = false; }
    }
}
