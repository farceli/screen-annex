namespace HosMirror.Windows;

// AppWindow 与 SDL 窗口都提供 HWND。组内位置统一用物理像素，适配不同 DPI。
internal sealed class WindowGroup
{
    private readonly List<IntPtr> _order = new();
    private readonly Dictionary<IntPtr, WindowNative.Bounds> _previous = new();
    private IntPtr _lastForeground;

    public void Update(IEnumerable<IntPtr> handles)
    {
        var live = handles.Where(handle => handle != IntPtr.Zero).Distinct().ToHashSet();
        _order.RemoveAll(handle => !live.Contains(handle));
        foreach (var handle in live) if (!_order.Contains(handle)) _order.Add(handle);
        foreach (var handle in _previous.Keys.Where(handle => !live.Contains(handle)).ToArray()) _previous.Remove(handle);
        var visible = _order.Where(handle => !WindowNative.IsIconic(handle) && !WindowNative.IsZoomed(handle)).ToArray();
        if (visible.Length < 2) { _previous.Clear(); return; }
        IntPtr foreground = WindowNative.GetForegroundWindow();
        var current = new Dictionary<IntPtr, WindowNative.Bounds>();
        foreach (var handle in visible)
            if (WindowNative.GetWindowRect(handle, out var bounds)) current.Add(handle, bounds);
        if (!current.ContainsKey(foreground)) { Remember(current); _lastForeground = foreground; return; }
        if (current.Count < 2) { Remember(current); return; }

        if (foreground != _lastForeground)
        {
            // 在当前窗口后方依次抬起同组窗口，保持选中的窗口焦点。
            bool foregroundPinned = WindowNative.IsPinned(foreground);
            IntPtr pinnedAfter = foregroundPinned ? foreground : (IntPtr)(-1);
            IntPtr regularAfter = foregroundPinned ? IntPtr.Zero : foreground;
            foreach (var handle in visible.Where(handle => handle != foreground))
            {
                bool pinned = WindowNative.IsPinned(handle);
                WindowNative.SetWindowPos(handle, pinned ? pinnedAfter : regularAfter, 0, 0, 0, 0, 0x0013);
                if (pinned) pinnedAfter = handle;
                else regularAfter = handle;
            }
        }
        _lastForeground = foreground;
        var anchor = current[foreground];
        bool moved = _previous.TryGetValue(foreground, out var last) && (anchor.Left != last.Left || anchor.Top != last.Top);
        if (moved && WindowNative.GetAsyncKeyState(0x12) < 0) // Alt 拖动时按当前屏幕坐标换序。
        {
            _order.Sort((left, right) =>
            {
                if (!current.TryGetValue(left, out var a)) return current.ContainsKey(right) ? 1 : 0;
                return current.TryGetValue(right, out var b) ? a.Left.CompareTo(b.Left) : -1;
            });
        }
        // 前台窗口作为锚点。邻居只移动，视频比例和各设备的置顶选择保留。
        int index = _order.IndexOf(foreground);
        int leftEdge = anchor.Left, rightEdge = anchor.Right;
        for (int i = index - 1; i >= 0; i--)
        {
            var handle = _order[i];
            if (!current.TryGetValue(handle, out var bounds)) continue;
            leftEdge -= bounds.Width;
            Move(handle, bounds, leftEdge, anchor.Top);
        }
        for (int i = index + 1; i < _order.Count; i++)
        {
            var handle = _order[i];
            if (!current.TryGetValue(handle, out var bounds)) continue;
            Move(handle, bounds, rightEdge, anchor.Top);
            rightEdge += bounds.Width;
        }
        Remember(current);
    }

    public bool Fit(IntPtr anchor, IEnumerable<IntPtr> handles, Func<IntPtr, int> videoInset)
    {
        var live = handles.Where(handle => handle != IntPtr.Zero && !WindowNative.IsIconic(handle)
            && !WindowNative.IsZoomed(handle)).Distinct().ToArray();
        if (live.Length < 2) return false;
        var order = _order.Where(live.Contains).Concat(live.Where(handle => !_order.Contains(handle))).ToArray();
        IntPtr monitor = WindowNative.MonitorFromWindow(anchor, 2); // MONITOR_DEFAULTTONEAREST。
        var info = new WindowNative.MonitorInfo { Size = System.Runtime.InteropServices.Marshal.SizeOf<WindowNative.MonitorInfo>() };
        if (!WindowNative.GetMonitorInfo(monitor, ref info)) return false;
        var windows = new List<(IntPtr Handle, double Ratio, int FrameX, int FrameY)>();
        foreach (var handle in order)
        {
            if (!WindowNative.GetClientRect(handle, out var client) || !WindowNative.GetWindowRect(handle, out var frame) ||
                client.Width <= 0 || client.Height <= 0) return false;
            int inset = Math.Clamp(videoInset(handle), 0, client.Height - 1);
            windows.Add((handle, (double)client.Width / (client.Height - inset), frame.Width - client.Width, frame.Height - client.Height + inset));
        }
        int height = (int)Math.Min(info.Work.Height - windows.Max(window => window.FrameY),
            (info.Work.Width - windows.Sum(window => window.FrameX)) / windows.Sum(window => window.Ratio));
        if (height < 100) return false;
        int x = info.Work.Left;
        foreach (var window in windows)
        {
            int width = (int)(height * window.Ratio) + window.FrameX;
            WindowNative.SetWindowPos(window.Handle, IntPtr.Zero, x, info.Work.Top, width, height + window.FrameY, 0x0014);
            x += width;
        }
        return true;
    }

    public void Reset() { _order.Clear(); _previous.Clear(); _lastForeground = IntPtr.Zero; }

    private static void Move(IntPtr handle, WindowNative.Bounds bounds, int x, int y)
    {
        if (bounds.Left == x && bounds.Top == y) return;
        WindowNative.SetWindowPos(handle, IntPtr.Zero, x, y, 0, 0, 0x0015); // SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE。
    }

    private void Remember(Dictionary<IntPtr, WindowNative.Bounds> current)
    {
        _previous.Clear();
        foreach (var handle in current.Keys)
            if (WindowNative.GetWindowRect(handle, out var bounds)) _previous.Add(handle, bounds);
    }
}
