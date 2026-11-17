import AppKit

/// 新安装默认浅色，深色和跟随系统均通过原生窗口外观切换。
enum MirrorAppearance: String, Codable, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue } // Picker 使用稳定标识保存选项。
    var label: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "跟随系统"
        }
    }
    var native: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua) // 默认值不依赖系统当前是否为深色。
        case .dark: return NSAppearance(named: .darkAqua) // 所有标题文字和按钮使用语义颜色适配。
        case .system: return nil // 移除覆盖后交由 AppKit 跟随系统实时变化。
        }
    }
}
