import SwiftUI
import AppKit
import HosMirrorCore

struct MirrorPane: View {
    @ObservedObject var controller: DeviceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion // 系统减少动态效果时直接切换，不播放显影动画。
    @State private var revealFinished = false // 遮罩持续到显影结束，避免首帧发布时闪一下清晰画面。
    @State private var isRevealing = false
    @State private var revealTask: Task<Void, Never>? // 断线或关窗后取消尚未完成的过渡。

    private var showsConnection: Bool {
        controller.busy || controller.reconnectPending || (controller.connected && !revealFinished)
    }

    var body: some View {
        ZStack {
            Color.black
            VideoSurfaceView(
                renderer: controller.renderer,
                deviceSize: controller.videoSize,
                onTouch: { phase, point in controller.touch(phase, at: point) },
                onScroll: { input, point in controller.scroll(input, at: point) },
                onKey: { code, modifiers in
                    if code == 53 && showsConnection { controller.disconnect() } // 旧视频视图仍持有焦点时，Escape 也能取消连接。
                    else { controller.key(code, modifiers: modifiers) }
                },
                onText: { controller.typeText($0) },
                acceptsText: controller.connected && revealFinished,
                onRightClick: { controller.rightClick() },
                onMiddleClick: { controller.press(KeyMap.home) } // 与标题栏“桌面”按钮使用同一个设备键码。
            )
            .allowsHitTesting(controller.connected && revealFinished) // 显影过程中不把点击误发给仍被遮住的视频。
            if showsConnection {
                MirrorConnectionView(
                    deviceName: controller.displayName.isEmpty ? controller.windowTitle : controller.displayName, // 加载页也即时使用自定义名称。
                    previewImage: controller.connectionPreview,
                    isRevealing: isRevealing,
                    onCancel: { controller.disconnect() }
                )
                .overlay { MirrorRightClickView { controller.rightClick() } } // 锁屏没有视频帧时，也能在连接画面上右键唤醒。
                .zIndex(1)
            } else if !controller.connected {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 42, weight: .thin))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(controller.status).foregroundStyle(.white.opacity(0.7))
                    Button("重新连接") { controller.connect() }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.16))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { FileDropPanel(transfers: controller.fileDrops) } // 每个结果保留完整位置或失败原因。
        .overlay { FileDropHighlight(transfers: controller.fileDrops) } // 目标高亮不拦截手机点击或拖放。
        .onChange(of: controller.hasVideoFrame) { _, ready in updateReveal(ready: ready) }
        .onAppear { updateReveal(ready: controller.hasVideoFrame) }
        .onDisappear { revealTask?.cancel() } // 不让离屏动画改变下一次窗口的状态。
    }

    private func updateReveal(ready: Bool) {
        revealTask?.cancel()
        if !ready {
            isRevealing = false // 新连接重新从完全模糊开始。
            revealFinished = false
            return
        }
        if reduceMotion {
            revealFinished = true // 尊重辅助功能，直接显示已经就绪的视频。
            return
        }
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 32_000_000) // 先让新首帧以模糊状态绘制，再启动清晰插值。
            guard !Task.isCancelled, controller.hasVideoFrame else { return }
            withAnimation(.easeInOut(duration: 0.72)) { isRevealing = true } // 同一真实画面由模糊变清晰并移交实时层。
            try? await Task.sleep(nanoseconds: 720_000_000)
            guard !Task.isCancelled, controller.hasVideoFrame else { return }
            revealFinished = true // 清晰过渡完成后移除预览层并释放动画任务。
            revealTask = nil
        }
    }
}

/// 只接收右键，其余事件继续交给下层 SwiftUI，保留 Escape 等原有交互。
private struct MirrorRightClickView: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> Catcher { let view = Catcher(); view.action = action; return view }
    func updateNSView(_ view: Catcher, context: Context) { view.action = action }

    final class Catcher: NSView {
        var action: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } // 加载或锁屏状态的第一次右键也能唤醒手机。
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point), let event = NSApp.currentEvent,
                  [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(event.type) else { return nil } // 不拦截左键或键盘。
            return self
        }
        override func rightMouseDown(with event: NSEvent) { action?() } // 一次按下只发一次唤醒或返回。
        override func rightMouseUp(with event: NSEvent) {}
    }
}
