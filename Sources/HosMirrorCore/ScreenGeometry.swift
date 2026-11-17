import Foundation
import CoreGraphics

/// 将原始面板尺寸调整到当前视频方向，保留物理像素尺寸而不受视频缩放影响。
public enum ScreenGeometry {
    public static func orientedSize(native: CGSize, video: CGSize) -> CGSize {
        guard native.width > 0, native.height > 0, video.width > 0, video.height > 0 else {
            return native // 尚无有效关键帧时保留设备探测结果。
        }
        let sameOrientation = (native.width > native.height) == (video.width > video.height) // 比较横竖屏。
        return sameOrientation ? native : CGSize(width: native.height, height: native.width) // 仅在方向变化时交换宽高。
    }

    public static func pixel(_ normalized: CGFloat, extent: CGFloat) -> Int {
        let last = max(0, Int(extent) - 1) // 像素坐标最后一位是尺寸减一。
        return min(last, max(0, Int(normalized * extent))) // 边缘点击和拖出窗口都限制在屏幕内。
    }
}
