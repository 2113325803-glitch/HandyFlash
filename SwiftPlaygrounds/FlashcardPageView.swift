import SwiftUI
import UIKit

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
