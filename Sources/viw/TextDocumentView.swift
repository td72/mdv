import AppKit
import Markdown

/// `DocumentView` for everything that is text: Markdown (rendered), source code, JSON and
/// plain files, in an NSTextView (TextKit 1) inside a scroll view. Owns rendering, the
/// asynchronous syntax highlighting, link handling, scrolling, find and the debug snapshot.
final class TextDocumentView: NSObject, DocumentView, NSTextViewDelegate {
    private let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let textView = VimTextView(usingTextLayoutManager: false)
    private var theme = Theme.load()
    /// Bumped on every load so a highlight pass for an older rendering is dropped.
    private var highlightGeneration = 0

    /// Text beyond this (UTF-16 units) is cut off with a notice. TextKit lays the whole
    /// document out before the window shows, and a million paragraphs take tens of seconds.
    static let maxDisplayLength = 1 << 20

    var view: NSView { scrollView }
    var onOpenFile: ((URL) -> Void)?
    var onStatusChange: (() -> Void)?
    /// Receiver of the vim keys typed into the text view.
    var commands: ViewerCommands? {
        get { textView.commands }
        set { textView.commands = newValue }
    }

    override init() {
        super.init()
        buildViews()
    }

    func focus() { scrollView.window?.makeFirstResponder(textView) }
    var helpSections: [KeyHelp.Section] { [KeyHelp.text] }

    // MARK: - Views

