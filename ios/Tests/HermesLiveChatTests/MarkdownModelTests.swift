import XCTest
@testable import HermesLiveChat

/// [MarkdownDocumentBuilder] 的纯函数单测：验证 AST → 块模型的转换覆盖三类验收样本。
///
/// 这是 iOS 端「复杂留在能被测的纯函数里」的核心：解析 + 折叠逻辑全部可在此断言，
/// UIKit 渲染层只是把这里产出的块模型摆成视图，不含可测业务规则。
final class MarkdownModelTests: XCTestCase {

    // MARK: 样本一：带 query 参数的链接（修复 `_` 被吞 / 不可点的核心 bug）

    func testQueryParamLinkKeepsUnderscoresAndDestination() {
        let url = "https://applink.feishu.cn/client/chat/chatter/add_by_link?link_token=b3ah2f80-d6ba-4784-86a7-7da256b03aea"
        let blocks = MarkdownDocumentBuilder.build("[加好友](\(url))")

        guard case let .paragraph(inlines) = blocks.first else {
            return XCTFail("首块应为段落，实际：\(blocks)")
        }
        guard let link = inlines.compactMap({ inline -> (String, String)? in
            if case let .link(text, destination, _) = inline { return (text, destination) }
            return nil
        }).first else {
            return XCTFail("段落里应有一个链接，实际：\(inlines)")
        }
        XCTAssertEqual(link.0, "加好友")
        // 关键断言：带参 URL 完整保留，下划线没有被当成斜体标记吞掉。
        XCTAssertEqual(link.1, url)
        XCTAssertTrue(link.1.contains("add_by_link"))
        XCTAssertTrue(link.1.contains("link_token="))
    }

    // MARK: 样本二：内联图片单独成块

    func testInlineImageBecomesImageBlock() {
        let blocks = MarkdownDocumentBuilder.build("![预览](https://cdn.example.com/x.png)")
        guard case let .image(destination, alt) = blocks.first else {
            return XCTFail("首块应为图片块，实际：\(blocks)")
        }
        XCTAssertEqual(destination, "https://cdn.example.com/x.png")
        XCTAssertEqual(alt, "预览")
    }

    func testTextThenImageSplitsIntoParagraphAndImage() {
        // 段落里夹一张图片：应切成「段落 + 图片块」两块。
        let blocks = MarkdownDocumentBuilder.build("看图 ![图](https://x/y.png)")
        XCTAssertEqual(blocks.count, 2)
        guard case .paragraph = blocks[0] else { return XCTFail("第一块应为段落") }
        guard case let .image(destination, _) = blocks[1] else { return XCTFail("第二块应为图片") }
        XCTAssertEqual(destination, "https://x/y.png")
    }

    // MARK: 样本三：列表 + 粗体 / 斜体 / 行内 code

    func testUnorderedListWithEmphasisAndCode() {
        let markdown = """
        - **粗** 与 *斜* 与 `code`
        - 第二项
        """
        let blocks = MarkdownDocumentBuilder.build(markdown)
        guard case let .unorderedList(items) = blocks.first else {
            return XCTFail("首块应为无序列表，实际：\(blocks)")
        }
        XCTAssertEqual(items.count, 2)

        // 第一项应包含一个粗体、一个斜体、一个 code 文本片段。
        let styles = items[0].inlines.compactMap { inline -> (String, MarkdownInlineStyle)? in
            if case let .text(value, style) = inline { return (value, style) }
            return nil
        }
        XCTAssertTrue(styles.contains { $0.0 == "粗" && $0.1.bold })
        XCTAssertTrue(styles.contains { $0.0 == "斜" && $0.1.italic })
        XCTAssertTrue(styles.contains { $0.0 == "code" && $0.1.code })
    }

    func testOrderedListStartIndex() {
        let blocks = MarkdownDocumentBuilder.build("""
        3. 第三
        4. 第四
        """)
        guard case let .orderedList(start, items) = blocks.first else {
            return XCTFail("首块应为有序列表，实际：\(blocks)")
        }
        XCTAssertEqual(start, 3)
        XCTAssertEqual(items.count, 2)
    }

    // MARK: 行内强调叠加

    func testNestedBoldItalicCombinesStyle() {
        // ***x*** → 粗 + 斜 同时生效。
        let blocks = MarkdownDocumentBuilder.build("***x***")
        guard case let .paragraph(inlines) = blocks.first else {
            return XCTFail("首块应为段落")
        }
        let boldItalic = inlines.contains { inline in
            if case let .text("x", style) = inline { return style.bold && style.italic }
            return false
        }
        XCTAssertTrue(boldItalic, "x 应同时为粗体和斜体，实际：\(inlines)")
    }

    // MARK: 代码块

    func testFencedCodeBlock() {
        let blocks = MarkdownDocumentBuilder.build("""
        ```
        let a = 1
        ```
        """)
        guard case let .codeBlock(code) = blocks.first else {
            return XCTFail("首块应为代码块，实际：\(blocks)")
        }
        XCTAssertEqual(code, "let a = 1")
    }
}
