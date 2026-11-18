import SwiftUI
import HosMirrorCore // 目录编辑沿用文件传输的路径校验。

struct SettingsView: View {
    @ObservedObject var panel: SettingsPanelModel
    @State private var directoriesExpanded = false // 保持首页精简，手动目录编辑按需展开。
    @State private var harmonyDraft: String? // 只保存尚未提交的输入，空值时显示当前设置。
    @State private var androidDraft: String?
    @State private var directoryError: String? // 无效路径留在表单中供修正。

    var body: some View {
        Form {
            Section("投屏") {
                Toggle("自动重连", isOn: setting(\.autoReconnect))
                Toggle("连接后自动置顶窗口", isOn: setting(\.alwaysOnTop))
                    .help("开启后，新连接的投屏窗口自动置顶。关闭后按各设备保存的置顶设置打开。")
                if ReleaseFeatures.harmonyEnabled {
                    Picker("鸿蒙投屏窗口外观", selection: setting(\.mirrorAppearance)) {
                        ForEach(MirrorAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance) // 复用投屏窗口支持的系统外观选项。
                        }
                    }
                }
            }

            Section {
                Toggle("电脑锁屏时锁定已连接的手机", isOn: setting(\.lockPhonesWithMac))
                Toggle("电脑解锁时解锁已连接的手机", isOn: setting(\.unlockPhonesWithMac))
            } header: {
                Text("手机锁屏联动")
            } footer: {
                Text("手机需要密码、指纹或人脸验证时，仍由手机完成验证。")
            }

            if ReleaseFeatures.harmonyEnabled { harmonyQuality }

            Section("文件传输") {
                DisclosureGroup("手机保存目录", isExpanded: $directoriesExpanded) {
                    directoryFields
                }
            }
        }
        .formStyle(.grouped) // 采用系统表单的分组、行距、分隔线和语义颜色。
        .toggleStyle(.switch) // 用同一种原生开关表达即时保存的布尔设置。
        .pickerStyle(.menu) // 下拉选择随系统对齐，保留清晰的字段名称。
        .frame(maxWidth: 680) // 大窗口中保持标签和控件的距离适中。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var harmonyQuality: some View {
        Section {
            Picker("目标帧率", selection: setting(\.frameRate)) {
                ForEach([15, 30, 60], id: \.self) { rate in
                    Text("\(rate) fps").tag(rate)
                }
            }
            Picker("目标码率", selection: setting(\.bitRateMbps)) {
                ForEach([2, 4, 8, 12, 16, 20, 24], id: \.self) { rate in
                    Text("\(rate) Mbps").tag(rate)
                }
            }
            Picker("分辨率缩放", selection: setting(\.scale)) {
                Text("原始").tag(1.0)
                Text("50%").tag(0.5)
            }
            Button("恢复平衡画质") {
                let balanced = MirrorSettings() // 只复位鸿蒙画质，保留连接、置顶和目录偏好。
                var settings = panel.snapshot.settings
                settings.frameRate = balanced.frameRate
                settings.bitRateMbps = balanced.bitRateMbps
                settings.scale = balanced.scale
                panel.update(settings: settings)
            }
        } header: {
            Text("鸿蒙画质")
        } footer: {
            Text("平衡设置为原始分辨率、30 fps、16 Mbps。更改在下次连接时生效。Android 使用 scrcpy 原生画质。")
        }
    }

    private var directoryFields: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                if ReleaseFeatures.harmonyEnabled {
                    GridRow {
                        Text("鸿蒙").accessibilityHidden(true) // 输入框本身已提供同名辅助功能标签。
                        TextField("鸿蒙", text: directoryDraft($harmonyDraft, current: \.fileDestination))
                            .labelsHidden()
                    }
                }
                GridRow {
                    Text("Android").accessibilityHidden(true)
                    TextField("Android", text: directoryDraft($androidDraft, current: \.androidFileDestination))
                        .labelsHidden()
                }
            }
            if let directoryError {
                Text(directoryError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("保存目录", action: saveDirectories)
                .disabled(harmonyDraft == nil && androidDraft == nil)
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit(saveDirectories) // 输入路径后也可以用回车提交。
        .padding(.vertical, 4)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<MirrorSettings, Value>) -> Binding<Value> {
        Binding {
            panel.snapshot.settings[keyPath: keyPath] // 每次读取共享存储中的最新值。
        } set: { value in
            var settings = panel.snapshot.settings // 单项更新保留菜单或其他窗口刚修改的设置。
            settings[keyPath: keyPath] = value
            panel.update(settings: settings) // 复用持久化和现有投屏窗口的同步入口。
        }
    }

    private func directoryDraft(_ draft: Binding<String?>, current keyPath: KeyPath<MirrorSettings, String>) -> Binding<String> {
        Binding {
            draft.wrappedValue ?? panel.snapshot.settings[keyPath: keyPath]
        } set: { value in
            draft.wrappedValue = value == panel.snapshot.settings[keyPath: keyPath] ? nil : value
            directoryError = nil // 用户修改输入后清除上一轮校验结果。
        }
    }

    private func saveDirectories() {
        guard harmonyDraft != nil || androidDraft != nil else { return } // 回车时没有修改就无需写入。
        var settings = panel.snapshot.settings // 提交时合并最新设置，避免覆盖窗口外观等即时偏好。
        var platform = "鸿蒙" // 校验错误指出需要修改的字段。
        do {
            if let harmonyDraft {
                settings.fileDestination = try FileDelivery.validateDirectory(harmonyDraft)
            }
            platform = "Android"
            if let androidDraft {
                settings.androidFileDestination = try FileDelivery.validateDirectory(androidDraft)
            }
        } catch {
            directoryError = "\(platform)：\(error.localizedDescription)"
            return // 任一路径无效时，两项均不写入。
        }
        panel.update(settings: settings)
        harmonyDraft = nil // 提交后显示规范化的路径。
        androidDraft = nil
        directoryError = nil
    }
}
