import AppKit
import Markdown

/// Converts a swift-markdown `Document` (GFM) into an `NSAttributedString`
/// that NSTextView (TextKit 1) can lay out natively: headings, lists,
/// task lists, block quotes, fenced code, tables, images, links, rules.
final class MarkdownRenderer {
    private let theme: Theme
    private let baseURL: URL?
    private var out = NSMutableAttributedString()
    private let maxImageWidth: CGFloat

    /// A fenced code block with a known language, to be syntax-highlighted after the fact
    /// (see `DocumentController.highlight`). `range` is in the string `render` returned.
    struct CodeBlockRef {
        var range: NSRange
        let code: String
        let language: String
    }
    private(set) var codeBlocks: [CodeBlockRef] = []

    /// Pending list marker ("•", "1.", "☑") to be glued onto the next paragraph.
    private var pendingMarker: (text: String, indent: CGFloat)?

    private struct Context {
        var indent: CGFloat = 0        // absolute left edge of normal text
        var blockIndent: CGFloat = 0   // indent already absorbed by enclosing text blocks
        var blocks: [NSTextBlock] = [] // enclosing NSTextBlocks (quotes, cells, ...)
        var inList = false
        var inQuote = false
        var relIndent: CGFloat { indent - blockIndent }
    }

    private struct Inline {
        var font: NSFont
        var color: NSColor
        var code = false
        var strike = false
        var link: URL?
    }

    init(theme: Theme, baseURL: URL?, maxImageWidth: CGFloat = 720) {
        self.theme = theme
        self.baseURL = baseURL
        self.maxImageWidth = maxImageWidth
    }

    // MARK: - Entry

    func render(_ document: Document) -> NSAttributedString {
        out = NSMutableAttributedString()
        codeBlocks = []
        pendingMarker = nil
        let ctx = Context()
        for child in document.children { block(child, ctx) }
        flushMarker(ctx)
        return out
    }

    /// A whole file as one code block (source files opened directly). `language` nil → plain.
    func renderCode(_ code: String, language: String?) -> NSAttributedString {
        out = NSMutableAttributedString()
        codeBlocks = []
        pendingMarker = nil
        codeBlock(code, Context(), dim: false, language: language)
        return out
    }

    // MARK: - Blocks

    private func block(_ node: Markup, _ ctx: Context) {
        switch node {
        case let p as Paragraph: paragraph(p, ctx)
        case let h as Heading: heading(h, ctx)
        case let c as CodeBlock: codeBlock(c.code, ctx, dim: false, language: c.language)
        case let h as HTMLBlock: codeBlock(h.rawHTML, ctx, dim: true)
        case let q as BlockQuote: quote(q, ctx)
        case let l as UnorderedList: list(l, ordered: false, start: 1, ctx)
        case let l as OrderedList: list(l, ordered: true, start: Int(l.startIndex), ctx)
        case is ThematicBreak: rule(ctx)
        case let t as Table: table(t, ctx)
        default:
            // Unknown block: render whatever inline content it has as a paragraph.
            let inl = node.children.compactMap { $0 as? InlineMarkup }
            if !inl.isEmpty {
                let style = paragraphStyle(ctx)
                let s = NSMutableAttributedString()
                s.append(takeMarker(style, ctx))
                s.append(inlines(inl, Inline(font: theme.body, color: theme.text)))
                finish(s, style)
            } else {
                for c in node.children { block(c, ctx) }
            }
        }
    }

    private func paragraph(_ p: Paragraph, _ ctx: Context) {
        let style = paragraphStyle(ctx)
        let s = NSMutableAttributedString()
        s.append(takeMarker(style, ctx))
        s.append(inlines(p.inlineChildren, Inline(font: theme.body, color: ctx.inQuote ? theme.secondary : theme.text)))
        finish(s, style)
    }

