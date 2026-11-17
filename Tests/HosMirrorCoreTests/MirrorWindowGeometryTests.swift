import XCTest
@testable import HosMirrorCore

final class MirrorWindowGeometryTests: XCTestCase {
    private let phone = CGSize(width: 1216, height: 2688) // 当前设备面板尺寸，仅用于几何计算。

    func testPortraitMaximizesHeightIncludingTitlebar() {
        let size = MirrorWindowGeometry.maximumContent(device: phone, visible: CGSize(width: 1440, height: 900), chromeHeight: 28)
        XCTAssertEqual(size.height, 872, accuracy: 0.001) // 最大高度必须扣除标题栏。
        XCTAssertEqual(size.width / size.height, phone.width / phone.height, accuracy: 0.000001)
    }

    func testLandscapeMaximizesWidthWithoutExceedingScreen() {
        let landscape = CGSize(width: 2688, height: 1216)
        let size = MirrorWindowGeometry.maximumContent(device: landscape, visible: CGSize(width: 1280, height: 800), chromeHeight: 28)
        XCTAssertEqual(size.width, 1280, accuracy: 0.001) // 横屏以可用宽度作为限制边。
        XCTAssertLessThanOrEqual(size.height + 28, 800)
        XCTAssertEqual(size.width / size.height, landscape.width / landscape.height, accuracy: 0.000001)
    }

    func testVerySmallScreenKeepsMinimumConsistentWithMaximum() {
        let maximum = MirrorWindowGeometry.maximumContent(device: phone, visible: CGSize(width: 800, height: 600), chromeHeight: 28)
        let minimum = MirrorWindowGeometry.minimumContent(device: phone, maximum: maximum, preferredWidth: 400)
        XCTAssertEqual(minimum.width, maximum.width, accuracy: 0.001) // 首选最小宽度放不下时，不能把窗口推到屏幕外。
        XCTAssertEqual(minimum.height, maximum.height, accuracy: 0.001)
    }

    func testDraggingEitherEdgeChangesBothDimensions() {
        let current = CGSize(width: 400, height: 400 * phone.height / phone.width)
        let minimum = CGSize(width: 300, height: 300 * phone.height / phone.width)
        let maximum = CGSize(width: 600, height: 600 * phone.height / phone.width)
        for proposed in [CGSize(width: 500, height: current.height), CGSize(width: 400, height: 1000)] {
            let size = MirrorWindowGeometry.constrainedContent(proposed: proposed, current: current, device: phone, minimum: minimum, maximum: maximum)
            XCTAssertNotEqual(size.width, current.width) // 只拖高度也会改变宽度。
            XCTAssertNotEqual(size.height, current.height) // 只拖宽度也会改变高度。
            XCTAssertEqual(size.width / size.height, phone.width / phone.height, accuracy: 0.000001)
        }
    }

    func testResizeClampsBothLimitsWithoutBreakingAspect() {
        let minimum = CGSize(width: 360, height: 360 * phone.height / phone.width)
        let maximum = CGSize(width: 500, height: 500 * phone.height / phone.width)
        for width in [50.0, 5000.0] {
            let size = MirrorWindowGeometry.constrainedContent(proposed: CGSize(width: width, height: 900), current: CGSize(width: 400, height: 900), device: phone, minimum: minimum, maximum: maximum)
            XCTAssertGreaterThanOrEqual(size.width, minimum.width)
            XCTAssertLessThanOrEqual(size.width, maximum.width)
            XCTAssertEqual(size.width / size.height, phone.width / phone.height, accuracy: 0.000001) // 到达最小或最大尺寸也不能分别夹紧长宽。
        }
    }

    func testMaximizedFrameUsesSecondaryScreenCoordinates() {
        let screen = CGRect(x: -1920, y: 120, width: 1920, height: 1000)
        let original = CGRect(x: -1500, y: 300, width: 340, height: 780)
        let available = MirrorWindowGeometry.availableSize(keepingTopLeftOf: original, within: screen)
        let content = MirrorWindowGeometry.maximumContent(device: phone, visible: available, chromeHeight: 28)
        let frame = MirrorWindowGeometry.resizedFrame(content: content, keepingTopLeftOf: original, chromeHeight: 28)
        XCTAssertEqual(frame.minX, original.minX, accuracy: 0.001) // 副屏负坐标也保留原来的标题左上角。
        XCTAssertEqual(frame.maxY, original.maxY, accuracy: 0.001)
        XCTAssertTrue(screen.insetBy(dx: -0.001, dy: -0.001).contains(frame)) // 包含标题栏的整个外框均在屏幕内。
    }

    func testMaximizingOffCenterDoesNotRecenterOrOverflow() {
        let screen = CGRect(x: 0, y: 60, width: 1440, height: 900)
        let original = CGRect(x: 1000, y: 150, width: 340, height: 780)
        let available = MirrorWindowGeometry.availableSize(keepingTopLeftOf: original, within: screen)
        let content = MirrorWindowGeometry.maximumContent(device: phone, visible: available, chromeHeight: 28)
        let frame = MirrorWindowGeometry.resizedFrame(content: content, keepingTopLeftOf: original, chromeHeight: 28)
        XCTAssertEqual(frame.minX, 1000) // 不再移动到屏幕水平中心。
        XCTAssertEqual(frame.maxY, 930) // 标题高度保持不变，窗口向下增长。
        XCTAssertTrue(screen.contains(frame)) // 只能使用原位置剩余的空间。
        XCTAssertEqual(frame.width / (frame.height - 28), phone.width / phone.height, accuracy: 0.000001)
    }

    func testResizingRepeatedlyKeepsSameTopLeft() {
        let original = CGRect(x: 170, y: 300, width: 350, height: 780)
        let expanded = MirrorWindowGeometry.resizedFrame(content: CGSize(width: 400, height: 400 * phone.height / phone.width), keepingTopLeftOf: original, chromeHeight: 28)
        let restored = MirrorWindowGeometry.resizedFrame(content: CGSize(width: 350, height: 752), keepingTopLeftOf: expanded, chromeHeight: 28)
        XCTAssertEqual(expanded.minX, original.minX)
        XCTAssertEqual(expanded.maxY, original.maxY)
        XCTAssertEqual(restored.minX, original.minX) // 反复布局不能累计位置漂移。
        XCTAssertEqual(restored.maxY, original.maxY)
    }
}
