//
//  ContentView.swift
//  HandyFlash — 单文件版（Swift Playgrounds App 项目）
//
//  用法：
//  1. 直接全选本文件内容，覆盖 Swift Playgrounds 项目里的 ContentView.swift；
//  2. 项目里的 App.swift 保持模板原样（它的 WindowGroup 里调用 ContentView()）；
//  3. 不需要再新建其它 .swift 文件。
//
//  文件内容（阶段 5）：根视图（标签页）+ 卡片模型 + 本地存储 + 笔迹渲染 + PencilKit 画布
//  + 分区模板 + 环形倒计时 + 收卡动画 + 笔刷设置 + 采集控制器 + 采集页
//  + 卡片页（按日期分组 / 沉浸式翻卡 / 点击翻面 / 选择性删除）。
//  卡片写入 Documents/HandyFlash/，重启 App 后仍然存在。
//
//  文件顺序不影响编译，Swift 会把同一模块里的声明一起解析。
//

import SwiftUI
import PencilKit
import UIKit
import Combine
import Foundation

// ============================================================================
// MARK: - 1. 根视图
// ============================================================================
/// 根视图：两个标签页（采集 / 卡片）。
///
/// 卡片库由这里持有：生命周期等于整个 App，
/// 采集页和卡片页共用同一份数据（收一张卡，卡片页立刻多一格）。
///
/// 阶段 5 会追加“复习”和“设置”两个标签。
struct ContentView: View {
    @StateObject private var store = FlashcardStore()

    var body: some View {
        TabView {
            NavigationContainer {
                CaptureView(store: store)
            }
            .tabItem {
                Label("采集", systemImage: "pencil.and.outline")
            }

            NavigationContainer {
                CardsView(store: store)
            }
            .tabItem {
                Label("卡片", systemImage: "square.stack.3d.up")
            }
            // 0 张时不显示角标（`.badge(0)` 会自动隐藏）。
            .badge(store.count)
        }
    }
}

/// 统一的导航容器。
///
/// Swift Playgrounds 的 App 项目部署目标可能低于 iOS 16，因此这里做了版本判断：
/// - iOS 16 及以上：`NavigationStack`
/// - 更老的系统：`NavigationView` + `.stack` 样式（避免 iPad 上自动变成左右分栏）
struct NavigationContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content
            }
        } else {
            NavigationView {
                content
            }
            .navigationViewStyle(.stack)
        }
    }
}

// ============================================================================
// MARK: - 2. 卡片数据模型
// ============================================================================
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
// ============================================================================
// MARK: - 3. 笔迹渲染工具
// ============================================================================
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

// ============================================================================
// MARK: - 4. PencilKit 画布
// ============================================================================
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

        // 纸张始终是白色，因此墨色使用固定的深色，不随深色模式变化。
        canvas.tool = PKInkingTool(
            .pen,
            color: UIColor(white: 0.10, alpha: 1),
            width: 4
        )
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
// ============================================================================
// MARK: - 5. 分区模板
// ============================================================================
/// 画布背景模板：上半区“单词”，下半区“翻译”。
///
/// 模板只负责显示，不接收触摸（`allowsHitTesting(false)`），
/// 所有书写事件都交给上层的 `PKCanvasView`。
struct CanvasTemplateView: View {
    private let dividerColor = Color.black.opacity(0.14)
    private let captionColor = Color.black.opacity(0.22)

    var body: some View {
        GeometryReader { proxy in
            let halfHeight = proxy.size.height / 2

            ZStack(alignment: .topLeading) {
                Color.white

                // 中间虚线：划分单词区和翻译区。
                Canvas { context, size in
                    var divider = Path()
                    divider.move(to: CGPoint(x: 16, y: halfHeight))
                    divider.addLine(
                        to: CGPoint(x: max(16, size.width - 16), y: halfHeight)
                    )
                    context.stroke(
                        divider,
                        with: .color(dividerColor),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                    )
                }

                zoneCaption(title: "单词", english: "WORD")
                    .padding(.top, 14)
                    .padding(.leading, 16)

                zoneCaption(title: "翻译", english: "TRANSLATION")
                    .padding(.top, halfHeight + 14)
                    .padding(.leading, 16)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func zoneCaption(title: String, english: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(english)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(1.2)
        }
        .foregroundStyle(captionColor)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

// ============================================================================
// MARK: - 6. 环形倒计时
// ============================================================================
/// 停笔后的环形倒计时。
///
/// `progress` 是“已等待的比例”（0...1），圆环按剩余比例收缩，
/// 中间显示剩余整秒数。视图本身不接收点击，笔尖落下时画布仍能正常书写。
struct CountdownRingView: View {
    let progress: Double
    let remainingSeconds: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)

            Circle()
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 5)

            Circle()
                .trim(from: 0, to: max(0.001, 1 - clampedProgress))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(3)

            VStack(spacing: 0) {
                Text("\(remainingSeconds)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("秒后收卡")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        .frame(width: 68, height: 68)
        .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(remainingSeconds) 秒后自动收卡")
        .accessibilityHint("继续书写可取消收卡")
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}
// ============================================================================
// MARK: - 7. 收卡动画
// ============================================================================
/// 收卡时的轻量动画：刚收下的卡片从画布中央缩小、滑向右上角的卡片栈。
///
/// 由 `CaptureView` 控制 `isFlying`：先以正常大小出现一帧，再切换到飞行状态。
/// 整个视图 `allowsHitTesting(false)`，不会挡住书写。
struct CaptureFlightOverlay: View {
    let image: UIImage
    let isFlying: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cardWidth = min(size.width * 0.5, 320)
            let aspect = image.size.width / max(image.size.height, 1)
            let cardHeight = min(cardWidth / max(aspect, 0.6), size.height * 0.6)
            let endScale: CGFloat = 0.12

            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                }
                .shadow(
                    color: .black.opacity(isFlying ? 0.10 : 0.22),
                    radius: isFlying ? 6 : 18,
                    x: 0,
                    y: isFlying ? 2 : 10
                )
                .rotationEffect(.degrees(isFlying ? -7 : 0))
                .scaleEffect(isFlying ? endScale : 1)
                .opacity(isFlying ? 0 : 1)
                .position(x: size.width / 2, y: size.height / 2)
                .offset(
                    x: isFlying ? (size.width / 2 - cardWidth * endScale * 0.5 - 26) : 0,
                    y: isFlying ? -(size.height / 2 - cardHeight * endScale * 0.5 - 26) : 0
                )
        }
        .allowsHitTesting(false)
    }
}

// ============================================================================
// MARK: - 8. 本地存储（Documents）
// ============================================================================

/// 卡片的本地存储。
///
/// 目录结构（`Documents/HandyFlash/`）：
///
/// ```text
/// Documents/HandyFlash/
/// ├── index.json                 # 卡片顺序与元数据（很小，一次读完）
/// ├── Drawings/<uuid>.pkdrawing  # PKDrawing.dataRepresentation()
/// └── Thumbnails/<uuid>.png      # 列表 / 复习用缩略图
/// ```
///
/// 为什么一张卡拆成多个文件，而不是把所有卡片塞进同一个大文件：
/// - 收一张卡只写 3 个小文件，不必重写整库；
/// - 每个文件都用 `.atomic` 写入（先写临时文件再原子替换），进程中断也不会留下半个文件；
/// - **索引最后写**，所以索引里出现的卡片一定有对应的笔迹和缩略图；
/// - 某一张卡的文件损坏只影响它自己，其它卡片照常读取。
///
/// 启动时同步读取（MVP 取舍）：卡片数量很大（数千张）时会拖慢冷启动，
/// 阶段 6 如有需要可以改成异步或懒加载。
final class FlashcardStore: ObservableObject {

