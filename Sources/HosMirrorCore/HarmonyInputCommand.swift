import Foundation

/// 将 Mac 输入转换成鸿蒙系统实际支持的命令。
enum HarmonyInputCommand {
    static func swipe(x: Int, y: Int, steps: Int, size: CGSize) -> String? {
        let count = min(3, max(-3, steps)) // 一批最多三格，用一次滑动完成。
        guard count != 0, size.width >= 64, size.height >= 128 else { return nil }
        let width = Int(size.width)
        let height = Int(size.height)
        let sideInset = max(8, width / 25) // 避开鸿蒙左右边缘的系统返回手势。
        let edgeInset = max(16, height / 12) // 留出通知栏和底部桌面手势区域。
        let bottom = height - edgeInset - 1
        let distance = min(bottom - edgeInset, max(56, height / 14) * abs(count)) // 至少移动 56 像素，并确保起终点都在安全区域。
        let column = min(width - sideInset - 1, max(sideInset, x))
        let dy = count > 0 ? distance : -distance // 正向滚动看上方内容，手指向下移动。
        let start = min(bottom - max(0, dy), max(edgeInset - min(0, dy), y))
        let duration = 135 + 25 * (abs(count) - 1) // 控制拖动速度，减少惯性将列表甩得太远。
        return "uinput -T -m \(column) \(start) \(column) \(start + dy) \(duration)"
    }

    static func focusedText(_ text: String) -> String? {
        guard !text.isEmpty, !text.utf8.contains(0) else { return nil } // shell 参数不能包含空字节。
        let literal = text.replacingOccurrences(of: "'", with: "'\\''") // 单引号、换行与 shell 元字符均按字面传入。
        return "uitest uiInput text '\(literal)'" // 使用当前焦点，避免二次点击导致光标跳回。
    }
}
