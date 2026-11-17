using System.Text.Json;

namespace HosMirror.Windows;

internal sealed class MirrorPreferences
{
    public const string HarmonyDirectory = "/storage/media/100/local/files/Docs/Download/HosMirror";
    private static readonly string FilePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HosMirror", "settings.json");

    public int FrameRate { get; set; } = 30;
    public int Bitrate { get; set; } = 16;
    public double Scale { get; set; } = 1;
    public bool AutoReconnect { get; set; } = true;
    public bool AutoPin { get; set; }
    public bool LockPhones { get; set; } = true;
    public bool WakePhones { get; set; } = true;
    public bool SnapWindows { get; set; }
    public string Appearance { get; set; } = "Light";
    public string HarmonyDestination { get; set; } = HarmonyDirectory;
    public string AndroidDestination { get; set; } = "/sdcard/Download/HosMirror";
    public Dictionary<string, string> Aliases { get; set; } = new();
    public Dictionary<string, bool> Pins { get; set; } = new();
    public Dictionary<string, DeviceChoice> History { get; set; } = new();

    public static MirrorPreferences Load()
    {
        try { return JsonSerializer.Deserialize<MirrorPreferences>(File.ReadAllText(FilePath)) ?? new(); }
        catch (IOException) { return new(); }
        catch (UnauthorizedAccessException) { return new(); }
        catch (JsonException) { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        string temporary = FilePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, FilePath, overwrite: true); // 避免中断时留下半份设置。
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public string Name(DeviceChoice device) => Aliases.GetValueOrDefault(device.Key) ?? device.Model;
    public bool Pinned(DeviceChoice device) => AutoPin || Pins.GetValueOrDefault(device.Key);
}

internal sealed class ReconnectPolicy
{
    private long _openedAt;
    private bool _displayed;
    private int _attempts;

    public void Opened(long now) { _openedAt = now; _displayed = false; }
    public void Displayed() => _displayed = true;

    public TimeSpan? NextDelay(long now)
    {
        if (_displayed && now - _openedAt >= 30_000) _attempts = 0;
        _displayed = false; // 只有实际出图且达到稳定期的连接可以恢复预算。
        return _attempts >= 5 ? null : TimeSpan.FromSeconds(Math.Min(++_attempts * 1.5, 6));
    }
}
