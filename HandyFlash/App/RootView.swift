import SwiftUI

/// 应用的根视图。
///
/// 现在是两个标签页：采集 / 卡片。
/// 阶段 5 会追加“复习”和“设置”两个标签。
///
/// 卡片库由根视图持有：它的生命周期等于整个 App，
/// 采集页和卡片页共用同一份数据（收一张卡，卡片页立刻多一格）。
struct RootView: View {
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

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
    }
}
