import SwiftUI
import PencilKit
import UIKit

/// 把 `PKCanvasView` 包装成 SwiftUI 视图。
///
/// 设计要点：
/// - `drawingPolicy = .anyInput`：Apple Pencil 和手指都能书写。
/// - 画布固定为可见区域大小，不滚动、不缩放，保证笔迹坐标与背景模板始终对齐。
/// - 背景透明，让下层的单词 / 翻译模板透出来。
struct PencilCanvasView: UIViewRepresentable {
    /// 由 `CaptureController` 持有的画布实例（delegate 也由它设置）。
    /// 必须在 `makeUIView` 中返回同一个实例，否则外部拿到的对象不是屏幕上显示的那一个。
    let canvasView: PKCanvasView

    func makeUIView(context: Context) -> PKCanvasView {
        configure(canvasView)
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // 工具固定，且 SwiftUI 可能在书写过程中频繁刷新（阶段 2 的倒计时）。
        // 这里刻意不做任何设置，避免打断正在进行的笔迹。
    }

    private func configure(_ canvas: PKCanvasView) {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.contentInsetAdjustmentBehavior = .never

        // 工具（颜色 / 粗细）由 `CaptureController.applyTool()` 设置：
        // 这里写死会覆盖用户刚选的笔刷，所以只给一个兜底值。
        if !(canvas.tool is PKInkingTool) {
            canvas.tool = PKInkingTool(.pen, color: UIColor(white: 0.10, alpha: 1), width: 4.5)
        }
        canvas.accessibilityLabel = "手写画布"
    }
}

/// 固定尺寸画布。
///
/// `PKCanvasView` 本质上是 `UIScrollView`，默认的 `contentSize` 会随绘制区域变化。
/// 这里让它始终等于可见区域，并保持 `contentOffset` 为零，保证：
/// 1. 笔迹坐标从画布左上角开始；
/// 2. 与背景模板的 50% 分割线严格对齐；
/// 3. 分屏 / 旋转改变尺寸时不会出现滚动偏移。
final class SketchCanvasView: PKCanvasView {
    private var isSyncingContentSize = false

    override func layoutSubviews() {
        super.layoutSubviews()

        guard !isSyncingContentSize,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        isSyncingContentSize = true
        defer { isSyncingContentSize = false }

        if contentSize != bounds.size {
            contentSize = bounds.size
        }
        if contentOffset != .zero {
            setContentOffset(.zero, animated: false)
        }
    }
}
