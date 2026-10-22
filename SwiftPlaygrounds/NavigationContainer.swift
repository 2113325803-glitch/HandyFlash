import SwiftUI

/// 统一的导航容器。
///
/// Xcode 版最低支持 iOS 16，本来可以直接写 `NavigationStack`；
/// 但为了和 Swift Playgrounds 版共用同一份代码（Playgrounds 模板的部署目标可能低于
/// iOS 16），这里仍然保留 `NavigationView` 回退。
///
/// `NavigationView` 上加了 `.navigationViewStyle(.stack)`：iPad 上默认会变成左右分栏，
/// `.stack` 强制使用堆栈式导航，标签页和弹层里的表现才和 iPhone 一致。
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
