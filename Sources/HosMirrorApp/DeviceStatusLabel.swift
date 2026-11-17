import SwiftUI // 主窗口保留原有设备名称和状态布局。

struct DeviceStatusLabel: View {
    let device: SettingsPanelSnapshot.Device

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(device.name)
                .lineLimit(1)
                .truncationMode(.middle) // 长设备标识保留首尾以便区分。
            if device.status != "可连接" {
                Text(device.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .help(device.serial) // 同型号或同名设备仍可区分。
    }
}
