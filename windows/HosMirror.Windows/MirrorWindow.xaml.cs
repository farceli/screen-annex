using System.Runtime.InteropServices;
using LibVLCSharp.Shared;
using Microsoft.UI.Xaml;
using Microsoft.UI.Input;
using Windows.Graphics;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Windowing;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;

namespace HosMirror.Windows;

public sealed partial class MirrorWindow : Window
{
    private DeviceChoice _device;
    private readonly Func<DeviceChoice?> _findDevice;
    private readonly string _resources;
    private readonly Func<bool> _fitGroup;
    private readonly string _hdc;
    private readonly MirrorPreferences _preferences;
    private readonly Action _save;
    private readonly Action<string> _recordTransfer;
    private readonly Action _openHistory;
    private readonly WindowNative _native;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _gate = new(1, 1);
    private static readonly TimeSpan VideoPollInterval = TimeSpan.FromMilliseconds(90);
    private readonly DispatcherTimer _scrollEnd = new() { Interval = TimeSpan.FromMilliseconds(140) };
    private ReconnectPolicy _reconnect = new();
    private readonly TaskCompletionSource _initialized = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _closed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _recordingLock = new();
    private LibVLC? _vlc;
    private MediaPlayer? _player;
    private IntPtr _session;
    private Task? _connection;
    private bool _closing;
    private bool _allowClose;
    private bool _ready;
    private bool _firstSize = true;
    private bool _composing;
    private bool _customTitle;
    private bool _textQueued;
    private uint? _pressedPointer;
    private Point _lastPoint;
    private Point? _pendingMove;
    private bool _moveQueued;
    private double _wheelOffset;
    private int _wheelRemainder;
    private Point? _wheelPoint;
    private bool _wheelSending;
    private long _nextDecoderRecovery;
    private int _wheelEpoch;
    private int _nativeWidth, _nativeHeight, _videoWidth, _videoHeight;
    private CancellationTokenSource? _transferCancellation;
    private Task? _transfer;
    private bool _transferNoticeDismissed;
    private readonly Queue<string> _transferFiles = new();
    private H264Recording? _recording;
    private byte[]? _sps, _pps;
    private long _lastFrame;
    private bool _idleKeyFrameRequested;
    private static readonly bool DebugFrames = Environment.GetEnvironmentVariable("HOSMIRROR_DEBUG") == "1";

    internal bool IsConnecting => !_ready && RetryButton.Visibility == Visibility.Collapsed;
    internal string ConnectionLabel => _ready ? "正在投屏" : ConnectionStatus.Text;
    internal bool IsPinned => PinButton.IsChecked == true;
    internal void SetPinned(bool pinned) { PinButton.IsChecked = pinned; ApplyPin(); }
    internal IntPtr Handle => _native.Handle;
    internal int VideoInset => (int)Math.Round(TitleStrip.ActualHeight * WindowNative.GetDpiForWindow(Handle) / 96.0);

