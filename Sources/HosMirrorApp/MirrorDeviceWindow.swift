import AppKit
import HosMirrorCore

/// 统一设备窗口的拖动缩放、首次放大、跨屏与标题栏双击行为。
final class MirrorDeviceWindow: NSWindow {
    private(set) var deviceSize = CGSize(width: 1080, height: 2340) // 探测完成前仅用作加载画面的临时比例。
    private var fittedFrame = CGRect.zero // 保存上次屏幕最大尺寸，跨屏时仍能判断窗口是否原本已放大。
    private(set) var snappedFrame: CGRect?
    weak var titleControls: NSView? // 右侧按钮仍接收自己的鼠标事件。
    private var draggingTitle = false
    private var applyingSnapFrame = false // setFrame 可能同步发出移动和缩放通知。
    private var freeCollectionBehavior: NSWindow.CollectionBehavior?
    private var lastFreeLimits: (min: CGSize, max: CGSize)?

    var chromeHeight: CGFloat {
        frame.height - contentRect(forFrameRect: frame).height // 使用当前系统实际标题栏高度，不硬编码到设备比例中。
    }

    var availableScreenFrame: CGRect {
        if let visible = screen?.visibleFrame, !visible.isEmpty { return visible }
        if let visible = NSScreen.main?.visibleFrame, !visible.isEmpty { return visible }
        return CGRect(x: 0, y: 0, width: 1280, height: 900) // 会话切换期间系统可能暂未提供有效屏幕范围。
    }

    var maximumDeviceFrame: CGRect {
        let available = MirrorWindowGeometry.availableSize(keepingTopLeftOf: frame, within: availableScreenFrame) // 当前位置不变，只沿右侧和下方扩大。
        let content = MirrorWindowGeometry.maximumContent(device: deviceSize, visible: available, chromeHeight: chromeHeight)
        return MirrorWindowGeometry.resizedFrame(content: content, keepingTopLeftOf: frame, chromeHeight: chromeHeight) // 最大化不再把窗口移到屏幕中心。
    }

    func updateLayout(device: CGSize, title: String, maximize: Bool = false) {
        guard device.width > 1, device.height > 1 else { return } // 无效探测结果不能破坏现有窗口。
        let wasMaximized = abs(frame.width - fittedFrame.width) < 1 && abs(frame.height - fittedFrame.height) < 1 // 用户只移动窗口时仍保留最大化意图。
        let oldAspect = deviceSize.width / deviceSize.height // 横竖屏变化时需要同步改变两个方向。
        deviceSize = device // 始终使用物理设备尺寸，避免视频编码取整导致比例偏差。
        guard snappedFrame == nil else { return } // 磁吸管理器按新比例重新布局所有窗口。
        contentAspectRatio = device // AppKit 自身先约束用户拖边、拖角的内容比例。
        let maximum = MirrorWindowGeometry.maximumContent(device: device, visible: availableScreenFrame.size, chromeHeight: chromeHeight)
        let labelWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width // 最小宽度同时考虑实际设备名称。
        let preferredWidth = max(340, 2 * (MirrorTitlebarControls.width + 8) + ceil(labelWidth * 0.8) + 12) // 与标题允许的最小字号同步，保留缩小空间且不让文字撞上两侧按钮。
        contentMinSize = MirrorWindowGeometry.minimumContent(device: device, maximum: maximum, preferredWidth: preferredWidth)
        contentMaxSize = maximum // 缩放上限也按同一比例，窗口不能溢出当前可用屏幕。
        fittedFrame = maximumDeviceFrame // 更新双击与跨屏共用的目标。
        if maximize || wasMaximized {
            fitDeviceToScreen() // 首次接通及已最大化窗口旋转时，重新占满可用高度或宽度。
        } else {
            let current = contentRect(forFrameRect: frame).size
            let aspectChanged = abs(oldAspect - device.width / device.height) > 0.00001
            let proposed = aspectChanged ? CGSize(width: current.height * device.width / device.height, height: current.height) : current // 手动缩小后旋转仍保持内容比例。
            let content = MirrorWindowGeometry.constrainedContent(proposed: proposed, current: current, device: device, minimum: contentMinSize, maximum: contentMaxSize)
            let target = MirrorWindowGeometry.resizedFrame(content: content, keepingTopLeftOf: frame, chromeHeight: chromeHeight) // 普通布局更新也保持标题位置，避免连接阶段先居中再放大。
            if frame != target { setFrame(target, display: isVisible) } // 隐藏窗口先定好外框，再由 AppKit 首次绘制。
        }
    }

    func fitDeviceToScreen() {
        guard snappedFrame == nil else { return }
        fittedFrame = maximumDeviceFrame // 每次计算当前屏幕，不复用另一块屏幕的尺寸。
        if frame != fittedFrame { setFrame(fittedFrame, display: isVisible) } // 保持标题栏左上角，隐藏窗口不提前绘制。
    }

