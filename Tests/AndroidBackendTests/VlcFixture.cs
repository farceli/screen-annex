using System.Runtime.InteropServices;

internal static class VlcFixture
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr CreateInstance(int count, IntPtr arguments);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void ReleaseInstance(IntPtr instance);

    internal static void Verify(string directory)
    {
        // 先加载同目录的核心库，测试真实的 Windows 动态加载和插件目录。
        IntPtr core = NativeLibrary.Load(Path.Combine(directory, "libvlccore.dll"));
        try
        {
            IntPtr vlc = NativeLibrary.Load(Path.Combine(directory, "libvlc.dll"));
            try
            {
                var create = Marshal.GetDelegateForFunctionPointer<CreateInstance>(NativeLibrary.GetExport(vlc, "libvlc_new"));
                var release = Marshal.GetDelegateForFunctionPointer<ReleaseInstance>(NativeLibrary.GetExport(vlc, "libvlc_release"));
                IntPtr instance = create(0, IntPtr.Zero);
                if (instance == IntPtr.Zero) throw new InvalidOperationException("LibVLC could not initialize.");
                release(instance);
            }
            finally { NativeLibrary.Free(vlc); }
        }
        finally { NativeLibrary.Free(core); }
    }
}
