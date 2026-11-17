import Foundation

/// 把触控板的高精度增量合并成原生滚轮步进，不生成任何触摸按下或抬起。
public struct ScrollWheelAccumulator {
    private var remainder = 0.0 // 保留不足一个步进的触控板位移。
    private var lastTime: TimeInterval? // 不让上一轮惯性的尾部影响下一次手势。
    private static let pointsPerStep = 8.0 // 高精度滚动累计八个逻辑点发送一步。

    public init() {}

    public mutating func reset() {
        remainder = 0 // 连接切换或新手势开始时丢弃旧位移。
        lastTime = nil // 重置时间基准。
    }

    public mutating func consume(delta: Double, precise: Bool, timestamp: TimeInterval) -> Int {
        guard delta.isFinite, timestamp.isFinite else { return 0 } // 异常数值不能进入整数换算。
        if let lastTime, timestamp < lastTime || timestamp - lastTime > 0.2 { remainder = 0 } // 分开独立滚动手势。
        lastTime = timestamp // 时间由输入事件或测试注入。
        guard delta != 0 else { return 0 } // 结束事件的零增量不能造成设备操作。
        if !precise {
            remainder = 0 // 鼠标滚轮不继承触控板的小数余量。
            return Int(max(-3, min(3, delta.rounded(.awayFromZero)))) // 一次事件最多发送三步，避免积压。
        }
        if remainder * delta < 0 { remainder = 0 } // 换方向立即响应，不先抵消上一方向的尾数。
        remainder = max(-24, min(24, remainder + delta)) // 限制突发事件在一个小批次内完成。
        let steps = Int(remainder / Self.pointsPerStep) // 向零取整，细小惯性只累计而不触碰屏幕。
        remainder -= Double(steps) * Self.pointsPerStep // 下一次事件继续使用剩余的小数位移。
        return steps
    }
}

/// 保留 AppKit 事件的精度和手势边界，避免把触控板像素误当作鼠标滚轮格数。
public struct ScrollWheelInput {
    public let delta: Double // 原始纵向增量，正负方向沿用现有交互约定。
    public let precise: Bool // 触控板提供高精度逻辑点，普通鼠标提供离散格数。
    public let startsGesture: Bool // 新的手势或惯性序列不能继承旧的小数尾数。
    public let timestamp: TimeInterval // 使用事件自身的单调时间，而非墙上时钟。
    public let endsGesture: Bool
    public let viewportHeight: Double // 投屏内容高度，用来将触控板位移换成手机像素。

    public init(delta: Double, precise: Bool, startsGesture: Bool, timestamp: TimeInterval,
                endsGesture: Bool = false, viewportHeight: Double = 800) {
        self.delta = delta
        self.precise = precise
        self.startsGesture = startsGesture
        self.timestamp = timestamp
        self.endsGesture = endsGesture
        self.viewportHeight = viewportHeight
    }
}