    func constrainedFrameSize(_ proposed: CGSize) -> CGSize {
        let current = contentRect(forFrameRect: frame).size
        let content = MirrorWindowGeometry.constrainedContent(proposed: CGSize(width: proposed.width, height: max(1, proposed.height - chromeHeight)), current: current, device: deviceSize, minimum: contentMinSize, maximum: contentMaxSize)
        return CGSize(width: content.width, height: content.height + chromeHeight) // 只有标题栏高度不参与设备缩放。
    }

    override func zoom(_ sender: Any?) {
        fitDeviceToScreen() // 原生缩放命令与首次接通使用同一最大化计算。
    }

    override func sendEvent(_ event: NSEvent) {
        if snappedFrame != nil, let id = identifier?.rawValue {
            let snap = MirrorWindowSnap.shared
            switch event.type {
            case .leftMouseDown:
                snap.revealGroup(from: id) // 视频区点击照常交给手机，也能唤回整组。
                if isTitlebarBackground(event.locationInWindow) {
                    if !isKeyWindow { makeKeyAndOrderFront(nil) }
                    if event.clickCount == 2 {
                        draggingTitle = false
                        snap.maximizeGroup(from: id)
                        return
                    }
                    draggingTitle = true
                    snap.beginDrag(id, at: convertPoint(toScreen: event.locationInWindow), reorder: event.modifierFlags.contains(.option))
                    return
                }
            case .leftMouseDragged where draggingTitle:
                snap.drag(id, to: convertPoint(toScreen: event.locationInWindow))
                return
            case .leftMouseUp where draggingTitle:
                draggingTitle = false
                snap.endDrag(id, at: convertPoint(toScreen: event.locationInWindow))
                return
            default: break
            }
        }
        if event.type == .leftMouseDown, event.clickCount == 2, isTitlebarBackground(event.locationInWindow) {
            fitDeviceToScreen() // 标题空白区域双击固定按设备比例放大，不受系统“填充”偏好拉伸。
            return // 不让原生标题栏再次执行另一次缩放或最小化。
        }
        super.sendEvent(event) // 普通鼠标、键盘与拖动仍交给 AppKit。
    }

    private func isTitlebarBackground(_ point: CGPoint) -> Bool {
        guard point.y >= contentRect(forFrameRect: frame).height else { return false } // 视频内双击仍完整传给手机。
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(kind), button.convert(button.bounds, to: nil).contains(point) { return false } // 不截获交通灯按钮。
        }
        if let titleControls, titleControls.convert(titleControls.bounds, to: nil).contains(point) { return false }
        return true // 居中标题不拦截鼠标，属于可双击的标题背景。
    }

    func setSnapFrame(_ target: CGRect?) {
        if let target {
            if snappedFrame == nil {
                lastFreeLimits = (contentMinSize, contentMaxSize)
                freeCollectionBehavior = collectionBehavior
                isMovable = false
                if isMiniaturized { deminiaturize(nil) }
                standardWindowButton(.miniaturizeButton)?.isEnabled = false
                collectionBehavior.remove(.fullScreenPrimary)
                collectionBehavior.insert(.fullScreenNone)
                if styleMask.contains(.fullScreen) { toggleFullScreen(nil) }
                // 允许多设备排在窄屏上，视频比例由整排布局保证。
                contentMinSize = CGSize(width: 1, height: 1)
                contentMaxSize = CGSize(width: 100_000, height: 100_000)
            }
            snappedFrame = target
            enforceSnapFrame()
        } else {
            guard snappedFrame != nil else { return }
            snappedFrame = nil
            draggingTitle = false
            isMovable = true
            standardWindowButton(.miniaturizeButton)?.isEnabled = true
            if let freeCollectionBehavior { collectionBehavior = freeCollectionBehavior }
            if let lastFreeLimits {
                contentMinSize = lastFreeLimits.min
                contentMaxSize = lastFreeLimits.max
            }
            contentAspectRatio = deviceSize // 使用磁吸期间可能更新的视频比例。
            freeCollectionBehavior = nil
            lastFreeLimits = nil
        }
    }

    func enforceSnapFrame() {
        guard let snappedFrame, !applyingSnapFrame, !styleMask.contains(.fullScreen) else { return }
        applyingSnapFrame = true
        defer { applyingSnapFrame = false }
        if isMiniaturized { deminiaturize(nil) } // 磁吸期间系统最小化命令也不能拆开窗口组。
        guard frame != snappedFrame else { return }
        setFrame(snappedFrame, display: isVisible)
    }

    func reportSnapGeometry(id: String) {
        let geometry = MirrorWindowSnap.Geometry(aspect: deviceSize.width / deviceSize.height,
                                                  titleHeight: chromeHeight, origin: frame.origin)
        MirrorWindowSnap.shared.update(id, geometry: geometry, apply: { [weak self] in self?.setSnapFrame($0) }) { [weak self] in
            guard let self else { return }
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            if self.isMiniaturized { self.deminiaturize(nil) }
            self.orderFrontRegardless()
        }
    }
}
