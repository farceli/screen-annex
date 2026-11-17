import XCTest
@testable import HosMirrorCore

final class RightClickPolicyTests: XCTestCase {
    func testPhysicalScreenOffIgnoresAwakeVirtualScreen() {
        let dump = """
        screen[0]: id=0, powerStatus=POWER_STATUS_OFF, isVirtual=false, skipFrameInterval=1
        screen[1]: id=4294967295, powerStatus=POWER_STATUS_ON, isVirtual=true
        """ // 回归：虚拟屏持续工作不能证明物理屏已经点亮。
        XCTAssertEqual(DisplayPowerState.parse(dump), .off)
        XCTAssertEqual(DisplayPowerState.parse(dump.replacingOccurrences(of: "POWER_STATUS_OFF", with: "POWER_STATUS_SUSPEND")), .off) // 实机 power-shell suspend 后得到该状态。
        XCTAssertEqual(RightClickPolicy.command(for: .off), "power-shell wakeup") // 使用已在复现设备验证的系统唤醒命令。
    }

    func testAwakePhysicalScreenUsesOnlyBack() {
        let dump = "screen[0]: id=0, powerStatus=POWER_STATUS_ON, backlight=29341, isVirtual=false, skipFrameInterval=1"
        XCTAssertEqual(DisplayPowerState.parse(dump), .on) // 解析当前商业固件的 RenderService 输出。
        XCTAssertEqual(RightClickPolicy.command(for: .on), KeyMap.command(KeyMap.back)) // 亮屏时右键保持返回功能。
    }

    func testUnknownOrVirtualOnlyStateOnlyWakes() {
        let virtual = "screen[1]: id=4294967295, powerStatus=POWER_STATUS_ON, isVirtual=true"
        XCTAssertEqual(DisplayPowerState.parse(virtual), .unknown) // 不能把投屏虚拟屏当成物理主屏。
        XCTAssertEqual(DisplayPowerState.parse("PowerManagerService\n"), .unknown) // 空诊断标题没有有效状态。
        XCTAssertEqual(RightClickPolicy.command(for: .unknown), "power-shell wakeup") // 不串联返回、密码、点击或电源切换。
    }

    func testLegacyCurrentStateStillWorksWithoutMatchingHistory() {
        XCTAssertEqual(DisplayPowerState.parse("Current State: AWAKE\nLast Screen Off: 123"), .on)
        for value in ["INACTIVE", "SLEEP", "OFF", "DOZE"] {
            XCTAssertEqual(DisplayPowerState.parse("Current State: \(value)"), .off) // 兼容提供有效 PowerManager 状态的系统。
        }
        XCTAssertEqual(DisplayPowerState.parse("DUMP EACH STATES:\nState: AWAKE\nState: INACTIVE"), .unknown) // 历史记录不能替代当前状态。
    }

    func testBackReplyFallsBackOnlyWhenTheDeviceLacksTheMethod() {
        XCTAssertEqual(ControlClient.backResult(from: ["result": NSNull()]), .sent) // UiTest 的 void 成功结果是 JSON null。
        XCTAssertEqual(ControlClient.backResult(from: ["exception": ["message": "No handler found for api 'Driver.pressBack'"]]), .unsupported)
        XCTAssertEqual(ControlClient.backResult(from: ["exception": ["message": "Timed out"]]), .unconfirmed)
        XCTAssertEqual(ControlClient.backResult(from: nil), .unconfirmed) // 无应答时不能判断手机是否已执行。
    }
}
