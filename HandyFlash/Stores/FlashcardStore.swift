import Foundation
import PencilKit
import UIKit
import Combine

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
