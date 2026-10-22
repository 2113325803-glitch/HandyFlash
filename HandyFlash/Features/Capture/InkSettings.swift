import SwiftUI
import PencilKit
import UIKit

/// 笔迹颜色。
///
/// 纸张永远是白色，所以这里用固定的深色 / 系统红蓝，
/// 不跟随深色模式变化（深色模式下浅色笔迹在白纸上反而看不清）。
enum InkColor: String, CaseIterable, Identifiable {
    case black
    case red
    case blue

    var id: String { rawValue }

    /// 无障碍朗读用的名字。
    var title: String {
        switch self {
        case .black: return "黑色"
        case .red: return "红色"
        case .blue: return "蓝色"
        }
    }

    /// 写进 PencilKit 的颜色。
    var color: UIColor {
        switch self {
        case .black: return UIColor(white: 0.10, alpha: 1)
        case .red: return UIColor(red: 0.82, green: 0.16, blue: 0.16, alpha: 1)
        case .blue: return UIColor(red: 0.11, green: 0.36, blue: 0.82, alpha: 1)
        }
    }
}

/// 笔迹粗细。
///
/// 只给三档：分屏时画布上方很窄，档位太多反而点不中。
enum InkWidth: String, CaseIterable, Identifiable {
    case thin
    case medium
    case thick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thin: return "细"
        case .medium: return "中"
        case .thick: return "粗"
        }
    }

    /// 实际笔宽（pt）。
    var points: CGFloat {
        switch self {
        case .thin: return 2
        case .medium: return 4.5
        case .thick: return 8
        }
    }

    /// 工具栏里圆点的直径（pt）：粗细不同，一眼能分辨。
    var previewDiameter: CGFloat {
        switch self {
        case .thin: return 5
        case .medium: return 9
        case .thick: return 14
        }
    }
}
