import XCTest
@testable import HosMirrorCore

final class DeviceIdentityTests: XCTestCase {
    func testUsesProductNameWhenMarketParameterIsMissing() {
        let output = "__MD__\nTEST-001 \n__PN__\nExample Phone \n__MN__\nGet parameter \"const.product.marketname\" fail! errNum is:106!\n" // 合成输出复用系统查询的字段及错误格式。
        let identity = DeviceIdentity.parse(output)
        XCTAssertEqual(identity.displayName, "Example Phone") // 用户标题优先显示可读产品名称。
        XCTAssertEqual(identity.modelCode, "TEST-001") // 诊断仍保留硬件型号字段。
    }

    func testMarketNameHasPriorityOverInternalProductName() {
        let identity = DeviceIdentity(modelCode: "TEST-001", productName: "internal-product", marketName: "Example Phone Pro")
        XCTAssertEqual(identity.displayName, "Example Phone Pro") // 有市场名称时不使用内部工程代号。
    }

    func testUnknownDeviceFallsBackWithoutInventingAName() {
        let identity = DeviceIdentity(modelCode: "TEST-001", productName: "null", marketName: "Get parameter failed")
        XCTAssertEqual(identity.displayName, "TEST-001") // 未知机型不猜测型号映射。
        XCTAssertEqual(DeviceIdentity.parse("").displayName, "HarmonyOS") // 完全缺少字段仍可正常显示。
    }

    func testDeviceSectionsCannotLeakIntoName() {
        let identity = DeviceIdentity.parse("__MD__\nABC-001\n__PN__\nExample Phone\n__MN__\n\n__E__\nprobe data")
        XCTAssertEqual(identity.displayName, "Example Phone") // 模拟器或分辨率探测内容不能进入窗口标题。
    }
}
