import Foundation
import Markdown

// MARK: - 纯值类型块模型
//
// 这一层把 swift-markdown 的 AST 转换成一组**纯值类型**（无 UIKit 依赖），
// 既是「复杂留在能被测的纯函数」的落点（[MarkdownDocumentBuilder] 可被单测覆盖），
// 也让 UIKit 渲染层只需做「块模型 → UIView」的简单转换。
// 渲染范围与 widget 对齐：段落 / 标题 / 链接 / 内联图片 / 有序无序列表 / 行内 code / 代码块。

/// 行内强调样式组合（可叠加，如「粗 + 斜」）。
struct MarkdownInlineStyle: Equatable {
    /// 是否加粗（`**` / `__`）。
    var bold: Bool = false
    /// 是否斜体（`*` / `_`）。
    var italic: Bool = false
    /// 是否行内 code（`` ` ``），等宽 + 底色。
    var code: Bool = false

    /// 返回叠加某一强调后的新样式（值语义，便于在递归遍历中向下传递）。
    func adding(bold: Bool = false, italic: Bool = false, code: Bool = false) -> MarkdownInlineStyle {
        MarkdownInlineStyle(
            bold: self.bold || bold,
            italic: self.italic || italic,
            code: self.code || code
        )
    }
}

/// 行内片段：段落 / 标题 / 列表项内部的最小渲染单元。
enum MarkdownInline: Equatable {
    /// 普通文本片段，携带其强调样式。
    case text(String, style: MarkdownInlineStyle)
    /// 链接：展示文案 [text] + 目标地址 [destination]，可点击跳转。
    case link(text: String, destination: String, style: MarkdownInlineStyle)
    /// 软换行（源码里的单个换行）。对齐 widget `breaks: true`，渲染为换行。
    case softBreak
    /// 硬换行（行尾两空格 / 反斜杠换行）。
    case lineBreak
}

/// 列表项：自身的行内内容 + 可选的嵌套块（子列表等）。
struct MarkdownListItem: Equatable {
    /// 该列表项首段的行内内容。
    var inlines: [MarkdownInline]
    /// 嵌套块（如子列表）；扁平列表时为空。
    var children: [MarkdownBlock]
}

/// 块级元素：气泡内纵向排布的最小单元。
enum MarkdownBlock: Equatable {
    /// 段落。
    case paragraph([MarkdownInline])
    /// 标题（[level] 1...6）。
    case heading(level: Int, [MarkdownInline])
    /// 块级图片（`![alt](url)`）：与 widget 一致，图片单独成块。
    case image(destination: String, alt: String)
    /// 无序列表。
    case unorderedList([MarkdownListItem])
    /// 有序列表，[start] 为起始序号（CommonMark 默认 1）。
    case orderedList(start: Int, [MarkdownListItem])
    /// 代码块（围栏 ``` 或缩进）。
    case codeBlock(String)
}

// MARK: - AST → 块模型 构建器

/// 把 markdown 文本解析并转换成 [MarkdownBlock] 数组的纯函数构建器。
///
/// 解析交给 swift-markdown（cmark-gfm），本类型只负责把 AST 折叠成自有的值类型，
/// 因此整段逻辑可在单元测试里直接断言结构，无需任何 UIKit / 真机环境。
enum MarkdownDocumentBuilder {
    /// 解析 markdown 文本，返回块模型数组。
    static func build(_ markdown: String) -> [MarkdownBlock] {
        let document = Document(parsing: markdown)
        var blocks: [MarkdownBlock] = []
        for child in document.children {
            append(child, into: &blocks)
        }
        return blocks
    }

