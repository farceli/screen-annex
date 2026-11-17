import Foundation
import CoreGraphics

/// 所有窗口尺寸计算都以设备内容比例为准，标题栏高度单独计入外框。
public enum MirrorWindowGeometry {
    public static func maximumContent(device: CGSize, visible: CGSize, chromeHeight: CGFloat) -> CGSize {
        guard device.width > 0, device.height > 0 else { return .zero } // 尚无有效设备尺寸时不计算比例。
        let available = CGSize(width: max(1, visible.width), height: max(1, visible.height - chromeHeight)) // 菜单栏和 Dock 已由 visibleFrame 排除。
        let scale = min(available.width / device.width, available.height / device.height) // 同时满足屏幕宽度与高度约束。
        return CGSize(width: device.width * scale, height: device.height * scale) // 两个方向始终使用同一缩放系数。
    }

    public static func minimumContent(device: CGSize, maximum: CGSize, preferredWidth: CGFloat) -> CGSize {
        guard device.width > 0, device.height > 0 else { return .zero } // 防止设备尚未就绪时除以零。
        let width = min(maximum.width, max(1, preferredWidth)) // 小屏幕上最小值不能反过来超过可用最大值。
        return CGSize(width: width, height: width * device.height / device.width) // 最小高度也严格按设备比例计算。
    }

    public static func constrainedContent(proposed: CGSize, current: CGSize, device: CGSize, minimum: CGSize, maximum: CGSize) -> CGSize {
        guard device.width > 0, device.height > 0 else { return current } // 无效设备尺寸不改变窗口。
        let aspect = device.width / device.height // 使用原始设备像素比例，避免编码缩放取整造成偏差。
        let widthChange = abs(proposed.width - current.width) // 判断用户这次主要拖动哪个方向。
        let heightChange = abs(proposed.height - current.height) * aspect // 把高度变化换算到同一宽度尺度。
        let requestedWidth = widthChange >= heightChange ? proposed.width : proposed.height * aspect // 拖边时另一个方向也同步变化。
        let width = min(maximum.width, max(minimum.width, requestedWidth)) // 同时遵守标题可读性和当前屏幕上限。
        return CGSize(width: width, height: width / aspect) // 禁止分别夹紧长宽导致设备画面比例被破坏。
    }

    public static func availableSize(keepingTopLeftOf current: CGRect, within visible: CGRect) -> CGSize {
        CGSize(width: max(1, min(visible.width, visible.maxX - current.minX)), height: max(1, min(visible.height, current.maxY - visible.minY))) // 只使用当前标题左上角向右、向下的可用空间，不移动窗口寻找空间。
    }

    public static func resizedFrame(content: CGSize, keepingTopLeftOf current: CGRect, chromeHeight: CGFloat) -> CGRect {
        let size = CGSize(width: content.width, height: content.height + chromeHeight) // 只有外框高度包含原生标题栏。
        return CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height) // AppKit 原点在左下角，反算 y 才能保持标题栏左上角不动。
    }
}
