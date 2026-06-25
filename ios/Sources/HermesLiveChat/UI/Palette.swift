import UIKit

/// Hermes 客服界面的固定调色板。
///
/// iOS 端原先全用系统语义色（`.systemBackground` / `.systemBlue` / `.label` 等），
/// 在不同系统外观下观感不稳定。这里把 widget（网页客服）的卡片化蓝色风格固化为常量，
/// 取值与 widget `frame.css` 同源，禁止在 UI 代码里散落裸 `UIColor(red:...)`。
enum Palette {
    /// 主色：访客气泡底、发送按钮、链接、在线状态点。
    static let primary = UIColor(hex: 0x2563EB)
    /// 主色之上的前景（白）。
    static let onPrimary = UIColor.white
    /// 屏幕背景。
    static let screenBackground = UIColor(hex: 0xF5F7FB)
    /// 面色：header / composer / bot 气泡（白）。
    static let surface = UIColor.white
    /// bot 气泡描边色。
    static let botBubbleBorder = UIColor(hex: 0xE2E8F0)
    /// 弱面色：行内 code 底、图片占位底、输入框填充。
    static let surfaceMuted = UIColor(hex: 0xF1F5F9)
    /// 主文本色。
    static let textPrimary = UIColor(hex: 0x111827)
    /// 次文本色：状态文案、时间戳。
    static let textSecondary = UIColor(hex: 0x475569)
    /// 弱文本色：占位、辅助说明。
    static let textMuted = UIColor(hex: 0x94A3B8)
    /// 在线状态点（绿）。
    static let statusOnline = UIColor(hex: 0x16A34A)
    /// 连接中状态点（琥珀）。
    static let statusConnecting = UIColor(hex: 0xF59E0B)
    /// 离线状态点（灰）。
    static let statusOffline = UIColor(hex: 0x94A3B8)
    /// 错误文字。
    static let errorText = UIColor(hex: 0xB91C1C)
    /// 错误条背景。
    static let errorBackground = UIColor(hex: 0xFEF2F2)

    /// 把连接状态点色调映射为具体颜色（数据来自纯函数 [ConnectionStatusPresenter.tone]）。
    static func color(for tone: ConnectionDotTone) -> UIColor {
        switch tone {
        case .online: return statusOnline
        case .connecting: return statusConnecting
        case .offline: return statusOffline
        }
    }
}

extension UIColor {
    /// 用 0xRRGGBB 十六进制整数构造不透明颜色，便于直接对齐 widget 配色表。
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
