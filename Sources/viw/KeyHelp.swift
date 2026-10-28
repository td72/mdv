import AppKit

/// The key bindings as data: the `?` overlay, Help › Keyboard Shortcuts and `viw -h` all
/// print from here, so there is one list to keep in step with `VimKeyMap`.
enum KeyHelp {
    struct Entry {
        let keys: String
        let action: String
        init(_ keys: String, _ action: String) { self.keys = keys; self.action = action }
    }

    struct Section {
        let title: String
        let entries: [Entry]
    }

    /// Every view.
    static let common: [Section] = [
        Section(title: "Move", entries: [
            Entry("j / k   ⌃e / ⌃y   ↓ / ↑", "line down / up"),
            Entry("d / u   ⌃d / ⌃u", "half page down / up"),
            Entry("⌃f / ⌃b   Space / ⇧Space   b", "page down / up"),
            Entry("gg / G   Home / End", "top / bottom"),
            Entry("50G", "go to 50 %"),
            Entry("h / l   0 / $", "sideways (tables: the column cursor)"),
            Entry("5j, 3d, …", "counts work with every motion"),
        ]),
        Section(title: "Find & copy", entries: [
            Entry("/", "find, incrementally; Esc goes back"),
            Entry("n / N", "next / previous match"),
            Entry("y", "copy the selection (tables: the cell)"),
            Entry("Esc   ⌃[", "clear count, selection, filter"),
        ]),
        Section(title: "Tabs & window", entries: [
            Entry("gt / gT   Tab / ⇧Tab", "next / previous tab"),
            Entry("3gt   ⌘1 – ⌘9", "tab 3   tab n (⌘9: the last)"),
            Entry("o", "open a file in a new tab"),
            Entry("q", "close the tab (the last one closes the window)"),
            Entry("r", "reload (PDF / images: rotate instead)"),
            Entry("+ / -   =", "zoom in / out   reset"),
            Entry("?   ⌘/", "this help (?, Esc or q closes it)"),
        ]),
    ]

    static let text = Section(title: "Text", entries: [
        Entry("click a link", "files that viw can show open in this tab; others in their app"),
        Entry("⌘F", "the system find bar (same as /)"),
    ])

    static let table = Section(title: "Table (CSV / xlsx)", entries: [
        Entry("h / l   0 / $", "column cursor: the cell y copies and s sorts by"),
        Entry("f", "filter rows (Enter keeps the filter, Esc clears it)"),
        Entry("s / S", "sort by the cursor column (again: reverse) / file order"),
        Entry("click a header", "sort by that column"),
        Entry("y / Y", "copy the cell / the row as TSV"),
        Entry("Enter / i   Esc", "into the detail pane / back to the grid"),
        Entry(".   I", "show / hide the pane   pane on the right / at the bottom"),
        Entry("j / k   h / l   s  (in the pane)", "next / previous field   next / previous row   sort by the field"),
    ])

    static let sheets = Section(title: "Sheets (xlsx)", entries: [
        Entry("]s / [s   ⌘] / ⌘[", "next / previous sheet (3]s: three ahead; wraps)"),
        Entry("click a sheet", "in the bar under the grid"),
    ])

    static let pdf = Section(title: "PDF", entries: [
        Entry("p", "page view (one page at a time) ⇄ continuous scrolling"),
        Entry("t", "page overview: h / j / k / l move, Enter or i opens the page, Esc goes back"),
        Entry("gg / G   50G", "first / last page   the page at 50 % (page view: page by page)"),
        Entry("r / R", "rotate clockwise / counter-clockwise"),
        Entry("+ / -   =", "zoom   fit to width"),
        Entry("/", "find: every hit is highlighted, n / N step through them"),
    ])

    static let image = Section(title: "Image", entries: [
        Entry("r / R", "rotate clockwise / counter-clockwise"),
        Entry("+ / -   =", "zoom   fit to the window"),
        Entry("y", "copy the image"),
    ])

    /// `viw -h`.
    static func plainText(_ sections: [Section]) -> String {
        var out = ""
        for s in sections {
            out += "  \(s.title)\n"
            let w = s.entries.map { $0.keys.count }.max() ?? 0
            for e in s.entries { out += "    " + e.keys.padding(toLength: w + 3, withPad: " ", startingAt: 0) + e.action + "\n" }
            out += "\n"
        }
        return out
    }
}

