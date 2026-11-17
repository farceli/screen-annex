import Foundation // 按固定 scrcpy 5.0.1 协议构造消息，不改写上游源码。
import CoreGraphics // 坐标携带编码尺寸，避免缩放或旋转后误触。

/// 依据随包官方 ControlMessageReader/Streamer 的字段布局独立实现。
public enum AndroidWire {
    public static func integer<T: FixedWidthInteger>(_ value: T) -> Data { // 所有协议整数均为网络字节序。
        var big = value.bigEndian // 不依赖主机是 Intel 还是 ARM。
        return withUnsafeBytes(of: &big) { Data($0) } // 复制值，不保留临时指针。
    }
    public static func unsigned(_ data: Data, at offset: Int, bytes: Int) -> UInt64 { // 不做未对齐指针加载。
        data.dropFirst(offset).prefix(bytes).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } // 调用者先验证消息长度。
    }
    public static func key(code: UInt32, down: Bool) -> Data { // type/action/keycode/repeat/metastate 共十四字节。
        Data([0, down ? 0 : 1]) + integer(code) + integer(UInt32(0)) + integer(UInt32(0)) // 注入一次真实按下或抬起。
    }
    public static func androidKey(_ logical: UInt32) -> UInt32? { // 与鸿蒙按钮共享逻辑键，不能直接传鸿蒙码。
        switch logical {
        case KeyMap.home: return 3 // KEYCODE_HOME。
        case KeyMap.back: return 4 // KEYCODE_BACK。
        case KeyMap.recent: return 187 // KEYCODE_APP_SWITCH。
        case KeyMap.power: return 26 // KEYCODE_POWER。
        case KeyMap.volumeUp: return 24 // KEYCODE_VOLUME_UP。
        case KeyMap.volumeDown: return 25 // KEYCODE_VOLUME_DOWN。
        case KeyMap.enter: return 66 // KEYCODE_ENTER。
        case KeyMap.backspace: return 67 // KEYCODE_DEL。
        case 2049: return 61 // Tab。
        case 2071: return 112 // Forward delete。
        case 2014: return 21 // Left。
        case 2015: return 22 // Right。
        case 2013: return 20 // Down。
        case 2012: return 19 // Up。
        default: return nil // 未定义映射不能注入不相关系统键。
        }
    }
    public static func position(x: Int, y: Int, physical: CGSize, video: CGSize) -> Data { // scrcpy 要求编码帧尺寸与坐标一致。
        let width = max(1, min(65535, Int(video.width))) // 尺寸字段为无符号十六位。
        let height = max(1, min(65535, Int(video.height))) // 防止异常尺寸溢出。
        let px = max(0, min(width - 1, Int(Double(x) * Double(width) / max(1, physical.width)))) // 物理像素转换为编码像素。
        let py = max(0, min(height - 1, Int(Double(y) * Double(height) / max(1, physical.height)))) // 横竖屏采用同一转换。
        return integer(UInt32(px)) + integer(UInt32(py)) + integer(UInt16(width)) + integer(UInt16(height)) // 完整 Position 字段。
    }
    public static func touch(_ phase: TouchPhase, position: Data) -> Data { // finger 指针不混用鼠标按钮位。
        let action: UInt8 = phase == .down ? 0 : (phase == .up ? 1 : 2) // Android ACTION_DOWN/UP/MOVE。
        return Data([2, action]) + integer(UInt64.max - 1) + position + integer(UInt16(phase == .up ? 0 : 65535)) + integer(UInt32(0)) + integer(UInt32(0)) // pointer=-2，指压与按键字段按官方布局发送。
    }
    public static func scroll(steps: Int, position: Data) -> Data { // scrcpy 定点滚轮范围为 [-16,16]。
        let fixed = Int16(max(-32768, min(32767, steps * 2048))) // 一步映射为 1/16 全量程。
        return Data([3]) + position + integer(UInt16(0)) + integer(UInt16(bitPattern: fixed)) + integer(UInt32(0)) // 不产生触摸按下或抬起。
    }
    public static func clipboard(_ text: String, paste: Bool) throws -> Data { // SET_CLIPBOARD 支持中文，不受 injectText 的键盘映射限制。
        let raw = Data(text.utf8) // 按 UTF-8 字节计数。
        guard raw.count <= 262130 else { throw HdcError("发送文本超过设备剪贴板协议上限") } // 不截断用户文本。
        return Data([9]) + integer(UInt64(0)) + Data([paste ? 1 : 0]) + integer(UInt32(raw.count)) + raw // sequence=0 表示不要求 ACK。
    }
    public enum VideoHeader: Equatable { // scrcpy 5 的会话尺寸消息与视频帧使用同一十二字节头。
        case size(Int, Int) // session 标记占最高位，不能把高度误当帧长度。
        case frame(length: Int, timing: VideoPacket.Timing?) // 参数集没有可用于播放的时间戳。
    }
    public static func videoHeader(_ data: Data) throws -> VideoHeader { // 直接用于真实接收线程与协议回归。
        guard data.count == 12 else { throw HdcError("Android 视频头长度无效") } // 不读取截断消息。
        let flagsAndPTS = unsigned(data, at: 0, bytes: 8) // 前八字节同时包含帧标记和微秒时间戳。
        if flagsAndPTS & (UInt64(1) << 63) != 0 { // 新编码会话或旋转会发送尺寸元数据。
            let width = Int(unsigned(data, at: 4, bytes: 4)), height = Int(unsigned(data, at: 8, bytes: 4)) // 固定网络序。
            guard (1...65535).contains(width), (1...65535).contains(height) else { throw HdcError("Android 视频尺寸无效") } // 拒绝溢出或零尺寸。
            return .size(width, height) // 该消息本身没有额外 payload。
        }
        let count = Int(unsigned(data, at: 8, bytes: 4)) // 最后四字节为编码帧长度。
        guard count > 0, count <= 32 * 1024 * 1024 else { throw HdcError("Android 视频帧长度无效") } // 限制异常内存分配。
        guard flagsAndPTS & (UInt64(1) << 62) == 0 else { return .frame(length: count, timing: nil) } // 配置包仅更新解码参数。
        let keyFrameFlag = UInt64(1) << 61 // 官方 scrcpy-server 的关键帧标记。
        let pts = Int64(flagsAndPTS & (keyFrameFlag - 1)) // 仅保留低 61 位的微秒值。
        let timing = VideoPacket.Timing(presentationTimeUs: pts, isKeyFrame: flagsAndPTS & keyFrameFlag != 0)
        return .frame(length: count, timing: timing)
    }
}
