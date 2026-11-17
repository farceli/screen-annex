import XCTest
@testable import HosMirrorCore

final class ScreenGeometryTests: XCTestCase {
    func testLandscapeUsesFullPhysicalPixelsEvenWhenVideoIsScaled() {
        let size = ScreenGeometry.orientedSize(native: CGSize(width: 1216, height: 2688), video: CGSize(width: 1344, height: 608))
        XCTAssertEqual(size, CGSize(width: 2688, height: 1216)) // 50% 横屏视频仍映射到全分辨率物理屏幕。
        XCTAssertEqual(ScreenGeometry.pixel(0.5, extent: size.width), 1344) // 中心点按当前方向换算。
    }

    func testRotationBackToPortraitRestoresNativeSize() {
        XCTAssertEqual(ScreenGeometry.orientedSize(native: CGSize(width: 1216, height: 2688), video: CGSize(width: 608, height: 1344)), CGSize(width: 1216, height: 2688)) // 不累积交换宽高的误差。
    }

    func testEdgeAndOutOfBoundsTouchesStayInsideScreen() {
        XCTAssertEqual(ScreenGeometry.pixel(1, extent: 1216), 1215) // 最右侧像素不是 1216。
        XCTAssertEqual(ScreenGeometry.pixel(-0.2, extent: 1216), 0) // 拖出左边界仍在有效范围。
        XCTAssertEqual(ScreenGeometry.pixel(1.2, extent: 1216), 1215) // 拖出右边界同样安全。
    }
}