    private func heading(_ h: Heading, _ ctx: Context) {
        flushMarker(ctx)
        let style = paragraphStyle(ctx)
        style.paragraphSpacingBefore = theme.baseSize * 1.5
        style.paragraphSpacing = theme.baseSize * 1.0
        style.lineSpacing = 0
        if h.level <= 2 {
            let b = box(leftMargin: ctx.relIndent, bottomMargin: style.paragraphSpacing)
            b.setBorderColor(theme.separator)
            b.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            b.setWidth(theme.baseSize * 0.3, type: .absoluteValueType, for: .padding, edge: .maxY)
            b.setWidth(style.paragraphSpacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            style.textBlocks = ctx.blocks + [b]
            style.headIndent = 0
            style.firstLineHeadIndent = 0
        }
        let s = NSMutableAttributedString()
        s.append(inlines(h.inlineChildren, Inline(font: theme.heading(h.level), color: h.level == 6 ? theme.secondary : theme.text)))
        finish(s, style)
    }

    private func codeBlock(_ code: String, _ ctx: Context, dim: Bool, language: String? = nil) {
        flushMarker(ctx)
        var text = code
        while text.hasSuffix("\n") { text.removeLast() }
        let b = box(leftMargin: ctx.relIndent, bottomMargin: theme.baseSize * 1.0)
        b.backgroundColor = theme.codeBackground
        b.setWidth(theme.baseSize * 0.8, type: .absoluteValueType, for: .padding)

        let style = NSMutableParagraphStyle()
        style.textBlocks = ctx.blocks + [b]
        style.lineBreakMode = .byCharWrapping
        style.paragraphSpacing = 0
        style.lineSpacing = 2
        var attrs: [NSAttributedString.Key: Any] = [
            .font: theme.mono,
            .foregroundColor: dim ? theme.secondary : theme.text,
            .paragraphStyle: style,
        ]
        if dim { attrs[.obliqueness] = 0 }
        // One paragraph per line, all sharing the same NSTextBlock → drawn as one box.
        let lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        let block = NSMutableAttributedString()
        for line in lines {
            block.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        if !dim, let language, Highlighter.language(for: language) != nil {
            codeBlocks.append(CodeBlockRef(range: NSRange(location: out.length, length: (text as NSString).length),
                                           code: text, language: language))
        }
        out.append(block)
    }

    private func quote(_ q: BlockQuote, _ ctx: Context) {
        flushMarker(ctx)
        let b = box(leftMargin: ctx.relIndent, bottomMargin: theme.baseSize * 1.0)
        b.setBorderColor(theme.quoteBar)
        b.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        b.setWidth(theme.baseSize, type: .absoluteValueType, for: .padding, edge: .minX)
        var inner = ctx
        inner.blocks.append(b)
        inner.blockIndent = ctx.indent
        inner.inQuote = true
        for c in q.children { block(c, inner) }
        flushMarker(inner)
    }

    private func list(_ l: ListItemContainer, ordered: Bool, start: Int, _ ctx: Context) {
        flushMarker(ctx)
        let markerWidth: CGFloat = (theme.baseSize * (ordered ? 1.9 : 1.5)).rounded()
        var inner = ctx
        inner.indent = ctx.indent + markerWidth
        inner.inList = true
        var n = start
        for item in l.listItems {
            let marker: String
            if let cb = item.checkbox {
                marker = cb == .checked ? "☑" : "☐"
            } else if ordered {
                marker = "\(n)."
            } else {
                marker = "•"
            }
            n += 1
            pendingMarker = (marker, ctx.indent)
            for c in item.children { block(c, inner) }
            flushMarker(inner)
        }
        // Breathing room after a list when it is top-level.
        if !ctx.inList { spacer(ctx, height: theme.baseSize * 0.4) }
    }

    private func rule(_ ctx: Context) {
        flushMarker(ctx)
        let b = box(leftMargin: ctx.relIndent, bottomMargin: theme.baseSize)
        b.setBorderColor(theme.separator)
        b.setWidth(2, type: .absoluteValueType, for: .border, edge: .minY)
        b.setWidth(theme.baseSize, type: .absoluteValueType, for: .margin, edge: .minY)
        let style = NSMutableParagraphStyle()
        style.textBlocks = ctx.blocks + [b]
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style,
        ]))
    }

    private func table(_ t: Table, _ ctx: Context) {
        flushMarker(ctx)
        let columns = max(1, t.maxColumnCount)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(ctx.relIndent, type: .absoluteValueType, for: .margin, edge: .minX)
        table.setWidth(theme.baseSize * 1.0, type: .absoluteValueType, for: .margin, edge: .maxY)

        func alignment(_ col: Int) -> NSTextAlignment {
            guard col < t.columnAlignments.count, let a = t.columnAlignments[col] else { return .left }
            switch a {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }

        func row(_ cells: [Table.Cell], rowIndex: Int, header: Bool) {
            var col = 0
            for cell in cells {
                let span = max(1, Int(cell.colspan))
                let rowSpan = max(1, Int(cell.rowspan))
                if cell.colspan == 0 || cell.rowspan == 0 { col += span; continue } // covered by a span
                let b = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: rowSpan,
                                         startingColumn: col, columnSpan: span)
                b.setBorderColor(theme.separator)
                b.setWidth(1, type: .absoluteValueType, for: .border)
                b.setWidth(theme.baseSize * 0.45, type: .absoluteValueType, for: .padding, edge: .minY)
                b.setWidth(theme.baseSize * 0.45, type: .absoluteValueType, for: .padding, edge: .maxY)
                b.setWidth(theme.baseSize * 0.8, type: .absoluteValueType, for: .padding, edge: .minX)
                b.setWidth(theme.baseSize * 0.8, type: .absoluteValueType, for: .padding, edge: .maxX)
                if header { b.backgroundColor = theme.tableHeaderBackground }

                let style = NSMutableParagraphStyle()
                style.textBlocks = ctx.blocks + [b]
                style.alignment = alignment(col)
                style.paragraphSpacing = 0
                let font = header ? NSFont.boldSystemFont(ofSize: theme.baseSize) : theme.body
                let s = NSMutableAttributedString()
                s.append(inlines(cell.inlineChildren, Inline(font: font, color: theme.text)))
                finish(s, style)
                col += span
            }
            // Pad missing cells so the row has `columns` entries.
            while col < columns {
                let b = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: col, columnSpan: 1)
                b.setBorderColor(theme.separator)
                b.setWidth(1, type: .absoluteValueType, for: .border)
                if header { b.backgroundColor = theme.tableHeaderBackground }
                let style = NSMutableParagraphStyle()
                style.textBlocks = ctx.blocks + [b]
                finish(NSMutableAttributedString(string: "", attributes: [.font: theme.body]), style)
                col += 1
            }
        }

        var r = 0
        row(Array(t.head.cells), rowIndex: r, header: true)
        r += 1
        for body in t.body.rows {
            row(Array(body.cells), rowIndex: r, header: false)
            r += 1
        }
    }

    // MARK: - Inlines

    private func inlines<S: Sequence>(_ nodes: S, _ st: Inline) -> NSAttributedString where S.Element == InlineMarkup {
        let s = NSMutableAttributedString()
        for n in nodes { inline(n, st, into: s) }
        return s
    }

    private func inline(_ node: Markup, _ st: Inline, into s: NSMutableAttributedString) {
        switch node {
        case let t as Text:
            s.append(text(t.string, st))
        case is SoftBreak:
            s.append(text(" ", st))
        case is LineBreak:
            s.append(text("\u{2028}", st))
        case let e as Emphasis:
            var n = st; n.font = trait(st.font, .italicFontMask)
            for c in e.children { inline(c, n, into: s) }
        case let e as Strong:
            var n = st; n.font = trait(st.font, .boldFontMask)
            for c in e.children { inline(c, n, into: s) }
        case let e as Strikethrough:
            var n = st; n.strike = true
            for c in e.children { inline(c, n, into: s) }
        case let c as InlineCode:
            var n = st; n.code = true
            n.font = codeFont(matching: st.font)
            s.append(text(c.code, n))
        case let h as InlineHTML:
            var n = st; n.code = true; n.color = theme.secondary
            n.font = codeFont(matching: st.font)
            s.append(text(h.rawHTML, n))
        case let l as Link:
            var n = st
            n.link = resolve(l.destination)
            if l.children.underestimatedCount == 0, let d = l.destination {
                s.append(text(d, n))
            } else {
                for c in l.children { inline(c, n, into: s) }
            }
        case let img as Image:
            image(img, st, into: s)
        default:
            for c in node.children { inline(c, st, into: s) }
        }
    }

    private func text(_ string: String, _ st: Inline) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: st.font, .foregroundColor: st.color]
        if st.code { attrs[.backgroundColor] = theme.codeBackground }
        if st.strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = st.color
        }
        if let url = st.link { attrs[.link] = url }
        return NSAttributedString(string: string, attributes: attrs)
    }

    private func image(_ img: Image, _ st: Inline, into s: NSMutableAttributedString) {
        let alt = img.plainText
        guard let url = resolve(img.source), url.isFileURL, let image = NSImage(contentsOf: url),
              image.size.width > 0 else {
            // Remote or missing image → show alt text as a link to the source.
            var n = st; n.link = resolve(img.source); n.color = theme.secondary
            s.append(text(alt.isEmpty ? (img.source ?? "image") : alt, n))
            return
        }
        var size = image.size
        if size.width > maxImageWidth {
            size.height *= maxImageWidth / size.width
            size.width = maxImageWidth
        }
        let att = NSTextAttachment()
        att.image = image
        att.bounds = CGRect(origin: .zero, size: size)
        let a = NSMutableAttributedString(attachment: att)
        a.addAttributes([.toolTip: alt], range: NSRange(location: 0, length: a.length))
        s.append(a)
    }

    // MARK: - Helpers

    /// A 1x1 NSTextTable cell. Unlike a bare NSTextBlock, consecutive paragraphs sharing
    /// the cell are drawn as one box, and margins/padding/borders are honored.
    private func box(leftMargin: CGFloat, bottomMargin: CGFloat) -> NSTextTableBlock {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.collapsesBorders = false
        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        cell.setWidth(leftMargin, type: .absoluteValueType, for: .margin, edge: .minX)
        cell.setWidth(bottomMargin, type: .absoluteValueType, for: .margin, edge: .maxY)
        return cell
    }

    private func paragraphStyle(_ ctx: Context) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textBlocks = ctx.blocks
        style.firstLineHeadIndent = ctx.relIndent
        style.headIndent = ctx.relIndent
        style.paragraphSpacing = theme.baseSize * (ctx.inList ? 0.25 : 1.0)
        style.lineSpacing = theme.baseSize * 0.3
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// If a list marker is pending, mutate `style` for a hanging indent and return the marker prefix.
    private func takeMarker(_ style: NSMutableParagraphStyle, _ ctx: Context) -> NSAttributedString {
        guard let m = pendingMarker else { return NSAttributedString() }
        pendingMarker = nil
        style.firstLineHeadIndent = m.indent - ctx.blockIndent
        style.headIndent = ctx.relIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: ctx.relIndent, options: [:])]
        let isBox = m.text == "☐" || m.text == "☑"
        let font = isBox ? NSFont.systemFont(ofSize: theme.baseSize * 1.05) : theme.body
        return NSAttributedString(string: m.text + "\t", attributes: [
            .font: font, .foregroundColor: theme.text,
        ])
    }

    /// Emit a pending marker on its own line (item whose first child is not a paragraph).
    private func flushMarker(_ ctx: Context) {
        guard pendingMarker != nil else { return }
        let style = paragraphStyle(ctx)
        style.paragraphSpacing = 0
        let s = NSMutableAttributedString()
        s.append(takeMarker(style, ctx))
        finish(s, style)
    }

    private func finish(_ s: NSMutableAttributedString, _ style: NSParagraphStyle) {
        s.append(NSAttributedString(string: "\n", attributes: [.font: theme.body]))
        s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
        out.append(s)
    }

    private func spacer(_ ctx: Context, height: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.textBlocks = ctx.blocks
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style,
        ]))
    }

    private func trait(_ font: NSFont, _ mask: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: mask)
    }

    private func codeFont(matching font: NSFont) -> NSFont {
        let traits = NSFontManager.shared.traits(of: font)
        let weight: NSFont.Weight = traits.contains(.boldFontMask) ? .semibold : .regular
        return theme.codeFont(size: (font.pointSize * 0.9).rounded(), weight: weight)
    }

    private func resolve(_ destination: String?) -> URL? {
        guard var d = destination?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
        if d.hasPrefix("<") && d.hasSuffix(">") { d = String(d.dropFirst().dropLast()) }
        if let u = URL(string: d), u.scheme != nil { return u }
        if d.hasPrefix("#") { return URL(string: d, relativeTo: baseURL) }
        // Relative/local path: resolve against the document's directory.
        let base = baseURL?.deletingLastPathComponent()
        let path = d.removingPercentEncoding ?? d
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }
        if let base { return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL }
        return URL(string: d.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? d)
    }
}

/// Front matter (`---\n...\n---`) at the top of a file is returned separately.
func splitFrontMatter(_ source: String) -> (frontMatter: String?, body: String) {
    guard source.hasPrefix("---\n") else { return (nil, source) }
    let afterOpen = source.index(source.startIndex, offsetBy: 4)
    guard let close = source.range(of: "\n---\n", range: afterOpen..<source.endIndex) ??
            (source.hasSuffix("\n---") ? source.range(of: "\n---", options: .backwards) : nil) else {
        return (nil, source)
    }
    let fm = String(source[afterOpen..<close.lowerBound])
    let body = String(source[close.upperBound...])
    return (fm, body)
}
