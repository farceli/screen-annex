# 构建用于本机测试的 Windows x64 程序，并验证必需运行时资源。
$ErrorActionPreference = "Stop" # PowerShell 自身操作失败时立即停止。
$root = Split-Path -Parent $PSScriptRoot # 项目根目录。
$app = Join-Path $PSScriptRoot "HosMirror.Windows" # WinUI 工程目录。
$output = Join-Path $root "dist\windows-x64" # 显式输出目录，避免猜测 SDK 的 RID 子目录。
$vendor = Join-Path $root "scripts\vendor_scrcpy.py" # 构建前后使用同一个运行材料校验器。
python $vendor verify # Android 官方文件、许可证与对应源码必须完整。
if ($LASTEXITCODE -ne 0) { throw "Android 内置组件或合规材料校验失败。" } # 禁止用缺少材料的资源继续发布。

Push-Location (Join-Path $root "core") # Rust 命令在 core 中执行。
try {
    cargo build --locked --release --target x86_64-pc-windows-msvc # 生成版本锁约束下的原生协议 DLL。
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed: $LASTEXITCODE" } # 外部程序失败不会自动受 ErrorActionPreference 保护。
} finally { Pop-Location } # 任意失败都恢复调用者目录。

Push-Location $app # 切换到 WinUI 工程。
try {
    dotnet build -c Release -p:Platform=x64 -r win-x64 --self-contained false -o $output # 统一构建和资源复制目的地。
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed: $LASTEXITCODE" } # 不继续发布失败构建的旧产物。
} finally { Pop-Location } # 恢复原目录。

foreach ($relative in @("ScreenAnnex.exe", "hosmirror_core.dll", "LICENSE")) {
    if (!(Test-Path (Join-Path $output $relative))) { throw "输出缺少必需文件：$relative" } # 检查资源复制和 DLL 链接确实生效。
}
python $vendor verify --resources (Join-Path $output "Resources") --platform windows-x86_64 --staged # 核对实际输出，发现旧 SDK 残留时返回错误。
if ($LASTEXITCODE -ne 0) { throw "Windows 发行包的 Android 合规材料校验失败。" } # 缺少任意 DLL 或许可即停止。
Write-Host "==> done: $output" # 所有检查通过后才报告成功。
