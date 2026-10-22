import SwiftUI
import UIKit

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
