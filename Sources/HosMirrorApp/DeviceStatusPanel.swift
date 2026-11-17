import AppKit
import SwiftUI
import HosMirrorCore

struct DeviceStatusPanel: View {
    @ObservedObject var model: DeviceStatusPanelModel
    @ObservedObject var store: SessionStore
    @State private var expandedDevices: Set<String> = [] // 收起弹出窗口后继续保留设备展开状态。
    @State private var expandedHistory: Set<DevicePlatform> = []
    @State private var naturalHeight: CGFloat = 290

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                deviceList
                if let message = store.discoveryMessage {
                    Text("部分设备状态读取失败").foregroundStyle(.secondary).help(message)
                }
                Divider().padding(.vertical, 4)
                heading("批量操作")
                PanelCommand(title: "连接所有可投屏设备", symbol: "rectangle.on.rectangle", action: model.connectAll)
                    .disabled(!model.availability.connectAll)
                forSystemActions { model.perform($0) }
                    .disabled(!model.availability.systemActions)
                PanelSwitch(title: "窗口置顶", symbol: "pin",
                            isOn: Binding(get: { model.availability.pinned }, set: { model.setPin($0) }))
                    .disabled(!model.availability.pinEnabled)
                PanelSwitch(title: "投屏窗口磁吸", symbol: "rectangle.split.2x1",
                            isOn: Binding(get: { model.availability.snapping }, set: model.setSnapping))
                    .help("拖动标题栏移动整组，按住 Option 拖动换序，双击标题栏最大化。")
                if let failure = model.failure {
                    Text("上次操作有设备未完成").foregroundStyle(.secondary).help(failure)
                }
                Divider().padding(.vertical, 4)
                PanelSwitch(title: "连接后自动置顶窗口", symbol: "pin",
                            isOn: Binding(get: { store.settings.alwaysOnTop }, set: model.setAutomaticPin))
                PanelCommand(title: "设置…", symbol: "gearshape", action: model.showSettings)
                PanelCommand(title: "退出 Screen Annex", symbol: "rectangle.portrait.and.arrow.right", action: model.quit)
            }
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 258, height: min(naturalHeight, model.heightLimit))
        .environment(\.appearsActive, true) // 只使用 SwiftUI 提供的窗口控件外观和系统强调色。
    }

    @ViewBuilder private var deviceList: some View {
        let current = store.currentDevices
        let history = store.historicalDevices
        let platforms = DevicePlatform.allCases.filter { platform in
            current.contains { $0.device.platform == platform } || history.contains { $0.platform == platform }
        }
        if current.isEmpty {
            Text("当前没有检测到设备").foregroundStyle(.secondary).padding(.vertical, 4)
        }
        ForEach(platforms, id: \.self) { platform in
            if platform != platforms.first { Divider().padding(.vertical, 4) }
            if platforms.count > 1 { heading(platform.titlePrefix) }
            ForEach(current.filter { $0.device.platform == platform }) { entry in
                let device = entry.device
                let controller = store.controller(for: device.serial, platform: platform, model: device.model)
                DevicePanelRow(entry: entry, controller: controller, model: model,
                               expanded: expandedDevices.contains(entry.id)) {
                    toggleExpansion(entry.id, in: &expandedDevices)
                }
            }
            let previous = history.filter { $0.platform == platform }
            if !previous.isEmpty {
                DisclosureGroup("历史设备（\(previous.count)）",
                                isExpanded: Binding(get: { expandedHistory.contains(platform) },
                                                    set: { _ in toggleExpansion(platform, in: &expandedHistory) })) {
                    ForEach(previous) { device in
                        Text(device.customName ?? (device.model.isEmpty ? device.serial : device.model))
                            .foregroundStyle(.secondary).lineLimit(1).padding(.leading, 16)
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func toggleExpansion<Value: Hashable>(_ value: Value, in selection: inout Set<Value>) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if !selection.insert(value).inserted { selection.remove(value) }
        }
    }
}

private struct DevicePanelRow: View {
    let entry: DeviceListEntry
    @ObservedObject var controller: DeviceController
    @ObservedObject var model: DeviceStatusPanelModel
    let expanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        let name = controller.displayName.isEmpty ? entry.device.serial : controller.displayName
        let on = model.connectionIsOn(controller)
        let available = entry.unavailableReason == nil
        PanelSwitch(title: name, symbol: entry.transport.map { $0 == .usb ? "cable.connector" : "wifi" },
                    isOn: Binding(get: { model.connectionIsOn(controller) }, set: { model.setConnection($0, id: entry.id) }),
                    enabled: on || available, expand: toggleExpanded, expanded: expanded)
            .help(entry.unavailableReason ?? entry.status(for: controller))
        if expanded {
            VStack(alignment: .leading, spacing: 3) {
                forSystemActions { model.perform($0, id: entry.id) }
                    .disabled(!available || model.actionRunning)
                PanelSwitch(title: "窗口置顶", symbol: "pin",
                            isOn: Binding(get: {
                                on ? controller.isAlwaysOnTop : model.store.isAlwaysOnTopAtLaunch(for: controller)
                            }, set: { model.setPin($0, id: entry.id) }))
                    .disabled(!available || controller.busy || controller.isRestartingForWindowPin || model.actionRunning)
            }
            .padding(.leading, 12)
        }
    }
}

private func forSystemActions(_ run: @escaping (DeviceSystemAction) -> Void) -> some View {
    ForEach(DeviceSystemAction.allCases, id: \.self) { action in
        let icon: String = switch action {
        case .lock: "lock"
        case .wake: "sunrise"
        case .light: "sun.max"
        case .dark: "moon"
        }
        PanelCommand(title: action.title, symbol: icon) { run(action) }
    }
}

private struct PanelSwitch: View {
    let title: String
    let symbol: String?
    @Binding var isOn: Bool
    var enabled = true
    var expand: (() -> Void)?
    var expanded = false

    var body: some View {
        HStack(spacing: 8) {
            if let expand {
                PanelCommand(title: title, symbol: symbol, action: expand)
                    .accessibilityValue(expanded ? "已展开" : "已折叠")
            } else {
                PanelLabel(title: title, symbol: symbol).accessibilityHidden(true)
            }
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.accentColor)
                .disabled(!enabled)
        }
        .padding(.horizontal, 5)
    }
}

private struct PanelCommand: View {
    let title: String
    let symbol: String?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            PanelLabel(title: title, symbol: symbol)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .opacity(enabled ? 1 : 0.55)
        .padding(.horizontal, 5)
        .background(hovered && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovered = $0 }
    }
}

private struct PanelLabel: View {
    let title: String
    let symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).frame(width: 16).accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 16, height: 1).accessibilityHidden(true)
            }
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
