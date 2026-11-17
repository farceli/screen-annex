import Foundation

/// 只在真正出图且稳定连接后重置失败预算，避免短命连接无限自动重试。
public struct ReconnectPolicy {
    public private(set) var attempts = 0 // 累计本轮自动重试，手动连接创建新策略。
    private var openedAt: Date? // 建立通道并不代表视频已经可用。
    private var displayedVideo = false // 静态桌面只需成功显示一帧，无需持续出帧。

    public init() {}

    public mutating func connectionOpened(at now: Date) {
        openedAt = now // 新通道重新开始稳定观察期，保留已有重试次数。
        displayedVideo = false // 不继承上一次连接的画面就绪状态。
    }

    public mutating func videoDisplayed() {
        displayedVideo = true // 由渲染器真正显示首帧后确认，而非收到 SPS 包时确认。
    }

    public mutating func nextDelay(at now: Date) -> TimeInterval? {
        if displayedVideo, let openedAt, now.timeIntervalSince(openedAt) >= 30 {
            attempts = 0 // 正常使用至少三十秒后发生的新故障拥有新的重试预算。
        }
        openedAt = nil // 同一次故障不能重复利用稳定期清零。
        displayedVideo = false // 失败后必须等待新连接再次出图。
        guard attempts < 5 else { return nil } // 连续失败最多自动重试五次。
        attempts += 1 // 建立 socket 成功不会重置本计数。
        return min(Double(attempts) * 1.5, 6) // 逐次退避，最长六秒。
    }
}
