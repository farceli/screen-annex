using System.IO.Compression;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace HosMirror.Windows;

internal sealed class DeviceFileDelivery(string hdc, AndroidBackend android)
{
    private static readonly HashSet<string> Packages = new(StringComparer.OrdinalIgnoreCase)
        { ".hap", ".hsp", ".app", ".apk", ".aab", ".ipa", ".apks", ".xapk" };

    public async Task<string> DeliverAsync(DeviceChoice device, string path, string folder, Action<string> progress, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var file = new FileInfo(path);
        if (!file.Exists || file.Name.Any(char.IsControl)) throw new IOException("只支持可读取的普通文件");
        string extension = file.Extension.ToLowerInvariant();
        bool install = extension == (device.IsAndroid ? ".apk" : ".hap");
        if (!install && Packages.Contains(extension)) throw new IOException(device.IsAndroid ? "此设备只支持安装 APK" : "此设备只支持安装 HAP");
        folder = install ? "/data/local/tmp" : DeviceTools.DirectoryPath(folder);
        string id = Guid.NewGuid().ToString("N");
        string staging = $"{folder}/.hosmirror-{id}{(install ? extension : ".part")}";
        string? localDirectory = null;
        string? destination = null;
        bool completed = false;
        bool ownsRemote = false;
        Task<string> Shell(string command, CancellationToken cancel, int seconds = 15) => device.IsAndroid
            ? android.RunAdbAsync(["-s", device.Serial, "shell", command], cancel, TimeSpan.FromSeconds(seconds))
            : DeviceTools.HarmonyShellAsync(hdc, device.Serial, command, cancel, TimeSpan.FromSeconds(seconds));
        try
        {
            string local = file.FullName;
            string remote = staging;
            if (device.IsAndroid || install)
                await Shell($"mkdir -p {Q(folder)}", token);
            if (!install)
            {
                destination = folder + "/" + file.Name;
                string occupied = await Shell($"if [ -e {Q(destination)} ] || [ -L {Q(destination)} ]; then printf yes; fi", token);
                if (occupied == "yes") destination = $"{folder}/{Path.GetFileNameWithoutExtension(file.Name)} ({id[..8]}){file.Extension}";
                if (!device.IsAndroid)
                {
                    // 鸿蒙公共下载目录允许 HDC 创建，设备 shell 可能没有 mkdir/rename 权限。
                    int separator = folder.LastIndexOf('/');
                    string container = Path.Combine(Path.GetTempPath(), "hosmirror-send-" + id);
                    string leaf = Path.Combine(container, folder[(separator + 1)..]);
                    localDirectory = container;
                    Directory.CreateDirectory(leaf);
                    await using (var source = file.OpenRead())
                    await using (var copy = File.Create(Path.Combine(leaf, destination[(destination.LastIndexOf('/') + 1)..])))
                        await source.CopyToAsync(copy, token);
                    local = leaf;
                    remote = folder[..(separator + 1)];
                    staging = destination; // 公共下载目录走 HDC 目录发送，保留电脑原文件名。
                }
            }
            progress($"正在发送 {file.Name}");
            ownsRemote = true; // 只有开始写入后才拥有远端清理责任。
            var send = device.IsAndroid
                ? android.RunAdbAsync(["-s", device.Serial, "push", local, remote], token, TimeSpan.FromHours(1))
                : DeviceTools.RunAsync(hdc, ["-t", device.Serial, "file", "send", local, remote], token, TimeSpan.FromHours(1));
            using var polling = CancellationTokenSource.CreateLinkedTokenSource(token);
            var monitor = MonitorAsync();
            async Task MonitorAsync()
            {
                while (!polling.IsCancellationRequested)
                {
                    try
                    {
                        await Task.Delay(500, polling.Token);
                        string size = await Shell($"stat -c %s {Q(staging)}", polling.Token, 3);
                        if (long.TryParse(size, out long bytes) && bytes >= 0 && bytes <= file.Length)
                            progress($"正在发送 {file.Name} · {bytes:N0} / {file.Length:N0} 字节");
                    }
                    catch (OperationCanceledException) { return; }
                    catch (Exception) { } // 设备限制 stat 时保持不定进度。
                }
            }
            string result;
            try { result = await send; }
            finally { polling.Cancel(); await monitor; }
            if (!device.IsAndroid && (!result.Contains("FileTransfer finish") || result.Contains("[Fail]", StringComparison.OrdinalIgnoreCase)))
                throw new IOException(result.Length == 0 ? "HDC 未确认文件传输成功" : result);
            string actual = await Shell($"stat -c %s {Q(staging)}", token);
            if (!long.TryParse(actual, out long received) || received != file.Length)
                throw new IOException($"大小校验失败，手机返回 {actual}，本地为 {file.Length} 字节");
            token.ThrowIfCancellationRequested(); // 用户取消后不得继续安装或发布文件。
            if (install)
            {
                progress($"正在安装 {file.Name}");
                string installCommand = $"pm install -r -d {Q(staging)}"; // Android 默认允许原位覆盖和降级。
                if (!device.IsAndroid)
                {
                    string apiLevel = await Shell("param get const.ohos.apiversion || true", token);
                    // bm 从 API 23 支持 -d。已确认的旧版继续覆盖，未知版本按默认请求降级。
                    bool legacy = int.TryParse(apiLevel, out int api) && api is > 0 and < 23;
                    string options = legacy ? "-r" : "-r -d";
                    installCommand = $"bm install {options} -p {Q(staging)}";
                }
                string confirmation = await Shell(installCommand, token, 600);
                if (device.IsAndroid ? confirmation != "Success" : !confirmation.Contains("success", StringComparison.OrdinalIgnoreCase) ||
                    confirmation.Contains("failed", StringComparison.OrdinalIgnoreCase) || confirmation.Contains("error:", StringComparison.OrdinalIgnoreCase))
                    throw new IOException(confirmation.Length == 0 ? "手机未确认安装成功" : confirmation);
            }
            else if (device.IsAndroid)
            {
                await Shell($"test ! -d {Q(destination!)} && mv -n {Q(staging)} {Q(destination!)} && test ! -e {Q(staging)} && test -f {Q(destination!)}", token);
                try
                {
                    var uri = "file://" + string.Join("/", destination!.Split('/').Select(Uri.EscapeDataString));
                    await Shell($"am broadcast --user current -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d {Q(uri)}", token, 5);
                }
                catch (Exception) { } // 文件已落盘，媒体索引失败不能改变传输结果。
            }
            completed = true;
            string success = install ? $"已安装 {file.Name}" : $"已发送到 {destination}";
            progress($"{success}，正在打开");
            try
            {
                if (device.IsAndroid)
                {
                    if (install)
                    {
                        string package = await ApkManifest.PackageNameAsync(file.FullName, token);
                        string launcher = Component(await Shell($"cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER {Q(package)}", token), package);
                        RequireOpened(await Shell($"am start --user current -n {Q(launcher)}", token), android: true);
                    }
                    else
                    {
                        string prefix = folder.StartsWith("/sdcard/") ? "/sdcard/" : "/storage/emulated/0/";
                        if (!folder.StartsWith(prefix)) throw new IOException("保存目录不属于系统文件管理器可打开的公共存储区");
                        string uri = "content://com.android.externalstorage.documents/document/" + Uri.EscapeDataString("primary:" + folder[prefix.Length..]);
                        string picker = Component(await Shell("cmd package resolve-activity --brief --user current -a android.intent.action.OPEN_DOCUMENT_TREE", token));
                        string package = picker.Split('/')[0];
                        string request = $"-a android.intent.action.VIEW -p {Q(package)} -d {Q(uri)} -t vnd.android.document/directory";
                        _ = Component(await Shell($"cmd package resolve-activity --brief --user current {request}", token), package);
                        RequireOpened(await Shell($"am start --user current {request} --grant-read-uri-permission", token), android: true);
                    }
                }
                else
                {
                    string bundle = install ? await HapBundleAsync(file.FullName, token) : "com.huawei.hmos.files";
                    string dump = await Shell($"bm dump -n {Q(bundle)}", token);
                    var (module, ability) = HarmonyEntry(bundle, dump);
                    string command = $"aa start -b {Q(bundle)} -m {Q(module)} -a {Q(ability)}";
                    if (!install)
                    {
                        string mapped = Regex.Replace(folder, @"\A/storage/media/[0-9]+/local/files/Docs(?=/|$)", "/storage/Users/currentUser");
                        if (mapped != "/storage/Users/currentUser" && !mapped.StartsWith("/storage/Users/currentUser/"))
                            throw new IOException("保存目录不属于系统文件管理器可打开的公共文档区");
                        string uri = "file://docs" + string.Join("/", mapped.Split('/').Select(Uri.EscapeDataString));
                        command += $" -U 'filemanager://openDirectory' --ps fileUri {Q(uri)}";
                    }
                    RequireOpened(await Shell(command, token), android: false);
                }
            }
            catch (Exception error) { return $"{success}。打开失败：{error.Message}"; }
            return success;
        }
        finally
        {
            if (localDirectory is not null && Directory.Exists(localDirectory))
            {
                try { Directory.Delete(localDirectory, true); }
                catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
            if (ownsRemote && (install || !completed))
            {
                try { await Shell($"rm -f {Q(staging)}", CancellationToken.None, 4); } // 取消后只清理本次任务拥有的目标。
                catch (Exception) { }
            }
        }
    }

    private static string Q(string value) => DeviceTools.Quote(value);
    private static string Component(string output, string? expected = null)
    {
        string component = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.Trim() ?? "";
        if (!Regex.IsMatch(component, @"\A[\w.]+/[\w.$]+\z") || component.StartsWith("android/") ||
            (expected is not null && !component.StartsWith(expected + "/", StringComparison.Ordinal)))
            throw new IOException("手机没有确认可用的打开入口");
        return component;
    }

    private static void RequireOpened(string text, bool android)
    {
        if (!text.Contains(android ? "Starting:" : "start ability successfully", StringComparison.OrdinalIgnoreCase)
            || text.Contains("error:", StringComparison.OrdinalIgnoreCase) || text.Contains("Error type", StringComparison.OrdinalIgnoreCase))
            throw new IOException(text.Length == 0 ? "手机未确认打开成功" : text);
    }

    private static async Task<string> HapBundleAsync(string path, CancellationToken token)
    {
        using var zip = ZipFile.OpenRead(path);
        var entry = zip.GetEntry("module.json") ?? zip.GetEntry("config.json");
        if (entry is null || entry.Length > 4 * 1024 * 1024) throw new IOException("HAP 应用声明缺失或过大");
        await using var stream = entry.Open();
        using var manifest = await JsonDocument.ParseAsync(stream, cancellationToken: token);
        string? bundle = StringProperty(Property(manifest.RootElement, "app"), "bundleName");
        if (bundle is null || !Regex.IsMatch(bundle, @"\A[A-Za-z0-9_.]+\z")) throw new IOException("HAP 未声明有效的包名");
        return bundle;
    }

    private static (string Module, string Ability) HarmonyEntry(string bundle, string dump)
    {
        int start = dump.IndexOf('{'), end = dump.LastIndexOf('}');
        if (start < 0 || end < start) throw new IOException("未找到已安装应用的入口");
        using var doc = JsonDocument.Parse(dump[start..(end + 1)]);
        var root = doc.RootElement;
        string? returnedBundle = StringProperty(root, "name") ?? StringProperty(Property(root, "applicationInfo"), "bundleName");
        if (returnedBundle is not null && returnedBundle != bundle) throw new IOException("设备返回的应用与所请求的包不一致");
        string? primary = StringProperty(root, "entryModuleName");
        var modules = Elements(Property(root, "hapModuleInfos")).OrderByDescending(item =>
            (StringProperty(item, "moduleName") ?? StringProperty(item, "name")) == primary);
        foreach (var module in modules)
        {
            string? name = StringProperty(module, "moduleName") ?? StringProperty(module, "name");
            if (string.IsNullOrEmpty(name)) continue;
            string? main = new[] { StringProperty(module, "mainElementName"), StringProperty(module, "mainAbility") }
                .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
            var visible = Elements(Property(module, "abilityInfos")).Where(ability =>
                Property(ability, "exported").ValueKind != JsonValueKind.False && Property(ability, "visible").ValueKind != JsonValueKind.False);
            var entry = visible.FirstOrDefault(ability => Elements(Property(ability, "skills")).Any(skill =>
                Elements(Property(skill, "entities")).Any(entity => entity.ValueKind == JsonValueKind.String && entity.GetString() == "entity.system.home")));
            if (entry.ValueKind == JsonValueKind.Undefined && main is not null)
                entry = visible.FirstOrDefault(ability => StringProperty(ability, "name") == main);
            string? abilityName = StringProperty(entry, "name");
            if (!string.IsNullOrWhiteSpace(abilityName)) return (name, abilityName);
        }
        throw new IOException("应用未声明可打开的主页面");
    }

    private static JsonElement Property(JsonElement element, string key) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) ? value : default;
    private static string? StringProperty(JsonElement element, string key) =>
        Property(element, key) is { ValueKind: JsonValueKind.String } text ? text.GetString() : null;
    private static IEnumerable<JsonElement> Elements(JsonElement element) =>
        element.ValueKind == JsonValueKind.Array ? element.EnumerateArray().ToArray() : [];
}
