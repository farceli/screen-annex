using System;
using System.Runtime.InteropServices;

namespace HosMirror.Windows;

internal static class CoreInterop
{
    private const string Dll = "hosmirror_core";

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void FrameCallback(IntPtr user, IntPtr data, nuint length);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void LogCallback(IntPtr user, IntPtr message);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    internal static extern IntPtr hm_session_new(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string serial,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string resources,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string hdcBinary);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int hm_session_start(
        IntPtr session,
        uint fps,
        uint bitrateMbps,
        double scale,
        FrameCallback frame,
        LogCallback log,
        IntPtr user);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void hm_session_stop(IntPtr session);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void hm_session_free(IntPtr session);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void hm_touch(IntPtr session, int phase, int x, int y);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void hm_scroll(IntPtr session, int x, int y, int steps); // 对应 Rust 的原生滚轮入口。

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void hm_key(IntPtr session, uint code);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void hm_rotate(IntPtr session, int horizontal);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    internal static extern void hm_text(
        IntPtr session, int x, int y,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string text);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    internal static extern int hm_screenshot(
        IntPtr session,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string destination);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void hm_size(IntPtr session, out int width, out int height);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void hm_session_cancel_start(IntPtr session);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int hm_video_ended(IntPtr session);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int hm_back_or_wake(IntPtr session);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void hm_request_key_frame(IntPtr session);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int hm_focused_text(IntPtr session, [MarshalAs(UnmanagedType.LPUTF8Str)] string text);

}

internal static class KeyCodes
{
    public const uint Home = 1;
    public const uint Back = 2;
    public const uint Power = 18;
    public const uint Recent = 2720;
    public const uint Enter = 2054;
    public const uint Backspace = 2055;
}
