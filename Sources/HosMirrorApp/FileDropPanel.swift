import SwiftUI // 使用原生材质与紧凑悬浮提示。
import HosMirrorCore // 区分文件发送与系统安装阶段。

struct FileDropHistoryMenuItem: View {
    @ObservedObject var transfers: FileDropController // 直接观察任务变化，断线后也能及时启用记录入口。
    var body: some View {
        Button("传输记录…") { transfers.historyPresented = true } // 提示淡出后仍能查看完整位置和原因。
            .disabled(transfers.items.isEmpty) // 只有确实没有记录时禁用。
    }
}

struct FileDropHighlight: View {
    @ObservedObject var transfers: FileDropController // 接收原生拖放目标状态。
    var body: some View {
        Group {
            if transfers.hovering {
                ZStack {
                    Color.accentColor.opacity(0.12) // 拖入期间轻量提示目标区域。
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).padding(6) // 保持窗口原有布局。
                    Label("松开发送文件或安装应用", systemImage: "arrow.down.doc") // 两个平台提示相同，系统格式由拖放控制器判断。
                        .font(.callout).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) // 不展示底层协议信息。
                }
            }
        }
        .allowsHitTesting(false) // 不阻挡原生拖放接收。
    }
}

/// 以原生轻量浮层展示当前任务；整条点击收起，无关闭按钮、无自动关闭。
struct FileDropPanel: View {
    @ObservedObject var transfers: FileDropController // 窗口状态直接来自独立任务队列。

    var body: some View {
        VStack(spacing: 0) {
            if let item = transfers.toastItem {
                toast(item).transition(.opacity) // 新结果出现时只淡入，不移动投屏内容。
            }
        }
        .frame(maxWidth: .infinity) // 在设备窗口底部居中，不拉长提示内容。
        .padding(.horizontal, 18).padding(.bottom, 18) // 留出呼吸空间，避免贴住窗口边框。
        .popover(isPresented: $transfers.historyPresented) { FileDropHistory(transfers: transfers) } // 手动收起后仍可从更多菜单查看记录。
    }

