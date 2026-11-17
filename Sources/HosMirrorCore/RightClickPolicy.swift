import Foundation

/// 电源信息只能在明确报告当前状态时使用；空输出与历史状态一律视为未知。
public enum DisplayPowerState: Equatable {
    case on, off, unknown

    public static func parse(_ output: String) -> DisplayPowerState {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces).uppercased()
            if text.hasPrefix("SCREEN["), text.contains(": ID=0,"), text.contains("ISVIRTUAL=FALSE") {
                let fields = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } // 只读取主物理屏，忽略投屏虚拟屏。
                if fields.contains("POWERSTATUS=POWER_STATUS_ON") { return .on } // RenderService 能在商业固件返回实际屏幕状态。
                if fields.contains("POWERSTATUS=POWER_STATUS_OFF") || fields.contains("POWERSTATUS=POWER_STATUS_SUSPEND") { return .off } // 真机熄屏报告 SUSPEND，不能把它当作亮屏。
            }
            guard text.hasPrefix("CURRENT STATE:") || text.hasPrefix("CURRENTSTATE:") else { continue } // 不匹配历史 AWAKE/INACTIVE 记录。
            let value = text.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            if ["AWAKE", "ON", "DIM"].contains(value) { return .on } // DIM 仍然是亮屏状态。
            if ["INACTIVE", "SLEEP", "OFF", "DOZE"].contains(value) { return .off }
        }
        return .unknown // 部分商业固件的 hidumper 不返回电源状态。
    }
}

public enum RightClickPolicy {
    public static func command(for state: DisplayPowerState) -> String {
        switch state {
        case .on: return KeyMap.command(KeyMap.back) // 明确亮屏时只执行返回。
        case .off, .unknown: return "power-shell wakeup" // 真机验证可真正点亮屏幕；未知时也只唤醒，避免额外返回误操作。
        }
    }
}
