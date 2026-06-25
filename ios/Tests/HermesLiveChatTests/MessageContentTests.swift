import XCTest
@testable import HermesLiveChat

/// [MessageContentType] / [MessageSenderType] / [MessageDisplayRules] 的纯函数单测。
///
/// 不依赖 UIKit 行为（虽然测试 target 因模块整体含 UIKit 而在模拟器上运行），
/// 覆盖「类型映射」「展示文案兜底」「是否渲染 markdown」三类核心规则，与 Android / Flutter 对齐。
final class MessageContentTests: XCTestCase {
    func testContentTypeKnownRawMapsToEnum() {
        XCTAssertEqual(MessageContentType.from("text"), .text)
        XCTAssertEqual(MessageContentType.from("image"), .image)
        XCTAssertEqual(MessageContentType.from("file"), .file)
        XCTAssertEqual(MessageContentType.from("welcome"), .welcome)
        XCTAssertEqual(MessageContentType.from("close"), .close)
    }

    func testContentTypeUnknownFallsBackToUnknown() {
        XCTAssertEqual(MessageContentType.from("brand_new"), .unknown)
        XCTAssertEqual(MessageContentType.from(nil), .unknown)
        XCTAssertEqual(MessageContentType.from(""), .unknown)
    }

    func testSenderIsMineOnlyForVisitor() {
        XCTAssertTrue(MessageSenderType.from("visitor").isMine)
        XCTAssertFalse(MessageSenderType.from("agent").isMine)
        XCTAssertFalse(MessageSenderType.from("bot").isMine)
        XCTAssertFalse(MessageSenderType.from("system").isMine)
        // 未知发送方按「非本人」兜底，保证对方消息仍走 markdown。
        XCTAssertFalse(MessageSenderType.from("whoever").isMine)
        XCTAssertFalse(MessageSenderType.from(nil).isMine)
    }

    func testDisplayTextPrefersTextForTextLikeTypes() {
        XCTAssertEqual(MessageDisplayRules.displayText(contentType: "text", text: "你好", url: nil), "你好")
        XCTAssertEqual(MessageDisplayRules.displayText(contentType: "welcome", text: "欢迎", url: nil), "欢迎")
        XCTAssertEqual(MessageDisplayRules.displayText(contentType: "close", text: nil, url: nil), "")
    }

    func testDisplayTextUsesUrlForImage() {
        XCTAssertEqual(
            MessageDisplayRules.displayText(contentType: "image", text: nil, url: "https://x/y.png"),
            "https://x/y.png"
        )
        XCTAssertEqual(MessageDisplayRules.displayText(contentType: "image", text: nil, url: nil), "")
    }

    func testDisplayTextFallbackPlaceholderForOtherTypes() {
        XCTAssertEqual(MessageDisplayRules.displayText(contentType: "file", text: nil, url: nil), "[file]")
        XCTAssertEqual(MessageDisplayRules.displayText(contentType: "mystery", text: nil, url: nil), "[mystery]")
    }

    func testShouldRenderMarkdownOnlyForNonMine() {
        XCTAssertFalse(MessageDisplayRules.shouldRenderMarkdown(sender: .visitor))
        XCTAssertTrue(MessageDisplayRules.shouldRenderMarkdown(sender: .bot))
        XCTAssertTrue(MessageDisplayRules.shouldRenderMarkdown(sender: .agent))
        XCTAssertTrue(MessageDisplayRules.shouldRenderMarkdown(sender: .system))
    }
}

/// [ConnectionStatusPresenter] 连接态映射的纯函数单测。
final class ConnectionStatusTests: XCTestCase {
    func testToneMapping() {
        XCTAssertEqual(ConnectionStatusPresenter.tone(for: .connected), .online)
        XCTAssertEqual(ConnectionStatusPresenter.tone(for: .connecting), .connecting)
        XCTAssertEqual(ConnectionStatusPresenter.tone(for: .idle), .offline)
        XCTAssertEqual(ConnectionStatusPresenter.tone(for: .disconnected), .offline)
    }

    func testLabelMapping() {
        XCTAssertEqual(ConnectionStatusPresenter.label(for: .connected), "在线")
        XCTAssertEqual(ConnectionStatusPresenter.label(for: .connecting), "连接中")
        XCTAssertEqual(ConnectionStatusPresenter.label(for: .idle), "未连接")
        XCTAssertEqual(ConnectionStatusPresenter.label(for: .disconnected), "连接已断开")
    }
}
