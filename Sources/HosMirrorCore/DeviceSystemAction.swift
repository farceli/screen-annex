import Foundation // 调试工具超时和手机返回内容在核心层处理。

/// 手机系统操作使用确定的目标状态，重复点击唤醒不会反过来熄屏。
public enum DeviceSystemAction: CaseIterable, Sendable {
    case lock, wake, light, dark

    public var title: String {
        switch self {
        case .lock: return "锁屏"
        case .wake: return "唤醒"
        case .light: return "浅色模式"
        case .dark: return "深色模式"
        }
    }

    public func run(on platform: DevicePlatform, serial: String, hdc: Hdc, adb: Adb,
                    attempt: ConnectionAttempt, followMac: Bool = false) throws {
        try attempt.checkCancellation() // 已断开的投屏不能启动新的手机命令。
        switch platform {
        case .harmony:
            switch self {
            case .lock: try Self.harmonyShell("power-shell suspend", serial: serial, hdc: hdc, attempt: attempt)
            case .wake:
                // 亮屏会启动手机自己的人脸认证。注入上滑可能中断这一过程。
                try Self.harmonyShell("power-shell wakeup", serial: serial, hdc: hdc, attempt: attempt)
                if followMac { try Self.dismissHarmonyLockIfShowing(serial: serial, hdc: hdc, attempt: attempt) }
            case .light, .dark:
                let mode = self == .dark ? "dark" : "light"
                try Self.harmonyShell("testhelper set-viewmode \(mode)", serial: serial, hdc: hdc, attempt: attempt,
                                      expected: "Set view mode to \(mode) successfully.",
                                      alreadySatisfied: "Error: View mode is already set to \(mode).")
            }
        case .android:
            let shell = ["-s", serial, "shell"] // 仅对绑定投屏会话的 ADB 设备操作。
            switch self {
            case .lock: _ = try adb.run(shell + ["input", "keyevent", "KEYCODE_SLEEP"], timeout: 5, attempt: attempt)
            case .wake:
                _ = try adb.run(shell + ["input", "keyevent", "KEYCODE_WAKEUP"], timeout: 5, attempt: attempt)
                Thread.sleep(forTimeInterval: 0.45) // 等待 Android 完成亮屏并挂载锁屏界面。
                // 由系统处理解锁请求，并按当前设备状态决定是否需要认证。
                _ = try adb.run(shell + ["wm", "dismiss-keyguard"], timeout: 5, attempt: attempt)
            case .light, .dark:
                let night = self == .dark ? "yes" : "no" // Android 系统外观命令接收固定值。
                _ = try adb.run(shell + ["cmd", "uimode", "night", night], timeout: 5, attempt: attempt)
                let result = try adb.run(shell + ["cmd", "uimode", "night"], timeout: 5, attempt: attempt)
                guard result.split(whereSeparator: \.isNewline).contains("Night mode: \(night)") else {
                    throw HdcError("手机没有确认系统外观已切换")
                }
            }
        }
    }

    static func harmonyScreenIsLocked(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            // 屏幕锁与设备认证是两个字段，只在系统确认锁屏界面存在时触发手势。
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 3 && fields[0] == "*" && fields[1] == "screenLocked" && fields[2] == "true"
        }
    }

    private static func dismissHarmonyLockIfShowing(serial: String, hdc: Hdc, attempt: ConnectionAttempt) throws {
        Thread.sleep(forTimeInterval: 0.65) // 先让亮屏和系统人脸识别启动。
        let state = try hdc.shell("hidumper -s ScreenlockService -a -all", serial: serial, timeout: 3, attempt: attempt)
        guard harmonyScreenIsLocked(state) else { return }
        // 使用系统锁屏的上滑动作，手机自行决定是进入桌面还是显示身份验证。
        try harmonyShell("uitest uiInput dircFling 2", serial: serial, hdc: hdc, attempt: attempt)
    }

    private static func harmonyShell(_ command: String, serial: String, hdc: Hdc, attempt: ConnectionAttempt,
                                     expected: String? = nil, alreadySatisfied: String? = nil) throws {
        // HDC 可能只返回本地传输状态；另行核对手机端命令退出码。
        let marker = "HOSMIRROR_COMMAND_EXIT:"
        let output = try hdc.shell("\(command); printf '\\n\(marker)%s\\n' \"$?\"", serial: serial, timeout: 5, attempt: attempt)
        guard let end = output.range(of: marker, options: .backwards) else {
            throw HdcError("手机未返回命令结果")
        }
        let message = output[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let exit = output[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = message.split(whereSeparator: \.isNewline)
        if let alreadySatisfied, lines.contains(Substring(alreadySatisfied)) { return } // 手机已经在目标模式，重复操作视为成功。
        guard exit == "0", !message.hasPrefix("[Fail]"), !message.lowercased().contains("permission denied"),
              expected.map({ lines.contains(Substring($0)) }) ?? true else {
            if message.contains("testhelper"), message.contains("not found") {
                throw HdcError("这台鸿蒙设备不支持通过调试工具切换系统外观")
            }
            throw HdcError(message.isEmpty ? "手机拒绝执行系统操作" : String(message.prefix(220)))
        }
    }
}
