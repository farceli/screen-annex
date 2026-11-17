import SwiftUI
import CoreImage // 直接模糊预览像素，原生窗口与离屏截图都得到同样的焦点效果。

/// 连接时显示真实画面的柔焦版本，首帧就绪后把同一画面逐渐变清晰。
struct MirrorConnectionView: View {
    let deviceName: String // 可读的产品名称，而非型号代码。
    let previewImage: CGImage? // 只在内存中保留当前设备的画面，不写入磁盘。
    let isRevealing: Bool // 首帧真正可显示后才进入清晰过渡。
    let onCancel: () -> Void // Escape 取消，界面不再额外显示按钮文案。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let previewImage {
                    MirrorPreviewFocus(image: previewImage, size: geometry.size, radius: isRevealing ? 0 : 36)
                        .scaleEffect(isRevealing ? 1 : 1.08) // 同一张真实画面在清晰过程中恢复原始比例。
                } else {
                    MirrorConnectionBackdrop() // 初次连接尚无画面时使用自行绘制的中性色背景。
                        .blur(radius: isRevealing ? 0 : 22, opaque: true)
                }
                Color.white.opacity(isRevealing ? 0 : 0.54) // 柔和磨砂感保证两行深色文字在暗画面上也可读。
                    .allowsHitTesting(false)
                VStack(spacing: 5) { // 仅两行，紧挨排列；不再显示阶段说明、转圈或取消按钮。
                    Text("正在连接")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.black.opacity(0.88))
                    Text(deviceName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6) // 长名称仍保持用户要求的总共两行。
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center) // 相对整个内容区水平和垂直居中。
                .opacity(isRevealing ? 0 : 1)
                .blur(radius: isRevealing ? 4 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: isRevealing) // 文字先轻柔消失，随后完整显露视频。
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在连接，\(deviceName)")
                .accessibilityHint("按 Escape 取消连接")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .opacity(isRevealing ? 0 : 1) // 清晰过程中同步移交给下面正在更新的实时视频。
        .onExitCommand(perform: onCancel) // 不增加任何可见的额外文案。
    }
}

/// 仅在尚无设备画面时使用；自行绘制，不复制或依赖系统 iPhone 镜像的图片资源。
private struct MirrorConnectionBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .linearGradient(
                Gradient(colors: [Color(red: 0.67, green: 0.58, blue: 0.45), Color(red: 0.72, green: 0.69, blue: 0.64), Color(red: 0.19, green: 0.23, blue: 0.31)]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: size.height)
            )) // 香槟、珍珠灰与深灰过渡，避免原先过于鲜艳的独立流光效果。
            context.addFilter(.blur(radius: min(size.width, size.height) * 0.16))
            var ribbon = Path()
            ribbon.move(to: CGPoint(x: -size.width * 0.25, y: size.height * 0.5))
            ribbon.addCurve(to: CGPoint(x: size.width * 1.15, y: -size.height * 0.08), control1: CGPoint(x: size.width * 0.2, y: size.height * 0.05), control2: CGPoint(x: size.width * 1.05, y: size.height * 0.38))
            ribbon.addLine(to: CGPoint(x: size.width * 1.2, y: size.height * 0.28))
            ribbon.addCurve(to: CGPoint(x: -size.width * 0.2, y: size.height * 0.72), control1: CGPoint(x: size.width * 0.6, y: size.height * 0.58), control2: CGPoint(x: size.width * 0.2, y: size.height * 0.36))
            ribbon.closeSubpath()
            context.fill(ribbon, with: .color(.white.opacity(0.72))) // 宽阔柔焦的亮带模拟模糊壁纸的结构，而非不断漂移的色块。
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// 半径参与 SwiftUI 插值，但模糊实际写入预览像素，不依赖窗口合成器是否支持滤镜截图。
private struct MirrorPreviewFocus: View, Animatable {
    let image: CGImage
    let size: CGSize
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue } // 0.72 秒显影期间逐帧改变实际高斯模糊半径。
    }
    private static let context = CIContext(options: [.cacheIntermediates: false]) // 复用线程安全的图像上下文，不缓存屏幕中间帧。

    var body: some View {
        let result = focusedImage() // 预览最长边已限制为 720，单次连接只处理短暂的显影过程。
        return Image(decorative: result, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
    }

    private func focusedImage() -> CGImage {
        guard radius > 0.05, size.width > 0 else { return image } // 清晰后直接复用原图，不继续做滤镜计算。
        let input = CIImage(cgImage: image)
        let pixelRadius = radius * CGFloat(image.width) / size.width // 把窗口逻辑点换算到预览像素。
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: pixelRadius]).cropped(to: input.extent) // 扩展边缘后裁回原图，避免黑边。
        return Self.context.createCGImage(blurred, from: input.extent) ?? image // 滤镜失败时仍能显示原帧并完成连接。
    }
}
