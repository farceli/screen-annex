import Foundation

/// 用一次触摸手势传递连续滚动位移，直到抬手或滚轮停止。
public struct ScrollWheelDrag {
    public struct Event {
        public let phase: TouchPhase
        public let x: Int
        public let y: Int
    }

    private var lastPoint: (x: Int, y: Int)?
    private var remainder: Double = 0

    public init() {}

    public mutating func move(by pixels: Double, at point: CGPoint, in size: CGSize) -> [Event] {
        guard pixels.isFinite, pixels != 0, size.width >= 64, size.height >= 128 else { return [] }
        let width = Int(size.width)
        let height = Int(size.height)
        let top = height / 12 // 避开状态栏和底部导航手势。
        let bottom = height - top - 1
        let side = width / 25 // 避免在系统返回手势区起手。
        let minimum = max(24, height / 100)
        remainder += pixels // 保留触控板的小数位移。
        let delta = Int(max(-Double(height / 3), min(Double(height / 3), remainder)))
        guard delta != 0 else { return [] }
        var events: [Event] = []
        if let lastPoint, !(top...bottom).contains(lastPoint.y + delta) {
            // 长手势到达屏幕边缘时抬起，再在指针附近续接。
            if let up = end() { events.append(up) }
            remainder = Double(delta)
        }
        if lastPoint == nil {
            guard abs(delta) >= minimum else { return events } // 很轻的滚动不能被识别为一次点击。
            let x = min(width - side - 1, max(side, ScreenGeometry.pixel(point.x, extent: size.width)))
            let y = min(bottom - max(0, delta), max(top - min(0, delta), ScreenGeometry.pixel(point.y, extent: size.height)))
            lastPoint = (x, y)
            events.append(Event(phase: .down, x: x, y: y))
        }
        if let start = lastPoint {
            let y = start.y + delta
            lastPoint = (start.x, y)
            remainder -= Double(delta)
            events.append(Event(phase: .move, x: start.x, y: y))
        }
        return events
    }

    public mutating func end() -> Event? {
        let point = lastPoint
        lastPoint = nil
        remainder = 0
        return point.map { Event(phase: .up, x: $0.x, y: $0.y) }
    }
}
