import SwiftUI

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
