import Foundation

/// 连接状态圆点的色调类别（不含具体颜色，颜色映射留给 UI 薄层 Palette）。
///
/// 把「连接态 → 视觉类别」这一规则与具体 UIColor 解耦，便于纯函数单元测试，
/// 同时与 widget 头部状态点的三态（在线 / 连接中 / 离线）对齐。
enum ConnectionDotTone {
    /// 在线（绿）。
    case online
    /// 连接中（琥珀）。
    case connecting
    /// 离线 / 未连接 / 已断开（灰）。
    case offline
}

/// 连接状态展示规则（纯函数）。
///
/// 输入实时连接态，输出头部状态点的色调与中文文案，供自定义 header 绑定。
enum ConnectionStatusPresenter {
    /// 连接态 → 状态点色调。
    ///
    /// - connected：在线；
    /// - connecting：连接中；
    /// - idle / disconnected：离线。
    static func tone(for state: LiveChatConnectionState) -> ConnectionDotTone {
        switch state {
        case .connected:
            return .online
        case .connecting:
            return .connecting
        case .idle, .disconnected:
            return .offline
        }
    }

    /// 连接态 → 头部状态文案（中文）。
    static func label(for state: LiveChatConnectionState) -> String {
        switch state {
        case .connected:
            return "在线"
        case .connecting:
            return "连接中"
        case .idle:
            return "未连接"
        case .disconnected:
            return "连接已断开"
        }
    }
}
