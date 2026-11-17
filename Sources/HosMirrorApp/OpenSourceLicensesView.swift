import SwiftUI // 许可证采用系统列表和文本阅读器，不插入连接流程。
import AppKit // 用户可主动在 Finder 中查看随包源码。
import HosMirrorCore // 与运行时共用安装包资源根目录。

struct OpenSourceLicensesView: View {
    var resources = AppResources.root
    @State private var selection = "THIRD_PARTY_NOTICES.txt" // 默认先展示组件与版权总表。
    private let entries: [(String, String)] = [ // 路径与打包校验器使用相同文件约定。
        ("组件与版权声明", "THIRD_PARTY_NOTICES.txt"), // 包含准确版本、原始来源及许可边界。
        ("scrcpy · Apache 2.0", "licenses/scrcpy-LICENSE.txt"), // 保留完整英文原文。
        ("FFmpeg · LGPL 2.1", "licenses/FFmpeg-LGPL-2.1.txt"), // 实际采用的 FFmpeg 许可。
        ("libusb · LGPL 2.1", "licenses/libusb-COPYING.txt"), // 静态链接也提供源码与重建说明。
        ("SDL · zlib", "licenses/SDL-LICENSE.txt"), // 不冒认上游代码来源。
        ("dav1d · BSD", "licenses/dav1d-COPYING.txt"), // 解码依赖同样保留完整归属。
        ("zlib · zlib", "licenses/zlib-LICENSE.txt"), // 平台解压缩库的原始声明同样可以查阅。
        ("第三方授权与用户权利", "THIRD_PARTY_TERMS.md"), // 不将第三方代码笼统纳入排他条款。
        ("scrcpy 修改说明", "SCRCPY_CHANGES.md"), // 区分外层集成和真正修改上游代码。
        ("源码与重新构建", "REBUILDING.md"), // 静态链接所需完整源材料随包交付。
    ]
    private var root: URL { resources.appendingPathComponent("compliance") }
    private var text: String { // 缺少文件时显示具体问题，不伪装成许可齐全。
        (try? String(contentsOf: root.appendingPathComponent(selection), encoding: .utf8)) ?? "安装包缺少此许可文件，请重新安装完整版本。" // 阅读不需要联网。
    }
    var body: some View {
        NavigationSplitView { // 原生分栏便于查阅长篇许可证。
            List(selection: $selection) { // 选择只影响当前文档。
                ForEach(entries, id: \.1) { entry in // 不拼接任何远端内容或执行代码。
                    Text(entry.0).foregroundStyle(selection == entry.1 ? Color.white : Color.primary).tag(entry.1) // 选中行在原生高亮背景上保持明确对比度。
                }
            }
            .navigationTitle("开源许可")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220) // 保留组件名称可读空间。
        } detail: {
            LicenseTextView(text: text) // 使用原生文本阅读器，长达数万行的 ADB 声明也不截断。
            .toolbar {
                Button("查看全部许可与源码") { NSWorkspace.shared.open(root) } // 用户主动打开本地材料目录，不要求重新下载工具。
            }
        }
        .frame(minWidth: 760, minHeight: 520) // 独立窗口不挡住正在使用的设备。
    }
}

/// 原生 NSTextView 支持大文本、复制和系统查找，保持完整英文许可可读。
private struct LicenseTextView: NSViewRepresentable {
    let text: String // 只展示本地文件，不执行 Markdown 或远端内容。
    func makeNSView(context: Context) -> NSScrollView { // 文档区域使用原生滚动与文本布局。
        let scroll = NSScrollView() // 滚动器负责控制长文档的可见范围。
        scroll.hasVerticalScroller = true // 许可证全文可向下阅读。
        scroll.autohidesScrollers = true // 短声明不常驻无用滚动条。
        scroll.drawsBackground = true // 离屏和普通窗口都使用明确背景。
        scroll.backgroundColor = .textBackgroundColor // 跟随系统浅色或深色。
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 0)) // 文本会按实际文档区宽度重新布局。
        view.isEditable = false // 用户不能误改安装包内的原始声明。
        view.isSelectable = true // 支持选择、复制原文和链接。
        view.isRichText = false // 不自动解释代码或改变许可正文。
        view.usesFindBar = true // 支持原生查找长篇 ADB 声明。
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular) // 等宽字体保留上游许可证的缩进。
        view.textColor = .textColor // 与原生文档背景保持对比度。
        view.backgroundColor = .textBackgroundColor // 不依赖透明合成层。
        view.textContainerInset = NSSize(width: 16, height: 16) // 原文与阅读器边缘保持清晰间距。
        view.isVerticallyResizable = true // 文档高度按实际全文增长。
        view.isHorizontallyResizable = false // 长行随窗口折行，不要求左右拖动。
        view.autoresizingMask = [.width] // 跟随分栏宽度变化。
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude) // 不截断超长声明，明确 CGFloat 避免 SDK 重载歧义。
        view.textContainer?.widthTracksTextView = true // 排版宽度始终与可见文档区一致。
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude) // 为全文保留无限纵向空间。
        view.string = text // 首次显示完整文件内容。
        scroll.documentView = view // 将原生文本编辑器作为只读文档使用。
        return scroll // 生命周期由 SwiftUI 管理。
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { // 只在用户切换组件时替换正文。
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return } // 不因普通刷新清除选择或滚动位置。
        view.string = text // 原始声明内容不经过摘要或截断。
        view.scrollToBeginningOfDocument(nil) // 切换到新许可证时从标题开始阅读。
    }
}
