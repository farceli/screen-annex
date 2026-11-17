# HarmonyOS 本机组件配置

从华为官方渠道安装与设备和电脑架构相符的 [DevEco Testing](https://developer.huawei.com/consumer/cn/deveco-testing/) 和 [HarmonyOS 调试工具](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/hdc/)。请按你使用的组件条款配置本机副本。

Screen Annex 默认在以下目录查找鸿蒙组件：

| 系统 | 默认目录 |
| --- | --- |
| macOS | `~/Library/Application Support/Screen Annex/HarmonyOS` |
| Windows | `%LOCALAPPDATA%\Screen Annex\HarmonyOS` |

从终端启动时，可用环境变量 `HOSMIRROR_HARMONY_RESOURCES` 指定其他目录。当目录配置完成后重启应用。

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

按平台配置对应的 HDC。HDC 如需伴随动态库，请与 HDC 放在同一目录。macOS 的 DevEco Testing 安装包中，HDC 和伴随库可在 `Contents/Resources/app/resources/bin/` 找到。

在已核对的 macOS DevEco Testing 版本中，打开 `Contents/Resources/app/resources/tools/demoWithoutRecord.jar`，再打开其中 `lib/` 下的 `hosScrcpy-1.0.17.12-java21-SNAPSHOT-shaded.jar`。把内层归档的 `libscrcpy/` 中匹配的采集组件放进 `devices/`，把内层归档根目录下匹配的 `uitest_agent_*.so` 放进 `agents/`。保留文件名。若 SDK 中没有项目识别的 `libscrcpy_server_unix_6.5-device.z.so`，程序会尝试配置中的 6.4 组件。见 [组件版本选择](PROTOCOL.md#组件版本选择)。

开启手机的开发者模式和 USB 调试。插入数据线并允许调试后，先用本机 HDC 执行 `list targets` 确认设备可见，再回到 Screen Annex 刷新。无线连接需要先在手机打开无线调试，使用手机显示的地址和端口。

鸿蒙组件的可用版本取决于你的设备和 SDK。公开仓库和构建产物只提供 Screen Annex 宿主侧源码与配套材料。
