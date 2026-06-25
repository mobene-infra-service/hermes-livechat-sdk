import UIKit

/// 把 [MarkdownBlock] 块模型渲染成一组 UIKit 视图（气泡内纵向排布）。
///
/// 这是 markdown 渲染的「IO 薄层」：解析与结构判定已在纯函数 [MarkdownDocumentBuilder] 完成，
/// 这里只负责把值类型块模型摆成 `UITextView` / `UIImageView` / 列表栈，不含业务规则。
///
/// 文本块用 `UITextView` 承载：设置 `.link` 属性后，不可编辑但可选中的 textView 默认即会在
/// 点击链接时调用系统打开 URL，无需自管 delegate，也避开 iOS 17 起 `shouldInteractWith` 的弃用。
struct MarkdownRenderer {
    /// 正文基准字体。
    let baseFont: UIFont
    /// 正文主色（bot 气泡为 `Palette.textPrimary`）。
    let textColor: UIColor
    /// 内联图片的目标宽度（与气泡图片宽度一致）。
    let imageWidth: CGFloat

    init(
        baseFont: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = Palette.textPrimary,
        imageWidth: CGFloat = 220
    ) {
        self.baseFont = baseFont
        self.textColor = textColor
        self.imageWidth = imageWidth
    }

    /// 解析 markdown 文本并产出块视图数组。
    func makeViews(from markdown: String) -> [UIView] {
        MarkdownDocumentBuilder.build(markdown).map(view(for:))
    }

    // MARK: - 块 → 视图

    private func view(for block: MarkdownBlock) -> UIView {
        switch block {
        case let .paragraph(inlines):
            return makeTextView(attributed(inlines))
        case let .heading(_, inlines):
            // 标题在客服文案里罕见：整体加粗即可，不额外放大层级。
            return makeTextView(attributed(inlines.map(boldened)))
        case let .image(destination, _):
            return makeImageView(destination: destination)
        case let .unorderedList(items):
            return makeListView(items: items, ordered: false, start: 1)
        case let .orderedList(start, items):
            return makeListView(items: items, ordered: true, start: start)
        case let .codeBlock(code):
            return makeCodeBlockView(code)
        }
    }

    // MARK: - 行内 → 富文本

    /// 把行内序列拼成 `NSAttributedString`，链接挂 `.link` 属性以便点击跳转。
    private func attributed(_ inlines: [MarkdownInline]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for inline in inlines {
            switch inline {
            case let .text(string, style):
                output.append(NSAttributedString(string: string, attributes: attributes(for: style)))
            case let .link(text, destination, style):
                var attrs = attributes(for: style)
                if let url = URL(string: destination) {
                    attrs[.link] = url
                }
                output.append(NSAttributedString(string: text, attributes: attrs))
            case .softBreak, .lineBreak:
                output.append(NSAttributedString(string: "\n"))
            }
        }
        return output
    }

    /// 根据强调样式组合出字体与文字属性（粗 / 斜可叠加，code 用等宽 + 底色）。
    private func attributes(for style: MarkdownInlineStyle) -> [NSAttributedString.Key: Any] {
        var font = style.code
            ? UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
            : baseFont
        if style.bold { font = font.addingSymbolicTraits(.traitBold) }
        if style.italic { font = font.addingSymbolicTraits(.traitItalic) }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        if style.code { attrs[.backgroundColor] = Palette.surfaceMuted }
        return attrs
    }

    /// 给一个行内片段叠加粗体（用于标题渲染）。
    private func boldened(_ inline: MarkdownInline) -> MarkdownInline {
        switch inline {
        case let .text(string, style):
            return .text(string, style: style.adding(bold: true))
        case let .link(text, destination, style):
            return .link(text: text, destination: destination, style: style.adding(bold: true))
        case .softBreak, .lineBreak:
            return inline
        }
    }

    // MARK: - 视图工厂

    /// 文本块视图：不可编辑、不可滚动、透明底的 textView，链接默认可点击跳转。
    private func makeTextView(_ attributed: NSAttributedString) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.linkTextAttributes = [
            .foregroundColor: Palette.primary,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.attributedText = attributed
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }

    /// 内联图片视图：占位底 + 异步加载，加载完成后按真实宽高比修正高度。
    private func makeImageView(destination: String) -> UIView {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = Palette.surfaceMuted
        imageView.layer.cornerRadius = 10
        let heightConstraint = imageView.heightAnchor.constraint(equalToConstant: 160)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: imageWidth),
            heightConstraint,
        ])
        let targetWidth = imageWidth
        if let url = URL(string: destination) {
            Task { @MainActor in
                guard
                    let (data, _) = try? await URLSession.shared.data(from: url),
                    let image = UIImage(data: data)
                else { return }
                imageView.image = image
                heightConstraint.constant = Self.displayHeight(for: image.size, width: targetWidth)
                imageView.superview?.setNeedsLayout()
            }
        }
        return imageView
    }

    /// 列表视图：每项一行「标记 + 内容」，嵌套子列表缩进排在其下。
    private func makeListView(items: [MarkdownListItem], ordered: Bool, start: Int) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (offset, item) in items.enumerated() {
            let marker = ordered ? "\(start + offset)." : "•"
            stack.addArrangedSubview(makeListItemView(marker: marker, item: item))
        }
        return stack
    }

    private func makeListItemView(marker: String, item: MarkdownListItem) -> UIView {
        let markerLabel = UILabel()
        markerLabel.font = baseFont
        markerLabel.textColor = textColor
        markerLabel.text = marker
        markerLabel.setContentHuggingPriority(.required, for: .horizontal)
        markerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [markerLabel, makeTextView(attributed(item.inlines))])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 6

        guard !item.children.isEmpty else { return row }

        // 该项含嵌套块（子列表等）：整体改为纵向栈，嵌套块左缩进。
        let column = UIStackView(arrangedSubviews: [row])
        column.axis = .vertical
        column.spacing = 4
        for block in item.children {
            let indent = UIStackView(arrangedSubviews: [view(for: block)])
            indent.isLayoutMarginsRelativeArrangement = true
            indent.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
            column.addArrangedSubview(indent)
        }
        return column
    }

    /// 代码块视图：等宽字体 + 弱面色底 + 内边距。
    private func makeCodeBlockView(_ code: String) -> UIView {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = UIFont.monospacedSystemFont(ofSize: max(baseFont.pointSize - 1, 11), weight: .regular)
        label.textColor = textColor
        label.text = code
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = Palette.surfaceMuted
        container.layer.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    /// 按图片真实宽高比，在宽度 [width] 下计算展示高度（夹在 96...320）。
    private static func displayHeight(for size: CGSize, width: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 160 }
        let aspectHeight = width * size.height / size.width
        return min(max(aspectHeight, 96), 320)
    }
}

extension UIFont {
    /// 在现有符号特征上叠加新的特征（如粗、斜），失败时返回自身。
    func addingSymbolicTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(traits)
        ) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
