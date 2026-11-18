import Foundation
import SwiftUI
import AppKit
import HosMirrorCore
import CryptoKit // 使用摘要保存硬件身份，避免持久化额外的原始设备标识。

/// 同一调试标识在不同平台可以对应不同设备。
struct KnownDevice: Codable, Equatable, Identifiable {
    let platform: DevicePlatform // 存储后端身份，菜单按平台分组。
    var serial: String // 历史条目保留一次实际连接的设备标识。
    var hardwareKey: String? // 可读取硬件身份时在不同调试链路间共用名称。
    var knownRoutes: [String]? // 保存已核对过的连接标识，兼容没有此字段的旧记录。
    var model = "" // 最近一次成功读取的默认型号。
    var customName: String? // 清除后重新使用默认型号。
    var wasAvailable = false // 仅曾经就绪的设备会进入历史。
    var routeID: String { platform.identifier(serial: serial) } // 会话和窗口始终使用后端连接键。
    var id: String { hardwareKey ?? routeID } // 设备历史与别名优先使用稳定的硬件身份。
}

struct DeviceListEntry: Identifiable {
    let device: KnownDevice // 当前列表和历史共用名称来源。
    var unavailableReason: String? // 当前可投屏时为空。
    let transport: DeviceTransport? // 图标跟随当前调试路径，历史别名仍按设备保存。
    var id: String { device.routeID } // 当前列表的操作必须绑定实际调试连接。

