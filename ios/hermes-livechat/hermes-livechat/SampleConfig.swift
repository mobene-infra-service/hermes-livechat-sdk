import Foundation

enum SampleConfig {
    struct Environment {
        let name: String
        let description: String
        let baseUrl: String
        let realtimeUrl: String
        let appKey: String
        let secretKey: String
        let bizToken: String
    }

    static let environments: [Environment] = [
        Environment(
            name: "测试",
            description: "hermes-test.financifyx.com",
            baseUrl: "https://hermes-test.financifyx.com/api",
            realtimeUrl: "wss://hermes-test.financifyx.com/api/connection/websocket",
            appKey: "app_019e6335c04478838ef4f9418263d279",
            secretKey: "sk_bB3QVOT8KZWex6qSU58Y196MUPHFb1WA8rBGdppA1hg",
            bizToken: ""
        ),
        Environment(
            name: "生产",
            description: "hermesomni.com",
            baseUrl: "https://hermesomni.com/api",
            realtimeUrl: "wss://hermesomni.com/api/connection/websocket",
            appKey: "app_019e6335c04478838ef4f9418263d279",
            secretKey: "sk_bB3QVOT8KZWex6qSU58Y196MUPHFb1WA8rBGdppA1hg",
            bizToken: ""
        ),
    ]

    static let defaultEnvironmentIndex = 0

    /// 三端统一的 Markdown 验收样本文案（与 Android `SampleConfig.sampleBotMarkdown` / widget 同源）。
    ///
    /// 验收时把这段文案从客服 / 机器人后台作为一条 bot 消息下发，确认以下三类均与 widget 一致：
    /// 1. 带 query 参数的链接：`link_token` 里的 `_` 不被吞、文案完整、可点击；
    /// 2. 内联图片：`![]()` 在气泡内渲染；
    /// 3. 列表 + 粗体/斜体/行内 code：缩进、配色与 widget `.md-body` 同源。
    static let sampleBotMarkdown = """
    欢迎体验在线客服，下面验证 **Markdown** 渲染：

    1. 带参链接：[点此加好友](https://applink.feishu.cn/client/chat/chatter/add_by_link?link_token=b3ah2f80-d6ba-4784-86a7-7da256b03aea)
    2. *斜体* 与 `inline code`

    内联图片：

    ![示例图片](https://picsum.photos/240/120)
    """

    static func randomCustomerId() -> String {
        "ios-demo-\(UUID().uuidString.prefix(8).lowercased())"
    }
}
