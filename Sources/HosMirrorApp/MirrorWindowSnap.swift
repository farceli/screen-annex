import AppKit

/// 按同一屏幕的可见宽度排列投屏窗口。每台设备仍在自己的原生窗口中显示。
@MainActor
final class MirrorWindowSnap {
    static let shared = MirrorWindowSnap()

    struct Geometry {
        var aspect: CGFloat // 视频宽高比，不包含标题栏。
        var titleHeight: CGFloat // 由当前系统的实际窗口测得。
        var origin: CGPoint // 开启时按现有窗口位置排列。
    }

    private struct Member {
        var geometry: Geometry
        var frame: CGRect?
        let apply: (CGRect?) -> Void // nil 解除约束，窗口保留当前所在位置。
        let reveal: () -> Void // 将同组窗口带到前台，不接管键盘焦点。
    }

    private struct Drag {
        let id: String
        let offset: CGPoint // 按下时指针相对整组左上角的偏移，拖动不会跳位。
        let reorder: Bool
    }

    private var members: [String: Member] = [:]
    private var order: [String] = []
    private var screenID: NSNumber?
    private var groupTopLeft: CGPoint?
    private var activeDrag: Drag?
    private var revealing = false
    private(set) var isEnabled = false

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.groupTopLeft = nil // 显示器断开或缩放后，重新把整组放进可用区域。
                self?.activeDrag = nil
                self?.layout()
            }
        }
    }

    func setEnabled(_ enabled: Bool, on screen: NSScreen? = NSScreen.main) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        groupTopLeft = nil
        activeDrag = nil
        if enabled {
            screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            order.sort { lhs, rhs in
                let left = members[lhs]?.geometry.origin.x ?? 0
                let right = members[rhs]?.geometry.origin.x ?? 0
                return left == right ? lhs < rhs : left < right
            }
            layout()
        } else {
            for id in order {
                members[id]?.frame = nil
                members[id]?.apply(nil)
            }
        }
    }

    func update(_ id: String, geometry: Geometry, apply: @escaping (CGRect?) -> Void, reveal: @escaping () -> Void) {
        guard geometry.aspect.isFinite, geometry.aspect > 0 else { return }
        if var member = members[id] {
            let changed = member.geometry.aspect != geometry.aspect || member.geometry.titleHeight != geometry.titleHeight
            member.geometry = geometry
            members[id] = member
            if changed { layout() } // 手机旋转后调整整排尺寸，窗口顺序不变。
        } else {
            members[id] = Member(geometry: geometry, apply: apply, reveal: reveal)
            order.append(id)
            layout() // 磁吸开启期间新投屏自动加入末尾。
        }
    }

    func remove(_ id: String) {
        guard let removed = members.removeValue(forKey: id) else { return }
        if removed.frame != nil { removed.apply(nil) }
        order.removeAll { $0 == id }
        if activeDrag?.id == id { activeDrag = nil }
        if order.isEmpty { groupTopLeft = nil }
        layout() // 关闭或断开的窗口原位由剩余窗口收拢。
    }

    func revealGroup(from id: String) {
        guard isEnabled, !revealing, members[id]?.frame != nil else { return }
        revealing = true
        defer { revealing = false } // 系统恢复隐藏或最小化窗口时可能同步发出焦点通知。
        for peer in order where peer != id {
            members[peer]?.reveal()
        }
    }

    func maximizeGroup(from id: String) {
        guard isEnabled, let frame = members[id]?.frame else { return }
        // 跨屏拖动后，以被双击的窗口占用面积最大的显示器为准。
        let displays = NSScreen.screens.compactMap { screen -> (screen: NSScreen, area: CGFloat)? in
            let overlap = frame.intersection(screen.frame)
            return overlap.isEmpty ? nil : (screen, overlap.width * overlap.height)
        }
        if let screen = displays.max(by: { $0.area < $1.area })?.screen {
            screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        }
        activeDrag = nil // 释放双击的鼠标按键时不能重新移动已最大化的窗口组。
        groupTopLeft = nil // 按目标屏幕的可见区域统一计算大小和位置。
        layout()
    }

    func beginDrag(_ id: String, at point: CGPoint, reorder: Bool) {
        guard isEnabled, members[id]?.frame != nil, let first = order.first, let frame = members[first]?.frame,
              point.x.isFinite, point.y.isFinite else { return }
        let anchor = CGPoint(x: frame.minX, y: frame.maxY)
        activeDrag = Drag(id: id, offset: CGPoint(x: point.x - anchor.x, y: point.y - anchor.y), reorder: reorder)
    }

    func drag(_ id: String, to point: CGPoint) {
        guard isEnabled, let drag = activeDrag, drag.id == id, point.x.isFinite, point.y.isFinite else { return }
        if drag.reorder {
            reorder(id, toX: point.x)
        } else {
            groupTopLeft = CGPoint(x: (point.x - drag.offset.x).rounded(), y: (point.y - drag.offset.y).rounded())
            layout() // 只平移原有外框，所有窗口仍共用相邻边。
        }
    }

    func endDrag(_ id: String, at point: CGPoint) {
        guard activeDrag?.id == id else { return }
        drag(id, to: point) // Android 合并拖动事件时，也使用最后的释放位置。
        activeDrag = nil
    }

    private func reorder(_ id: String, toX x: CGFloat) {
        guard let oldIndex = order.firstIndex(of: id) else { return }
        var reordered = order
        reordered.remove(at: oldIndex)
        let index = reordered.firstIndex { x < (members[$0]?.frame?.midX ?? x) } ?? reordered.endIndex
        guard index != oldIndex else { return } // 未跨过其他窗口中心时保持原顺序。
        reordered.insert(id, at: index)
        order = reordered
        layout()
    }

    private func layout() {
        guard isEnabled, !order.isEmpty,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID
              }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.integral
        let geometries = order.compactMap { members[$0]?.geometry }
        let maxChrome = geometries.map(\.titleHeight).max() ?? 0
        let totalAspect = geometries.reduce(CGFloat.zero) { $0 + $1.aspect }
        let height = max(1, floor(min(visible.height - maxChrome, visible.width / totalAspect)))
        let widths = geometries.map { max(1, floor(height * $0.aspect)) }
        let anchor = groupTopLeft ?? CGPoint(x: visible.minX + floor((visible.width - widths.reduce(0, +)) / 2), y: visible.maxY)
        var x = anchor.x
        for (id, width) in zip(order, widths) {
            guard var member = members[id] else { continue }
            let outerHeight = height + member.geometry.titleHeight
            let target = CGRect(x: x, y: anchor.y - outerHeight, width: width, height: outerHeight)
            x += width // 相邻窗口共用一条边，统一对齐顶部。
            if member.frame == target { continue }
            member.frame = target
            members[id] = member
            member.apply(target)
        }
    }
}
