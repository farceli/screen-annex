import Foundation

/// Annex-B helpers for the hosScrcpy video stream.
public enum H264 {
    public enum NALType: UInt8 {
        case slice = 1
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case aud = 9
    }

    private struct StartCode {
        let position: Int  // index of the first 0x00 of the start code
        let length: Int    // 3 or 4
        var payloadStart: Int { position + length }
    }

    private static func startCodes(in bytes: [UInt8]) -> [StartCode] {
        var codes: [StartCode] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                codes.append(StartCode(position: index, length: 3))
                index += 3
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                codes.append(StartCode(position: index, length: 4))
                index += 4
            } else {
                index += 1
            }
        }
        return codes
    }

    /// Splits an Annex-B byte stream into NAL units (without start codes).
    public static func split(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        let codes = startCodes(in: bytes)
        guard !codes.isEmpty else { return [] }

        var result: [[UInt8]] = []
        for (offset, code) in codes.enumerated() {
            var end = offset + 1 < codes.count ? codes[offset + 1].position : bytes.count
            // A 4-byte start code's leading zero belongs to the next NAL's start code.
            if end > code.payloadStart, bytes[end - 1] == 0, offset + 1 < codes.count, codes[offset + 1].length == 4 {
                end -= 1
            }
            if end > code.payloadStart {
                result.append(Array(bytes[code.payloadStart..<end]))
            }
        }
        return result
    }

    public static func type(of nal: [UInt8]) -> NALType? {
        guard let first = nal.first else { return nil }
        return NALType(rawValue: first & 0x1F)
    }

    /// Converts Annex-B NALs into AVCC (4-byte length prefixed) form.
    public static func avcc(_ nals: [[UInt8]]) -> Data {
        var data = Data()
        for nal in nals where !nal.isEmpty {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: nal)
        }
        return data
    }

    /// Extracts SPS/PPS from a set of NALs, if present.
    public static func parameterSets(_ nals: [[UInt8]]) -> (sps: [UInt8], pps: [UInt8])? {
        var sps: [UInt8]?
        var pps: [UInt8]?
        for nal in nals {
            switch type(of: nal) {
            case .sps: sps = nal
            case .pps: pps = nal
            default: break
            }
        }
        guard let sps, let pps else { return nil }
        return (sps, pps)
    }
}