    // MARK: - 对外状态

    /// 已收下的卡片，最新的在最前面。与磁盘内容保持一致。
    @Published private(set) var cards: [Flashcard] = []

    /// 最近一次存储错误（写入失败、索引损坏等）。
    ///
    /// 视图用弹窗提示；用户关闭弹窗后调用 `clearError()`。
    @Published private(set) var lastErrorMessage: String?

    var count: Int { cards.count }
    var isEmpty: Bool { cards.isEmpty }

    // MARK: - 磁盘布局

    private static let folderName = "HandyFlash"
    private static let drawingsFolderName = "Drawings"
    private static let thumbnailsFolderName = "Thumbnails"
    private static let indexFileName = "index.json"

    private let rootURL: URL
    private let drawingsURL: URL
    private let thumbnailsURL: URL
    private let indexURL: URL

    /// 串行 I/O 队列：保证同一张卡的“写文件 → 写索引”不会乱序。
    private let ioQueue = DispatchQueue(label: "app.handyflash.store.io", qos: .utility)

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - 索引记录

    /// 索引里的一条记录。
    ///
    /// `Flashcard` 本身不参与 `Codable`：笔迹和缩略图都以独立文件保存，
    /// 索引只需要记住“哪张卡、什么时候收的、多大”，既小又便于将来迁移。
    private struct IndexEntry: Codable {
        let id: UUID
        let createdAt: Date
        let pageWidth: Double
        let pageHeight: Double
    }

    // MARK: - 初始化

    /// - Parameter rootURL: 存储根目录；传 `nil` 使用 `Documents/HandyFlash/`。
    ///   预览或测试可以传临时目录，避免碰真实数据。
    init(rootURL: URL? = nil) {
        let root = rootURL ?? Self.defaultRootURL()
        self.rootURL = root
        self.drawingsURL = root.appendingPathComponent(Self.drawingsFolderName, isDirectory: true)
        self.thumbnailsURL = root.appendingPathComponent(Self.thumbnailsFolderName, isDirectory: true)
        self.indexURL = root.appendingPathComponent(Self.indexFileName, isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        cards = loadCards()
    }

    /// `Documents/HandyFlash/`。
    ///
    /// 用 `Documents` 的原因：随 App 卸载一起清理、会被系统备份，且不需要任何额外权限。
    ///
    /// 真机上万一取不到 `documentDirectory`，退回临时目录，保证 App 不会启动即崩
    /// （这种情况极少见，数据不会长期保留）。
    static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - 增删

    /// 收下一张卡片：先更新内存（界面立刻看到张数变化），再在后台写盘。
    func add(_ card: Flashcard) {
        cards.insert(card, at: 0)

        guard let indexData = makeIndexData() else { return }

        let drawingsURL = self.drawingsURL
        let thumbnailsURL = self.thumbnailsURL
        let indexURL = self.indexURL
        let drawingName = Self.drawingFileName(for: card.id)
        let thumbnailName = Self.thumbnailFileName(for: card.id)

        ioQueue.async { [weak self] in
            do {
                try Self.write(card.drawingData, to: drawingsURL.appendingPathComponent(drawingName))
                try Self.write(card.thumbnailData, to: thumbnailsURL.appendingPathComponent(thumbnailName))
                // 索引最后写：保证索引里出现的卡片一定有对应的两个文件。
                try Self.write(indexData, to: indexURL)
            } catch {
                self?.report("保存卡片失败：\(error.localizedDescription)")
            }
        }
    }

    /// 删除若干张卡片：先从内存移除，再在后台更新索引、删掉文件。
    ///
    /// 单张删除（“找回上一张”、集合里左滑删除）和多选删除都走这里，
    /// 保证“索引先写、文件后删”的顺序只有一份实现。
    func remove(ids: [UUID]) {
        let targets = Set(ids)
        guard !targets.isEmpty else { return }

        let countBeforeRemoval = cards.count
        cards.removeAll { targets.contains($0.id) }
        guard cards.count != countBeforeRemoval else { return }

        guard let indexData = makeIndexData() else { return }

        let drawingsURL = self.drawingsURL
        let thumbnailsURL = self.thumbnailsURL
        let indexURL = self.indexURL
        let drawingNames = targets.map { Self.drawingFileName(for: $0) }
        let thumbnailNames = targets.map { Self.thumbnailFileName(for: $0) }

        ioQueue.async { [weak self] in
            do {
                // 先写索引，再删文件：即使中途失败，也只会留下“索引里没有的孤儿文件”，
                // 不会出现“索引里有、文件没了”的坏引用。
                try Self.write(indexData, to: indexURL)
            } catch {
                self?.report("更新卡片索引失败：\(error.localizedDescription)")
                return
            }

            // 文件删不掉也无所谓：索引不再引用它，下次启动不会读到。
            for name in drawingNames {
                try? FileManager.default.removeItem(at: drawingsURL.appendingPathComponent(name))
            }
            for name in thumbnailNames {
                try? FileManager.default.removeItem(at: thumbnailsURL.appendingPathComponent(name))
            }
        }
    }

    /// 删除一张卡片（`remove(ids:)` 的便捷写法）。
    ///
    /// 用于“找回上一张”（卡片回到画布后从库里移除）和单张删除。
    func remove(id: UUID) {
        remove(ids: [id])
    }

    /// 删除全部卡片：先写空索引，再清空两个文件目录。
    ///
    /// 顺序和单张删除一致（索引优先）：即使后面删文件时进程被杀，
    /// 下次启动也只会看到空索引，不会把已经删掉的卡片读回来。
    func removeAll() {
        guard !cards.isEmpty else { return }
        cards.removeAll()

        guard let indexData = makeIndexData() else { return }

        let drawingsURL = self.drawingsURL
        let thumbnailsURL = self.thumbnailsURL
        let indexURL = self.indexURL

        ioQueue.async { [weak self] in
            do {
                try Self.write(indexData, to: indexURL)
            } catch {
                self?.report("清空卡片索引失败：\(error.localizedDescription)")
                return
            }

            // 逐个删文件要循环上百次；整目录清空再重建更快，也避免中途留下半个状态。
            Self.resetDirectory(at: drawingsURL)
            Self.resetDirectory(at: thumbnailsURL)
        }
    }

    // MARK: - 读取

    /// 读取索引和每张卡的文件。
    ///
    /// 任何一步失败都不会让 App 崩：能读多少读多少，并把原因交给 `lastErrorMessage`。
    private func loadCards() -> [Flashcard] {
        do {
            try createDirectoriesIfNeeded()
        } catch {
            report("无法创建存储目录：\(error.localizedDescription)")
            return []
        }

        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return []   // 首次启动：还没有任何卡片。
        }

        let entries: [IndexEntry]
        do {
            let data = try Data(contentsOf: indexURL)
            entries = try decoder.decode([IndexEntry].self, from: data)
        } catch {
            // 索引损坏：改名保留现场（不直接删除用户数据），本次以空库启动。
            let backupURL = quarantineIndexFile()
            let note = backupURL.map { "，原文件已改名为 \($0.lastPathComponent)" } ?? ""
            report("卡片索引读取失败\(note)：\(error.localizedDescription)")
            return []
        }

        var loaded: [Flashcard] = []
        var skipped = 0

        for entry in entries {
            let pageSize = CGSize(width: entry.pageWidth, height: entry.pageHeight)
            if let card = loadCard(id: entry.id, createdAt: entry.createdAt, pageSize: pageSize) {
                loaded.append(card)
            } else {
                skipped += 1
            }
        }

        if skipped > 0 {
            // 索引里有、文件缺失（例如被外部清理过）：重写索引，避免每次启动都跳过一遍。
            report("有 \(skipped) 张卡片的数据不完整，已跳过。")
            writeIndexSnapshot(of: loaded)
        }

        return loaded
    }

