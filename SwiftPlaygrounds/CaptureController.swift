import Foundation
import PencilKit
import UIKit
import Combine

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
