import Foundation // 文件 URL、安全作用域和时间信息。
import SwiftUI // 为设备窗口发布任务状态。
import HosMirrorCore // 复用 hdc、分流与可取消传输服务。

struct FileDropItem: Identifiable {
    let id: UUID // 回调只更新其所属任务，避免新任务被旧结果覆盖。
    let local: URL // 保留文件 URL，等待队列期间不提前读取内容。
    let kind: FileDeliveryKind // 安装任务和发送任务使用各自的中文提示。
    var progress: FileDeliveryProgress? // nil 表示还在排队。
    var startedAt: Date? // 系统安装不提供百分比时显示真实已用时间。
    var finished = false // 成功、失败、取消后不再接管进度回调。
    var destination: String? // 仅普通文件成功时显示实际保存路径。
    var error: String? // 保留完整底层原因，可展开并复制。
    var openingError: String? // 文件或安装已成功，仅自动打开失败时在记录中保留原因。
    var title: String {
        if let _ = error { return kind == .package ? "安装失败" : "发送失败" } // 失败不能被进度覆盖。
        if finished { return kind == .package ? "安装成功" : "发送成功" } // 不用“任务完成”掩盖分流结果。
        switch progress {
        case .preparing: return "正在准备"
        case .sending: return kind == .package ? "安装中 · 发送安装包" : "发送中"
        case .installing: return "安装中 · 系统安装"
        case .finishing: return "发送中 · 正在保存"
        case .opening: return kind == .package ? "安装成功 · 正在打开应用" : "发送成功 · 正在打开目录" // 打开阶段与主任务结果分开。
        case nil: return "等待中"
        }
    }
}

@MainActor
final class FileDropController: ObservableObject {
    @Published private(set) var items: [FileDropItem] = [] // 每个文件保留独立结果，直到用户清除。
    @Published var historyPresented = false // 完整记录只在用户主动展开时显示。
    @Published var hovering = false // 由原生窗口拖放回调驱动目标高亮。
    @Published private(set) var dismissedToasts: Set<String> = [] // 收起提示不取消任务，也不修改传输结果。
    private let queue = DispatchQueue(label: "hosmirror.file-delivery", qos: .utility) // 不占用投屏输入队列。
    private var attempts: [UUID: ConnectionAttempt] = [:] // 取消不依赖投屏的自动改档生命周期。
    private let serial: String // 一台设备独立队列，绝不发送给其他设备。
    private let delivery: any FileDelivering // 两个平台共用排队、取消、进度与结果界面。
    private let platform: DevicePlatform // 仅文件路径与可安装格式由系统决定。

    init(serial: String, hdc: Hdc, platform: DevicePlatform = .harmony) {
        self.serial = serial // 创建时绑定目标设备。
        self.platform = platform // 不根据扩展名猜测目标设备系统。
        delivery = platform == .android ? AndroidFileDelivery() : FileDelivery(hdc: hdc) // UI 不分叉传输逻辑。
    }

    var activeCount: Int { items.filter { !$0.finished }.count } // 收起时仍显示未结束任务数量。
    var toastItem: FileDropItem? {
        let current = items.first(where: { !$0.finished }) ?? items.last // 仍只展示当前任务，避免列表遮挡手机。
        guard let current, !dismissedToasts.contains(toastKey(current)) else { return nil } // 进度变化不重新弹出已收起的同阶段提示。
        return current // 完成时使用新的阶段标识，仍可告知最终结果。
    }

    private func toastKey(_ item: FileDropItem) -> String {
        item.id.uuidString + (item.finished ? ":result" : ":running") // 区分执行中的提示与最终结果。
    }

    func dismissToast(_ item: FileDropItem) {
        dismissedToasts.insert(toastKey(item)) // 点击任意位置只收起当前提示，没有自动关闭计时器。
    }
    var displayedItems: [FileDropItem] {
        items.filter { !$0.finished && $0.progress != nil } // 正在发送/安装的进度优先可见。
        + items.filter { !$0.finished && $0.progress == nil } // 其次保留等待队列顺序。
        + items.filter { $0.finished }.reversed() // 最近完成的结果排在历史结果前面。
    }

