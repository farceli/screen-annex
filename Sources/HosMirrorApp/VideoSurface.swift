import SwiftUI
import AppKit
import HosMirrorCore

final class VideoSurface: NSView, NSTextInputClient {
    var onTouch: ((TouchPhase, CGPoint) -> Void)?
    var onScroll: ((ScrollWheelInput, CGPoint) -> Void)?
    var onKey: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onText: ((String) -> Void)? // 只把 Mac 输入法已确认的文本交给设备。
    var onRightClick: (() -> Void)?
    var onMiddleClick: (() -> Void)? // 中键单独映射桌面，不经过触摸或滚轮通道。
    var videoSize: CGSize = .zero

    private var trackingArea: NSTrackingArea?
    private var lastPoint: CGPoint = .zero
    private var leftButtonDown = false // 只有真正的左键按下才允许发送触摸抬起。
    private var markedText = NSAttributedString(string: "") // 候选文字先留在 Mac 端。
    private var markedSelection = NSRange(location: 0, length: 0)
    private var inputAnchor: CGPoint? // 输入法候选框跟随最近一次手机画面内的点击。

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // 未聚焦时首次点击也发送完整触摸，不只激活窗口。
    override func becomeFirstResponder() -> Bool { true }

    override func resignFirstResponder() -> Bool {
        clearComposition() // 焦点切到 Mac 其他控件时丢弃未确认文字。
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window?.initialFirstResponder == nil { window?.initialFirstResponder = self } // 唤回窗口后仍可直接打字。
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func videoRect() -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func normalized(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = videoRect()
        let x = (point.x - rect.minX) / max(rect.width, 1)
        let y = (rect.maxY - point.y) / max(rect.height, 1)
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        clearComposition() // 点击新的手机输入位置时不能把旧候选字发过去。
        inputAnchor = convert(event.locationInWindow, from: nil)
        leftButtonDown = true // 滚轮事件从不设置这个标记。
        lastPoint = normalized(event)
        onTouch?(.down, lastPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        guard leftButtonDown else { return } // 不为没有起点的事件合成触摸。
        let point = normalized(event)
        lastPoint = point
        onTouch?(.move, point)
    }

    override func mouseUp(with event: NSEvent) {
        guard leftButtonDown else { return } // 拒绝孤立 mouseUp，不能被设备解释成一次点按。
        leftButtonDown = false
        onTouch?(.up, normalized(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return } // 仅滚轮中键触发，鼠标侧键不冒充中键。
        window?.makeFirstResponder(self) // 未聚焦窗口的中键也同时取得键盘焦点。
        onMiddleClick?() // 每次按下只发送一次 Home。
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseUp(with: event) } // 中键抬起不重复触发，也不合成 touchUp。
    }

    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseDragged(with: event) } // 按住中键移动不会重复返回桌面。
    }

    override func scrollWheel(with event: NSEvent) {
        guard !leftButtonDown else { return } // 左键拖拽期间不混入另一种指针事件。
        let endsGesture = !event.phase.intersection([.ended, .cancelled]).isEmpty
        guard event.momentumPhase.isEmpty || endsGesture else { return } // 手机在抬手时产生自己的惯性。
        let input = ScrollWheelInput(
            delta: event.momentumPhase.isEmpty ? Double(event.scrollingDeltaY) : 0,
            precise: event.hasPreciseScrollingDeltas,
            startsGesture: event.phase.contains(.began),
            timestamp: event.timestamp,
            endsGesture: endsGesture,
            viewportHeight: videoRect().height
        )
        onScroll?(input, normalized(event)) // 完整传递精度与手势边界，绝不在视图层合成点击。
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), KeyMap.hardware(event.keyCode) != nil,
           !event.modifierFlags.contains(.command) {
            onKey?(event.keyCode, event.modifierFlags) // 保留手机上的方向键、退格、回车及 Escape。
            return
        }
        interpretKeyEvents([event]) // 让 AppKit 根据当前键盘布局和输入法解析按键。
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard window?.firstResponder === self, modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 123, 126:
            onKey?(event.keyCode, event.modifierFlags) // 保留 Command-左方向键返回、Command-上方向键桌面。
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "v" else { return super.performKeyEquivalent(with: event) }
            paste(nil) // 只在投屏有键盘焦点时读取 Mac 剪贴板。
        }
        return true
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        clearComposition()
        onText?(text)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.attributed(string).string
        markedText = NSAttributedString(string: "") // 确认后的字符串只转发一次。
        if !text.isEmpty { onText?(text) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = Self.attributed(string) // 输入法更新预编辑区时不向设备发送拼音。
        markedSelection = selectedRange
    }

    func unmarkText() {
        let text = markedText.string // 输入法也可通过解除标记来确认当前候选。
        markedText = NSAttributedString(string: "")
        if !text.isEmpty { onText?(text) }
    }

    func clearComposition() {
        guard hasMarkedText() else { return }
        markedText = NSAttributedString(string: "") // 先清空，discard 回调不会误提交。
        inputContext?.discardMarkedText()
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0) // 手机的全文与选区不在 Mac 端读取。
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location < markedText.length else { return nil }
        let slice = NSRange(location: range.location, length: min(range.length, markedText.length - range.location))
        actualRange?.pointee = slice
        return markedText.attributedSubstring(from: slice) // 仅返回本地输入法正在编辑的部分。
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound } // 设备画面无法反查 Mac 文本索引。

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        actualRange?.pointee = range
        let point = inputAnchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let caret = NSRect(x: point.x, y: point.y - 10, width: 2, height: 20)
        return window.convertToScreen(convert(caret, to: nil)) // AppKit 以全局坐标定位候选框。
    }

    private static func attributed(_ value: Any) -> NSAttributedString {
        if let value = value as? NSAttributedString { return value }
        return NSAttributedString(string: value as? String ?? "")
    }
}

struct VideoSurfaceView: NSViewRepresentable {
    let renderer: VideoRenderer
    let deviceSize: CGSize
    let onTouch: (TouchPhase, CGPoint) -> Void
    let onScroll: (ScrollWheelInput, CGPoint) -> Void
    let onKey: (UInt16, NSEvent.ModifierFlags) -> Void
    let onText: (String) -> Void
    let acceptsText: Bool
    let onRightClick: () -> Void
    let onMiddleClick: () -> Void // SwiftUI 更新时同步刷新桌面操作回调。

    func makeNSView(context: Context) -> VideoSurface {
        let view = VideoSurface()
        view.layer = renderer.layer
        view.onTouch = onTouch
        view.onScroll = onScroll
        view.onKey = onKey
        view.onText = acceptsText ? onText : nil
        view.onRightClick = onRightClick
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ view: VideoSurface, context: Context) {
        view.videoSize = deviceSize
        view.onTouch = onTouch
        view.onScroll = onScroll
        view.onKey = onKey
        view.onText = acceptsText ? onText : nil
        if !acceptsText { view.clearComposition() } // 断线时清理本地输入法状态。
        view.onRightClick = onRightClick
        view.onMiddleClick = onMiddleClick
    }
}
