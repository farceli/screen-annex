import XCTest
@testable import HosMirrorCore

final class ScrollWheelTests: XCTestCase {
    func testContinuousScrollKeepsOneTouchAndReversesDirection() {
        var drag = ScrollWheelDrag()
        let size = CGSize(width: 1216, height: 2688)
        let point = CGPoint(x: 0.5, y: 0.6)
        XCTAssertTrue(drag.move(by: 5, at: point, in: size).isEmpty) // 噪声不足以开始触摸。
        let start = drag.move(by: -45, at: point, in: size)
        guard start.count == 2 else { return XCTFail("应先按下再移动") }
        XCTAssertEqual(start[0].phase, .down)
        XCTAssertEqual(start[1].phase, .move)
        XCTAssertEqual(start[1].y - start[0].y, -40)
        let reverse = drag.move(by: 15, at: point, in: size)
        XCTAssertEqual(reverse.map(\.phase), [.move]) // 反向也沿用原触摸。
        XCTAssertEqual(reverse.first?.y, start[1].y + 15)
        XCTAssertEqual(drag.end()?.phase, .up)
        XCTAssertNil(drag.end())
    }

    func testHarmonySwipeAtEdgesDoesNotBecomeTapOrSystemGesture() throws {
        let size = CGSize(width: 1216, height: 2688) // Mate 70 的物理触摸坐标，独立于编码分辨率。
        for (point, steps) in [(CGPoint.zero, -1), (CGPoint(x: 1215, y: 2687), Int.max)] {
            let command = try XCTUnwrap(HarmonyInputCommand.swipe(x: Int(point.x), y: Int(point.y), steps: steps, size: size))
            let parts = command.split(separator: " ")
            let pixels = parts.dropFirst(3).compactMap { Int($0) }
            XCTAssertEqual(parts.prefix(3), ["uinput", "-T", "-m"])
            XCTAssertEqual(pixels.count, 5)
            guard pixels.count == 5 else { continue }
            XCTAssertEqual(pixels[0], pixels[2]) // 两点在同一列，不会生成横向返回。
            XCTAssertTrue((48...1167).contains(pixels[0]))
            XCTAssertTrue((224...2463).contains(pixels[1]) && (224...2463).contains(pixels[3]))
            XCTAssertGreaterThan(abs(pixels[3] - pixels[1]), 100) // 即使到边缘也保留可识别的位移。
            XCTAssertEqual(pixels[3] > pixels[1], steps > 0)
        }
        XCTAssertNil(HarmonyInputCommand.swipe(x: 600, y: 800, steps: 0, size: size))
    }

    func testTinyTrackpadDeltasAccumulateWithoutGeneratingTouches() {
        var accumulator = ScrollWheelAccumulator() // 使用生产增量转换器。
        for index in 0..<7 {
            XCTAssertEqual(accumulator.consume(delta: 1, precise: true, timestamp: Double(index) * 0.01), 0) // 旧代码每次都会生成一次近似点击。
        }
        XCTAssertEqual(accumulator.consume(delta: 1, precise: true, timestamp: 0.07), 1) // 累计足够后只产生一个滚轮步进。
    }

    func testMomentumTailAndZeroDeltaNeverBecomeTap() {
        var accumulator = ScrollWheelAccumulator()
        XCTAssertEqual(accumulator.consume(delta: 0.6, precise: true, timestamp: 0), 0) // 微小惯性尾部只累计。
        XCTAssertEqual(accumulator.consume(delta: 0, precise: true, timestamp: 0.01), 0) // 手势结束的零增量不触发操作。
        XCTAssertEqual(accumulator.consume(delta: 7.4, precise: true, timestamp: 1), 0) // 下一次手势不继承上一轮尾数。
    }

    func testDirectionChangesAndBurstAreBounded() {
        var accumulator = ScrollWheelAccumulator()
        XCTAssertEqual(accumulator.consume(delta: 7, precise: true, timestamp: 0), 0)
        XCTAssertEqual(accumulator.consume(delta: -8, precise: true, timestamp: 0.01), -1) // 反向时直接丢弃旧尾数。
        XCTAssertEqual(accumulator.consume(delta: 10000, precise: true, timestamp: 0.02), 3) // 巨大增量不能堆积成数百次 RPC。
        XCTAssertEqual(accumulator.consume(delta: 0, precise: true, timestamp: 0.03), 0)
    }

    func testMouseWheelAndResetDoNotInheritTrackpadRemainder() {
        var accumulator = ScrollWheelAccumulator()
        _ = accumulator.consume(delta: 7, precise: true, timestamp: 0)
        XCTAssertEqual(accumulator.consume(delta: -1, precise: false, timestamp: 0.01), -1) // 普通鼠标保留一格滚动。
        XCTAssertEqual(accumulator.consume(delta: 1, precise: true, timestamp: 0.02), 0) // 切换设备不带入旧余数。
        accumulator.reset() // 模拟断开或开始新手势。
        XCTAssertEqual(accumulator.consume(delta: 7, precise: true, timestamp: 0.03), 0)
        XCTAssertEqual(accumulator.consume(delta: .nan, precise: true, timestamp: 0.04), 0) // 不允许异常数值崩溃。
    }

    func testScrollProtocolContainsOnlyAxisEventsEvenAtScreenEdge() {
        var calls: [String] = [] // 记录高层实际发送的 API。
        var coordinates: [[String: Int]] = []
        let control = ControlClient(requestHandler: { api, args in
            calls.append(api)
            coordinates.append(args as! [String: Int]) // 设备端轴事件以 x/y 定位滚动容器。
            return ["result": NSNull()]
        })
        XCTAssertTrue(control.scroll(x: 0, y: 0, steps: 1)) // 边缘坐标不再裁切成零长度触摸。
        XCTAssertEqual(calls, ["AxisDown", "AxisStop"])
        XCTAssertEqual(coordinates, [["x": 0, "y": 0], ["x": 0, "y": 0]])
        calls.removeAll()
        XCTAssertTrue(control.scroll(x: 1215, y: 2687, steps: -1))
        XCTAssertEqual(calls, ["AxisUp", "AxisStop"]) // 方向相反仍然没有按钮或触摸事件。
        calls.removeAll()
        XCTAssertTrue(control.scroll(x: 0, y: 0, steps: 0))
        XCTAssertTrue(calls.isEmpty) // 零移动绝不产生点按或空事件。
    }

    func testRejectedAxisNeverFallsBackToTouch() {
        var calls: [String] = []
        let control = ControlClient(requestHandler: { api, _ in
            calls.append(api)
            return api == "AxisStop" ? ["result": NSNull()] : ["exception": "unsupported"] // 模拟设备拒绝滚轮轴。
        })
        XCTAssertFalse(control.scroll(x: 10, y: 20, steps: 3))
        XCTAssertEqual(calls, ["AxisDown", "AxisStop"]) // 即使失败也只结束轴事件，不改发 touchDown/Up。
    }

    func testAxisBatchHasUpperBound() {
        var calls: [String] = []
        let control = ControlClient(requestHandler: { api, _ in
            calls.append(api)
            return ["result": NSNull(), "error": NSNull()] // 显式空错误不应被视作失败。
        })
        XCTAssertTrue(control.scroll(x: 20, y: 30, steps: .max))
        XCTAssertEqual(calls, ["AxisDown", "AxisDown", "AxisDown", "AxisStop"]) // 一批最多三步。
    }
}