    func enqueue(_ urls: [URL], directory: String, connected: Bool, removeAfter: Bool = false) {
        for url in urls { // 按拖入顺序串行处理，多文件不会同时争用设备链路。
            let id = UUID() // 为每个文件创建独立回调标识。
            var item = FileDropItem(id: id, local: url, kind: FileDeliveryKind.classify(url, platform: platform)) // 初始处于等待状态。
            if item.kind == .unsupportedPackage {
                item.finished = true // 不支持的包立即反馈，不进入设备队列。
                item.error = "当前设备仅支持安装 .\(platform.packageExtension)，暂不支持 .\(url.pathExtension) 格式" // 两个平台使用相同的明确拒绝逻辑。
                items.append(item) // 记录保留拒绝原因供查看。
                if removeAfter { try? FileManager.default.removeItem(at: url) } // 只清理应用自行创建的临时副本。
                continue // 既不安装，也不运行任何设备命令。
            }
            if !connected {
                if removeAfter { try? FileManager.default.removeItem(at: url) } // 断线时也清理应用自行导出的图片副本。
                item.finished = true // 未连接也产生可见失败提示，不静默吞掉拖放。
                item.error = "设备未连接，请连接后重新拖入" // 明确失败原因。
                items.append(item) // 保留失败结果供查看。
                continue // 不启动 hdc，也不排队等待未来的另一连接。
            }
            items.append(item) // 立即发布等待项。
            let attempt = ConnectionAttempt() // 每个任务可以独立取消。
            attempts[id] = attempt // 主线程保存取消权。
            let delivery = self.delivery // 工作线程使用固定执行器。
            let serial = self.serial // 设备目标不会随窗口状态改变。
            let scoped = url.startAccessingSecurityScopedResource() // 拖放授权必须覆盖整个排队与传输周期。
            queue.async { [weak self] in
                defer { if scoped { url.stopAccessingSecurityScopedResource() } } // 成功、失败、取消都释放授权。
                defer { if removeAfter { try? FileManager.default.removeItem(at: url) } } // 只删除应用创建的拖放图片副本，绝不删除用户原文件。
                let result = Result { // 把本地文件错误和设备错误统一交回 UI。
                    try delivery.deliverAndOpen(local: url, directory: directory, serial: serial, attempt: attempt) { progress in
                        Task { @MainActor [weak self] in
                            guard let self, let index = self.items.firstIndex(where: { $0.id == id }),
                                  !self.items[index].finished else { return } // 取消或已删除的任务不能复活。
                            self.items[index].startedAt = self.items[index].startedAt ?? Date() // 只记录首次真正执行时间。
                            self.items[index].progress = progress // 主线程负责所有 SwiftUI 状态更新。
                        }
                    }
                }
                Task { @MainActor [weak self] in
                    guard let self else { return } // 关闭且释放的控制器不再接管结果。
                    self.attempts[id] = nil // 任务已结束，释放取消凭据。
                    guard let index = self.items.firstIndex(where: { $0.id == id }),
                          !self.items[index].finished else { return } // 取消提示优先于随后到达的旧结果。
                    self.items[index].finished = true // 终态只进入一次。
                    switch result {
                    case .success(let outcome):
                        self.items[index].destination = outcome.destination // 展示包含冲突改名的真实路径。
                        self.items[index].openingError = outcome.openingError // 打开失败也保留已经成功的文件或安装结果。
                    case .failure(let error): self.items[index].error = error is CancellationError ? "已取消；若已进入系统安装，请在手机确认安装结果" : error.localizedDescription // 取消安装不冒充系统已回滚。
                    }
                }
            }
        }
    }

    func cancel(_ id: UUID, reason: String = "已取消；若已进入系统安装，请在手机确认安装结果") {
        attempts[id]?.cancel() // 使运行中的 hdc 客户端退出，也使排队任务拒绝启动。
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].finished else { return } // 不能覆盖已成功结果。
        items[index].error = reason // 立即给出用户可见原因。
        items[index].finished = true // 后台清理完成后也不再改变提示。
    }

    func cancelAll() {
        for item in items where !item.finished { cancel(item.id, reason: "设备连接已关闭，任务已取消；若正在系统安装，请在手机确认结果") } // 关窗/主动断开取消全部尚未完成的任务。
    }

    func clearFinished() {
        let removed = items.filter(\.finished) // 同步清理已删除记录的提示标识。
        for item in removed { dismissedToasts.remove(item.id.uuidString + ":running"); dismissedToasts.remove(item.id.uuidString + ":result") } // 不让会话内收起标记无限增长。
        items.removeAll { $0.finished } // 不影响正在发送的文件。
    }
}
