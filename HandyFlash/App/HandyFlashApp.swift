import SwiftUI

/// 应用入口。
///
/// 根视图 `RootView` 里是「采集 / 卡片」两个标签页；
/// 阶段 5 会追加复习和设置。
@main
struct HandyFlashApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
