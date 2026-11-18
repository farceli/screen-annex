# 默认构建开发版。Android 发行版自带运行时，单独生成全新的输出目录。
param([switch]$IncludeAdbSource, [switch]$AndroidRelease, [switch]$SeparateSources)

$ErrorActionPreference = "Stop" # PowerShell 自身操作失败时立即停止。
$root = Split-Path -Parent $PSScriptRoot # 项目根目录。
$app = Join-Path $PSScriptRoot "HosMirror.Windows" # WinUI 工程目录。
$output = Join-Path $root $(if ($AndroidRelease) { "dist\android-windows-x64" } else { "dist\windows-x64" })
if ($AndroidRelease -and (Test-Path $output)) { throw "请为 Android 发行版使用空的输出目录：$output" } # 防止旧文件进入公开包。
if ($SeparateSources -and (!$AndroidRelease -or $IncludeAdbSource)) { throw "单独交付源码仅用于 GitHub Android 发行版。" }
$sourceArgs = @() # 普通构建保留随包的 scrcpy 对应源码。
$separateSourcesProperty = 'false'
if ($SeparateSources) {
    $sourceArgs += '--separate-sources'
    $separateSourcesProperty = 'true'
}
$vendor = Join-Path $root "scripts\vendor_scrcpy.py" # 构建前后使用同一个运行材料校验器。
python $vendor verify # Android 官方文件、许可证与对应源码必须完整。
if ($LASTEXITCODE -ne 0) { throw "Android 内置组件或合规材料校验失败。" } # 禁止用缺少材料的资源继续发布。

if (!$AndroidRelease) {
    Push-Location (Join-Path $root "core")
    try {
        cargo build --locked --release --target x86_64-pc-windows-msvc # 开发版的鸿蒙协议 DLL。
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed: $LASTEXITCODE" }
    } finally { Pop-Location }
}

Push-Location $app # 切换到 WinUI 工程。
try {
    if ($AndroidRelease) {
        $version = python -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' (Join-Path $root 'Info.plist')
        if ($LASTEXITCODE -ne 0) { throw "无法读取 Screen Annex 发行版本。" }
        dotnet publish -c Release -p:Platform=x64 -p:AndroidRelease=true "-p:SeparateSources=$separateSourcesProperty" "-p:Version=$version" -r win-x64 --self-contained true -o $output
    } else {
        dotnet build -c Release -p:Platform=x64 -r win-x64 --self-contained false -o $output
    }
    if ($LASTEXITCODE -ne 0) { throw "dotnet build or publish failed: $LASTEXITCODE" }
} finally { Pop-Location } # 恢复原目录。

$required = @("ScreenAnnex.exe", "LICENSE")
if ($AndroidRelease) {
    $required += @("hostfxr.dll", "coreclr.dll", "Microsoft.UI.Xaml.dll", "Microsoft.WindowsAppRuntime.dll")
    # 最终发布材料拒绝任何来自鸿蒙播放器或协议后端的残留文件。
    $harmonyFiles = Get-ChildItem $output -File -Recurse | Where-Object { $_.Name -match '^(LibVLC|VideoLAN|hosmirror_core|hdc\.exe)' }
    if ($harmonyFiles) { throw "Android 发行版包含鸿蒙依赖：$($harmonyFiles.Name -join ', ')" }

    # 用实际解析的版本复制 Microsoft 再分发组件的原始许可和声明。
    $assets = Get-Content (Join-Path $app 'obj/project.assets.json') -Raw | ConvertFrom-Json -AsHashtable
    $deps = Get-Content (Join-Path $output 'ScreenAnnex.deps.json') -Raw | ConvertFrom-Json -AsHashtable
    $sdk = @($assets.libraries.Keys | Where-Object { $_ -like 'Microsoft.WindowsAppSDK/*' })
    $runtimes = @($deps.libraries.Keys | Where-Object { $_ -like 'runtimepack.Microsoft.*' })
    if ($sdk.Count -ne 1 -or $runtimes.Count -eq 0) { throw "无法确定 Windows 发布包的运行时版本。" }
    foreach ($entry in ($sdk + $runtimes)) {
        $package, $version = ($entry -replace '^runtimepack\.', '') -split '/', 2
        $relative = "$($package.ToLowerInvariant())/$version"
        $packagePath = $assets.packageFolders.Keys | ForEach-Object { Join-Path $_ $relative } |
            Where-Object { Test-Path $_ -PathType Container } | Select-Object -First 1
        if (!$packagePath) { throw "未找到 $package $version 的 NuGet 包。" }
        $noticeDirectory = Join-Path $output "Licenses/$package"
        New-Item $noticeDirectory -ItemType Directory -Force | Out-Null
        if ($package -eq 'Microsoft.Windows.SDK.NET.Ref') {
            # 此包的 nuspec 指向官方 Windows SDK 条款，包内没有单独的许可或声明文件。
            $nuspec = Get-ChildItem $packagePath -Filter '*.nuspec' | Select-Object -First 1
            [xml]$metadata = Get-Content $nuspec.FullName -Raw
            $url = $metadata.package.metadata.licenseUrl
            if ($url -ne 'https://aka.ms/WinSDKLicenseURL') { throw "Windows SDK 许可链接已变更。" }
            Copy-Item $nuspec.FullName -Destination $noticeDirectory
            @(
                "Microsoft.Windows.SDK.NET.Ref $version - Copyright Microsoft Corporation",
                "Use of the included Microsoft components is subject to the Windows SDK license terms.",
                "License: $url",
                "Redistributable files: https://learn.microsoft.com/en-us/legal/windows-sdk/redist#microsoftwindowssdknetref"
            ) | Set-Content -Encoding utf8 (Join-Path $noticeDirectory 'LICENSE-INFO.txt')
            continue
        }
        $notices = @(Get-ChildItem $packagePath -File | Where-Object { $_.Name -match '^(license|notice|third[-_ ]?party[-_ ]?notices)\.txt$' })
        if (!($notices | Where-Object { $_.Name -match '^license\.' }) -or $notices.Count -lt 2) {
            throw "$package $version 缺少许可或第三方声明文件。"
        }
        $notices | Copy-Item -Destination $noticeDirectory
    }
} else {
    $required += "hosmirror_core.dll"
}
foreach ($relative in $required) {
    if (!(Test-Path (Join-Path $output $relative))) { throw "输出缺少必需文件：$relative" } # 检查资源复制和 DLL 链接确实生效。
}
python $vendor verify --resources (Join-Path $output "Resources") --platform windows-x86_64 --staged @sourceArgs # 核对实际输出，发现旧 SDK 残留时返回错误。
if ($LASTEXITCODE -ne 0) { throw "Windows 发行包的 Android 合规材料校验失败。" } # 缺少任意 DLL 或许可即停止。
if ($IncludeAdbSource) {
    python $vendor adb-source --destination (Join-Path $output "Source Code")
    if ($LASTEXITCODE -ne 0) { throw "Windows 发行包缺少 ADB 对应源码。" }
}
Write-Host "==> done: $output" # 所有检查通过后才报告成功。