    private func toast(_ item: FileDropItem) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { transfers.dismissToast(item) } // 点击整条只隐藏提示，不取消传输或安装。
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(tint(item).opacity(0.10)) // 柔和底色承托状态，避免突兀的警示色块。
                    if !item.finished, !hasByteProgress(item) {
                        ProgressView().controlSize(.small).tint(tint(item)) // 不可量化的准备、安装和打开阶段显示原生动态进度。
                    } else {
                        Image(systemName: symbol(item)).font(.system(size: 19, weight: .medium)).foregroundStyle(tint(item)) // 清晰的单一状态符号。
                    }
                }
                .frame(width: 40, height: 40) // 图标区保持统一尺寸，状态变化时文字不跳动。
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.title(item)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary) // 状态为第一层信息。
                    Text(item.local.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) // 文件名独立成行，不挤压标题。
                    if !item.finished { Self.progress(item) } // 精简显示真实百分比或必要阶段。
                    if item.finished, let path = item.destination, item.openingError == nil {
                        Text("已打开 \(Self.friendlyFolder(path))").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) // 成功反馈与手机自动打开行为一致。
                    }
                    if let error = item.error {
                        Text(Self.reason(error)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) // 失败原因直接可读，长日志留在记录中。
                    } else if item.openingError != nil {
                        Text(item.kind == .package ? "已安装，暂时无法自动打开" : "文件已保存，暂时无法打开目录")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) // 不把打开失败误报成安装或发送失败。
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading) // 保持两行文字自然对齐。
            }
            .padding(.horizontal, 15).padding(.vertical, 13) // 避免按钮密集排列，保持原生留白。
            .frame(maxWidth: 304, alignment: .leading) // 大窗口仍然保持轻量大小。
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous)) // 连续圆角与原生材质适应浅色和深色。
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.055), lineWidth: 0.5) } // 极淡边线增强画面上的轮廓。
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous)) // 图标、文字和留白全部属于同一点击区域。
            .shadow(color: .black.opacity(0.13), radius: 14, x: 0, y: 5) // 柔和阴影营造悬浮感，不遮蔽大块画面。
        }
        .buttonStyle(.plain) // 不附加系统按钮边框或额外关闭控件。
        .help("点击收起提示") // 操作说明按需显示，不占默认提示空间。
        .accessibilityLabel("\(Self.title(item))，\(item.local.lastPathComponent)") // 辅助功能能读出任务身份。
        .accessibilityHint("收起提示，不会中止任务") // 明确收起与取消的区别。
        .contextMenu {
            Button("查看传输记录") { transfers.historyPresented = true } // 完整位置、错误码等放在按需入口。
            if !item.finished { Button("取消任务") { transfers.cancel(item.id) } } // 取消任务保留在上下文菜单，不混作关闭提示。
        }
    }

    private func hasByteProgress(_ item: FileDropItem) -> Bool {
        if case .sending(let bytes?, let total) = item.progress { return bytes >= 0 && total > 0 } // 仅在设备确实提供字节数时显示百分比。
        return false // 系统安装不模拟百分比。
    }

    @ViewBuilder fileprivate static func progress(_ item: FileDropItem) -> some View {
        if case .sending(let bytes?, let total) = item.progress, total > 0 {
            let fraction = min(Double(bytes) / Double(total), 0.99) // 校验完成前不展示百分之百成功。
            HStack(spacing: 8) {
                ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.mini).tint(.accentColor) // 细进度条只占一行。
                Text("\(Int(fraction * 100))%").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary) // 真实比例与进度条对齐。
            }
            .padding(.top, 2) // 与文件名保留少量间距。
        } else if let start = item.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text("已用 \(Int(max(0, context.date.timeIntervalSince(start)))) 秒").font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit() // 安装/打开阶段提供真实等待时间。
            }
        }
    }

    private func tint(_ item: FileDropItem) -> Color {
        if item.error != nil { return .red } // 主任务失败使用明确的错误状态。
        if item.openingError != nil { return .orange } // 后续打开异常与主任务失败区分。
        return item.finished ? .green : .accentColor // 正常进度和成功保持克制。
    }

    private func symbol(_ item: FileDropItem) -> String {
        if item.error != nil || item.openingError != nil { return "exclamationmark" } // 原因通过文字解释，不展示复杂图标。
        return item.finished ? "checkmark" : (item.kind == .package ? "shippingbox" : "arrow.down") // 发送与安装共享统一图标容器。
    }

    fileprivate static func title(_ item: FileDropItem) -> String {
        if item.error != nil { return item.kind == .file ? "发送失败" : "安装失败" } // 失败有明确结果。
        if item.finished { return item.kind == .package && item.openingError == nil ? "已安装并打开" : (item.kind == .package ? "安装成功" : "发送成功") } // 成功不夹带实现细节。
        if item.progress == nil { return "等待中" } // 尚未执行的任务不伪称正在发送。
        if item.progress == .opening { return item.kind == .package ? "正在打开应用" : "正在打开文件夹" } // 自动打开有独立反馈。
        return item.kind == .package ? "正在安装" : "正在发送" // 对用户隐藏内部发送/校验阶段。
    }

    fileprivate static func friendlyFolder(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent // 默认提示只显示保存目录。
        for root in [FileDelivery.defaultDirectory, DevicePlatform.android.defaultDirectory] { // 两个平台显示相同的用户可见目录名称。
            if folder == root || folder.hasPrefix(root + "/") { return "下载/HosMirror" + folder.dropFirst(root.count) } // 不把相似前缀认作默认目录。
        }
        return folder // 自定义目录保留真实手机路径；完整文件路径可在详情复制。
    }

    fileprivate static func reason(_ error: String) -> String {
        let lower = error.lowercased() // 只对已识别的底层错误做简短翻译。
        if lower.contains("no signature") || lower.contains("install_parse_failed_no_certificates") { return "安装包缺少有效签名" } // 识别两种包管理器的签名错误。
        if ["signature verification", "verify signature", "signature check", "invalid signature"].contains(where: lower.contains) { return "安装包签名验证失败" } // 只匹配明确的签名错误，不根据文件名猜测。
        if lower.contains("install_failed_update_incompatible") { return "安装包签名与手机上已安装的版本不一致" } // 保留已有应用和数据，完整原文留在记录中。
        if lower.contains("install_failed_user_restricted") || lower.contains("install permission denied") { return "手机系统限制了此应用的安装" } // 安装权限与目录写权限分别提示。
        if lower.contains("permission denied") { return "没有写入目标目录的权限" } // 用户可以据此修改保存目录。
        if lower.contains("no space left") { return "手机存储空间不足" } // 给出可采取行动的原因。
        if lower.contains("read-only") { return "目标目录为只读，请更换目录" } // 不建议修改系统权限。
        if lower.contains("device not found") || lower.contains("not connected") { return "设备已断开，请重新连接" } // 连接问题不显示协议术语。
        if error.contains("已取消") { return "任务已取消" } // 系统安装是否完成的提示仍保留在详情。
        return error.split(whereSeparator: \.isNewline).first.map(String.init) ?? "操作失败，请查看详情" // 未识别原因显示首行，完整原文始终可查。
    }
}

