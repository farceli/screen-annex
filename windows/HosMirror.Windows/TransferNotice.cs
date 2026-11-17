using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;

namespace HosMirror.Windows;

// Android 的画面由 scrcpy 进程拥有。使用独立、无焦点的 WinUI 状态条跟随其窗口。
internal sealed class TransferNotice
{
    private readonly Window _window = new();
    private readonly Button _message = new() { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
    private readonly TextBlock _label = new() { TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly DispatcherTimer _position = new() { Interval = TimeSpan.FromMilliseconds(120) };
    private readonly Func<IntPtr> _owner;
    private bool _dismissed;

    public TransferNotice(Func<IntPtr> owner, Action cancel, Action history)
    {
        _owner = owner;
        _window.Title = "Screen Annex 文件传输";
        _message.Content = _label;
        _message.Click += (_, _) => Dismiss();
        var menu = new MenuFlyout();
        var cancelItem = new MenuFlyoutItem { Text = "取消传输" };
        cancelItem.Click += (_, _) => cancel();
        var historyItem = new MenuFlyoutItem { Text = "传输记录…" };
        historyItem.Click += (_, _) => history();
        menu.Items.Add(cancelItem);
        menu.Items.Add(historyItem);
        _message.ContextFlyout = menu;
        _window.Content = _message;
        if (_window.AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
        }
        _window.AppWindow.IsShownInSwitchers = false;
        _position.Tick += (_, _) => Update();
    }

    public void Show(string text)
    {
        _label.Text = text;
        if (_dismissed) return;
        _position.Start();
        Update();
    }

    public void BeginTransfer() => _dismissed = false; // 用户收起后，当前任务的轮询不会重新弹出。

    public void Dismiss()
    {
        _dismissed = true;
        _position.Stop();
        _window.AppWindow.Hide();
    }

    public void Close()
    {
        _position.Stop();
        _window.Close();
    }

    private void Update()
    {
        IntPtr owner = _owner();
        if (owner == IntPtr.Zero || WindowNative.IsIconic(owner) ||
            !WindowNative.GetWindowRect(owner, out var bounds))
        {
            _window.AppWindow.Hide();
            return;
        }
        var foreground = WindowNative.GetForegroundWindow();
        var notice = WinRT.Interop.WindowNative.GetWindowHandle(_window);
        if (foreground != owner && foreground != notice)
        {
            _window.AppWindow.Hide();
            return;
        }
        double scale = Math.Max(1, WindowNative.GetDpiForWindow(owner) / 96.0);
        int margin = (int)(14 * scale);
        int height = (int)(70 * scale);
        int width = Math.Min(bounds.Width - 2 * margin, (int)(460 * scale));
        if (width < 100 || bounds.Height <= height + margin) return;
        _window.AppWindow.MoveAndResize(new(bounds.Left + (bounds.Width - width) / 2,
            bounds.Bottom - height - margin, width, height));
        if (!_window.AppWindow.IsVisible) _window.AppWindow.Show(false);
    }
}
