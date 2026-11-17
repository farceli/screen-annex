using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace HosMirror.Windows;

internal sealed class WindowNative : IDisposable
{
    private readonly IntPtr _handle;
    private readonly SubclassProcedure _procedure;
    private readonly Action<bool>? _lockChanged;
    private readonly bool _registered;
    private bool _installed;
    public Func<uint, nuint, nint, bool>? OnMessage { get; set; }
    public Func<double>? AspectRatio { get; set; }
    public Func<bool>? FitToScreen { get; set; }
    public IntPtr Handle => _handle;

    public WindowNative(Window window, Action<bool>? lockChanged = null)
    {
        _handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        _procedure = ProcessMessage;
        _lockChanged = lockChanged;
        _installed = SetWindowSubclass(_handle, _procedure, 1, 0);
        _registered = _installed && lockChanged is not null && WTSRegisterSessionNotification(_handle, 0);
    }

    private IntPtr ProcessMessage(IntPtr window, uint message, nuint wParam, IntPtr lParam, nuint id, nuint data)
    {
        if (OnMessage?.Invoke(message, wParam, lParam) == true) return (IntPtr)1;
        if (message == 0x02B1 && wParam is 7 or 8) _lockChanged?.Invoke(wParam == 7); // 当前登录会话的锁定/解锁。
        if (message == 0x00A3 && wParam == 2 && FitToScreen?.Invoke() == true) return IntPtr.Zero; // 原生标题栏双击。
        if (message == 0x0112 && (wParam & 0xFFF0) == 0xF030 && FitToScreen?.Invoke() == true) return IntPtr.Zero;
        if (message == 0x0214 && AspectRatio?.Invoke() is double aspect && aspect > 0)
        {
            // WM_SIZING 接受外框像素。减去系统边框与工具栏后锁定视频区比例。
            var bounds = Marshal.PtrToStructure<Bounds>(lParam);
            if (GetWindowRect(window, out var outer) && GetClientRect(window, out var client))
            {
                int chromeWidth = outer.Width - client.Width;
                int chromeHeight = outer.Height - client.Height + (int)Math.Round(42 * GetDpiForWindow(window) / 96.0);
                if (wParam is 3 or 6)
                    bounds.Right = bounds.Left + chromeWidth + (int)Math.Round(Math.Max(1, bounds.Height - chromeHeight) * aspect);
                else
                {
                    int height = chromeHeight + (int)Math.Round(Math.Max(1, bounds.Width - chromeWidth) / aspect);
                    if (wParam is 4 or 5) bounds.Top = bounds.Bottom - height;
                    else bounds.Bottom = bounds.Top + height;
                }
                Marshal.StructureToPtr(bounds, lParam, false);
                return (IntPtr)1;
            }
        }
        if (message == 0x0082) Dispose(); // HWND 销毁前释放注册，委托仍由 WindowNative 持有。
        return DefSubclassProc(window, message, wParam, lParam);
    }

    public void Dispose()
    {
        if (!_installed) return;
        if (_registered) WTSUnRegisterSessionNotification(_handle);
        RemoveWindowSubclass(_handle, _procedure, 1);
        _installed = false;
    }

    public static void BringToForeground(IntPtr handle) => SetForegroundWindow(handle);

    public static void Show(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return;
        if (IsIconic(handle)) ShowWindow(handle, 9);
        SetForegroundWindow(handle);
    }

    public static void Rename(IntPtr handle, string name)
    {
        if (handle != IntPtr.Zero) SetWindowText(handle, name);
    }

    public static bool IsPinned(IntPtr handle) => (GetWindowLongPtr(handle, -20).ToInt64() & 0x8) != 0; // GWL_EXSTYLE / WS_EX_TOPMOST。

    public static void SetPinned(IntPtr handle, bool pinned)
    {
        if (handle != IntPtr.Zero) SetWindowPos(handle, (IntPtr)(pinned ? -1 : -2), 0, 0, 0, 0, 0x0013);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Bounds
    {
        public int Left, Top, Right, Bottom;
        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MonitorInfo
    {
        public int Size;
        public Bounds Monitor, Work;
        public uint Flags;
    }

    [DllImport("user32.dll")] internal static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    private delegate IntPtr SubclassProcedure(IntPtr window, uint message, nuint wParam, IntPtr lParam, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(IntPtr window, SubclassProcedure callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(IntPtr window, SubclassProcedure callback, nuint id);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr window, uint message, nuint wParam, IntPtr lParam);
    [DllImport("wtsapi32.dll")] private static extern bool WTSRegisterSessionNotification(IntPtr window, uint flags);
    [DllImport("wtsapi32.dll")] private static extern bool WTSUnRegisterSessionNotification(IntPtr window);
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr window, out Bounds bounds);
    [DllImport("user32.dll")] internal static extern bool GetClientRect(IntPtr window, out Bounds bounds);
    [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll")] internal static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] internal static extern bool IsZoomed(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int mode);
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool SetWindowText(IntPtr window, string title);
    [DllImport("user32.dll")] internal static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
}