    /// 把单个块级 AST 节点折叠进 [blocks]。
    private static func append(_ markup: any Markup, into blocks: inout [MarkdownBlock]) {
        switch markup {
        case let paragraph as Paragraph:
            // 段落可能内联图片：在图片处切断，前后文本各自成段，图片单独成块。
            blocks.append(contentsOf: splitParagraph(paragraph.inlineChildren.map { $0 as any Markup }, headingLevel: nil))
        case let heading as Heading:
            blocks.append(contentsOf: splitParagraph(heading.inlineChildren.map { $0 as any Markup }, headingLevel: heading.level))
        case let list as UnorderedList:
            blocks.append(.unorderedList(list.listItems.map(listItem)))
        case let list as OrderedList:
            blocks.append(.orderedList(start: Int(list.startIndex), list.listItems.map(listItem)))
        case let codeBlock as CodeBlock:
            // 去掉围栏代码块末尾 cmark 附带的换行，避免气泡底部多一空行。
            blocks.append(.codeBlock(codeBlock.code.trimmingTrailingNewline()))
        case let quote as BlockQuote:
            // 引用不在子集内，但仍把其内部块平铺出来以免吞掉文字。
            for child in quote.children { append(child, into: &blocks) }
        default:
            break
        }
    }

    /// 把一段行内序列在「块级图片」处切分：图片单独成 `.image` 块，其余文本成段 / 标题。
    /// 统一用 `[any Markup]`：调用方把 `inlineChildren`（元素为 `InlineMarkup`）向上转换后传入。
    private static func splitParagraph(
        _ markups: [any Markup],
        headingLevel: Int?
    ) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var current: [MarkdownInline] = []

        func flush() {
            guard !current.isEmpty else { return }
            if let level = headingLevel {
                blocks.append(.heading(level: level, current))
            } else {
                blocks.append(.paragraph(current))
            }
            current = []
        }

        for markup in markups {
            if let image = markup as? Image {
                flush()
                blocks.append(.image(destination: image.source ?? "", alt: image.plainText))
            } else {
                current.append(contentsOf: inlines(from: [markup], style: MarkdownInlineStyle()))
            }
        }
        flush()
        return blocks
    }

    /// 递归遍历行内节点，折叠成 [MarkdownInline]；[style] 为从父节点继承的强调样式。
    private static func inlines(
        from markups: [any Markup],
        style: MarkdownInlineStyle
    ) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for markup in markups {
            switch markup {
            case let text as Markdown.Text:
                result.append(.text(text.string, style: style))
            case let strong as Strong:
                result.append(contentsOf: inlines(from: Array(strong.children), style: style.adding(bold: true)))
            case let emphasis as Emphasis:
                result.append(contentsOf: inlines(from: Array(emphasis.children), style: style.adding(italic: true)))
            case let inlineCode as InlineCode:
                result.append(.text(inlineCode.code, style: style.adding(code: true)))
            case let link as Markdown.Link:
                // 链接文案取其纯文本（嵌套强调在客服文案里极少见，简化处理）。
                result.append(.link(text: link.plainText, destination: link.destination ?? "", style: style))
            case is SoftBreak:
                result.append(.softBreak)
            case is LineBreak:
                result.append(.lineBreak)
            case let image as Image:
                // 行内（非段落级）图片：退化为其 alt 文本，避免在列表项里丢内容。
                result.append(.text(image.plainText, style: style))
            case let container as InlineContainer:
                // 其它行内容器（如删除线）不在子集内：保留其纯文本。
                result.append(.text(container.plainText, style: style))
            default:
                break
            }
        }
        return result
    }

    /// 把一个列表项 AST 折叠成 [MarkdownListItem]：首段作为行内内容，其余（含子列表）作为嵌套块。
    private static func listItem(_ item: ListItem) -> MarkdownListItem {
        var inlineContent: [MarkdownInline] = []
        var children: [MarkdownBlock] = []
        var pickedFirstParagraph = false

        for child in item.children {
            if let paragraph = child as? Paragraph, !pickedFirstParagraph {
                inlineContent = inlines(from: paragraph.inlineChildren.map { $0 as any Markup }, style: MarkdownInlineStyle())
                pickedFirstParagraph = true
            } else {
                append(child, into: &children)
            }
        }
        return MarkdownListItem(inlines: inlineContent, children: children)
    }
}

private extension String {
    /// 去掉末尾恰好一个换行（cmark 代码块常在尾部多带一个 `\n`）。
    func trimmingTrailingNewline() -> String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
