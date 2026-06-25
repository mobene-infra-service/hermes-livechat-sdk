import Foundation

/// 消息内容类型枚举。
///
/// 后端在消息体的 `content_type` 字段下发字符串，这里用枚举收敛，
/// 避免在 UI 层散落 `contentType == "image"` 这类裸字符串比较。
/// 原始值即后端字符串；`unknown` 用空串占位，承接后端新增而 SDK 未跟进的类型。
enum MessageContentType: String, CaseIterable {
    /// 纯文本 / 富文本（markdown 串）：bot、客服、系统提示的主要载体。
    case text = "text"
    /// 图片消息：图片地址在 `content.url`。
    case image = "image"
    /// 文件 / 附件消息。
    case file = "file"
    /// 欢迎语：会话首条引导文案，同样走文本渲染。
    case welcome = "welcome"
    /// 会话关闭提示。
    case close = "close"
    /// 未识别类型：后端新增而 SDK 尚未跟进时的兜底。
    case unknown = ""

    /// 把后端原始字符串映射为枚举；无法识别时返回 [unknown]。
    static func from(_ raw: String?) -> MessageContentType {
        guard let raw else { return .unknown }
        return MessageContentType(rawValue: raw) ?? .unknown
    }
}

/// 消息发送方类型枚举。
///
/// 本 SDK 的本地用户始终是「访客（visitor）」，因此 [isMine] 以是否访客判定，
/// 用枚举替代各处 `senderType == "visitor"` 的裸字符串比较。
enum MessageSenderType: String, CaseIterable {
    /// 访客：即 App 内的本地用户自己，气泡靠右、纯文本展示。
    case visitor = "visitor"
    /// 人工客服。
    case agent = "agent"
    /// 机器人 / 智能体。
    case bot = "bot"
    /// 系统消息（提示、状态变更等）。
    case system = "system"
    /// 未识别发送方：兜底，按「非本人」处理。
    case unknown = ""

    /// 是否为本地用户（访客）自己发出的消息。
    ///
    /// 决定气泡左右对齐、是否纯文本展示（本人消息不渲染 markdown，与 widget 对齐）。
    var isMine: Bool { self == .visitor }

    /// 把后端原始字符串映射为枚举；无法识别时返回 [unknown]。
    static func from(_ raw: String?) -> MessageSenderType {
        guard let raw else { return .unknown }
        return MessageSenderType(rawValue: raw) ?? .unknown
    }
}

/// 消息展示规则（纯函数集合）。
///
/// 把「展示哪段文案」「是否按 markdown 渲染」从 UI 层抽出，便于单元测试覆盖核心规则，
/// 与 Android / Flutter 端保持同构。
enum MessageDisplayRules {
    /// 计算气泡要展示的文案。
    ///
    /// 规则（与既有 `Message.displayText` 行为保持一致）：
    /// - text / welcome / close：取 [text]，缺省空串；
    /// - image：取图片地址 [url]，缺省空串（图片本身由图片视图承载）；
    /// - 其它（file / 未知类型）：返回 `[原始类型]` 占位，便于排查未渲染消息。
    ///
    /// - Parameters:
    ///   - contentType: 后端原始 `content_type`。
    ///   - text: `content.text`。
    ///   - url: `content.url`（图片地址）。
    static func displayText(contentType: String, text: String?, url: String?) -> String {
        switch MessageContentType.from(contentType) {
        case .text, .welcome, .close:
            return text ?? ""
        case .image:
            return url ?? ""
        case .file, .unknown:
            return "[\(contentType)]"
        }
    }

    /// 是否按 markdown 渲染该气泡。
    ///
    /// 仅渲染「非本人」（bot / 客服 / 系统）的文本：本人发送的消息保持纯文本，
    /// 避免把用户原样输入的 `*` `_` 等字符误当成 markdown 标记，与 widget 行为一致。
    static func shouldRenderMarkdown(sender: MessageSenderType) -> Bool {
        !sender.isMine
    }
}
