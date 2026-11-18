import SwiftUI
import AppKit
import HosMirrorCore

struct ContentView: View {
    @ObservedObject var panel: SettingsPanelModel
    @State private var showWireless = false // 侧栏只放入口，配对表单在原生面板中展开。
    @State private var wirelessPlatform = WirelessPlatform.defaultPlatform
    @State private var wirelessAddress = ""
    @State private var pairingAddress = ""
    @State private var pairingCode = ""

    var body: some View {
        let devices = panel.snapshot.devices
        let platforms = DevicePlatform.allCases.filter { platform in
            devices.contains { $0.platform == platform } // 空分组不占用侧栏空间。
        }
        NavigationSplitView {
            VStack(spacing: 0) {
                List {
                    ForEach(platforms, id: \.self) { platform in
                        Section(platform.titlePrefix) {
                            ForEach(devices.filter { $0.platform == platform }) { device in
                                HStack(spacing: 10) {
                                    Image(systemName: platform == .harmony ? "iphone" : "smartphone")
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true) // 设备名和操作已提供需要朗读的信息。
                                    DeviceStatusLabel(device: device)
                                    Spacer(minLength: 4)
                                    Button("投屏") {
                                        panel.send(.mirror(device.id))
                                    }
                                    .buttonStyle(.bordered) // 设备列表中的同级操作使用系统普通按钮。
                                    .controlSize(.small)
                                    .disabled(!device.canConnect)
                                }
                                .padding(.vertical, 2)
                                .contextMenu {
                                    Button("自定义设备名称…") {
                                        presentRename(device)
                                    }
                                    if platform == .android {
                                        Button(device.pinnedAtLaunch ? "下次投屏取消置顶" : "下次投屏保持置顶") {
                                            panel.send(.pin(device.id, !device.pinnedAtLaunch))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .overlay {
                    if devices.isEmpty {
                        ContentUnavailableView(
                            "未发现设备",
                            systemImage: "cable.connector.slash",
                            description: Text("请连接手机，并在手机上允许 USB 调试。")
                        )
                    }
                }

                if let message = panel.snapshot.discoveryMessage { // 部分后端失败不能弹窗挡住另一种设备。
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(10) // 完整保留工具返回的失败原因。
                }
                Divider()
                Button {
                    wirelessAddress = panel.snapshot.wirelessAddress
                    showWireless = true
                } label: {
                    Label("无线连接…", systemImage: "wifi")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 248, ideal: 256, max: 380) // 左侧给设备和连接，右侧给设置。
            .navigationTitle("设备")
            .toolbar {
                Button {
                    panel.send(.refresh)
                } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("刷新设备列表")
            }
        } detail: {
            SettingsView(panel: panel) // 进入主窗口即可修改设置。
                .navigationTitle("设置")
        }
        .sheet(isPresented: $showWireless) {
            VStack(alignment: .leading, spacing: 16) {
                Text("无线连接").font(.headline)
                wirelessBox
                HStack {
                    if panel.snapshot.wirelessBusy {
                        ProgressView().controlSize(.small).accessibilityLabel("正在连接或配对")
                    }
                    Spacer()
                    Button("关闭") { showWireless = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(panel.snapshot.wirelessBusy)
                }
            }
            .padding(20)
            .frame(width: 380) // 宽度容纳独立的连接和配对输入，侧栏尺寸无需改变。
            .fixedSize(horizontal: false, vertical: true)
            .interactiveDismissDisabled(panel.snapshot.wirelessBusy) // 提交后保留面板以展示结果。
            .alert("无线连接", isPresented: Binding(
                get: { panel.snapshot.errorMessage != nil },
                set: { if !$0 { panel.send(.clearError) } }
            )) {
                Button("好") { panel.send(.clearError) }
            } message: {
                Text(panel.snapshot.errorMessage ?? "")
            }
        }
    }

    private func presentRename(_ device: SettingsPanelSnapshot.Device) {
        MirrorWindowManager.presentRename(on: NSApp.keyWindow, current: device.customName,
                                          placeholder: device.name) { name in panel.send(.rename(device.id, name)) }
    }

    private func connectWireless() {
        panel.send(.connectWireless(wirelessPlatform, wirelessAddress))
    }

    private var wirelessBox: some View { // 原生控件区分 Android 的配对端口与连接端口。
        VStack(alignment: .leading, spacing: 8) {
            if ReleaseFeatures.harmonyEnabled {
                Picker("设备系统", selection: $wirelessPlatform) { // 用户明确选择所使用的连接工具。
                    ForEach(WirelessPlatform.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden() // 选择器仍有辅助功能标签。
            }
            HStack(spacing: 6) {
                TextField("连接 IP:端口", text: $wirelessAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { connectWireless() }
                Button("连接") { connectWireless() }
                    .disabled(wirelessAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if wirelessPlatform == .android { // Android 11+ 配对不是每次都需要执行。
                DisclosureGroup("首次连接时配对") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("配对 IP:端口", text: $pairingAddress).textFieldStyle(.roundedBorder) // 配对弹窗提供专用端口。
                        HStack {
                            SecureField("六位配对码", text: $pairingCode).textFieldStyle(.roundedBorder) // 不显示或保存明文配对码。
                            Button("配对") {
                                panel.send(.pairAndroid(pairingAddress, pairingCode))
                                pairingCode = "" // 提交后立即从设置窗口清除。
                            }
                        }
                        Text("在手机上选择“使用配对码配对设备”。配对后，使用无线调试主页的端口连接。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
            if let message = panel.snapshot.wirelessMessage { Text(message).font(.caption).foregroundStyle(.secondary) } // 成功配对不会伪装成已经连接。
        }
        .controlSize(.small)
        .disabled(panel.snapshot.wirelessBusy) // 命令提交后禁止重复操作或切换后端。
    }
}
