import Foundation

/// Hand-rolled protobuf decoding for the tiny `scrcpy.proto` surface we need.
///
/// ```proto
/// message ReplyMessage {
///   string data = 1;
///   int32  reply_type = 2;
///   map<string, ParamValue> payload = 3;
/// }
/// message ParamValue { oneof values { ... bytes val_bytes = 5; ... } }
/// ```
public enum Proto {
    public struct Reader {
        public private(set) var bytes: [UInt8]
        public var index: Int = 0

        public init(_ bytes: [UInt8]) { self.bytes = bytes }
        public var isAtEnd: Bool { index >= bytes.count }

        public mutating func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        public mutating func lengthDelimited() -> [UInt8]? {
            guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
            let start = index
            index += Int(length)
            return Array(bytes[start..<index])
        }

        public mutating func skip(wireType: Int) -> Bool {
            switch wireType {
            case 0: return varint() != nil
            case 1:
                guard bytes.count - index >= 8 else { return false }
                index += 8; return true
            case 2: return lengthDelimited() != nil
            case 5:
                guard bytes.count - index >= 4 else { return false }
                index += 4; return true
            default: return false
            }
        }
    }

    /// Returns the H.264 access unit carried by `payload["data"].val_bytes`, if any.
    public static func replyData(_ message: [UInt8]) -> [UInt8]? {
        var reader = Reader(message)
        var result: [UInt8]?

        while !reader.isAtEnd {
            guard let tag = reader.varint() else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if field == 3, wire == 2 {
                if let entry = reader.lengthDelimited(), let data = payloadData(entry) {
                    result = data
                }
            } else if !reader.skip(wireType: wire) {
                break
            }
        }
        return result
    }

    /// map entry: key = 1 (string), value = 2 (ParamValue)
    private static func payloadData(_ entry: [UInt8]) -> [UInt8]? {
        var reader = Reader(entry)
        var key: String?
        var value: [UInt8]?

        while !reader.isAtEnd {
            guard let tag = reader.varint() else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if field == 1, wire == 2 {
                if let raw = reader.lengthDelimited() { key = String(decoding: raw, as: UTF8.self) }
            } else if field == 2, wire == 2 {
                value = reader.lengthDelimited()
            } else if !reader.skip(wireType: wire) {
                break
            }
        }

        guard key == "data", let value else { return nil }
        // ParamValue: val_bytes = field 5, wire type 2
        var param = Reader(value)
        while !param.isAtEnd {
            guard let tag = param.varint() else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if field == 5, wire == 2 {
                return param.lengthDelimited()
            } else if !param.skip(wireType: wire) {
                break
            }
        }
        return nil
    }
}
