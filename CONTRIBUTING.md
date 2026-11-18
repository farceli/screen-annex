# 贡献指南

小范围修复可直接开 Pull Request。新增功能或涉及设备协议、依赖版本及发布内容的改动，先在 Issue 里说明目标和影响。

## 开发构建

macOS 需要 Swift 6、Python 3.11+ 和 curl。先在根目录执行 `python3 scripts/vendor_scrcpy.py install --download`，再执行 `./scripts/build-app.sh`。本机 App 输出到 `dist/Screen Annex.app`。设置 `SCREEN_ANNEX_ANDROID_RELEASE=1` 可以复现公开版的功能范围。

Windows 需要 Visual Studio 的 Windows 应用开发和 MSVC 工具、.NET 8 SDK、Rust 和 Python 3.11+。在根目录执行 `rustup target add x86_64-pc-windows-msvc` 和 `python scripts/vendor_scrcpy.py install --download`，再运行 `./windows/build.ps1`。开发输出依赖 [Windows App Runtime 1.7](https://learn.microsoft.com/windows/apps/windows-app-sdk/downloads)。使用 `./windows/build.ps1 -AndroidRelease` 生成自包含的公开版布局。

## 发行

[Release Android desktop apps](.github/workflows/release.yml) 在 `main` 手动运行后，使用当前版本号打包 macOS 和 Windows 的 Android 版本。验证完成后，工作流会把应用、校验值和 ADB 对应源码一起发布到同一个 GitHub Release。

若在 GitHub 以外单独分发本地 DMG，可先用 `python3 scripts/vendor_scrcpy.py adb-source --download --destination .build/adb-sources` 准备对应源码，再执行 `./scripts/package-dmg.sh`，让镜像包含完整的对应源码。需要 Developer ID 签名和公证时可使用 [notarize.sh](scripts/notarize.sh)。

## 验证改动

在仓库根目录运行下列适用检查：

```bash
# macOS Swift 单元测试。
swift test --disable-sandbox --cache-path .build/cache --scratch-path .build/scratch

# Rust 内核单元测试、格式和静态检查。
cargo test --locked --manifest-path core/Cargo.toml
cargo fmt --manifest-path core/Cargo.toml --check
cargo clippy --locked --manifest-path core/Cargo.toml --all-targets -- -D warnings

# Windows 后端可移植测试，使用 .NET 8 和本机进程替身。
dotnet run --project Tests/AndroidBackendTests/AndroidBackendTests.csproj

# 准备 Android 运行材料后，运行打包回归。
python3 scripts/vendor_scrcpy.py install --download
python3 -m unittest discover -s Tests -p 'test_*.py' -v
```

[check_android_app.sh](scripts/check_android_app.sh) 提供额外的 macOS AppKit 回归。可用 `--video-only` 在合成码流上验证视频路径。涉及真机的变更请在 Pull Request 写清主机系统、手机系统和连接方式。

提交 Issue 时，请提供复现步骤、预期行为与实际行为。分享日志、截图或录制前，请去掉设备序列号、UDID、配对码、局域网地址和个人内容。

提交的原创内容遵循 [MIT License](LICENSE)。更改第三方代码或运行组件时，请保留其许可和署名，并更新 [对应源码及构建材料](Resources/compliance/REBUILDING.md)。