    private func buildViews() {
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.findBarPosition = .aboveContent

        let size = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: size)
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.relayoutColumn()

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.displaysLinkToolTips = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = self
        scrollView.documentView = textView
    }

    // MARK: - Loading

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        let savedOrigin = scrollView.contentView.bounds.origin
        self.theme = theme
        textView.maxContentWidth = theme.maxWidth
        textView.relayoutColumn()
        let (text, baseURL): (String, URL?)
        switch source {
        case .file(let url):
            guard let data = FileManager.default.contents(atPath: url.path) else {
                show(error: "Cannot read \(url.path)")
                return
            }
            text = String(decoding: data, as: UTF8.self)
            baseURL = url
        case .text(let s, _):
            text = s
            baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/stdin")
        }

        let timing = ProcessInfo.processInfo.environment["VIW_TIMING"] != nil
        var t0 = CFAbsoluteTimeGetCurrent()
        func lap(_ label: String) {
            guard timing else { return }
            let t = CFAbsoluteTimeGetCurrent()
            FileHandle.standardError.write("\(label): \(Int((t - t0) * 1000)) ms\n".data(using: .utf8)!)
            t0 = t
        }

        // Cap what reaches the text system; `truncated` (lines shown / lines total) drives the notice.
        var truncated: (shown: Int, total: Int)?
        func lines(_ s: String) -> Int { s.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } + 1 }
        func clamp(_ s: String) -> String {
            let ns = s as NSString
            guard ns.length > Self.maxDisplayLength else { return s }
            var cut = Self.maxDisplayLength
            let nl = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: cut))
            if nl.location != NSNotFound, nl.location > cut / 2 { cut = nl.location }
            let shown = ns.substring(to: cut)
            truncated = (lines(shown), lines(s))
            return shown
        }

        let renderer = MarkdownRenderer(theme: theme, baseURL: baseURL)
        let attributed = NSMutableAttributedString()
        var codeBlocks: [MarkdownRenderer.CodeBlockRef] = []
        switch kind {
        case .markdown:
            let (front, body) = splitFrontMatter(clamp(text))
            if let front {
                attributed.append(renderer.render(Document(parsing: "```yaml\n\(front)\n```\n")))
                codeBlocks += renderer.codeBlocks
            }
            let document = Document(parsing: body)
            lap("parse")
            let offset = attributed.length
            attributed.append(renderer.render(document))
            codeBlocks += renderer.codeBlocks.map { var r = $0; r.range.location += offset; return r }
        case .code(let language):
            attributed.append(renderer.renderCode(clamp(text), language: language))
            codeBlocks = renderer.codeBlocks
        case .json:
            // Format first, cut after, so what is shown keeps its structure. Invalid JSON
            // (or jsonc with comments) is shown as written.
            attributed.append(renderer.renderCode(clamp(JSONPretty.format(text) ?? text), language: "json"))
            codeBlocks = renderer.codeBlocks
        case .jsonl:
            var records: [String] = []
            var shown = 0
            let all = JSONPretty.formatLines(text)
            for r in all {
                if shown + r.utf16.count > Self.maxDisplayLength { break }
                shown += r.utf16.count + 1
                records.append(r)
            }
            if records.count < all.count { truncated = (records.count, all.count) }
            attributed.append(renderer.renderCodeBlocks(records, language: "json", boxed: records.count <= 300))
            codeBlocks = renderer.codeBlocks
        case .plain, .table, .workbook, .pdf, .image, .video, .audio: // these have their own DocumentView; text only if they ever land here
            attributed.append(renderer.renderCode(clamp(text), language: nil))
        }
        if let t = truncated {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            let unit: String
            if case .jsonl = kind { unit = "records" } else { unit = "lines" }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = theme.baseSize
            attributed.append(NSAttributedString(
                string: "Showing the first \(f.string(from: t.shown as NSNumber)!) of \(f.string(from: t.total as NSNumber)!) \(unit) — the rest is cut off to keep the viewer responsive.\n",
                attributes: [.font: theme.body, .foregroundColor: theme.secondary, .paragraphStyle: style]))
        }
        lap("render")

        textView.textStorage?.setAttributedString(attributed)
        lap("setAttributedString")
        // Lay everything out now, before the display cycle gets a chance to. TextKit 1 filling
        // layout holes from a display request (setNeedsDisplay, cursor tracking) invalidates the
        // display per line fragment and turns quadratic: ~1 MB of text takes a minute that way
        // and well under a second this way. See also VimTextView.relayoutColumn.
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        lap("layout")
        let syncHighlight = ProcessInfo.processInfo.environment["VIW_SNAPSHOT"] != nil
        highlight(codeBlocks, sync: syncHighlight)
        if timing, syncHighlight, !codeBlocks.isEmpty { lap("highlight (sync)") }

        if preserveScroll, savedOrigin.y > 0 {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            scroll(toY: savedOrigin.y)
        }
    }

    /// Syntax-highlight fenced code blocks. The tree-sitter work (compiling a grammar's query
    /// the first time can take ~100 ms for Swift) runs off the main thread so the document
    /// appears immediately; the colors land a moment later. Only foreground colors change,
    /// so layout and the scroll position are untouched.
    private func highlight(_ blocks: [MarkdownRenderer.CodeBlockRef], sync: Bool) {
        highlightGeneration += 1
        let generation = highlightGeneration
        guard !blocks.isEmpty else { return }
        let theme = self.theme
        let compute = { () -> [(NSRange, NSColor)] in
            blocks.flatMap { block -> [(NSRange, NSColor)] in
                Highlighter.spans(block.code, info: block.language).compactMap { span in
                    guard let color = theme.codeColor(for: span.name) else { return nil }
                    let r = NSIntersectionRange(
                        NSRange(location: block.range.location + span.range.location, length: span.range.length), block.range)
                    return r.length > 0 ? (r, color) : nil
                }
            }
        }
        let apply = { [weak self] (runs: [(NSRange, NSColor)]) in
            guard let self, generation == self.highlightGeneration, let storage = self.textView.textStorage else { return }
            storage.beginEditing()
            for (range, color) in runs where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            storage.endEditing()
        }
        if sync {
            apply(Highlighter.queue.sync(execute: compute))
        } else {
            Highlighter.queue.async {
                let runs = compute()
                DispatchQueue.main.async { apply(runs) }
            }
        }
    }

    private func show(error: String) {
        let s = NSAttributedString(string: error, attributes: [
            .font: theme.body, .foregroundColor: NSColor.systemRed,
        ])
        textView.textStorage?.setAttributedString(s)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        if url.isFileURL {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists, !isDir.boolValue, FileKind.of(url).isViewable {
                onOpenFile?(url)
            } else if exists {
                // Never hand arbitrary local files to Launch Services (a doc could link to a
                // script or app bundle); reveal in Finder instead.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSSound.beep()
            }
            return true
        }
        if url.scheme == nil || (url.fragment != nil && url.path.isEmpty) {
            // "#heading" anchors: best effort — search for the heading text.
            if let frag = url.fragment?.removingPercentEncoding {
                jump(toHeading: frag)
                return true
            }
        }
        // External links: only well-known schemes; custom URL schemes can launch arbitrary apps.
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            NSSound.beep()
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }

    private func jump(toHeading slug: String) {
        guard let storage = textView.textStorage else { return }
        let wanted = slug.lowercased().replacingOccurrences(of: "-", with: " ")
        let text = storage.string as NSString
        var found: NSRange?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { sub, range, _, stop in
            guard let sub else { return }
            let norm = sub.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N} ]", with: "", options: .regularExpression)
            if norm == wanted {
                found = range
                stop.pointee = true
            }
        }
        if let r = found {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            if let lm = textView.layoutManager, let tc = textView.textContainer {
                let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: g, in: tc)
                scroll(toY: rect.minY)
            }
        }
    }

    // MARK: - Scrolling

    private var clip: NSClipView { scrollView.contentView }
    private var lineStep: CGFloat { theme.lineHeight * 2 }
    private var pageStep: CGFloat { max(clip.bounds.height - theme.lineHeight * 2, theme.lineHeight) }
    private var maxY: CGFloat { max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height) }

    private func scroll(toY y: CGFloat) {
        var o = clip.bounds.origin
        o.y = min(max(0, y), maxY)
        clip.scroll(to: o)
        scrollView.reflectScrolledClipView(clip)
        if ProcessInfo.processInfo.environment["VIW_TIMING"] != nil {
            FileHandle.standardError.write("scrollY: \(Int(o.y)) / \(Int(maxY))\n".data(using: .utf8)!)
        }
    }

    private func scroll(by dy: CGFloat) { scroll(toY: clip.bounds.origin.y + dy) }

    func scrollLines(_ n: Int) { scroll(by: CGFloat(n) * lineStep) }
    func scrollHalfPages(_ n: Int) { scroll(by: CGFloat(n) * clip.bounds.height / 2) }
    func scrollPages(_ n: Int) { scroll(by: CGFloat(n) * pageStep) }
    func scrollToTop() { scroll(toY: 0) }

    func scrollToBottom() {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        scroll(toY: .greatestFiniteMagnitude)
    }

    func scrollToPercent(_ percent: Int) {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        scroll(toY: maxY * CGFloat(percent) / 100)
    }

    func scrollHorizontal(_ n: Int) {
        guard let doc = scrollView.documentView, doc.frame.width > clip.bounds.width else { return }
        var o = clip.bounds.origin
        o.x = min(max(0, o.x + CGFloat(n) * theme.lineHeight * 2), doc.frame.width - clip.bounds.width)
        clip.scroll(to: o)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Find

    private func finderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    func find() { finderAction(.showFindInterface) }
    func filter() { find() } // no rows to filter; `f` behaves like `/`
    func sortRows() {}
    func unsortRows() {}
    func findNext(reverse: Bool) { finderAction(reverse ? .previousMatch : .nextMatch) }

    func copySelection() {
        let r = textView.selectedRange()
        guard r.length > 0 else { return }
        textView.copy(nil)
        var anchor: NSRect?
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: g, in: tc)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let visible = rect.intersection(textView.visibleRect)
            anchor = visible.isEmpty ? nil : scrollView.convert(visible, from: textView)
        }
        Toast.show(in: scrollView, "Copied", detail: (textView.string as NSString).substring(with: r), near: anchor)
    }

    func copyRow() { copySelection() }

    func clearSelection() {
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
    }

    func toggleDetail() {} // nothing to inspect in a text document
    func switchPane() {}

    // MARK: - Debug snapshot (VIW_SNAPSHOT=/path.png renders the whole document and quits)

    func snapshot(to path: String) {
        guard path != "/dev/null" else { return }
        if let w = ProcessInfo.processInfo.environment["VIW_SNAPSHOT_WIDTH"].flatMap(Double.init) {
            textView.setFrameSize(NSSize(width: CGFloat(w), height: textView.frame.height))
        }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let bounds = textView.bounds
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        textView.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