/// The `?` overlay: dims the content and shows the key list for the current view in a
/// centered card. Any of `?`, Esc, `q`, Enter or a click closes it.
final class HelpOverlay: NSView {
    var onClose: (() -> Void)?
    private let card = CardView()

    init(title: String, sections: [KeyHelp.Section], viewSections: [KeyHelp.Section]) {
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true

        card.wantsLayer = true
        card.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            s.shadowBlurRadius = 24
            s.shadowOffset = NSSize(width: 0, height: -8)
            return s
        }()
        card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(card)

        // Title row, then two columns: the common keys and the view's own (or the common
        // keys split in two when the view adds none).
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(labelWithString: "?  Esc  q  close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        var left = sections, right = viewSections
        if right.isEmpty, left.count > 1 { right = Array(left.suffix(from: (left.count + 1) / 2)); left = Array(left.prefix((left.count + 1) / 2)) }
        let columns = [left, right].filter { !$0.isEmpty }.map { Self.column($0) }

        let pad: CGFloat = 24, gap: CGFloat = 32
        let sizes = columns.map(\.fittingSize)
        let bodyWidth = sizes.map(\.width).reduce(0, +) + gap * CGFloat(max(0, columns.count - 1))
        let bodyHeight = sizes.map(\.height).max() ?? 0
        let headerHeight: CGFloat = 24
        let width = max(bodyWidth, header.fittingSize.width + hint.fittingSize.width + 24) + pad * 2
        let height = bodyHeight + headerHeight + 16 + pad * 2
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)

        header.frame = NSRect(x: pad, y: height - pad - headerHeight + 2, width: width - pad * 2, height: headerHeight)
        hint.frame = NSRect(x: width - pad - hint.fittingSize.width, y: height - pad - headerHeight + 6, width: hint.fittingSize.width, height: 16)
        card.addSubview(header)
        card.addSubview(hint)
        var x = pad
        for (col, size) in zip(columns, sizes) {
            col.frame = NSRect(x: x, y: pad, width: size.width, height: bodyHeight)
            card.addSubview(col)
            x += size.width + gap
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// One column: section titles in bold, then `keys  action` lines with the actions aligned.
    private static func column(_ sections: [KeyHelp.Section]) -> NSTextField {
        let keyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let actionFont = NSFont.systemFont(ofSize: 12)
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .bold)
        let keyWidth = sections.flatMap(\.entries).map { ($0.keys as NSString).size(withAttributes: [.font: keyFont]).width }.max() ?? 0
        let tab = (keyWidth + 18).rounded(.up)

        let line = NSMutableParagraphStyle()
        line.tabStops = [NSTextTab(textAlignment: .left, location: tab)]
        line.headIndent = tab
        line.paragraphSpacing = 3
        let title = NSMutableParagraphStyle()
        title.paragraphSpacingBefore = 12
        title.paragraphSpacing = 5

        let text = NSMutableAttributedString()
        for (i, s) in sections.enumerated() {
            let t = NSMutableParagraphStyle()
            t.setParagraphStyle(title)
            if i == 0 { t.paragraphSpacingBefore = 0 }
            text.append(NSAttributedString(string: s.title.uppercased() + "\n", attributes: [.font: titleFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: t, .kern: 0.6]))
            for e in s.entries {
                text.append(NSAttributedString(string: e.keys + "\t", attributes: [.font: keyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: line]))
                text.append(NSAttributedString(string: e.action + "\n", attributes: [.font: actionFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: line]))
            }
        }
        if text.length > 0 { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        let field = NSTextField(labelWithAttributedString: text)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = 520
        return field
    }

    override func layout() {
        super.layout()
        var f = card.frame
        f.origin = NSPoint(x: ((bounds.width - f.width) / 2).rounded(), y: ((bounds.height - f.height) / 2).rounded())
        card.frame = f
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers ?? "" {
        case "?", "q", "\u{1B}", "\r", "\u{3}": onClose?()
        default: break // swallow: the document must not scroll under the card
        }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func mouseDown(with event: NSEvent) { onClose?() }

    /// Opaque rounded card, so the dimmed content underneath does not show through the text.
    private final class CardView: NSView {
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            NSColor.controlBackgroundColor.setFill() // white (near-black in dark mode): a dialog, not a dimmed panel
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        override func mouseDown(with event: NSEvent) {} // clicks on the card keep it open
    }
}
