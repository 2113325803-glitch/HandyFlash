import Foundation
import PencilKit
import UIKit

/// 一张手写闪卡。
///
/// 卡片是纯数据：笔迹（`PKDrawing` 序列化后的二进制）和缩略图（PNG）。
/// 落盘由 `FlashcardStore` 负责，本类型不关心文件路径。
struct Flashcard: Identifiable, Equatable {
    let id: UUID

    /// 收卡时间。
    let createdAt: Date

    /// 整页笔迹，来自 `PKDrawing.dataRepresentation()`。
    let drawingData: Data

    /// 列表 / 复习用的缩略图（PNG 数据）。
    let thumbnailData: Data

    /// 收卡时画布的尺寸。
    ///
    /// 复习时需要按这个比例还原版式（上半个页面是单词区），
    /// 否则不同分屏宽度下收的卡片版式会不一致。
    let pageSize: CGSize

    /// 用当前画布笔迹生成一张卡片。
    ///
    /// - Returns: 空笔迹、非法尺寸或缩略图生成失败时返回 `nil`，避免产生空卡片。
    init?(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        drawing: PKDrawing,
        pageSize: CGSize
    ) {
        guard !drawing.strokes.isEmpty else { return nil }
        guard pageSize.width >= 1, pageSize.height >= 1 else { return nil }
        guard let thumbnail = DrawingRenderer.thumbnailImage(for: drawing, pageSize: pageSize),
              let thumbnailData = thumbnail.pngData() else {
            return nil
        }

        self.id = id
        self.createdAt = createdAt
        self.drawingData = drawing.dataRepresentation()
        self.thumbnailData = thumbnailData
        self.pageSize = pageSize
    }

    /// 从磁盘上的原始数据还原卡片。
    ///
    /// 与上面的便捷初始化器不同，这里**不重新渲染缩略图**：
    /// 启动时给每张卡重算一次缩略图会明显拖慢冷启动。
    ///
    /// - Returns: 数据为空、尺寸非法或笔迹无法解析时返回 `nil`。
    init?(
        id: UUID,
        createdAt: Date,
        drawingData: Data,
        thumbnailData: Data,
        pageSize: CGSize
    ) {
        guard !drawingData.isEmpty, !thumbnailData.isEmpty else { return nil }
        guard pageSize.width >= 1, pageSize.height >= 1 else { return nil }
        // 笔迹解析失败说明文件已损坏，宁可跳过这张卡，也不要让“找回上一张”把空笔迹放回画布。
        guard (try? PKDrawing(data: drawingData)) != nil else { return nil }

        self.id = id
        self.createdAt = createdAt
        self.drawingData = drawingData
        self.thumbnailData = thumbnailData
        self.pageSize = pageSize
    }

    /// 反序列化后的笔迹；数据损坏时返回 `nil`。
    var drawing: PKDrawing? {
        try? PKDrawing(data: drawingData)
    }

    var thumbnailImage: UIImage? {
        UIImage(data: thumbnailData)
    }
}