    internal MirrorWindow(DeviceChoice device, string resources, string hdc, MirrorPreferences preferences,
        Action save, Action<string> recordTransfer, Action openHistory, Func<bool> fitGroup, Func<DeviceChoice?> findDevice)
    {
        _device = device; _resources = resources; _hdc = hdc; _preferences = preferences;
        _fitGroup = fitGroup;
        _findDevice = findDevice;
        _save = save; _recordTransfer = recordTransfer; _openHistory = openHistory;
        InitializeComponent();
        RefreshTitle();
        RefreshAppearance();
        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            _customTitle = true;
            ExtendsContentIntoTitleBar = true;
            SetTitleBar(TitleStrip);
            TitleStrip.SizeChanged += (_, _) => UpdateTitleRegions();
            MoreButton.SizeChanged += (_, _) => UpdateTitleRegions();
        }
        else CenteredTitle.Visibility = Visibility.Collapsed;
        _native = new WindowNative(this) { AspectRatio = () => _videoHeight > 0 ? (double)_videoWidth / _videoHeight : 0,
            FitToScreen = () => _fitGroup() || FitWindow(true) };
        PinButton.IsChecked = preferences.Pinned(device);
        ApplyPin();
        AppWindow.Resize(new(370, 710));
        AppWindow.Closing += (window, args) =>
        {
            if (_allowClose) return;
            args.Cancel = true;
            _ = CloseAsync();
        };
        _scrollEnd.Tick += (_, _) => { _scrollEnd.Stop(); EndScroll(); };
        Video.Initialized += (_, _) => InitializeVideo();
        AddShortcut(VirtualKey.T, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () =>
        {
            PinButton.IsChecked = !IsPinned;
            OnPin(PinButton, null);
        });
        AddShortcut(VirtualKey.W, VirtualKeyModifiers.Control, () => _ = CloseAsync());
        AddShortcut(VirtualKey.Escape, VirtualKeyModifiers.None, () => { if (!_ready) _ = CloseAsync(); else Key(KeyCodes.Back); });
        _connection = ConnectAsync();
    }

    private void AddShortcut(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, args) => { args.Handled = true; action(); };
        Root.KeyboardAccelerators.Add(accelerator);
    }

    private void InitializeVideo()
    {
        if (_closing || _initialized.Task.IsCompleted) return;
        try
        {
            Core.Initialize();
            var options = new List<string>(Video.SwapChainOptions) { "--no-audio", "--no-video-title-show" };
            _vlc = new LibVLC(options.ToArray());
            _player = new MediaPlayer(_vlc);
            Video.MediaPlayer = _player;
            _initialized.TrySetResult();
        }
        catch (Exception error) { _initialized.TrySetException(error); }
    }

    public void Show() { Activate(); WindowNative.Show(Handle); }
    internal void RefreshTitle() => Title = ConnectionDevice.Text = CenteredTitle.Text = $"「HarmonyOS」{_preferences.Name(_device)}";

    private void UpdateTitleRegions()
    {
        if (!_customTitle || MoreButton.XamlRoot is not XamlRoot root || MoreButton.ActualWidth <= 0) return;
        double dpi = root.RasterizationScale;
        var regions = new List<RectInt32>();
        foreach (var button in new Control[] { HomeButton, RecentButton, PinButton, MoreButton })
        {
            var rect = button.TransformToVisual(Root).TransformBounds(new Rect(0, 0, button.ActualWidth, button.ActualHeight));
            if (rect.Width <= 0 || rect.Height <= 0) continue;
            regions.Add(new RectInt32((int)(rect.X * dpi), (int)(rect.Y * dpi),
                (int)Math.Ceiling(rect.Width * dpi), (int)Math.Ceiling(rect.Height * dpi)));
        }
        int safeInset = Math.Max(145, (int)Math.Ceiling(AppWindow.TitleBar.RightInset / dpi) + 8);
        // 窄竖屏仍可在连接层和任务栏看到完整设备名。
        CenteredTitle.Margin = new Thickness(safeInset, 0, safeInset, 0);
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, regions.ToArray());
    }
    internal void RefreshAppearance() => Root.RequestedTheme = Enum.TryParse<ElementTheme>(_preferences.Appearance, out var theme) ? theme : ElementTheme.Light;

    internal async Task CloseAsync()
    {
        if (_closing) { await _closed.Task; return; }
        _closing = true;
        _lifetime.Cancel();
        _transferCancellation?.Cancel();
        _scrollEnd.Stop();
        try
        {
            if (_connection is not null) await _connection;
            if (_transfer is not null) await _transfer;
        }
        finally
        {
            _native.Dispose();
            _player?.Dispose();
            _vlc?.Dispose();
            _lifetime.Dispose();
            _allowClose = true;
            try { Close(); }
            finally { _closed.TrySetResult(); }
        }
    }

    internal event Action? ConnectionChanged;

    private void SetConnecting(string message, bool working = true)
    {
        ConnectionStatus.Text = message;
        RetryButton.Visibility = working ? Visibility.Collapsed : Visibility.Visible;
        ConnectionOverlay.Visibility = Visibility.Visible;
        ConnectionOverlay.Opacity = 1;
        ConnectionChanged?.Invoke();
    }

    private async Task ConnectAsync()
    {
        var token = _lifetime.Token;
        try
        {
            await _initialized.Task.WaitAsync(TimeSpan.FromSeconds(12), token);
            while (!token.IsCancellationRequested)
            {
                // USB 与无线切换后，用同一硬件身份找到当前可用的连接标识。
                if (_findDevice() is DeviceChoice current) _device = current;
                string reason;
                try { reason = await RunConnectionAsync(token); }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
                catch (Exception error) { reason = error.Message; }
                if (token.IsCancellationRequested) return;
                if (!_preferences.AutoReconnect || _reconnect.NextDelay(Environment.TickCount64) is not TimeSpan delay)
                {
                    SetConnecting(reason, false);
                    return;
                }
                SetConnecting($"{reason}，正在重连");
                await Task.Delay(delay, token);
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) { if (!_closing) SetConnecting(error.Message, false); }
    }

    private async Task<string> RunConnectionAsync(CancellationToken token)
    {
        var player = _player!;
        var vlc = _vlc!;
        var frames = new FrameStream();
        IntPtr handle = IntPtr.Zero;
        string log = "";
        string? playbackError = null;
        Media? media = null;
        // 保存本次连接的引用，旧回调无法访问之后创建的新队列。
        CoreInterop.FrameCallback frame = (_, data, length) => OnFrame(frames, token, data, length);
        CoreInterop.LogCallback logger = (_, message) => log = Marshal.PtrToStringUTF8(message) ?? "";
        EventHandler<EventArgs> onError = (_, _) => Interlocked.Exchange(ref playbackError, "视频解码失败");
        player.EncounteredError += onError;
        SetConnecting("正在连接");
        try
        {
            int fps = _preferences.FrameRate;
            int bitrate = _preferences.Bitrate;
            double scale = _preferences.Scale;
            handle = CoreInterop.hm_session_new(_device.Serial, _resources, _hdc);
            if (handle == IntPtr.Zero) return "无法创建鸿蒙投屏会话";
            using (token.Register(() => CoreInterop.hm_session_cancel_start(handle)))
            {
                int result = await Task.Run(() => CoreInterop.hm_session_start(handle, (uint)fps, (uint)bitrate, scale, frame, logger, IntPtr.Zero));
                token.ThrowIfCancellationRequested();
                if (result != 0) return string.IsNullOrWhiteSpace(log) ? "无法连接手机" : log;
            }
            CoreInterop.hm_size(handle, out _nativeWidth, out _nativeHeight);
            _videoWidth = _nativeWidth; _videoHeight = _nativeHeight;
            media = new Media(vlc, new StreamMediaInput(frames), ":demux=h264", ":no-audio", ":network-caching=0", $":h264-fps={fps}");
            if (!player.Play(media)) return "无法启动视频播放器";
            _session = handle;
            _reconnect.Opened(Environment.TickCount64);
            long firstFrameDeadline = Environment.TickCount64 + 12_000;
            long nextIdr = Environment.TickCount64 + 2_000;
            long nextReport = Environment.TickCount64 + 1000;
            int previousDisplayed = 0;
            int previousLost = 0;
            _nextDecoderRecovery = 0;
            Volatile.Write(ref _idleKeyFrameRequested, true);
            while (!token.IsCancellationRequested)
            {
                await Task.Delay(VideoPollInterval, token);
                if (Volatile.Read(ref playbackError) is string error) return error;
                if (CoreInterop.hm_video_ended(handle) != 0) return "视频通道已断开";
                UpdateVideoGeometry();
                long now = Environment.TickCount64;
                var stats = media.Statistics;
                int displayed = stats.DisplayedPictures;
                if (_ready && stats.LostPictures > previousLost && now >= _nextDecoderRecovery)
                {
                    // 解码器仍在运行但丢失参考帧时，优先补发关键帧，保留已经显示的画面。
                    _nextDecoderRecovery = now + 1000;
                    _ = RunSessionAsync(CoreInterop.hm_request_key_frame);
                }
                previousLost = stats.LostPictures;
                if (DebugFrames && now >= nextReport)
                {
                    if (displayed != previousDisplayed)
                        Console.Error.WriteLine($"[HosMirror] {_videoWidth}×{_videoHeight} · {displayed - previousDisplayed} fps");
                    previousDisplayed = displayed;
                    nextReport = now + 1000;
                }
                if (!_ready && displayed > 0)
                {
                    _ready = true;
                    ConnectionChanged?.Invoke();
                    _reconnect.Displayed();
                    if (_firstSize) { FitWindow(false); _firstSize = false; }
                    await RevealAsync(token);
                }
                else if (!_ready && now >= firstFrameDeadline) return "未收到可显示的手机画面";
                else if (!_ready && now >= nextIdr)
                {
                    nextIdr = now + 2_000;
                    _ = RunSessionAsync(CoreInterop.hm_request_key_frame, requireReady: false);
                }
                else if (_ready && !Volatile.Read(ref _idleKeyFrameRequested) && now - Interlocked.Read(ref _lastFrame) > 220)
                {
                    Volatile.Write(ref _idleKeyFrameRequested, true);
                    _ = RunSessionAsync(CoreInterop.hm_request_key_frame);
                }
            }
            return "投屏已断开";
        }
        finally
        {
            _ready = false;
            _pressedPointer = null;
            _pendingMove = null;
            _wheelPoint = null;
            _wheelEpoch++;
            _wheelRemainder = 0;
            _wheelOffset = 0;
            _scrollEnd.Stop();
            _session = IntPtr.Zero; // 门内执行的当前操作完成后才释放句柄。
            _transferCancellation?.Cancel();
            frames.Complete();
            if (_transfer is not null) await _transfer;
            await _gate.WaitAsync();
            try
            {
                if (handle != IntPtr.Zero) await Task.Run(() => CoreInterop.hm_session_free(handle));
                player.EncounteredError -= onError;
                if (media is not null)
                {
                    await Task.Run(player.Stop);
                    media.Dispose();
                    media = null;
                }
                await FinishRecordingAsync();
            }
            finally
            {
                _sps = _pps = null;
                frames.Dispose();
                GC.KeepAlive(frame);
                GC.KeepAlive(logger);
                _gate.Release();
            }
        }
    }

    private async Task RevealAsync(CancellationToken token)
    {
        if (new global::Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
        {
            // 视频已经实际显示。让连接层淡出，减少动态效果设置关闭时立即切换。
            for (int i = 5; i > 0; i--)
            {
                ConnectionOverlay.Opacity = i / 5.0;
                await Task.Delay(28, token);
            }
        }
        ConnectionOverlay.Visibility = Visibility.Collapsed;
        ConnectionOverlay.Opacity = 1;
        InputBox.Focus(FocusState.Programmatic);
    }

    private void OnFrame(FrameStream frames, CancellationToken token, IntPtr data, nuint length)
    {
        if (token.IsCancellationRequested || length == 0 || length > 16 * 1024 * 1024) return;
        var bytes = new byte[(int)length];
        Marshal.Copy(data, bytes, 0, bytes.Length);
        try
        {
            bool picture = false;
            bool delta = false;
            lock (_recordingLock)
            {
                var units = H264Recording.Split(bytes);
                foreach (var nal in units)
                {
                    switch (nal.Span[0] & 31)
                    {
                        case 7: _sps = nal.ToArray(); break;
                        case 8: _pps = nal.ToArray(); break;
                        case 1: picture = delta = true; break;
                        case 5: picture = true; break;
                    }
                }
                _recording?.Append(units, _sps, _pps, Environment.TickCount64);
            }
            if (picture)
            {
                Interlocked.Exchange(ref _lastFrame, Environment.TickCount64);
                Volatile.Write(ref _idleKeyFrameRequested, !delta); // 已收到关键帧时不再补发一张。
            }
        }
        catch (Exception error)
        {
            string message = error.Message;
            DispatcherQueue.TryEnqueue(() => { _ = FinishRecordingAsync(); Notify($"录制错误：{message}", InfoBarSeverity.Error); });
        }
        frames.Push(bytes);
    }

    private async Task<bool> RunSessionAsync(Action<IntPtr> action, bool requireReady = true)
    {
        IntPtr handle = _session;
        if (handle == IntPtr.Zero || _closing || (requireReady && !_ready)) return false;
        await _gate.WaitAsync();
        try
        {
            if (handle != _session || _closing) return false;
            await Task.Run(() => action(handle));
            return true;
        }
        catch (Exception error) { Notify(error.Message, InfoBarSeverity.Error); return false; }
        finally { _gate.Release(); }
    }

    private void UpdateVideoGeometry()
    {
        uint width = 0, height = 0;
        if (_player is null || !_player.Size(0, ref width, ref height) || width == 0 || height == 0) return;
        if (_videoWidth == width && _videoHeight == height) return;
        _videoWidth = (int)width;
        _videoHeight = (int)height;
        if (_ready) FitWindow(false);
    }

    internal bool FitWindow(bool maximize)
    {
        if (_videoWidth <= 0 || _videoHeight <= 0) return false;
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        double dpi = WindowNative.GetDpiForWindow(Handle) / 96.0;
        double availableHeight = Math.Max(1, work.Height - 95 * dpi);
        double availableWidth = Math.Max(1, work.Width - 24 * dpi);
        double height = maximize ? availableHeight : Math.Min(availableHeight, 710 * dpi);
        double aspect = (double)_videoWidth / _videoHeight;
        height = Math.Min(height, availableWidth / aspect);
        AppWindow.ResizeClient(new((int)Math.Max(1, height * aspect), (int)(height + 42 * dpi)));
        if (WindowNative.GetWindowRect(Handle, out var bounds))
        {
            int x = Math.Clamp(bounds.Left, work.X, Math.Max(work.X, work.X + work.Width - bounds.Width));
            int y = Math.Clamp(bounds.Top, work.Y, Math.Max(work.Y, work.Y + work.Height - bounds.Height));
            if (x != bounds.Left || y != bounds.Top) AppWindow.Move(new(x, y));
        }
        return true;
    }

    private Point? DevicePoint(Point point, bool clamp)
    {
        if (_videoWidth <= 0 || _videoHeight <= 0 || _nativeWidth <= 0 || _nativeHeight <= 0 || Surface.ActualWidth <= 0 || Surface.ActualHeight <= 0)
            return null;
        double scale = Math.Min(Surface.ActualWidth / _videoWidth, Surface.ActualHeight / _videoHeight);
        double width = _videoWidth * scale, height = _videoHeight * scale;
        double x = (point.X - (Surface.ActualWidth - width) / 2) / width;
        double y = (point.Y - (Surface.ActualHeight - height) / 2) / height;
        if (!clamp && (x < 0 || x > 1 || y < 0 || y > 1)) return null;
        bool same = (_nativeWidth > _nativeHeight) == (_videoWidth > _videoHeight);
        int physicalWidth = same ? _nativeWidth : _nativeHeight, physicalHeight = same ? _nativeHeight : _nativeWidth;
        return new Point(Math.Clamp((int)(x * physicalWidth), 0, physicalWidth - 1),
            Math.Clamp((int)(y * physicalHeight), 0, physicalHeight - 1));
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var pointer = e.GetCurrentPoint(Surface);
        var properties = pointer.Properties;
        if (properties.PointerUpdateKind == Microsoft.UI.Input.PointerUpdateKind.RightButtonPressed) { _ = BackOrWakeAsync(); e.Handled = true; return; }
        if (properties.PointerUpdateKind == Microsoft.UI.Input.PointerUpdateKind.MiddleButtonPressed) { Key(KeyCodes.Home); e.Handled = true; return; }
        if (!_ready || _pressedPointer is not null || DevicePoint(pointer.Position, false) is not Point point) return;
        if (pointer.PointerDeviceType == PointerDeviceType.Mouse &&
            properties.PointerUpdateKind != PointerUpdateKind.LeftButtonPressed) return;
        EndScroll();
        _pressedPointer = e.Pointer.PointerId;
        _lastPoint = point;
        Surface.CapturePointer(e.Pointer);
        InputBox.Focus(FocusState.Programmatic);
        _ = TouchAsync(0, point);
        e.Handled = true;
    }

    private async void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_pressedPointer != e.Pointer.PointerId || DevicePoint(e.GetCurrentPoint(Surface).Position, true) is not Point point) return;
        _pendingMove = _lastPoint = point;
        if (_moveQueued) return;
        _moveQueued = true;
        try
        {
            while (_pressedPointer is not null && _pendingMove is Point next)
            {
                _pendingMove = null;
                await TouchAsync(1, next);
            }
        }
        finally { _moveQueued = false; }
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_pressedPointer != e.Pointer.PointerId) return;
        if (e.Pointer.PointerDeviceType == PointerDeviceType.Mouse &&
            e.GetCurrentPoint(Surface).Properties.PointerUpdateKind != PointerUpdateKind.LeftButtonReleased) return;
        EndTouch(DevicePoint(e.GetCurrentPoint(Surface).Position, true) ?? _lastPoint);
        Surface.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private void OnPointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (_pressedPointer == e.Pointer.PointerId) EndTouch(_lastPoint);
    }

    private void EndTouch(Point point)
    {
        _pressedPointer = null;
        _pendingMove = null;
        _ = TouchAsync(2, point);
    }

    private Task<bool> TouchAsync(int phase, Point point) =>
        RunSessionAsync(handle => CoreInterop.hm_touch(handle, phase, (int)point.X, (int)point.Y));

    private async void OnPointerWheel(object sender, PointerRoutedEventArgs e)
    {
        if (!_ready || _pressedPointer is not null) return;
        var pointer = e.GetCurrentPoint(Surface);
        int delta = pointer.Properties.MouseWheelDelta;
        if (delta == 0 || pointer.Properties.IsHorizontalMouseWheel || DevicePoint(pointer.Position, false) is not Point point) return;
        _wheelRemainder = Math.Clamp(_wheelRemainder + delta, -480, 480);
        _scrollEnd.Stop();
        _scrollEnd.Start();
        e.Handled = true;
        if (_wheelSending) return;
        _wheelSending = true;
        int epoch = _wheelEpoch;
        try
        {
            while (_ready && _wheelEpoch == epoch && _pressedPointer is null && Math.Abs(_wheelRemainder) >= 30)
            {
                int amount = _wheelRemainder;
                _wheelRemainder = 0;
                bool sameOrientation = (_nativeWidth > _nativeHeight) == (_videoWidth > _videoHeight);
                int width = sameOrientation ? _nativeWidth : _nativeHeight;
                int height = sameOrientation ? _nativeHeight : _nativeWidth;
                if (width < 64 || height < 128) break;
                int top = Math.Max(1, height / 12), bottom = height - top - 1;
                int move = (int)(height * 0.14 * amount / 120.0);
                if (_wheelPoint is null)
                {
                    move = Math.Clamp(move, top - bottom, bottom - top);
                    _wheelOffset = Math.Clamp(point.Y, top + Math.Max(0, -move), bottom - Math.Max(0, move));
                    int side = width / 25; // 避开鸿蒙从屏幕侧边返回的系统手势。
                    double x = Math.Clamp(point.X, side, width - side - 1);
                    var start = new Point(x, _wheelOffset);
                    _wheelPoint = start;
                    // 首次按下和移动在同一个串行操作内，滚动不会只发一个点击。
                    var end = new Point(x, Math.Clamp(_wheelOffset + move, top, bottom));
                    _wheelPoint = end;
                    _wheelOffset = end.Y;
                    await RunSessionAsync(handle =>
                    {
                        CoreInterop.hm_touch(handle, 0, (int)start.X, (int)start.Y);
                        CoreInterop.hm_touch(handle, 1, (int)end.X, (int)end.Y);
                    });
                }
                else
                {
                    var last = _wheelPoint.Value;
                    double y = Math.Clamp(_wheelOffset + move, top, bottom);
                    if (y == _wheelOffset)
                    {
                        // 到达安全边界时抬起，再从设备中部继续下一段滑动。
                        _wheelPoint = null;
                        _wheelRemainder += amount;
                        await TouchAsync(2, last);
                        continue;
                    }
                    _wheelOffset = y;
                    _wheelPoint = new Point(last.X, y);
                    await TouchAsync(1, _wheelPoint.Value);
                }
            }
        }
        finally { _wheelSending = false; }
    }

    private void EndScroll()
    {
        _wheelEpoch++;
        _wheelRemainder = 0;
        if (_wheelPoint is not Point end) return;
        _wheelPoint = null;
        _ = TouchAsync(2, end);
    }

    private void OnCompositionStarted(TextBox sender, TextCompositionStartedEventArgs e) => _composing = true;
    private void OnCompositionEnded(TextBox sender, TextCompositionEndedEventArgs e) { _composing = false; QueueText(); }
    private void OnInputChanged(object sender, TextChangedEventArgs e) => QueueText();
    private void QueueText()
    {
        if (_textQueued || _composing || InputBox.Text.Length == 0) return;
        _textQueued = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            _textQueued = false;
            if (_composing) return;
            string text = InputBox.Text;
            InputBox.Text = "";
            _ = SendTextAsync(text);
        });
    }

    private void OnInputKey(object sender, KeyRoutedEventArgs e)
    {
        if (_composing) { return; } // 方向、退格和回车交给当前的输入法候选窗口。
        uint code = e.Key switch
        {
            VirtualKey.Enter => KeyCodes.Enter, VirtualKey.Back => KeyCodes.Backspace,
            VirtualKey.Tab => 2049, VirtualKey.Delete => 2071, VirtualKey.Up => 2012,
            VirtualKey.Down => 2013, VirtualKey.Left => 2014, VirtualKey.Right => 2015, _ => 0,
        };
        if (code == 0) return; // Ctrl+V 由系统 TextBox 插入，走同一个已提交文本入口。
        Key(code);
        e.Handled = true;
    }

    private Task<bool> SendTextAsync(string text) => text.Length == 0 ? Task.FromResult(false) : RunSessionAsync(handle =>
    {
        if (text.Contains('\0') || CoreInterop.hm_focused_text(handle, text) != 0) throw new IOException("鸿蒙设备未能执行文本输入");
    });

    private async Task BackOrWakeAsync()
    {
        if (await RunSessionAsync(handle =>
        {
            if (CoreInterop.hm_back_or_wake(handle) != 0) throw new IOException("手机未确认返回或唤醒操作");
        }, requireReady: false)) return;
        if (_session != IntPtr.Zero || _closing) return;
        try { await DeviceTools.HarmonyShellAsync(_hdc, _device.Serial, "power-shell wakeup", _lifetime.Token); }
        catch (OperationCanceledException) { }
        catch (Exception error) { Notify(error.Message, InfoBarSeverity.Error); }
    }

    private void Key(uint code) => _ = RunSessionAsync(handle => CoreInterop.hm_key(handle, code));
    private void OnHome(object sender, RoutedEventArgs e) => Key(KeyCodes.Home);
    private void OnRecent(object sender, RoutedEventArgs e) => Key(KeyCodes.Recent);
    private void OnBack(object sender, RoutedEventArgs e) => Key(KeyCodes.Back);
    private void OnPower(object sender, RoutedEventArgs e) => Key(KeyCodes.Power);
    private void OnDisconnect(object sender, RoutedEventArgs e) => _ = CloseAsync();
    private void OnRetry(object sender, RoutedEventArgs e)
    {
        if (_closing || _connection is { IsCompleted: false } || !_initialized.Task.IsCompletedSuccessfully) return;
        _reconnect = new ReconnectPolicy(); // 用户主动重试拥有新的五次自动重试预算。
        _connection = ConnectAsync();
    }

    private void ApplyPin()
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.IsAlwaysOnTop = IsPinned;
    }

    private void OnPin(object sender, RoutedEventArgs? e)
    {
        _preferences.Pins[_device.Key] = IsPinned;
        ApplyPin();
        _save();
    }

    private void OnRotate(object sender, RoutedEventArgs e)
    {
        int horizontal = _videoWidth < _videoHeight ? 1 : 0;
        _ = RunSessionAsync(handle => CoreInterop.hm_rotate(handle, horizontal));
    }

    private async void OnScreenshot(object sender, RoutedEventArgs e)
    {
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "HosMirror");
        string file = Path.Combine(directory, $"shot-{DateTime.Now:yyyyMMdd-HHmmss-fff}-{Guid.NewGuid():N}.jpeg");
        if (await RunSessionAsync(handle =>
        {
            Directory.CreateDirectory(directory);
            if (CoreInterop.hm_screenshot(handle, file) != 0) throw new IOException("截图失败");
        })) Notify($"截图已保存到 {file}", InfoBarSeverity.Success);
    }

    private async void OnText(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        var box = new TextBox { AcceptsReturn = true, MinHeight = 100, TextWrapping = TextWrapping.Wrap };
        var dialog = new ContentDialog { Title = "发送文本到手机", Content = box, PrimaryButtonText = "发送", CloseButtonText = "取消", XamlRoot = Root.XamlRoot };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await SendTextAsync(box.Text);
    }

    private async void OnCopyFromDevice(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        try
        {
            string text = await DeviceTools.HarmonyShellAsync(_hdc, _device.Serial, "testhelper get-pastedata", _lifetime.Token);
            if (_closing) return;
            if (text.Length == 0) { Notify("手机剪贴板为空", InfoBarSeverity.Informational); return; }
            var data = new DataPackage();
            data.SetText(text);
            Clipboard.SetContent(data);
            Notify("已复制手机剪贴板", InfoBarSeverity.Success);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Notify(error.Message, InfoBarSeverity.Error); }
    }

    private async void OnRecord(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        if (_recording is not null) { await FinishRecordingAsync(); return; }
        try
        {
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "HosMirror");
            Directory.CreateDirectory(directory);
            string file = Path.Combine(directory, $"mirror-{DateTime.Now:yyyyMMdd-HHmmss-fff}-{Guid.NewGuid():N}.mp4");
            lock (_recordingLock) _recording = new H264Recording(file, _videoWidth, _videoHeight);
            RecordItem.Text = "停止录制";
            MoreButton.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Red);
            await RunSessionAsync(CoreInterop.hm_request_key_frame);
        }
        catch (Exception error) { Notify(error.Message, InfoBarSeverity.Error); }
    }

    private async Task FinishRecordingAsync()
    {
        H264Recording? recording;
        lock (_recordingLock) { recording = _recording; _recording = null; }
        if (recording is null) return;
        RecordItem.Text = "开始录制";
        MoreButton.ClearValue(Control.ForegroundProperty);
        try
        {
            if (await Task.Run(recording.Finish)) Notify($"录制已保存到 {recording.Path}", InfoBarSeverity.Success);
            else Notify("没有收到可用于录制的关键帧", InfoBarSeverity.Warning);
        }
        catch (Exception error) { Notify($"保存录制失败：{error.Message}", InfoBarSeverity.Error); }
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (_ready && !_closing && e.DataView.Contains(StandardDataFormats.StorageItems))
            e.AcceptedOperation = DataPackageOperation.Copy;
        e.Handled = true;
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (!_ready || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var deferral = e.GetDeferral(); // Windows 允许异步读取资源管理器提供的 StorageItems。
        try
        {
            var items = await e.DataView.GetStorageItemsAsync();
            QueueFiles(items.Select(item => item.Path).Where(path => !string.IsNullOrWhiteSpace(path)).ToArray());
        }
        catch (Exception error) { Notify(error.Message, InfoBarSeverity.Error); }
        finally { e.Handled = true; deferral.Complete(); }
    }

    internal static async Task<string[]> PickFilesAsync(IntPtr hwnd)
    {
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        var items = await picker.PickMultipleFilesAsync();
        return items?.Select(item => item.Path).ToArray() ?? [];
    }

    private async void OnPickFiles(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        try { QueueFiles(await PickFilesAsync(Handle)); }
        catch (Exception error) { Notify(error.Message, InfoBarSeverity.Error); }
    }

    private void QueueFiles(string[] paths)
    {
        if (!_ready || _closing || paths.Length == 0) return;
        if (_transferCancellation is { IsCancellationRequested: true }) return;
        foreach (string path in paths) _transferFiles.Enqueue(path);
        if (_transferCancellation is not null) return;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _transferNoticeDismissed = false;
        _transferCancellation = cancellation;
        _transfer = TransferFilesAsync(cancellation);
    }

    private async Task TransferFilesAsync(CancellationTokenSource cancellation)
    {
        using var android = new AndroidBackend(_resources);
        var delivery = new DeviceFileDelivery(_hdc, android);
        try
        {
            while (_transferFiles.TryDequeue(out var path))
            {
                cancellation.Token.ThrowIfCancellationRequested();
                try
                {
                    string result = await delivery.DeliverAsync(_device, path, _preferences.HarmonyDestination, text => NotifyTransfer(text), cancellation.Token);
                    NotifyTransfer(result, InfoBarSeverity.Success);
                    _recordTransfer($"{_preferences.Name(_device)} · {result}");
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    NotifyTransfer($"{Path.GetFileName(path)}：{error.Message}", InfoBarSeverity.Error);
                    _recordTransfer($"{_preferences.Name(_device)} · {path} · {error.Message}");
                }
            }
        }
        catch (OperationCanceledException)
        {
            NotifyTransfer("传输已取消");
            _recordTransfer($"{_preferences.Name(_device)} · 传输已取消");
        }
        finally
        {
            _transferFiles.Clear();
            _transferCancellation = null;
            cancellation.Dispose();
        }
    }

    private void OnCancelTransfer(object sender, RoutedEventArgs e) => _transferCancellation?.Cancel();
    private void OnTransferHistory(object sender, RoutedEventArgs e) => _openHistory();

    private void Notify(string message, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        if (_closing) return;
        Notice.Message = message;
        Notice.Severity = severity;
        Notice.IsOpen = true;
    }

    private void NotifyTransfer(string message, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        if (!_transferNoticeDismissed) Notify(message, severity);
    }

    private void OnDismissNotice(object sender, TappedRoutedEventArgs e)
    {
        _transferNoticeDismissed = true;
        Notice.IsOpen = false;
        e.Handled = true;
    }
}
