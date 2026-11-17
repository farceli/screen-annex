import XCTest
@testable import HosMirrorCore

final class ReconnectPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000) // 注入时钟，无需真实等待重连退避。

    func testShortConnectionsCannotResetFiveRetryLimit() {
        var policy = ReconnectPolicy()
        for index in 0..<5 {
            let opened = start.addingTimeInterval(Double(index) * 10)
            policy.connectionOpened(at: opened) // 模拟每次都短暂建立 socket 成功。
            policy.videoDisplayed() // 即使收到首帧，短暂连接也不能清零。
            XCTAssertEqual(policy.nextDelay(at: opened.addingTimeInterval(5)), min(Double(index + 1) * 1.5, 6))
        }
        policy.connectionOpened(at: start.addingTimeInterval(50))
        policy.videoDisplayed()
        XCTAssertNil(policy.nextDelay(at: start.addingTimeInterval(55))) // 第五次自动重试仍不稳定时停止，不能无限循环。
    }

    func testLongConnectionWithoutVideoDoesNotResetBudget() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.nextDelay(at: start), 1.5)
        policy.connectionOpened(at: start.addingTimeInterval(2))
        XCTAssertEqual(policy.nextDelay(at: start.addingTimeInterval(100)), 3) // 仅通道接通、长期不出图不算成功恢复。
    }

    func testStableStaticFrameRestoresBudget() {
        var policy = ReconnectPolicy()
        _ = policy.nextDelay(at: start) // 先消耗一次自动重试。
        policy.connectionOpened(at: start.addingTimeInterval(2))
        policy.videoDisplayed() // 静止桌面不再出帧，但仍是可正常使用的连接。
        XCTAssertEqual(policy.nextDelay(at: start.addingTimeInterval(32)), 1.5) // 稳定满三十秒才重置。
        XCTAssertEqual(policy.attempts, 1)
        XCTAssertEqual(policy.nextDelay(at: start.addingTimeInterval(33)), 3) // 同一稳定期不能重复清零。
    }

    func testNewConnectionCannotInheritOldVideoReadiness() {
        var policy = ReconnectPolicy()
        policy.connectionOpened(at: start)
        policy.videoDisplayed()
        _ = policy.nextDelay(at: start.addingTimeInterval(10))
        policy.connectionOpened(at: start.addingTimeInterval(12))
        XCTAssertEqual(policy.nextDelay(at: start.addingTimeInterval(100)), 3) // 新会话没有首帧，不能继承旧会话成功状态。
    }
}
