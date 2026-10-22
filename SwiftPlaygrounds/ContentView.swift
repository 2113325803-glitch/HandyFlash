import SwiftUI

/// 根视图：两个标签页（采集 / 卡片）。
///
/// 卡片库由这里持有：生命周期等于整个 App，
/// 采集页和卡片页共用同一份数据（收一张卡，卡片页立刻多一格）。
///
/// 每个标签页各自包一层 `NavigationContainer`：
/// - iOS 16 及以上用 `NavigationStack`；
/// - 更老的系统回退到 `NavigationView` + `.stack` 样式
///   （Playgrounds 模板的部署目标可能低于 iOS 16）。
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
