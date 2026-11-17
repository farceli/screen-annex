import XCTest
@testable import HosMirrorCore

final class H264Tests: XCTestCase {
    func testSplitsGoldenSample() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "h264"))
        let data = try Data(contentsOf: url)
        let nals = H264.split(data)

        XCTAssertEqual(nals.count, 7)
        XCTAssertEqual(nals.compactMap { H264.type(of: $0) }, [.sps, .pps, .idr, .slice, .slice, .slice, .slice])
        XCTAssertEqual(nals[0].count, 23) // 合成码流中的 SPS 字节数。
        XCTAssertEqual(nals[1].count, 4) // 合成码流中的 PPS 字节数。
    }

    func testAVCCPrefixesLengths() throws {
        let nals: [[UInt8]] = [[0x67, 0x01, 0x02], [0x68, 0x03]]
        let avcc = [UInt8](H264.avcc(nals))
        XCTAssertEqual(Array(avcc[0..<4]), [0, 0, 0, 3])
        XCTAssertEqual(Array(avcc[4..<7]), [0x67, 0x01, 0x02])
        XCTAssertEqual(Array(avcc[7..<11]), [0, 0, 0, 2])
    }

    func testParameterSets() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "h264"))
        let nals = H264.split(try Data(contentsOf: url))
        let sets = try XCTUnwrap(H264.parameterSets(nals))
        XCTAssertEqual(sets.sps.first.map { $0 & 0x1F }, 7)
        XCTAssertEqual(sets.pps.first.map { $0 & 0x1F }, 8)
    }
}
