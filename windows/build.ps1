# 默认构建开发版。Android 发行版自带运行时，单独生成全新的输出目录。
param([switch]$IncludeAdbSource, [switch]$AndroidRelease, [switch]$HarmonyRelease, [switch]$SeparateSources)

$ErrorActionPreference = "Stop" # PowerShell 自身操作失败时立即停止。
$root = Split-Path -Parent $PSScriptRoot # 项目根目录。
$app = Join-Path $PSScriptRoot "HosMirror.Windows" # WinUI 工程目录。
if ($AndroidRelease -and $HarmonyRelease) { throw "请选择一个发行目标。" }
$publish = $AndroidRelease -or $HarmonyRelease
$output = Join-Path $root $(if ($AndroidRelease) { "dist\android-windows-x64" } elseif ($HarmonyRelease) { "dist\harmony-windows-x64" } else { "dist\windows-x64" })
if ($publish -and (Test-Path $output)) { throw "请为发行版使用空的输出目录：$output" } # 防止旧文件进入公开包。
if ($SeparateSources -and (!$publish -or $IncludeAdbSource)) { throw "单独交付源码仅用于 GitHub 发行版。" }
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
    if ($publish) {
        $version = python -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' (Join-Path $root 'Info.plist')
        if ($LASTEXITCODE -ne 0) { throw "无法读取 Screen Annex 发行版本。" }
        $target = if ($HarmonyRelease) { "-p:HarmonyRelease=true" } else { "-p:AndroidRelease=true" }
        dotnet publish -c Release -p:Platform=x64 $target "-p:SeparateSources=$separateSourcesProperty" "-p:Version=$version" -r win-x64 --self-contained true -o $output
    } else {
        dotnet build -c Release -p:Platform=x64 -r win-x64 --self-contained false -o $output
    }
    if ($LASTEXITCODE -ne 0) { throw "dotnet build or publish failed: $LASTEXITCODE" }
} finally { Pop-Location } # 恢复原目录。

$required = @("ScreenAnnex.exe", "LICENSE")
if ($publish) {
    $required += @("hostfxr.dll", "coreclr.dll", "Microsoft.UI.Xaml.dll", "Microsoft.WindowsAppRuntime.dll")
    $excluded = if ($AndroidRelease) { '^(LibVLC|VideoLAN|hosmirror_core|hdc\.exe)' } else { '^(libvlc(?:core)?\.dll|hdc\.exe|libusb_shared\.dll)$|\.so$' }
    $harmonyFiles = Get-ChildItem $output -File -Recurse | Where-Object { $_.Name -match $excluded }
    if ($harmonyFiles) { throw "发行目录包含不应随包发布的鸿蒙组件：$($harmonyFiles.Name -join ', ')" }

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
            [xml]$sdkMetadata = Get-Content $nuspec.FullName -Raw
            $url = $sdkMetadata.package.metadata.licenseUrl
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
}
if (!$AndroidRelease) {
    $required += "hosmirror_core.dll"
}
if ($HarmonyRelease) {
    # 随包保留托管播放器和 Rust 依赖使用的许可文件。
    $licenses = Join-Path $output "Licenses"
    Copy-Item (Join-Path $PSScriptRoot "compliance/*") $licenses
    $cargoMetadataJson = cargo metadata --manifest-path (Join-Path $root 'core/Cargo.toml') --locked --format-version 1
    if ($LASTEXITCODE -ne 0) { throw "无法读取 Rust 依赖许可。" }
    $cargoMetadata = $cargoMetadataJson | ConvertFrom-Json -AsHashtable
    foreach ($crate in $cargoMetadata.packages | Where-Object { $_.source }) {
        $files = @(Get-ChildItem (Split-Path -Parent $crate.manifest_path) -File |
            Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE|UNLICENSE)' })
        if ($files.Count -eq 0) { throw "$($crate.name) 缺少原始许可文件。" }
        $directory = Join-Path $licenses "$($crate.name)-$($crate.version)"
        New-Item $directory -ItemType Directory -Force | Out-Null
        $files | Copy-Item -Destination $directory
    }
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