    private func loadCard(id: UUID, createdAt: Date, pageSize: CGSize) -> Flashcard? {
        let drawingURL = drawingsURL.appendingPathComponent(Self.drawingFileName(for: id))
        let thumbnailURL = thumbnailsURL.appendingPathComponent(Self.thumbnailFileName(for: id))

        guard let drawingData = try? Data(contentsOf: drawingURL),
              let thumbnailData = try? Data(contentsOf: thumbnailURL) else {
            return nil
        }

        return Flashcard(
            id: id,
            createdAt: createdAt,
            drawingData: drawingData,
            thumbnailData: thumbnailData,
            pageSize: pageSize
        )
    }

    // MARK: - 索引

    private func makeIndexData() -> Data? {
        do {
            return try encoder.encode(Self.indexEntries(for: cards))
        } catch {
            report("卡片索引编码失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 同步重写索引（只在启动清理缺失卡片时使用，索引很小）。
    private func writeIndexSnapshot(of cards: [Flashcard]) {
        do {
            let data = try encoder.encode(Self.indexEntries(for: cards))
            try Self.write(data, to: indexURL)
        } catch {
            report("整理卡片索引失败：\(error.localizedDescription)")
        }
    }

    private static func indexEntries(for cards: [Flashcard]) -> [IndexEntry] {
        cards.map { card in
            IndexEntry(
                id: card.id,
                createdAt: card.createdAt,
                pageWidth: Double(card.pageSize.width),
                pageHeight: Double(card.pageSize.height)
            )
        }
    }

    // MARK: - 文件工具

    private func createDirectoriesIfNeeded() throws {
        let manager = FileManager.default
        for url in [rootURL, drawingsURL, thumbnailsURL] where !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// 把损坏的索引改名保留，返回新位置（失败返回 `nil`）。
    private func quarantineIndexFile() -> URL? {
        let manager = FileManager.default
        let stamp = Self.fileTimestampFormatter.string(from: Date())
        let backupURL = rootURL.appendingPathComponent("index-corrupt-\(stamp).json")

        do {
            if manager.fileExists(atPath: backupURL.path) {
                try manager.removeItem(at: backupURL)
            }
            try manager.moveItem(at: indexURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    /// 原子写入：`.atomic` 会先写临时文件再替换目标文件，进程被杀也不会留下半个文件。
    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// 清空目录内容并重新创建。
    ///
    /// 目录本身必须存在：`.atomic` 写入不会自动创建中间的目录，
    /// 所以删掉之后要立刻重建，否则下一张卡片会写盘失败。
    private static func resetDirectory(at url: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func drawingFileName(for id: UUID) -> String {
        id.uuidString + ".pkdrawing"
    }

    private static func thumbnailFileName(for id: UUID) -> String {
        id.uuidString + ".png"
    }

    // MARK: - 错误提示

    /// 记录一条存储错误，供界面弹窗提示。
    ///
    /// 可能来自后台 I/O 队列，所以统一回到主线程再发布。
    private func report(_ message: String) {
        // Playgrounds 的控制台也能看到，方便在 iPad 上排查。
        print("[HandyFlash] \(message)")

        if Thread.isMainThread {
            lastErrorMessage = message
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.lastErrorMessage = message
            }
        }
    }

    /// 用户看过提示后调用。
    func clearError() {
        guard lastErrorMessage != nil else { return }
        lastErrorMessage = nil
    }
}

// ============================================================================
// MARK: - 9. 采集控制器（停笔计时 / 自动收卡 / 撤销）
// ============================================================================
// ----------------------------------------------------------------------------
// MARK: - 9.1 笔刷（颜色 / 粗细）
// ----------------------------------------------------------------------------

/// 笔迹颜色。
///
/// 纸张永远是白色，所以这里用固定的深色 / 系统红蓝，
/// 不跟随深色模式变化（深色模式下浅色笔迹在白纸上反而看不清）。
enum InkColor: String, CaseIterable, Identifiable {
    case black
    case red
    case blue

    var id: String { rawValue }

    /// 无障碍朗读用的名字。
    var title: String {
        switch self {
        case .black: return "黑色"
        case .red: return "红色"
        case .blue: return "蓝色"
        }
    }

    /// 写进 PencilKit 的颜色。
    var color: UIColor {
        switch self {
        case .black: return UIColor(white: 0.10, alpha: 1)
        case .red: return UIColor(red: 0.82, green: 0.16, blue: 0.16, alpha: 1)
        case .blue: return UIColor(red: 0.11, green: 0.36, blue: 0.82, alpha: 1)
        }
    }
}

/// 笔迹粗细。
///
/// 只给三档：分屏时画布上方很窄，档位太多反而点不中。
enum InkWidth: String, CaseIterable, Identifiable {
    case thin
    case medium
    case thick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thin: return "细"
        case .medium: return "中"
        case .thick: return "粗"
        }
    }

    /// 实际笔宽（pt）。
    var points: CGFloat {
        switch self {
        case .thin: return 2
        case .medium: return 4.5
        case .thick: return 8
        }
    }

    /// 工具栏里圆点的直径（pt）：粗细不同，一眼能分辨。
    var previewDiameter: CGFloat {
        switch self {
        case .thin: return 5
        case .medium: return 9
        case .thick: return 14
        }
    }
}


/// 采集页的核心逻辑：停笔计时、自动收卡、撤销收卡。
///
/// 所有入口都在主线程执行（SwiftUI 事件、`PKCanvasViewDelegate` 回调、主 RunLoop 上的
/// `Timer`），因此直接修改 `@Published` 属性是安全的，视图也会同步刷新。
final class CaptureController: NSObject, ObservableObject {

    // MARK: - 画布

    /// 屏幕上正在显示的画布实例，由本控制器持有并设置 delegate。
    ///
    /// 必须与 `PencilCanvasView(canvasView:)` 传入的是同一个对象，
    /// 否则收卡时读到的笔迹不是用户实际书写的那一张。
    let canvasView: SketchCanvasView

    /// 卡片库（写入 `Documents`）。收卡与找回都会经过它。
    let store: FlashcardStore

    // MARK: - 收卡状态

    /// 已收下的卡片，最新的在最前面。
    ///
    /// 直接转发存储里的数据：界面上看到的张数就是磁盘上真实保存的张数，
    /// 不会出现“界面显示 3 张、重启后只剩 2 张”的情况。
    var capturedCards: [Flashcard] { store.cards }

    /// 画布上是否有笔迹。用于按钮可用状态与“空画布不触发收卡”。
    @Published private(set) var hasContent = false

    /// 是否正在停笔倒计时。
    @Published private(set) var isCountingDown = false

    /// 倒计时进度：0 = 刚开始，1 = 到点。
    @Published private(set) var countdownProgress: Double = 0

    /// 收卡事件（附带卡片缩略图），供采集页播放“滑入卡片栈”的动画。
    ///
    /// 使用 `PassthroughSubject` 而不是 `@Published`，避免视图重建时重放旧事件。
    let captureEvents = PassthroughSubject<UIImage, Never>()

    // MARK: - 可调参数（阶段 5 接入设置页）

    /// 停笔后是否自动收卡。
    @Published var autoCaptureEnabled = true {
        didSet {
            if !autoCaptureEnabled {
                cancelCountdown()
            }
        }
    }

    /// 停笔停留多久后收卡（秒），限制在 1～10。
    @Published var holdDuration: TimeInterval = 3 {
        didSet {
            let clamped = min(max(holdDuration, 1), 10)
            if clamped != holdDuration {
                holdDuration = clamped
            }
        }
    }

    // MARK: - 笔刷（颜色 / 粗细）

    /// 当前笔色。改完立刻写回画布，不用等下一次落笔。
    @Published var inkColor: InkColor = .black {
        didSet { applyTool() }
    }

    /// 当前笔迹粗细。
    @Published var inkWidth: InkWidth = .medium {
        didSet { applyTool() }
    }

    // MARK: - 私有状态

    private var countdownTimer: Timer?
    private var countdownStartedAt: Date?

    /// 每秒刷新次数。30fps 足够让环形进度看起来连续，又不会太耗电。
    private let countdownTickInterval: TimeInterval = 1.0 / 30.0

    // MARK: - 生命周期

    /// - Parameter store: 应用唯一的卡片库。`CaptureView` 在初始化时把根视图持有的实例传进来，
    ///   保证收下的卡片立刻进入同一个存储（阶段 4 的卡片栈看到的也是它）。
    init(store: FlashcardStore) {
        self.store = store
        canvasView = SketchCanvasView()
        super.init()
        canvasView.delegate = self
        // 画布的初始工具由这里设置（`PencilCanvasView` 不再写死颜色粗细）。
        applyTool()
    }

    deinit {
        countdownTimer?.invalidate()
    }

    // MARK: - 笔刷

    /// 把当前颜色 / 粗细写回画布。
    ///
    /// `PencilCanvasView.updateUIView` 刻意什么都不做（避免打断正在写的笔迹），
    /// 所以工具由控制器直接设置：按钮一点，下一次落笔就是新的颜色和粗细。
    func applyTool() {
        canvasView.tool = PKInkingTool(.pen, color: inkColor.color, width: inkWidth.points)
    }

    // MARK: - 对外操作

    /// 是否还有可以找回的卡片。
    var canUndoLastCapture: Bool { !capturedCards.isEmpty }

    /// 立即把当前笔迹收成一张卡片并清空画布。空画布不会产生卡片。
    @discardableResult
    func captureNow() -> Flashcard? {
        cancelCountdown()

        let drawing = canvasView.drawing
        let pageSize = canvasView.bounds.size

        guard !drawing.strokes.isEmpty,
              let card = Flashcard(drawing: drawing, pageSize: pageSize) else {
            // 空画布 / 尺寸异常：只同步状态，不产生空卡片。
            refreshHasContent()
            return nil
        }

        // 写入本地存储：内存立刻更新，文件在后台队列里原子写入。
        store.add(card)

        // 清空画布，准备写下一张。
        // 直接赋值 `drawing` 不会触发新的收卡，收卡只由本方法产生。
        canvasView.drawing = PKDrawing()
        hasContent = false

        if let thumbnail = card.thumbnailImage {
            captureEvents.send(thumbnail)
        }
        return card
    }

    /// 找回最近一张收卡：把它的笔迹放回画布，并从存储中移除。
    ///
    /// 调用前若画布上已有内容，由调用方负责提示“会替换当前笔迹”。
    @discardableResult
    func undoLastCapture() -> Bool {
        guard let card = capturedCards.first, let drawing = card.drawing else { return false }

        cancelCountdown()
        store.remove(id: card.id)
        canvasView.drawing = drawing
        hasContent = !drawing.strokes.isEmpty
        return true
    }

    /// 手动清空画布（不产生卡片）。
    func clearCanvas() {
        cancelCountdown()
        canvasView.drawing = PKDrawing()
        hasContent = false
    }

    /// 取消停笔倒计时。
    ///
    /// 重新落笔、切到后台、关闭自动收卡、手动清空时都会调用。
    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownStartedAt = nil

        if isCountingDown {
            isCountingDown = false
        }
        if countdownProgress != 0 {
            countdownProgress = 0
        }
    }

    // MARK: - 停笔计时

    /// 停笔后开始倒计时；空画布或关闭自动收卡时什么都不做。
    private func scheduleCountdownIfNeeded() {
        guard autoCaptureEnabled else { return }
        guard !canvasView.drawing.strokes.isEmpty else { return }

        cancelCountdown()

        countdownStartedAt = Date()
        countdownProgress = 0
        isCountingDown = true

        let timer = Timer(timeInterval: countdownTickInterval, repeats: true) { [weak self] _ in
            self?.countdownTick()
        }
        timer.tolerance = countdownTickInterval * 0.25
        // .common 模式：即使手指正在拖动（tracking mode），计时也不会暂停。
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func countdownTick() {
        guard let startedAt = countdownStartedAt else { return }

        // 倒计时期间内容被擦空（例如全部擦除），取消收卡。
        guard !canvasView.drawing.strokes.isEmpty else {
            cancelCountdown()
            return
        }

        let duration = max(holdDuration, 0.5)
        let elapsed = Date().timeIntervalSince(startedAt)

        if elapsed >= duration {
            // captureNow() 内部会取消计时器。
            captureNow()
        } else {
            countdownProgress = min(1, elapsed / duration)
        }
    }

    /// 同步“画布是否为空”。只在值变化时发布，减少无意义的视图刷新。
    private func refreshHasContent() {
        let value = !canvasView.drawing.strokes.isEmpty
        if value != hasContent {
            hasContent = value
        }
    }
}

// MARK: - PKCanvasViewDelegate

extension CaptureController: PKCanvasViewDelegate {

    /// 落笔：取消正在进行的倒计时（继续书写不打断）。
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        cancelCountdown()
    }

    /// 停笔：画布不为空时开始倒计时。
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        refreshHasContent()
        scheduleCountdownIfNeeded()
    }

    /// 笔迹变化时同步“画布是否为空”（例如全部擦除后应禁用收卡按钮）。
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        refreshHasContent()
    }
}

// ============================================================================
// MARK: - 10. 采集页
// ============================================================================

/// 采集页：一张可以手写的“纸”。
///
/// 上半区用于写单词，下半区用于写翻译。
/// 停笔超过设定时间后，`CaptureController` 会自动把当前笔迹收成一张卡片并清空画布。
struct CaptureView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 卡片库：张数显示、存储错误提示都读它。
    @ObservedObject var store: FlashcardStore

    /// 画布实例、停笔计时、自动收卡逻辑都由它持有。
    @StateObject private var controller: CaptureController

    /// - Parameter store: 根视图持有的卡片库，进入页面后不再更换。
    init(store: FlashcardStore) {
        self.store = store
        // `StateObject` 的自动闭包只在首次创建时执行：
        // 之后视图重建不会替换控制器（画布实例和倒计时都依赖这一点）。
        _controller = StateObject(wrappedValue: CaptureController(store: store))
    }

    @State private var showsClearConfirmation = false
    @State private var showsUndoConfirmation = false

    // 收卡动画：先以正常大小显示刚收下的卡片，再缩小滑向右上角。
    @State private var flyingThumbnail: UIImage?
    @State private var isFlying = false
    @State private var flightToken = 0

    var body: some View {
        VStack(spacing: 10) {
            if verticalSizeClass != .compact {
                hintBar
            }

            // 笔刷工具栏紧贴画布上方：改颜色 / 粗细不用离开书写区域。
            brushBar

            drawingSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("HandyFlash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .confirmationDialog(
            "清空画布？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                controller.clearCanvas()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前笔迹会被清除，且不会被收成卡片。")
        }
        .confirmationDialog(
            "找回上一张？",
            isPresented: $showsUndoConfirmation,
            titleVisibility: .visible
        ) {
            Button("替换当前笔迹") {
                controller.undoLastCapture()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("画布上已有笔迹，找回上一张会替换当前内容。")
        }
        .onReceive(controller.captureEvents) { thumbnail in
            playCaptureAnimation(with: thumbnail)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // 切到后台或被 Slide Over 遮住时放弃倒计时，避免回来时“莫名其妙”收卡。
            controller.cancelCountdown()
        }
        .onDisappear {
            controller.cancelCountdown()
        }
        .alert(
            "存储出错了",
            isPresented: Binding(
                get: { store.lastErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { store.clearError() }
                }
            )
        ) {
            Button("好", role: .cancel) {
                store.clearError()
            }
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
    }

    // MARK: - 顶部提示条

    /// 横屏分屏高度很小时隐藏，给画布留出空间。
    private var hintBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.tip")
            Text("上半区写单词，下半区写翻译")
            Spacer(minLength: 8)
            statusText
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    /// 右侧状态：倒计时 > 已存张数 > 默认说明。
    @ViewBuilder
    private var statusText: some View {
        if controller.isCountingDown {
            Label("\(remainingSeconds) 秒后收卡", systemImage: "timer")
                .foregroundStyle(Color.accentColor)
        } else if store.count > 0 {
            Label("已存 \(store.count) 张", systemImage: "tray.full")
        } else if controller.autoCaptureEnabled {
            Text("停笔 \(Int(controller.holdDuration.rounded())) 秒自动收卡")
        } else {
            Text("自动收卡已关闭")
        }
    }

    // MARK: - 笔刷工具栏

    /// 画布上方的轻量工具栏：左边选颜色，右边选粗细。
    ///
    /// 放在画布外面而不是浮在画布上：浮动工具栏会盖住上半个页面（单词区），
    /// 而那里正好是最常写的地方。
    private var brushBar: some View {
        HStack(spacing: 6) {
            ForEach(InkColor.allCases) { ink in
                colorButton(for: ink)
            }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            ForEach(InkWidth.allCases) { width in
                widthButton(for: width)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("笔刷工具栏")
    }

    /// 一个颜色按钮：选中的那一个外面多一圈强调色。
    private func colorButton(for ink: InkColor) -> some View {
        let isSelected = controller.inkColor == ink

        return Button {
            controller.inkColor = ink
        } label: {
            Circle()
                .fill(Color(uiColor: ink.color))
                .frame(width: 20, height: 20)
                .padding(4)
                .background {
                    Circle()
                        .fill(isSelected ? Color.black.opacity(0.06) : Color.clear)
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.black.opacity(0.12),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ink.title)
        .accessibilityValue(isSelected ? "已选中" : "")
    }

    /// 一个粗细按钮：圆点越大代表笔迹越粗。
    private func widthButton(for width: InkWidth) -> some View {
        let isSelected = controller.inkWidth == width

        return Button {
            controller.inkWidth = width
        } label: {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.black.opacity(0.06) : Color.clear)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                    }

                Circle()
                    .fill(Color(uiColor: controller.inkColor.color))
                    .frame(width: width.previewDiameter, height: width.previewDiameter)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("笔迹\(width.title)")
        .accessibilityValue(isSelected ? "已选中" : "")
    }

    // MARK: - 画布区域

    /// 背景模板在下，透明的手写画布在上；倒计时和收卡动画叠加在画布内部。
    private var drawingSurface: some View {
        ZStack {
            CanvasTemplateView()
            PencilCanvasView(canvasView: controller.canvasView)

            if controller.isCountingDown {
                VStack {
                    Spacer()
                    CountdownRingView(
                        progress: controller.countdownProgress,
                        remainingSeconds: remainingSeconds
                    )
                    .padding(.bottom, 18)
                }
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }

            if let flyingThumbnail = flyingThumbnail {
                CaptureFlightOverlay(image: flyingThumbnail, isFlying: isFlying)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: controller.isCountingDown)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("手写画布")
        .accessibilityHint("上半区书写单词，下半区书写翻译")
    }

    private var remainingSeconds: Int {
        let progress = min(max(controller.countdownProgress, 0), 1)
        let remaining = controller.holdDuration * (1 - progress)
        return max(1, Int(remaining.rounded(.up)))
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                handleUndoTap()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .disabled(!controller.canUndoLastCapture)
            .accessibilityLabel("找回上一张收卡")
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                controller.captureNow()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(!controller.hasContent)
            .accessibilityLabel("立即收卡")

            Button {
                // 打开清空确认前停止倒计时，避免确认期间先收了一张卡。
                controller.cancelCountdown()
                showsClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!controller.hasContent)
            .accessibilityLabel("清空画布")
        }
    }

    // MARK: - 动作

    private func handleUndoTap() {
        if controller.hasContent {
            // 画布上已有内容，找回会覆盖，先确认。
            // 打开弹窗前停止倒计时，避免弹窗期间又被自动收卡。
            controller.cancelCountdown()
            showsUndoConfirmation = true
        } else {
            controller.undoLastCapture()
        }
    }

    /// 播放“卡片滑入卡片栈”的轻量动画。
    ///
    /// `flightToken` 用于丢弃过期回调：如果连续收卡，只让最后一次动画生效。
    private func playCaptureAnimation(with thumbnail: UIImage) {
        flightToken &+= 1
        let token = flightToken

        flyingThumbnail = thumbnail
        isFlying = false

        // 先让卡片以正常大小渲染一帧，再开始飞行。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            guard token == flightToken else { return }
            withAnimation(.easeIn(duration: 0.42)) {
                isFlying = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            guard token == flightToken else { return }
            flyingThumbnail = nil
            isFlying = false
        }
    }
}

// ============================================================================
// MARK: - 11. 卡片页（按日期分组 + 沉浸式翻卡）
// ============================================================================
// ----------------------------------------------------------------------------
// MARK: - 11.1 日期分组与激励语
// ----------------------------------------------------------------------------

/// 一天收下的所有卡片，对应卡片页里的“集合卡片”。
///
/// 卡片页不再平铺所有卡片：一行代表一天，点进去才是这一天的沉浸式翻卡。
struct CardDayGroup: Identifiable {
    /// 当天零点（`Calendar.startOfDay`），同时用作分组 ID。
    let day: Date

    /// 当天的卡片，最新的在最前面。
    let cards: [Flashcard]

    var id: Date { day }

    var count: Int { cards.count }

    /// 集合卡片的封面：当天最新的一张。
    var cover: Flashcard? { cards.first }
}

extension FlashcardStore {

    /// 按天分组的卡片，日期从新到旧。
    ///
    /// `cards` 本身是“最新的在最前面”，所以按出现顺序建组就能保持日期倒序，
    /// 不需要再排序（同一天内部也自然是新的在前）。
    var dayGroups: [CardDayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Flashcard]] = [:]

        for card in cards {
            let day = calendar.startOfDay(for: card.createdAt)
            if buckets[day] == nil {
                order.append(day)
            }
            buckets[day, default: []].append(card)
        }

        return order.map { day in
            CardDayGroup(day: day, cards: buckets[day] ?? [])
        }
    }

    /// 某一天的全部卡片（最新的在前）。
    func cards(on day: Date) -> [Flashcard] {
        let calendar = Calendar.current
        return cards.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
    }
}

/// 卡片页顶部随机展示的激励语。
///
/// 全部是短句：顶部只占一行，太长会把列表挤下去。
enum MotivationPhrases {
    static let all: [String] = [
        "每天一张卡，单词不会忘。",
        "写下来的，才是自己的。",
        "今天的五个词，是明天的底气。",
        "慢一点没关系，别停下来。",
        "一笔一画，都是积累。",
        "记不住的时候，就再写一遍。",
        "小卡片，也能攒出大进步。",
        "今天写下的，考试会记得。",
        "单词不怕多，只怕不复习。",
        "写一遍，胜过看十遍。",
        "坚持三十天，你会感谢今天的自己。",
        "每一个生词，都是一次机会。",
        "手写的力量，比想象中大。",
        "再难的词，写三遍就熟了。",
        "今天也要认真写一张。",
        "积累从来不会骗人。"
    ]

    /// 随机取一句；数组为空时（正常不会发生）返回空串，界面自然留空。
    static func random() -> String {
        all.randomElement() ?? ""
    }
}

/// 日期分组的标题格式（“10月21日”）。
///
/// `DateFormatter` 创建成本不低，这里按“是否当年”缓存两个实例，
/// 列表滚动时不会每次新建。
enum CardDayFormatter {
    private static let sameYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let otherYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        let isSameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return (isSameYear ? sameYear : otherYear).string(from: day)
    }
}

// ----------------------------------------------------------------------------
// MARK: - 11.2 卡片页（按日期分组）
// ----------------------------------------------------------------------------

/// 卡片页：按日期分组的卡片库。
///
/// 交互：
/// - 顶部随机显示一句激励语，每次进入页面换一句；
/// - 列表一行代表一天（“10月21日”），点进去是当天的沉浸式翻卡；
/// - 左滑一行可以删除这一天的全部卡片（会先弹确认）。
///
/// 这里不再提供“一次删光所有卡片”的入口：删除只能按天或按张进行。
struct CardsView: View {
    @ObservedObject var store: FlashcardStore

    /// 本次进入页面显示的激励语。
    @State private var motivation = MotivationPhrases.random()

    /// 待确认删除的日期分组；非 `nil` 时弹确认框。
    @State private var pendingDeletion: CardDayGroup?

    var body: some View {
        VStack(spacing: 0) {
            motivationBar

            if store.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("卡片")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 每次回到这一页都换一句：切标签回来、从集合里返回都算。
            motivation = MotivationPhrases.random()
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { pendingDeletion = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("删除这天的 \(pendingDeletion.map(\.count) ?? 0) 张卡片", role: .destructive) {
                if let group = pendingDeletion {
                    // 按天删除：只删这一天的 ID，其它日期不受影响。
                    store.remove(ids: group.cards.map(\.id))
                }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("删除后无法恢复，其它日期的卡片不受影响。")
        }
    }

    // MARK: - 随机激励语

    private var motivationBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)

            Text(motivation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今日激励：\(motivation)")
    }

    // MARK: - 集合列表

    private var list: some View {
        List {
            ForEach(store.dayGroups) { group in
                NavigationLink {
                    DayCollectionView(day: group.day, store: store)
                } label: {
                    CardDayRow(group: group)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeletion = group
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var deletionTitle: String {
        guard let group = pendingDeletion else { return "删除卡片？" }
        return "删除 \(CardDayFormatter.title(for: group.day)) 的卡片？"
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text("还没有卡片")
                .font(.headline)

            Text("去「采集」页写一张，停笔几秒后会自动收进来。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 320)
        .accessibilityElement(children: .combine)
    }
}

/// 集合列表的一行：封面 + 日期 + 当天张数。
struct CardDayRow: View {
    let group: CardDayGroup

    var body: some View {
        HStack(spacing: 12) {
            cover

            VStack(alignment: .leading, spacing: 4) {
                Text(CardDayFormatter.title(for: group.day))
                    .font(.headline)

                Text("\(group.count) 张卡片")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(CardDayFormatter.title(for: group.day))，\(group.count) 张卡片")
        .accessibilityAddTraits(.isButton)
    }

    /// 封面用当天最新一张的缩略图。
    private var cover: some View {
        ZStack {
            Color.white

            if let image = group.cover?.thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        }
    }
}

// ----------------------------------------------------------------------------
// MARK: - 11.3 集合页（沉浸式翻卡 + 多选删除）
// ----------------------------------------------------------------------------

/// 某一天的卡片集合：沉浸式左右滑动 + 轻点翻面。
///
/// 三种状态：
/// - 默认：整页翻卡（`TabView` + `PageTabViewStyle(indexDisplayMode: .never)`，不显示页码点）；
/// - 点右上角“选择”：进入多选，勾选后一次性删除所选；
/// - 卡片被删光：自动退回卡片页。
struct DayCollectionView: View {
    /// 这一天的零点（与 `CardDayGroup.day` 一致）。
    let day: Date

    @ObservedObject var store: FlashcardStore

    @Environment(\.dismiss) private var dismiss

    /// 当前翻到第几张。
    @State private var index = 0

    /// 是否处于多选删除模式。
    @State private var isSelecting = false

    /// 多选模式下勾选的卡片。
    @State private var selection: Set<UUID> = []

    /// 是否正在确认“删除所选”。
    @State private var showsDeleteConfirmation = false

    /// 当天卡片，最新的在最前面。
    private var cards: [Flashcard] { store.cards(on: day) }

    var body: some View {
        Group {
            if cards.isEmpty {
                emptyState
            } else if isSelecting {
                selectionList
            } else {
                pager
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onChange(of: cards.count) { newCount in
            // 删光了就退回卡片页；删到当前页之后就把页码夹回来。
            if newCount == 0 {
                dismiss()
            } else if index >= newCount {
                index = newCount - 1
            }
        }
        .confirmationDialog(
            "删除选中的 \(selection.count) 张卡片？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                store.remove(ids: Array(selection))
                selection.removeAll()
                isSelecting = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，其它日期的卡片不受影响。")
        }
    }

    // MARK: - 沉浸式翻卡

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { pair in
                FlashcardPageView(card: pair.element)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .tag(pair.offset)
            }
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            pagerFooter
                .padding(.bottom, 10)
                .allowsHitTesting(false)
        }
    }

    /// 底部状态条：第几张 / 共几张 + 翻面提示。
    private var pagerFooter: some View {
        HStack(spacing: 8) {
            Text("\(min(index + 1, max(cards.count, 1))) / \(cards.count)")
                .font(.footnote.monospacedDigit())

            Label("轻点卡片翻面", systemImage: "hand.tap")
                .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: - 多选删除

    private var selectionList: some View {
        List {
            ForEach(cards) { card in
                HStack(spacing: 12) {
                    thumbnail(for: card)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.timeFormatter.string(from: card.createdAt))
                            .font(.subheadline)

                        Text("当天第 \(orderNumber(of: card)) 张")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: selection.contains(card.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(card.id) ? Color.accentColor : Color.secondary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSelection(of: card)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        // 左滑单张删除：不用进多选也能删。
                        selection.remove(card.id)
                        store.remove(id: card.id)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(Self.timeFormatter.string(from: card.createdAt))，"
                        + (selection.contains(card.id) ? "已选中" : "未选中")
                )
                .accessibilityAddTraits(.isButton)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func thumbnail(for card: Flashcard) -> some View {
        ZStack {
            Color.white

            if let image = card.thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        }
    }

    private func orderNumber(of card: Flashcard) -> Int {
        (cards.firstIndex { $0.id == card.id } ?? 0) + 1
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("这一天的卡片都删完了")
                .font(.headline)

            Button("返回卡片页") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .padding(32)
    }

    // MARK: - 工具栏

    private var navigationTitle: String {
        if isSelecting {
            return selection.isEmpty ? "选择卡片" : "已选 \(selection.count) 张"
        }
        return CardDayFormatter.title(for: day)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(isSelecting ? "完成" : "选择") {
                toggleSelectionMode()
            }
            .disabled(cards.isEmpty)
            .accessibilityLabel(isSelecting ? "完成选择" : "选择卡片")
        }

        if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selection.isEmpty)
                .accessibilityLabel("删除所选")
            }
        }
    }

    // MARK: - 动作

    private func toggleSelectionMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSelecting.toggle()
            if !isSelecting {
                // 退出多选时清空勾选，下次进来不会残留。
                selection.removeAll()
            }
        }
    }

    private func toggleSelection(of card: Flashcard) {
        if selection.contains(card.id) {
            selection.remove(card.id)
        } else {
            selection.insert(card.id)
        }
    }

    /// 多选列表里的时间：同一天，只显示时分即可。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// ----------------------------------------------------------------------------
// MARK: - 11.4 翻面卡片
// ----------------------------------------------------------------------------

/// 一张“会翻面”的卡片。
///
/// 正面只露出上半页（单词区），下半页用白纸盖住并提示“轻点翻面”；
/// 轻点后 3D 翻转，显示完整的一页（单词 + 翻译）。
///
/// 整页图片用 `PKDrawing` 现场按 2 倍渲染，不是列表里的缩略图，
/// 所以笔迹位置和粗细与书写时完全一致。
struct FlashcardPageView: View {
    let card: Flashcard

    /// 是否已翻到背面。翻开状态每张卡各自持有：翻到下一张时不会串。
    @State private var showsBack = false

    /// 当前 3D 旋转角度：0 = 正面朝前，90 = 侧面（看不见）。
    @State private var rotation: Double = 0

    /// 翻转动画进行中：避免连点把手感弄乱。
    @State private var isFlipping = false

    /// 渲染好的整页图片；`nil` 表示还在渲染。
    @State private var pageImage: UIImage?

    /// 是否已经尝试渲染过（用来区分“渲染中”和“渲染失败”）。
    @State private var didRender = false

    var body: some View {
        GeometryReader { proxy in
            let cardSize = Self.fittedSize(for: card.pageSize, in: proxy.size)

            ZStack {
                // 只渲染朝前的一面：转到 90° 侧面时再换，正面永远不会“反着”露出来。
                if showsBack {
                    back(size: cardSize)
                } else {
                    front(size: cardSize)
                }
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .rotation3DEffect(
                .degrees(rotation),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.32
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                flip()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(showsBack ? "卡片背面：单词和翻译" : "卡片正面：单词")
            .accessibilityHint("轻点翻面")
            .accessibilityAddTraits(.isButton)
        }
        .task {
            // 每张卡只渲染一次；`TabView` 会预加载相邻页，滑过去时通常已经就绪。
            guard !didRender else { return }
            pageImage = Self.render(card)
            didRender = true
        }
    }

    // MARK: - 翻转

    /// 两段式翻转：先转到侧面（90°），换面，再从另一侧转回来。
    ///
    /// 比“旋转 + 透明度交叉”干净：任何时刻最多只有一面朝向用户，
    /// 中途不会看到镜像的字。
    private func flip() {
        guard !isFlipping else { return }
        isFlipping = true

        withAnimation(.easeIn(duration: 0.18)) {
            rotation = 90
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            // 侧面时换面，并瞬间挪到另一侧的对称角度（这一步不加动画）。
            showsBack.toggle()
            rotation = -90

            withAnimation(.easeOut(duration: 0.18)) {
                rotation = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                isFlipping = false
            }
        }
    }

    // MARK: - 两面

    /// 正面：上半页（单词区）原样显示，下半页用白纸盖住。
    private func front(size: CGSize) -> some View {
        VStack(spacing: 0) {
            pageContent(size: size)
                .frame(width: size.width, height: size.height, alignment: .top)
                .frame(width: size.width, height: size.height / 2, alignment: .top)
                .clipped()

            ZStack {
                Color.white

                VStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 18)

                    Label("轻点翻面看翻译", systemImage: "hand.tap")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size.width, height: size.height / 2)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        .clipShape(Self.cardShape)
        .overlay { Self.cardBorder }
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 6)
    }

    /// 背面：完整的一页（单词 + 翻译）。
    private func back(size: CGSize) -> some View {
        pageContent(size: size)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .clipShape(Self.cardShape)
            .overlay { Self.cardBorder }
            .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 6)
    }

    // MARK: - 内容

    @ViewBuilder
    private func pageContent(size: CGSize) -> some View {
        if let pageImage = pageImage {
            Image(uiImage: pageImage)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        } else if didRender {
            placeholder(size: size, message: "这张卡片的笔迹无法读取", symbol: "exclamationmark.triangle")
        } else {
            placeholder(size: size, message: "正在渲染…", symbol: "hourglass")
        }
    }

    private func placeholder(size: CGSize, message: String, symbol: String) -> some View {
        ZStack {
            Color.white

            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))

                Text(message)
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: size.width, height: size.height)
    }

    private static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private static var cardBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
    }

    // MARK: - 尺寸与渲染

    /// 按卡片长宽比缩放到容器内（留出前后页的间距）。
    private static func fittedSize(for pageSize: CGSize, in container: CGSize) -> CGSize {
        guard pageSize.width > 0, pageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGSize(width: max(container.width, 1), height: max(container.height, 1))
        }

        let scale = min(container.width / pageSize.width, container.height / pageSize.height)
        return CGSize(
            width: max((pageSize.width * scale).rounded(.down), 1),
            height: max((pageSize.height * scale).rounded(.down), 1)
        )
    }

    private static func render(_ card: Flashcard) -> UIImage? {
        guard let drawing = card.drawing else { return nil }
        // 2 倍图：放大查看时笔迹边缘依然干净。
        return DrawingRenderer.pageImage(for: drawing, pageSize: card.pageSize, scale: 2)
    }
}

// ============================================================================
// MARK: - 12. 可选：App 入口（默认不要启用）
// ============================================================================
//
// 项目里通常已有模板生成的 App.swift，内容是：
//
//     import SwiftUI
//
//     @main
//     struct HandyFlashApp: App {
//         var body: some Scene {
//             WindowGroup {
//                 ContentView()
//             }
//         }
//     }
//
// 这种情况下保持原样即可，本文件不要再写 @main，否则会出现两个入口。
//
// 只有在项目里没有 App.swift（编译报 “no entry point” 之类的错误）时，
// 才把下面 7 行行首的 // 删掉：
//
// @main
// struct HandyFlashApp: App {
//     var body: some Scene {
//         WindowGroup {
//             ContentView()
//         }
//     }
// }
