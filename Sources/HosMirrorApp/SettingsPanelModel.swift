import Combine
import Foundation
import HosMirrorCore

/// 设置窗口只读取快照并提交操作，设备连接和偏好仍由菜单栏进程管理。
struct SettingsPanelSnapshot: Codable, Equatable {
    struct Device: Codable, Equatable, Identifiable {
        let id: String
        let serial: String
        let platform: DevicePlatform
        let name: String
        let customName: String?
        let status: String
        let canConnect: Bool
        let pinnedAtLaunch: Bool
    }

    var settings = MirrorSettings()
    var devices: [Device] = []
    var discoveryMessage: String?
    var wirelessAddress = ""
    var wirelessBusy = false
    var wirelessMessage: String?
    var errorMessage: String?
}

enum SettingsPanelCommand: Codable {
    case refresh
    case mirror(String)
    case rename(String, String)
    case pin(String, Bool)
    case update(MirrorSettings, previous: MirrorSettings)
    case connectWireless(WirelessPlatform, String)
    case pairAndroid(String, String)
    case clearError
}

enum SettingsPanelEvent: Codable {
    case snapshot(SettingsPanelSnapshot)
    case showSettings
    case showLicenses
}

@MainActor
final class SettingsPanelModel: ObservableObject {
    @Published var snapshot = SettingsPanelSnapshot()
    let send: (SettingsPanelCommand) -> Void

    init(send: @escaping (SettingsPanelCommand) -> Void) {
        self.send = send
    }

    func update(settings: MirrorSettings) {
        let previous = snapshot.settings
        guard settings != previous else { return }
        snapshot.settings = settings // 连续编辑时，下一次操作以当前界面值为基准。
        send(.update(settings, previous: previous))
    }
}

extension SessionStore {
    var settingsPanelSnapshot: SettingsPanelSnapshot {
        SettingsPanelSnapshot(settings: settings, devices: currentDevices.map { entry in
            let device = entry.device
            let controller = controller(for: device.serial, platform: device.platform, model: device.model)
            let name = controller.displayName.isEmpty ? device.serial : controller.displayName
            return .init(id: entry.id, serial: device.serial, platform: device.platform,
                         name: name, customName: controller.customName, status: entry.status(for: controller),
                         canConnect: entry.unavailableReason == nil, pinnedAtLaunch: isAlwaysOnTopAtLaunch(for: controller))
        }, discoveryMessage: discoveryMessage, wirelessAddress: wirelessAddress, wirelessBusy: wirelessBusy,
           wirelessMessage: wirelessMessage, errorMessage: errorMessage)
    }

    func applySettingsPanelCommand(_ command: SettingsPanelCommand) {
        switch command {
        case .refresh:
            refreshDevices()
        case .mirror(let id):
            guard let entry = currentDevices.first(where: { $0.id == id && $0.unavailableReason == nil }) else { return }
            let device = entry.device
            MirrorWindowManager.shared.open(serial: device.serial, store: self, platform: device.platform, model: device.model)
        case .rename(let id, let name):
            guard let entry = currentDevices.first(where: { $0.id == id }) else { return }
            setCustomName(name, for: controller(for: entry.device.serial, platform: entry.device.platform, model: entry.device.model))
        case .pin(let id, let enabled):
            guard let entry = currentDevices.first(where: { $0.id == id && $0.device.platform == .android }) else { return }
            setAlwaysOnTop(enabled, for: [controller(for: entry.device.serial, platform: .android, model: entry.device.model)])
        case .update(let new, let previous):
            var merged = settings
            // 只应用设置窗口改过的字段，保留菜单栏同时提交的其他偏好。
            if new.frameRate != previous.frameRate { merged.frameRate = new.frameRate }
            if new.bitRateMbps != previous.bitRateMbps { merged.bitRateMbps = new.bitRateMbps }
            if new.scale != previous.scale { merged.scale = new.scale }
            if new.autoReconnect != previous.autoReconnect { merged.autoReconnect = new.autoReconnect }
            if new.alwaysOnTop != previous.alwaysOnTop { merged.alwaysOnTop = new.alwaysOnTop }
            if new.lockPhonesWithMac != previous.lockPhonesWithMac { merged.lockPhonesWithMac = new.lockPhonesWithMac }
            if new.unlockPhonesWithMac != previous.unlockPhonesWithMac { merged.unlockPhonesWithMac = new.unlockPhonesWithMac }
            if new.appearancePreference != previous.appearancePreference { merged.appearancePreference = new.appearancePreference }
            if new.fileDropDirectory != previous.fileDropDirectory { merged.fileDropDirectory = new.fileDropDirectory }
            if new.androidFileDropDirectory != previous.androidFileDropDirectory { merged.androidFileDropDirectory = new.androidFileDropDirectory }
            if merged != settings { update(settings: merged) }
        case .connectWireless(let platform, let address):
            wirelessPlatform = platform
            wirelessAddress = address
            connectWireless()
        case .pairAndroid(let address, let code):
            pairingAddress = address
            pairingCode = code
            pairAndroid()
        case .clearError:
            errorMessage = nil
        }
    }
}
