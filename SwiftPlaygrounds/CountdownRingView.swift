import SwiftUI

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
