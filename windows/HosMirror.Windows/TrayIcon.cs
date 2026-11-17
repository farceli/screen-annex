using System.Runtime.InteropServices;

namespace HosMirror.Windows;

// 使用任务栏通知区域的系统入口。所有操作都在宿主窗口所属线程派发。
internal sealed class TrayIcon : IDisposable
{
    public const uint CallbackMessage = 0x8001; // WM_APP + 1，保留给通知图标。
    private const uint Add = 0, Delete = 2;
    private readonly IntPtr _window;
    private readonly IntPtr _icon;
    private readonly Action _open;
    private readonly (string Label, Action Run)[] _commands;
    private readonly uint _taskbarCreated;
    private bool _disposed;

    public bool IsAvailable { get; private set; }

    public TrayIcon(IntPtr window, Action open, params (string Label, Action Run)[] commands)
    {
        _window = window;
        _open = open;
        _commands = commands;
        _icon = LoadIcon(IntPtr.Zero, (IntPtr)32512); // IDI_APPLICATION，借用系统图标资源。
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        IsAvailable = SetIcon(Add);
    }

    public void ProcessMessage(uint message, nuint eventCode)
    {
        if (_disposed) return;
        if (message == _taskbarCreated)
        {
            IsAvailable = SetIcon(Add); // Explorer 重启会清除原来的图标。
            return;
        }
        if (message != CallbackMessage) return;
        if (eventCode is 0x0202 or 0x0203) { _open(); return; } // WM_LBUTTONUP / WM_LBUTTONDBLCLK。
        if (eventCode is not (0x0205 or 0x007B)) return; // WM_RBUTTONUP / WM_CONTEXTMENU。
        IntPtr menu = CreatePopupMenu();
        if (menu == IntPtr.Zero) return;
        uint selected;
        try
        {
            for (int i = 0; i < _commands.Length; i++)
                AppendMenu(menu, 0, (nuint)(i + 1), _commands[i].Label);
            GetCursorPos(out var position);
            WindowNative.BringToForeground(_window); // 让鼠标点击菜单外部时按系统惯例关闭菜单。
            selected = TrackPopupMenu(menu, 0x0102, position.X, position.Y, 0, _window, IntPtr.Zero); // TPM_RETURNCMD | TPM_RIGHTBUTTON。
            PostMessage(_window, 0, 0, 0);
        }
        finally { DestroyMenu(menu); }
        if (selected > 0 && selected <= _commands.Length) _commands[selected - 1].Run();
    }

    private bool SetIcon(uint operation)
    {
        var icon = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = _window, Id = 1,
            Flags = 0x07, Callback = CallbackMessage, Icon = _icon, Tip = "Screen Annex", Info = "", InfoTitle = "",
        };
        return Shell_NotifyIcon(operation, ref icon);
    }

    public void Dispose()
    {
        if (_disposed) return;
        if (IsAvailable) SetIcon(Delete);
        IsAvailable = false;
        _disposed = true;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public IntPtr Window;
        public uint Id, Flags, Callback;
        public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid ItemGuid;
        public IntPtr BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Position { public int X, Y; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIcon(uint operation, ref NotifyIconData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadIcon(IntPtr instance, IntPtr name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(IntPtr menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr window, IntPtr bounds);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Position position);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, nuint wParam, nint lParam);
}
