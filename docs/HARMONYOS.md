# HarmonyOS 首次连接

1. 从华为官网下载并安装与电脑架构相符的 [DevEco Testing](https://developer.huawei.com/consumer/cn/deveco-testing/)。
2. 在手机上开启开发者模式和 USB 调试，接上数据线并在手机上允许调试。
3. 打开 Screen Annex，从设备列表连接手机。App 会在刷新设备时找到本机安装的 DevEco Testing，并自动准备 HDC、投屏和控制组件。

Windows 发行版首次投屏需要联网。App 会从 VideoLAN 的 NuGet 自动准备固定版本的播放组件，随后从本机缓存加载。

无线连接时，在手机上打开无线调试，并在 Screen Annex 中使用手机显示的地址和端口。设备组件的选择取决于手机的 uitest 版本和本机安装提供的文件。[组件版本对照](PROTOCOL.md#组件版本选择)

## 自定义本机组件

已有本机配置仍可使用。默认读取下面的目录，并按 `tools/`、`devices/`、`agents/` 读取相应的文件。

| 系统 | 默认目录 |
| --- | --- |
| macOS | `~/Library/Application Support/Screen Annex/HarmonyOS` |
| Windows | `%LOCALAPPDATA%\Screen Annex\HarmonyOS` |

从终端启动时，可用环境变量 `HOSMIRROR_HARMONY_RESOURCES` 指定其他目录。

```text
HarmonyOS/
├── tools/
│   ├── hdc                    # macOS 本机 SDK，保留执行权限
│   └── hdc.exe                # Windows 本机 SDK，所需 DLL 放在同一目录
├── devices/
│   └── libscrcpy_server_*.z.so # 与设备的 uitest 版本相符的采集扩展
└── agents/
    └── uitest_agent_*.so      # 与设备的 uitest 版本相符的控制扩展
```

自动准备的文件来自用户本机安装，按安装内容分别缓存。Screen Annex 公开发行包包含宿主端程序和相应的开源组件。
