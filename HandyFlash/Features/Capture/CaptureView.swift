import SwiftUI
import PencilKit
import UIKit
import Combine

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

struct CaptureView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            // 预览用临时目录，避免预览时写入真实的 Documents 数据。
            CaptureView(
                store: FlashcardStore(
                    rootURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("HandyFlashPreview", isDirectory: true)
                )
            )
        }
    }
}