    @MainActor
    func status(for controller: DeviceController) -> String {
        if controller.connected { return controller.hasVideoFrame ? "投屏中" : "等待画面" } // 区分通道就绪和首帧。
        if controller.busy { return "正在连接…" } // 启动中的设备可取消。
        if controller.reconnectPending { return "等待重连…" } // 重试阶段仍可停止。
        if let unavailableReason { return unavailableReason } // 如实展示 ADB 的离线或授权状态。
        return controller.status == "未连接" ? "可连接" : controller.status // 保留失败提示和主动断开状态。
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var androidDevices: [AndroidDevice] = [] // Android 与鸿蒙列表分别维护，序列号不会串用后端。
    @Published var discoveryMessage: String? // 一种后端失败时仍保留另一种后端的设备。
    @Published private(set) var isDiscovering = false // 自动打开仍需等两个后端都确认设备数量。
    @Published var wirelessPlatform = WirelessPlatform.defaultPlatform
    @Published var pairingAddress = "" // Android 配对端口与连接端口分别填写。
    @Published var pairingCode = "" // 六位配对码只保存在内存，不写入偏好或日志。
    @Published var wirelessBusy = false // 防止重复提交配对和连接命令。
    @Published var wirelessMessage: String? // 配对成功仍提示用户填写独立的连接端口。
    @Published var errorMessage: String?
    @Published var settings: MirrorSettings
    @Published var wirelessAddress: String

    @Published private var knownDevices: [String: KnownDevice] // 已连接过的设备和自定义名称跨启动共用。
    private static let knownDevicesKey = "devices.known" // 与全局画质等设置分开存储。
    private let defaults: UserDefaults // 离屏回归可隔离设备历史和别名。
    private let discoverDevices: Bool // 测试存储不会访问真实设备或启动调试工具。
    private var identityRequests: [String: UUID] = [:] // 同一次接入仅查询一次，移除后忽略旧结果。
    private var resolvedKeys: [String: String] = [:] // 仅保存仍然在线的调试连接到硬件身份的映射。
    private var namesEditedWhileIdentifying = Set<String>() // 识别完成时保留刚提交的改名或清除。
    private var refreshID: UUID? // 防止重复轮询或较慢的旧结果覆盖新状态。
    private var wirelessID = UUID() // 同样隔离连续发起的无线连接结果。
    private let hdc: Hdc
    private var controllers: [String: DeviceController] = [:]

    var activeMirrorControllers: [DeviceController] {
        controllers.values.filter(\.isActivelyMirroring).sorted { $0.id < $1.id } // 使用真实投屏会话，不用 USB/无线调试枚举替代。
    }

    init(discoverDevices: Bool = true, defaults: UserDefaults = .standard) { // 离屏 UI 检查可关闭设备枚举，避免访问真实手机。
        self.defaults = defaults // 读写使用同一偏好域。
        self.discoverDevices = discoverDevices
        let data = defaults.data(forKey: Self.knownDevicesKey) // 旧版用户首次运行时没有该字段。
        knownDevices = data.flatMap { try? JSONDecoder().decode([String: KnownDevice].self, from: $0) } ?? [:] // 首次运行从空历史开始。
        hdc = Hdc(binary: AppResources.hdcBinary)
        var loaded = MirrorSettings.load(from: defaults)
        if ProcessInfo.processInfo.environment["HOSMIRROR_PIN"] == "1" {
            loaded.alwaysOnTop = true
        }
        settings = loaded
        wirelessAddress = UserDefaults.standard.string(forKey: "wireless.address") ?? ""
        if discoverDevices { refreshDevices() } // 正常 App 入口保持自动枚举。
    }

    func refreshDevices(replacingInFlight: Bool = false) {
        guard discoverDevices else { return } // 状态栏定时刷新也尊重测试存储的设备隔离。
        guard refreshID == nil || replacingInFlight else { return } // 状态栏轮询复用正在进行的枚举。
        let request = UUID() // 每次刷新都生成新的结果版本。
        refreshID = request
        if !isDiscovering { isDiscovering = true }
        let hdc = self.hdc
        Task { [weak self] in
            var issues: [String] = [] // 将两个独立后端的结果合并为非阻塞提示。
            await withTaskGroup(of: DiscoveryResult.self) { group in
                if ReleaseFeatures.harmonyEnabled {
                    group.addTask {
                        // 未安装可选的鸿蒙组件时，Android 设备列表仍可正常使用。
                        guard FileManager.default.isExecutableFile(atPath: hdc.binary.path) else { return .harmony(.success([])) }
                        return .harmony(Result { try hdc.targets() }) // 读取真实的 HDC 在线和授权状态。
                    }
                }
                group.addTask { .android(Result { try Adb(directory: AndroidRuntime.directory).devices() }) } // 无需等待鸿蒙工具返回。
                for await result in group {
                    guard let self, self.refreshID == request else { continue } // 较旧刷新不能覆盖最新结果。
                    switch result {
                    case .harmony(.success(let targets)): self.updateHarmonyDevices(targets)
                    case .android(.success(let targets)): self.updateAndroidDevices(targets)
                    case .harmony(.failure(let error)):
                        self.updateHarmonyDevices([]) // 枚举失败时移除过期的在线状态。
                        issues.append("HarmonyOS：\(error.localizedDescription)")
                    case .android(.failure(let error)):
                        self.updateAndroidDevices([])
                        issues.append("Android：\(error.localizedDescription)")
                    }
                }
            }
            guard let self, self.refreshID == request else { return } // 只结束当前这一轮刷新。
            self.refreshID = nil // 允许菜单发起下一轮。
            self.discoveryMessage = issues.isEmpty ? nil : issues.joined(separator: "\n") // 成功刷新时清除旧提示。
            self.isDiscovering = false
        }
    }

    private enum DiscoveryResult: Sendable { // 每个后端完成时独立更新菜单。
        case harmony(Result<[DeviceInfo], Error>)
        case android(Result<[AndroidDevice], Error>)
    }

    func updateHarmonyDevices(_ targets: [DeviceInfo]) {
        let available = targets.filter(\.canConnect).map { KnownDevice(platform: .harmony, serial: $0.serial, wasAvailable: true) }
        updateIdentities(for: available, platform: .harmony) // 读取稳定身份独立于投屏启动。
        rememberAvailable(available)
        if devices != targets { devices = targets } // 无变化的轮询不触发视图更新。
    }

    func updateAndroidDevices(_ targets: [AndroidDevice]) {
        let available = targets.filter(\.canConnect).map { // 未授权和离线设备仍显示在当前列表。
            KnownDevice(platform: .android, serial: $0.serial, model: $0.model, wasAvailable: true)
        }
        updateIdentities(for: available, platform: .android)
        rememberAvailable(available)
        if androidDevices != targets { androidDevices = targets } // 避免相同枚举反复刷新 SwiftUI。
    }

    var currentDevices: [DeviceListEntry] {
        let harmony = devices.filter { $0.state != "offline" }.map { target in // 已脱离的设备出现在折叠历史。
            let device = profile(for: KnownDevice(platform: .harmony, serial: target.serial))
            return DeviceListEntry(device: device, unavailableReason: target.canConnect ? nil : target.statusText, transport: target.transport)
        }
        let android = androidDevices.filter { $0.state != "offline" }.map { target in
            let device = profile(for: KnownDevice(platform: .android, serial: target.serial, model: target.model))
            return DeviceListEntry(device: device, unavailableReason: target.canConnect ? nil : target.statusText, transport: target.transport)
        }
        return harmony + android // 菜单与主窗口采用同一顺序。
    }

    var screenLinkDevices: [KnownDevice] {
        var seen = Set<String>()
        return currentDevices.compactMap { entry in
            guard entry.unavailableReason == nil, seen.insert(entry.device.id).inserted else { return nil }
            return entry.device // 已识别为同一设备的 USB 和无线连接只执行一次。
        }
    }

    var historicalDevices: [KnownDevice] {
        let currentIDs = Set(currentDevices.map(\.device.id)) // 当前设备不会同时出现在历史。
        return knownDevices.values.filter {
            (ReleaseFeatures.harmonyEnabled || $0.platform == .android) && $0.wasAvailable && !currentIDs.contains($0.id)
        }.sorted { $0.serial < $1.serial } // 仅过滤视图，保留本机已有设备记录。
    }

    func setCustomName(_ name: String, for controller: DeviceController) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines) // 留空恢复默认设备名。
        var record = profile(for: KnownDevice(platform: controller.platform, serial: controller.serial, model: controller.deviceModel))
        record.customName = value.isEmpty ? nil : value
        if identityRequests[controller.id] != nil, resolvedKeys[controller.id] == nil {
            namesEditedWhileIdentifying.insert(controller.id) // 已提交的名称优先于识别后载入的旧值。
        }
        var records = knownDevices
        records[record.id] = record // 保留该设备的历史和默认型号。
        saveKnownDevices(records)
        controller.updateCustomName(record.customName)
        for (route, key) in resolvedKeys where key == record.id && route != controller.id {
            controllers[route]?.updateCustomName(record.customName) // 同一设备的其他调试连接也即时更新。
        }
    }

    private func profile(for device: KnownDevice) -> KnownDevice {
        var record = knownDevices[storedKey(for: device)] ?? device // 已核对过的 USB 标识仍能恢复本机保存的名字。
        record.serial = device.serial // 现有记录可能来自另一条调试链路。
        return record
    }

    private func storedKey(for device: KnownDevice) -> String {
        if let resolved = resolvedKeys[device.routeID] { return resolved } // 优先使用本次接入实际读取的硬件身份。
        if !device.serial.contains(":"),
           let saved = knownDevices.values.first(where: { $0.platform == device.platform && ($0.serial == device.serial || $0.knownRoutes?.contains(device.serial) == true) }) {
            return saved.id // USB 序列号已在历史中核对过时，硬件查询失败仍能恢复名称。
        }
        return device.routeID // 无线地址需要重新核对，避免同一 IP 被另一台设备复用后串名。
    }

    private func updateIdentities(for available: [KnownDevice], platform: DevicePlatform) {
        guard discoverDevices else { return } // 离屏运行仍可通过枚举夹具验证界面。
        let current = Set(available.map(\.routeID))
        let prefix = platform.identifier(serial: "")
        for route in Array(identityRequests.keys) where route.hasPrefix(prefix) && !current.contains(route) {
            identityRequests[route] = nil // 后端断开后作废本轮查询，已打开的窗口仍可修改原设备名称。
            namesEditedWhileIdentifying.remove(route)
        }
        for device in available where identityRequests[device.routeID] == nil {
            let request = UUID()
            identityRequests[device.routeID] = request
            resolvedKeys[device.routeID] = nil // 同一无线地址重新出现时重新验证设备身份。
            let fallback = profile(for: device)
            if let controller = controllers[device.routeID] {
                controller.updateCustomName(fallback.customName)
                if !controller.connected, !controller.busy { controller.deviceModel = fallback.model } // 避免把前一台设备的型号留在同一地址。
            }
            let hdc = self.hdc
            Task { [weak self] in
                let key = await Task.detached(priority: .utility) { Self.readHardwareKey(for: device, hdc: hdc) }.value // 调试查询不能阻塞列表或投屏。
                guard let self, let key, self.identityRequests[device.routeID] == request else { return } // 地址重连后忽略上一台设备的迟到结果。
                self.adoptHardwareKey(key, for: device)
            }
        }
    }

    nonisolated private static func readHardwareKey(for device: KnownDevice, hdc: Hdc) -> String? {
        let serial = device.serial
        let raw: String
        switch device.platform {
        case .harmony:
            guard let output = try? hdc.shell("bm get --udid", serial: serial, timeout: 3),
                  let udid = output.split(whereSeparator: \.isWhitespace).first(where: { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
            else { return nil } // 仅接受符合华为调试 UDID 格式的值。
            raw = String(udid).lowercased() // 兼容按字符切分得到的序列，再统一大小写。
        case .android:
            let adb = Adb(directory: AndroidRuntime.directory)
            guard let output = try? adb.run(["-s", serial, "shell", "getprop", "ro.serialno"], timeout: 3) else { return nil }
            raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !["", "unknown", "null"].contains(raw.lowercased()),
                  raw.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
            else { return nil } // 排除 ADB 错误文本和未提供序列号的设备。
        }
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined() // 本地保存摘要，无需保存原始硬件标识。
        return device.platform.identifier(serial: "hardware:" + digest)
    }

    func adoptHardwareKey(_ key: String, for device: KnownDevice) {
        var records = knownDevices
        let fallback = records.removeValue(forKey: device.routeID) // 迁移本次接入期间创建的临时记录。
        var record = records[key] ?? fallback ?? device
        record.hardwareKey = key
        record.wasAvailable = true
        var routes = Set(record.knownRoutes ?? [record.serial]) // 迁移旧记录并保留多条已验证连接。
        routes.insert(device.serial)
        record.knownRoutes = routes.sorted()
        if namesEditedWhileIdentifying.remove(device.routeID) != nil { record.customName = fallback?.customName }
        if record.model.isEmpty { record.model = fallback?.model ?? device.model }
        records[key] = record
        resolvedKeys[device.routeID] = key
        saveKnownDevices(records)
        if let controller = controllers[device.routeID] {
            controller.updateCustomName(record.customName)
            if !record.model.isEmpty { controller.deviceModel = record.model } // 恢复上次读取的默认型号。
        }
    }

    private func rememberAvailable(_ available: [KnownDevice], authoritativeModel: Bool = false) {
        var records = knownDevices // 一次枚举中的多台设备合并写入。
        for device in available {
            let key = storedKey(for: device)
            var record = records[key] ?? device
            record.wasAvailable = true
            if !device.model.isEmpty && (authoritativeModel || record.model.isEmpty || record.model == record.serial) {
                record.model = device.model // 后台枚举只能补全型号，不能覆盖采集端读取的默认名称。
                if let controller = controllers[device.routeID], controller.deviceModel != record.model {
                    controller.deviceModel = record.model // 刷新设备后同步主窗口和状态栏。
                }
            }
            records[key] = record // 保留自定义名。
        }
        saveKnownDevices(records)
    }

    private func saveKnownDevices(_ records: [String: KnownDevice]) {
        guard records != knownDevices, let data = try? JSONEncoder().encode(records) else { return } // 只持久化实际变化。
        knownDevices = records
        defaults.set(data, forKey: Self.knownDevicesKey)
    }

    func controller(for serial: String, platform: DevicePlatform = .harmony, model: String = "") -> DeviceController {
        let key = platform.identifier(serial: serial) // 不同系统的同序列号不能共享状态。
        if let existing = controllers[key] {
            existing.update(settings: settings)
            return existing
        }
        let record = profile(for: KnownDevice(platform: platform, serial: serial, model: model)) // 根据已确认的设备身份恢复名称。
        let controller = DeviceController(serial: serial, settings: settings, platform: platform, model: model.isEmpty ? record.model : model, customName: record.customName) { [weak self] model in
            self?.rememberAvailable([KnownDevice(platform: platform, serial: serial, model: model, wasAvailable: true)], authoritativeModel: true) // 保存协议实际返回的默认名称。
        }
        controller.initialWindowPin = { [weak self] in self?.isAlwaysOnTopAtLaunch(id: key) ?? false }
        controllers[key] = controller
        return controller
    }

    func connect(serial: String) {
        controller(for: serial).connect()
    }

    var batchConnectionTargets: [DeviceListEntry] {
        // 已核对为同一台设备的 USB/无线连接只开一个投屏，优先使用 USB。
        let entries = currentDevices.sorted { ($0.transport == .usb ? 0 : 1, $0.id) < ($1.transport == .usb ? 0 : 1, $1.id) }
        let inUse = Set(entries.filter { controllers[$0.id]?.hasPendingOrOpenConnection == true }.map(\.device.id))
        var seen = inUse
        return entries.filter { $0.unavailableReason == nil && seen.insert($0.device.id).inserted }
    }

    func connectWireless() {
        let address = wirelessAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        guard !wirelessBusy else { return } // 同一时刻只处理一次配对或连接。
        let platform = ReleaseFeatures.harmonyEnabled ? wirelessPlatform : .android // 固定本次选择与发行范围。
        let request = UUID() // 后发请求的结果优先。
        wirelessID = request
        wirelessBusy = true // 等待期间保留界面响应但禁用重复提交。
        let hdc = self.hdc
        Task { [weak self] in
            let result = await Task.detached { Result { // 后台使用所选平台对应的原生连接工具。
                if platform == .harmony {
                    guard FileManager.default.isExecutableFile(atPath: hdc.binary.path) else {
                        throw HdcError("请先按 README 配置本机 HarmonyOS 组件。")
                    }
                    try hdc.connectWireless(address) // 使用本机 HDC 连接设备。
                }
                else { try Adb(directory: AndroidRuntime.directory).connect(address) } // Android 只连接已配对或 USB 授权的调试端口。
            } }.value // 无线握手不阻塞主线程。
            guard let self, self.wirelessID == request else { return }
            self.wirelessBusy = false // 成功和失败均恢复入口。
            switch result {
            case .success:
                if platform == .harmony { UserDefaults.standard.set(address, forKey: "wireless.address") } // 不覆盖已有鸿蒙地址偏好。
                self.wirelessMessage = "\(platform.rawValue) 无线连接完成" // 仍以随后真实枚举结果为准。
                self.refreshDevices(replacingInFlight: true) // 无线连接完成后重新枚举，避免沿用提交前的结果。
            case .failure(let error):
                self.errorMessage = "无线连接失败：\(error.localizedDescription)"
            }
        }
    }

    func pairAndroid() { // 只有用户点击配对按钮时才提交配对码。
        guard !wirelessBusy else { return } // 防止与连接命令交叉覆盖状态。
        let address = pairingAddress // 固定本次配对端口。
        let code = pairingCode // 仅捕获本次后台调用所需的值。
        pairingCode = "" // 提交后立即清空界面与持久状态。
        wirelessBusy = true // 后台等待时禁用重复提交。
        Task { [weak self] in // 工具调用不占用 UI 线程。
            let result = await Task.detached { Result { try Adb(directory: AndroidRuntime.directory).pair(address, code: code) } }.value // 用户授权由 Android 系统处理。
            guard let self else { return } // 主窗口关闭后不强行展示提示。
            self.wirelessBusy = false // 无论是否配对成功都恢复操作。
            switch result { // 配对不能伪装成已经建立设备连接。
            case .success: self.wirelessMessage = "配对成功，请填写无线调试主页的连接 IP:端口，再点连接。" // Android 配对端口与连接端口通常不同。
            case .failure(let error): self.errorMessage = "Android 配对失败：\(error.localizedDescription)" // 不主动记录或展示配对码。
            }
        }
    }

    func update(settings newValue: MirrorSettings) {
        settings = newValue
        settings.save(to: defaults)
        for controller in controllers.values {
            controller.update(settings: newValue)
        }
    }

    private static let devicePinKey = "windows.alwaysOnTopByDevice" // 独立偏好与全局连接设置分开存储。

    func isAlwaysOnTopAtLaunch(for controller: DeviceController) -> Bool {
        isAlwaysOnTopAtLaunch(id: controller.id)
    }

    private func isAlwaysOnTopAtLaunch(id: String) -> Bool {
        let pins = defaults.dictionary(forKey: Self.devicePinKey)
        return settings.alwaysOnTop || (pins?[id] as? Bool ?? false) // 全局开启优先，关闭后保留手动设置。
    }

    func restoreAlwaysOnTop(for controller: DeviceController) {
        controller.isAlwaysOnTop = isAlwaysOnTopAtLaunch(for: controller) // 启动时恢复本设备独立的置顶设置。
    }

    func toggleAlwaysOnTop(for controller: DeviceController) {
        setAlwaysOnTop(!controller.isAlwaysOnTop, for: [controller])
    }

    var isApplyingWindowPin: Bool {
        controllers.values.contains { $0.isRestartingForWindowPin }
    }

    func setAlwaysOnTop(_ enabled: Bool, for targets: [DeviceController], applyToRunningAndroid: Bool = false) {
        var pins = defaults.dictionary(forKey: Self.devicePinKey) ?? [:]
        let changed = targets.filter { $0.isAlwaysOnTop != enabled }
        for controller in targets {
            controller.isAlwaysOnTop = enabled
            pins[controller.id] = enabled // 使用平台和序列号，保留其他设备的选择。
        }
        defaults.set(pins, forKey: Self.devicePinKey)
        if applyToRunningAndroid {
            changed.forEach { $0.applyWindowPinChange() } // 官方客户端在启动时读取置顶选项。
        }
    }

    func shutdown(completion: @escaping () -> Void) { // Mac 退出时同时清理两类设备，不等待用户手机指令返回界面。
        let group = DispatchGroup() // 只等待已有控制器自己的工作队列。
        for controller in controllers.values { // 包括已经关闭但清理仍排队的窗口。
            group.enter() // 每台设备独立并行释放。
            controller.disconnect { group.leave() } // 不停止共享 ADB 或 hdc 服务。
        }
        group.notify(queue: .main, execute: completion) // 完成后才让 AppKit 结束进程。
    }

    func logLine(_ line: String) {
        // Reserved for a future shared log console.
    }
}

enum WirelessPlatform: String, CaseIterable, Identifiable, Codable { // 界面选择不会改变现有鸿蒙设备数据结构。
    case harmony = "鸿蒙" // 使用 hdc tconn。
    case android = "Android" // 使用随包 ADB connect/pair。
    static let defaultPlatform: Self = ReleaseFeatures.harmonyEnabled ? .harmony : .android
    var id: String { rawValue } // 为 Picker 提供稳定标识。
}