/// 鸿蒙弹出层和 scrcpy 的传输记录窗口共用完整任务列表。
struct FileDropHistory: View {
    @ObservedObject var transfers: FileDropController // 实时显示同一设备的任务队列。

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("传输记录").font(.headline) // 只在用户主动请求时展示完整列表。
                Spacer()
                Button("清除已完成") { transfers.clearFinished() }.disabled(!transfers.items.contains { $0.finished }) // 不影响运行任务。
            }
            if transfers.items.isEmpty { Text("暂无记录").foregroundStyle(.secondary) } // 清空后保持简洁。
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(transfers.displayedItems) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.local.lastPathComponent).font(.callout).textSelection(.enabled) // 原文件名完整保留。
                                Text(FileDropPanel.title(item)).font(.caption).foregroundStyle(item.error == nil ? Color.secondary : Color.red) // 每项结果独立。
                                if !item.finished { FileDropPanel.progress(item) } // 历史页也能查看当前真实进度。
                                if let path = item.destination { Text(path).font(.caption).textSelection(.enabled) } // 保存位置可复制。
                                if let openingError = item.openingError { Text("自动打开失败：\(openingError)").font(.caption).textSelection(.enabled) } // 主任务成功仍保留后续失败原文。
                                if !item.finished { Button("取消任务") { transfers.cancel(item.id) }.controlSize(.small) } // 取消任务不再占用悬浮提示。
                                if let error = item.error {
                                    DisclosureGroup(FileDropPanel.reason(error)) { Text(error).font(.caption).textSelection(.enabled) }.font(.caption) // 完整原因由用户展开。
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading) // 路径在弹出层内换行。
                        }
                    }
                }
                .frame(maxHeight: 340) // 大批量任务也不撑大主窗口。
            }
        }
        .padding(16).frame(width: 320) // 使用原生小型弹出层。
    }

}

/// scrcpy 的原生悬浮条只接收当前任务的展示字段。
struct FileDropToastSnapshot: Encodable, Equatable {
    let id: UUID // 点击或取消只能作用于显示时的任务。
    let finished: Bool // 同一个任务的进行中提示和结果可分别收起。
    let title: String // 和鸿蒙悬浮条使用同样的阶段文案。
    let name: String // 只传文件名，完整路径留在 HosMirror 的传输记录中。
    let detail: String? // 只传一条状态或精简错误。
    let fraction: Double? // nil 表示未获得设备端的真实字节数。
    let symbol: String // 原生状态图标。
    let tone: String // Cocoa 使用对应的系统色。

    init(_ item: FileDropItem) {
        id = item.id // 保留任务身份供回传操作。
        finished = item.finished // 区分进度和结果。
        title = FileDropPanel.title(item) // 保持两个投屏窗口的文案一致。
        name = item.local.lastPathComponent // 仅显示文件名。
        if let error = item.error { detail = String(FileDropPanel.reason(error).prefix(256)) } // 完整错误保留在记录中。
        else if item.openingError != nil { detail = item.kind == .package ? "已安装，暂时无法自动打开" : "文件已保存，暂时无法打开目录" }
        else if let destination = item.destination { detail = "已打开 \(FileDropPanel.friendlyFolder(destination))" }
        else { detail = nil } // 传输中由 AppKit 显示进度。
        if !item.finished, case .sending(let bytes?, let total) = item.progress, total > 0 {
            fraction = min(Double(bytes) / Double(total), 0.99) // 校验完成前保持与鸿蒙相同的上限。
        } else { fraction = nil } // 安装等阶段用原生不定进度。
        symbol = item.error != nil || item.openingError != nil ? "exclamationmark" : "checkmark" // 结束后只显示成功或需关注状态。
        tone = item.error != nil ? "error" : (item.openingError != nil ? "warning" : "success") // 自动打开失败保留发送或安装成功。
    }
}
