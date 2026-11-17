import Foundation

/// 设备上报的产品名称与硬件型号代码分开保存，不从代码猜测商品名称。
public struct DeviceIdentity: Equatable {
    public let modelCode: String // 诊断时仍保留 CLS-AL30 这样的硬件代码。
    public let displayName: String // 标题与连接界面使用可读的产品名称。

    public init(modelCode: String, productName: String? = nil, marketName: String? = nil) {
        self.modelCode = Self.clean(modelCode) ?? "HarmonyOS" // 无有效值时使用明确的通用回退。
        self.displayName = Self.clean(marketName) ?? Self.clean(productName) ?? self.modelCode // 优先市场名称，再使用设备产品名称。
    }

    static let probeCommand = "echo __MD__; param get const.product.model; echo __PN__; param get const.product.name; echo __MN__; param get const.product.marketname" // 一次往返读取三个独立字段。

    public static func parse(_ output: String) -> DeviceIdentity {
        func section(_ marker: String) -> String {
            guard let start = output.range(of: "__\(marker)__") else { return "" } // 老设备或旧夹具可以缺少名称字段。
            let remaining = output[start.upperBound...] // 只读取目标标记后的内容。
            let end = remaining.range(of: "__")?.lowerBound ?? remaining.endIndex // 下一段内容不能被当作名称。
            return String(remaining[..<end])
        }
        return DeviceIdentity(modelCode: section("MD"), productName: section("PN"), marketName: section("MN")) // 统一解析启动探测和标题预取。
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first {
            let lower = $0.lowercased() // 设备错误消息大小写并不固定。
            return !$0.isEmpty && !lower.hasPrefix("get parameter") && !lower.contains("errnum")
                && !lower.hasPrefix("error") && !lower.hasPrefix("param:")
                && !["unknown", "null", "undefined", "[empty]"].contains(lower) // 缺失参数的诊断文本不可显示为产品名称。
        }
    }
}

extension Hdc {
    public func deviceIdentity(serial: String) throws -> DeviceIdentity {
        DeviceIdentity.parse(try shell(DeviceIdentity.probeCommand, serial: serial, timeout: 10)) // 只读，不修改设备名称。
    }
}
