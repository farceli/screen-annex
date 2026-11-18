#if !ANDROID_RELEASE
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using Microsoft.Win32;

namespace HosMirror.Windows;

internal static class HarmonySdk
{
    private static readonly object Preparation = new();
    private static string? _preparedRoot;
    private static readonly string[] CaptureFiles =
    [
        "libscrcpy_server3.z.so", "libscrcpy_server_5.10-20260114.z.so",
        "libscrcpy_server_unix_6.4-20260113.z.so", "libscrcpy_server_unix_6.5-device.z.so",
        "libscrcpy_server_emulator.z.so"
    ];
    private static readonly string[] ControlFiles = ["uitest_agent_1.1.10.so", "uitest_agent_1.2.2.so"];

    internal static string? Prepare(string configuredRoot)
    {
        lock (Preparation)
        {
            // 保留旧版本地配置和显式测试入口，自动配置只在没有本机 HDC 路径时启动。
            if (File.Exists(Path.Combine(configuredRoot, "tools", "hdc.exe"))) return configuredRoot;
            if (_preparedRoot is not null) return _preparedRoot;
            string? resources = Installations().Select(folder => Path.Combine(folder, "app", "resources"))
                .FirstOrDefault(folder => File.Exists(Path.Combine(folder, "bin", "hdc.exe")));
            if (resources is null) return null;
            string cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Screen Annex", "DevEco Testing");
            return _preparedRoot = ImportResources(resources, cache);
        }
    }

    internal static string ImportResources(string resources, string cache)
    {
        string bin = Path.Combine(resources, "bin");
        string hdc = Path.Combine(bin, "hdc.exe");
        string archivePath = Path.Combine(resources, "tools", "demoWithoutRecord.jar");
        if (!File.Exists(hdc) || !File.Exists(archivePath))
            throw new IOException("已安装的 DevEco Testing 缺少鸿蒙调试组件，请检查安装是否完整。");
        string[] tools = Directory.EnumerateFiles(bin, "*.dll").Order(StringComparer.OrdinalIgnoreCase).Prepend(hdc).ToArray();

        // 按本机安装内容隔离版本，设备连接始终使用一个完整的工具目录。
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[65536];
        foreach (string file in tools.Append(archivePath))
        {
            digest.AppendData(System.Text.Encoding.UTF8.GetBytes(Path.GetFileName(file) + "\0"));
            using var stream = File.OpenRead(file);
            int count;
            while ((count = stream.Read(buffer)) > 0) digest.AppendData(buffer, 0, count);
        }
        string root = Path.Combine(cache, "v1-" + Convert.ToHexString(digest.GetHashAndReset()));
        if (Directory.Exists(root)) return root;

        string stage = Path.Combine(cache, Guid.NewGuid().ToString("N"));
        try
        {
            string toolsDirectory = Directory.CreateDirectory(Path.Combine(stage, "tools")).FullName;
            string devicesDirectory = Directory.CreateDirectory(Path.Combine(stage, "devices")).FullName;
            string agentsDirectory = Directory.CreateDirectory(Path.Combine(stage, "agents")).FullName;
            foreach (string tool in tools) File.Copy(tool, Path.Combine(toolsDirectory, Path.GetFileName(tool)));
            using var outer = ZipFile.OpenRead(archivePath);
            ZipArchiveEntry member = outer.Entries.FirstOrDefault(entry =>
                entry.FullName.StartsWith("lib/hosScrcpy-", StringComparison.Ordinal) &&
                entry.FullName.EndsWith("-shaded.jar", StringComparison.Ordinal) &&
                entry.FullName.Count(character => character == '/') == 1)
                ?? throw new IOException("DevEco Testing 安装中找不到投屏组件。");
            using var inner = new ZipArchive(member.Open());
            var capture = CaptureFiles.Select(file => inner.GetEntry("libscrcpy/" + file)).OfType<ZipArchiveEntry>().ToArray();
            var control = ControlFiles.Select(inner.GetEntry).OfType<ZipArchiveEntry>().ToArray();
            if (capture.Length == 0 || control.Length == 0 || capture.Concat(control).Any(entry => entry.Length == 0))
                throw new IOException("此 DevEco Testing 版本缺少 Screen Annex 支持的投屏或控制组件。");
            // 只解出固定文件名，归档路径不会用于构造缓存路径。
            foreach (ZipArchiveEntry entry in capture) entry.ExtractToFile(Path.Combine(devicesDirectory, entry.Name));
            foreach (ZipArchiveEntry entry in control) entry.ExtractToFile(Path.Combine(agentsDirectory, entry.Name));
            try { Directory.Move(stage, root); }
            catch (IOException) when (Directory.Exists(root)) { /* 另一个实例已提交同一份缓存。 */ }
            return root;
        }
        finally
        {
            if (Directory.Exists(stage)) Directory.Delete(stage, recursive: true);
        }
    }

    private static IEnumerable<string> Installations()
    {
        foreach (var folder in new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86 })
        {
            string path = Environment.GetFolderPath(folder);
            if (Path.IsPathFullyQualified(path)) yield return Path.Combine(path, "DevEco Testing");
        }
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "DevEco Testing");
        if (!OperatingSystem.IsWindows()) yield break;

        // 安装程序可能在已安装程序记录中登记了自定义目录。
        const string uninstall = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";
        foreach (RegistryHive hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
        foreach (RegistryView view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using var registry = RegistryKey.OpenBaseKey(hive, view);
            using var programs = registry.OpenSubKey(uninstall);
            if (programs is null) continue;
            foreach (string name in programs.GetSubKeyNames())
            {
                using var item = programs.OpenSubKey(name);
                if (item?.GetValue("DisplayName") is not string displayName ||
                    !displayName.StartsWith("DevEco Testing", StringComparison.OrdinalIgnoreCase)) continue;
                if (item.GetValue("InstallLocation") is string location && Path.IsPathFullyQualified(location))
                    yield return location;
                // 部分安装器只登记可执行文件的图标路径。
                if (item.GetValue("DisplayIcon") is not string icon) continue;
                int extension = icon.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
                if (extension < 0) continue;
                string? folder = Path.GetDirectoryName(icon[..(extension + 4)].TrimStart('"'));
                if (folder is not null && Path.IsPathFullyQualified(folder)) yield return folder;
            }
        }
    }
}
#endif
