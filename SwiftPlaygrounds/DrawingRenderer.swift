import Foundation
import PencilKit
import UIKit

/// 把 `PKDrawing` 渲染成图片的工具。
///
/// PencilKit 的渲染方法在主线程调用最稳妥；收卡发生在停笔计时回调（主线程），
/// 且缩略图尺寸有上限，不会造成可感知的卡顿。
enum DrawingRenderer {
    /// 把整页笔迹渲染成图片。
    ///
    /// - Parameter scale: 像素倍率，1 表示 1pt 对应 1px。
    static func pageImage(
        for drawing: PKDrawing,
        pageSize: CGSize,
        scale: CGFloat = 2
    ) -> UIImage? {
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let rect = CGRect(origin: .zero, size: pageSize)
        return drawing.image(from: rect, scale: max(scale, 1))
    }

    /// 生成白底缩略图：等比缩放到 `maxDimension` 以内。
    ///
    /// 页面上没有笔迹的区域很多，先按 2x 渲染再缩小，避免细笔画糊掉。
    static func thumbnailImage(
        for drawing: PKDrawing,
        pageSize: CGSize,
        maxDimension: CGFloat = 640
    ) -> UIImage? {
        guard let fullPageImage = pageImage(for: drawing, pageSize: pageSize, scale: 2) else {
            return nil
        }

        let longestSide = max(pageSize.width, pageSize.height)
        let ratio = min(1, maxDimension / longestSide)
        let targetSize = CGSize(
            width: max(1, (pageSize.width * ratio).rounded()),
            height: max(1, (pageSize.height * ratio).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            fullPageImage.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
