import Foundation

/// HarmonyOS key codes injected through `uinput`.
public enum KeyMap {
    struct Stroke {
        let code: UInt32
        let shift: Bool
    }

    public static let home: UInt32 = 1
    public static let back: UInt32 = 2
    public static let power: UInt32 = 18
    public static let volumeUp: UInt32 = 16
    public static let volumeDown: UInt32 = 17
    public static let recent: UInt32 = 2720
    public static let enter: UInt32 = 2054
    public static let backspace: UInt32 = 2055

    public static func hardware(_ macKeyCode: UInt16) -> UInt32? {
        switch macKeyCode {
        case 53: return back        // esc
        case 36: return enter       // return
        case 51: return backspace   // delete
        case 48: return 2049        // tab
        case 117: return 2071       // forward delete
        case 123: return 2014       // left
        case 124: return 2015       // right
        case 125: return 2013       // down
        case 126: return 2012       // up
        default: return nil
        }
    }

    public static func command(_ code: UInt32) -> String {
        "uinput -K -d \(code) -u \(code)"
    }

    static func asciiStrokes(for text: String) -> [Stroke]? {
        guard text.utf8.count <= 3 else { return nil } // 连续短输入走按键，长文本一次交给系统输入工具。
        var strokes: [Stroke] = []
        for byte in text.utf8 {
            let key: UInt32
            let shift: Bool
            switch byte {
            case 97...122: (key, shift) = (2017 + UInt32(byte - 97), false) // a–z
            case 65...90: (key, shift) = (2017 + UInt32(byte - 65), true) // A–Z
            case 48...57: (key, shift) = (2000 + UInt32(byte - 48), false) // 0–9
            case 32: (key, shift) = (2050, false) // 空格
            default: return nil // 标点和 Unicode 仍按文本交给设备当前输入框。
            }
            strokes.append(Stroke(code: key, shift: shift))
        }
        return strokes
    }
}
