import AppKit
import PDFKit

/// `DocumentView` for PDFs: PDFKit's `PDFView` in continuous mode, fit to width, with the
/// vim keys (scrolling, pages, `50G`), a find bar (`/`, `n` / `N`) over `PDFDocument.findString`
/// and `+` / `-` / `=` zoom. Dark mode shows the PDF as is.
final class PDFDocumentView: NSObject, DocumentView, NSSearchFieldDelegate {
    private let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let pdfView = VimPDFView()
    private let searchBar = NSView()
    private let searchField = NSSearchField()
    private let barLabel = NSTextField(labelWithString: "FIND")
    private var matches: [PDFSelection] = []
    private var matchIndex = -1
    private var continuous = true
    private let badge = StatusBadge(frame: .zero)
    private let overviewScroll = NSScrollView()
    private let overview = PDFOverviewGrid()
    private var overviewShown = false
    private var overviewOrigin = 0 // the page to come back to when the overview is cancelled
    private var overviewCommands: OverviewCommands?
    private var pageObserver: NSObjectProtocol?

    var view: NSView { root }
    var onOpenFile: ((URL) -> Void)?
    /// Also refreshes the page badge in the corner.
    var onStatusChange: (() -> Void)?
    /// Refresh the corner badge and tell the controller (window subtitle).
    private func statusChanged() {
        badge.update(status ?? "", in: root)
        onStatusChange?()
    }
    var commands: ViewerCommands? {
        get { pdfView.commands }
        set {
            pdfView.commands = newValue
            overviewCommands = newValue.map { OverviewCommands(grid: overview, forward: $0) }
            overview.commands = overviewCommands
        }
    }

    /// "3 / 12" for the window subtitle: the page under the middle of the view (PDFView's own
    /// `currentPage` lags behind programmatic scrolling); "· page" in page view.
    var status: String? {
        guard let doc = pdfView.document else { return nil }
        let mid = NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        let page = pdfView.page(for: mid, nearest: true) ?? pdfView.currentPage
        guard let page else { return nil }
        return "\(doc.index(for: page) + 1) / \(doc.pageCount)" + (continuous ? "" : " · page")
    }

    private var pageIndex: Int {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return doc.index(for: page)
    }

    private func go(toPage i: Int, top: Bool = true) {
        guard let doc = pdfView.document, doc.pageCount > 0, let page = doc.page(at: max(0, min(i, doc.pageCount - 1))) else { return }
        pdfView.go(to: page) // continuous: puts the page at the top of the view
        if !continuous { scroll(toY: top ? 0 : .greatestFiniteMagnitude) } // page view: the page's own top / bottom
        statusChanged()
    }

    /// `p`: one page at a time ⇄ continuous scrolling.
    func togglePageMode() -> Bool {
        setContinuous(!continuous)
        Toast.show(in: root, continuous ? "Scroll view" : "Page view")
        return true
    }

    private func setContinuous(_ on: Bool) {
        let page = pageIndex
        continuous = on
        pdfView.displayMode = on ? .singlePageContinuous : .singlePage
        if pdfView.autoScales { pdfView.autoScales = false; pdfView.autoScales = true }
        go(toPage: page)
        statusChanged()
    }

    override init() {
        super.init()
        root.autoresizingMask = [.width, .height]
        root.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: root, queue: .main) { [weak self] _ in self?.layout() }

        barLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        barLabel.textColor = .secondaryLabelColor
        barLabel.alignment = .right
        searchBar.addSubview(barLabel)
        searchField.placeholderString = "Find in PDF (Enter: keep, Esc: clear)"
        searchField.delegate = self
        searchBar.addSubview(searchField)
        searchBar.isHidden = true
        searchBar.autoresizingMask = [.width, .minYMargin]
        root.addSubview(searchBar)

        overviewScroll.hasVerticalScroller = true
        overviewScroll.autohidesScrollers = true
        overviewScroll.borderType = .noBorder
        overviewScroll.drawsBackground = true
        overviewScroll.backgroundColor = .windowBackgroundColor
        overviewScroll.documentView = overview
        overviewScroll.isHidden = true
        overview.onPick = { [weak self] page in self?.setOverview(false, page: page) }
        root.addSubview(overviewScroll)

        pdfView.autoresizingMask = [.width, .height]
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.pageShadowsEnabled = true
        root.addSubview(pdfView)
        layout()

        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.statusChanged()
        }
    }

    deinit { if let o = pageObserver { NotificationCenter.default.removeObserver(o) } }

    private func layout() {
        let b = root.bounds
        let top: CGFloat = searchBar.isHidden ? 0 : TableDocumentView.searchBarHeight
        searchBar.frame = NSRect(x: 0, y: b.height - top, width: b.width, height: top)
        barLabel.frame = NSRect(x: 8, y: 9, width: 48, height: 16)
        searchField.frame = NSRect(x: 64, y: 6, width: b.width - 72, height: 22)
        pdfView.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - top)
        pdfView.autoresizingMask = []
        overviewScroll.frame = pdfView.frame
        overview.relayout(width: overviewScroll.contentSize.width)
        badge.update(overviewShown ? "" : (status ?? ""), in: root)
    }

    /// `t`: the page overview (all pages as thumbnails) ⇄ the document. Leaving it this way
    /// (or with Esc) is a cancel: back to the page the overview was opened from; Enter / `i` /
    /// a double-click pick the page under the cursor.
    func toggleThumbnails() -> Bool? {
        if overviewShown { setOverview(false, page: overviewOrigin) }
        else { overviewOrigin = pageIndex; setOverview(true, page: pageIndex) }
        return overviewShown
    }

    /// Show the overview with the cursor on `page`, or come back to the document at `page`.
    private func setOverview(_ on: Bool, page: Int) {
        overviewShown = on
        if on {
            overview.document = pdfView.document
            overview.cursor = page
            overviewScroll.isHidden = false
            pdfView.isHidden = true
            layout()
            overview.scrollToCursor()
            root.window?.makeFirstResponder(overview)
        } else {
            overviewScroll.isHidden = true
            pdfView.isHidden = false
            go(toPage: page)
            focus()
            statusChanged()
        }
    }

    func focus() { root.window?.makeFirstResponder(pdfView) }
    var helpSections: [KeyHelp.Section] { [KeyHelp.pdf] }

    // MARK: - Loading

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        guard let url = source.url else { return }
        let page = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }
        let savedScale = pdfView.scaleFactor
        let wasAuto = pdfView.autoScales
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let doc = PDFDocument(url: url) else {
            pdfView.document = nil
            return
        }
        pdfView.document = doc
        if continuous != theme.pdfContinuous {
            continuous = theme.pdfContinuous
            pdfView.displayMode = continuous ? .singlePageContinuous : .singlePage
        }
        if wasAuto { pdfView.autoScales = true } else { pdfView.scaleFactor = savedScale }
        if preserveScroll, let page, page < doc.pageCount, let p = doc.page(at: page) { pdfView.go(to: p) }
        matches = []
        matchIndex = -1
        pdfView.highlightedSelections = nil
        if ProcessInfo.processInfo.environment["VIW_TIMING"] != nil {
            FileHandle.standardError.write("pdf load: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms (\(doc.pageCount) pages)\n".data(using: .utf8)!)
        }
        statusChanged()
    }

    // MARK: - Scrolling (through PDFView's own scroll view)

    private var scrollView: NSScrollView? { pdfView.documentView?.enclosingScrollView }
    private var clip: NSClipView? { scrollView?.contentView }
    private var maxY: CGFloat {
        guard let sv = scrollView, let c = clip else { return 0 }
        return max(0, (sv.documentView?.frame.height ?? 0) - c.bounds.height)
    }
    private var lineStep: CGFloat { 48 }

    private func scroll(toY y: CGFloat) {
        guard let sv = scrollView, let c = clip else { return }
        var o = c.bounds.origin
        o.y = min(max(0, y), maxY)
        c.scroll(to: o)
        sv.reflectScrolledClipView(c)
        statusChanged()
    }
    private func scroll(by dy: CGFloat) { scroll(toY: (clip?.bounds.origin.y ?? 0) + dy) }

    // Continuous: everything scrolls the document. Page view: `j` / `k` scroll within the page
    // and flip at its edges, `d` / `u` / `⌃f` / `b` flip pages, `gg` / `G` / `50G` pick a page.
    func scrollLines(_ n: Int) {
        guard !continuous, let c = clip else { return scroll(by: CGFloat(n) * lineStep) }
        let y = c.bounds.origin.y
        if n > 0, y >= maxY - 0.5 { go(toPage: pageIndex + 1) }
        else if n < 0, y <= 0.5 { go(toPage: pageIndex - 1, top: false) }
        else { scroll(by: CGFloat(n) * lineStep) }
    }
    func scrollHalfPages(_ n: Int) {
        if continuous { scroll(by: CGFloat(n) * (clip?.bounds.height ?? 0) / 2) } else { go(toPage: pageIndex + n) }
    }
    func scrollPages(_ n: Int) {
        if continuous { scroll(by: CGFloat(n) * max((clip?.bounds.height ?? 0) - lineStep, lineStep)) } else { go(toPage: pageIndex + n) }
    }
    func scrollToTop() { go(toPage: 0) }
    func scrollToBottom() {
        if continuous { scroll(toY: .greatestFiniteMagnitude) } else { go(toPage: (pdfView.document?.pageCount ?? 1) - 1) }
    }
    func scrollToPercent(_ percent: Int) {
        if continuous { scroll(toY: maxY * CGFloat(percent) / 100) }
        else { go(toPage: ((pdfView.document?.pageCount ?? 1) - 1) * percent / 100) }
    }
    func scrollHorizontal(_ n: Int) {
        guard let sv = scrollView, let c = clip, let doc = sv.documentView, doc.frame.width > c.bounds.width else { return }
        var o = c.bounds.origin
        o.x = min(max(0, o.x + CGFloat(n) * lineStep), doc.frame.width - c.bounds.width)
        c.scroll(to: o)
        sv.reflectScrolledClipView(c)
    }

    // MARK: - Find

    func find() {
        searchBar.isHidden = false
        layout()
        root.window?.makeFirstResponder(searchField)
    }
    func filter() { find() }

    private func hideBar() {
        searchBar.isHidden = true
        layout()
        focus()
    }

    private func search(_ text: String) {
        guard let doc = pdfView.document else { return }
        matches = text.isEmpty ? [] : doc.findString(text, withOptions: [.caseInsensitive])
        for m in matches { m.color = .findHighlightColor.withAlphaComponent(0.6) }
        pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        matchIndex = -1
        if !matches.isEmpty { findNext(reverse: false) } else if !text.isEmpty { NSSound.beep() }
    }

    func findNext(reverse: Bool) {
        guard !matches.isEmpty else { if searchBar.isHidden { find() }; return }
        matchIndex = ((matchIndex + (reverse ? -1 : 1)) % matches.count + matches.count) % matches.count
        let m = matches[matchIndex]
        pdfView.setCurrentSelection(m, animate: true)
        pdfView.go(to: m)
        pdfView.scrollSelectionToVisible(nil)
        statusChanged()
    }

    func controlTextDidChange(_ obj: Notification) { search(searchField.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            matches = []
            pdfView.highlightedSelections = nil
            pdfView.clearSelection()
            hideBar()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            hideBar()
            return true
        default: return false
        }
    }

    // MARK: - Selection / zoom

    func copySelection() {
        guard let sel = pdfView.currentSelection, let text = sel.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        var anchor: NSRect?
        if let page = sel.pages.first {
            anchor = pdfView.convert(sel.bounds(for: page), from: page)
            anchor = root.convert(anchor!, from: pdfView)
        }
        Toast.show(in: root, "Copied", detail: text, near: anchor)
    }
    func copyRow() { copySelection() }

    func clearSelection() {
        pdfView.clearSelection()
        if !matches.isEmpty {
            matches = []
            pdfView.highlightedSelections = nil
        }
        if !searchBar.isHidden { hideBar() }
    }

    func toggleDetail() {}
    func switchPane() {}
    func sortRows() {}
    func unsortRows() {}

    /// Rotate every page (PDFPage.rotation is per page); the view re-lays out itself.
    func rotate(_ quarterTurns: Int) -> Bool {
        guard let doc = pdfView.document else { return false }
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += quarterTurns * 90 }
        pdfView.layoutDocumentView()
        if pdfView.autoScales { pdfView.autoScales = false; pdfView.autoScales = true } // refit the new width
        return true
    }

    func zoomView(_ delta: Int) -> Bool {
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.1, min(10, pdfView.scaleFactor * (delta > 0 ? 1.25 : 0.8)))
        return true
    }
    func resetZoomView() -> Bool {
        pdfView.autoScales = true
        return true
    }

    // MARK: - Debug snapshot: the first page

    func snapshot(to path: String) {
        guard path != "/dev/null", let page = pdfView.document?.page(at: 0) else { return }
        let w = ProcessInfo.processInfo.environment["VIW_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 800
        let bounds = page.bounds(for: .mediaBox)
        let size = NSSize(width: w, height: w * bounds.height / max(1, bounds.width))
        let image = page.thumbnail(of: size, for: .mediaBox)
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// All pages as a grid of thumbnails with a cursor: `h` / `j` / `k` / `l` move, Enter / `i` open the
/// page, Esc / `t` go back. Thumbnails are rendered on demand and cached.
final class PDFOverviewGrid: NSView {
    weak var commands: ViewerCommands?
    private var keys = VimKeyMap()
    var document: PDFDocument? { didSet { cache = [:]; relayout(width: frame.width); needsDisplay = true } }
    var cursor = 0 { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    private var cache: [Int: NSImage] = [:]
    private(set) var columns = 1
    private let cell = NSSize(width: 180, height: 240) // thumbnail box, label below
    private let gap: CGFloat = 16

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var pageCount: Int { document?.pageCount ?? 0 }

    func relayout(width: CGFloat) {
        columns = max(1, Int((width - gap) / (cell.width + gap)))
        let rows = (pageCount + columns - 1) / columns
        setFrameSize(NSSize(width: width, height: CGFloat(rows) * (cell.height + gap) + gap))
        needsDisplay = true
    }

    private func rect(of index: Int) -> NSRect {
        let col = index % columns, row = index / columns
        let total = CGFloat(columns) * (cell.width + gap) + gap
        let x0 = max(0, (frame.width - total) / 2)
        return NSRect(x: x0 + gap + CGFloat(col) * (cell.width + gap), y: gap + CGFloat(row) * (cell.height + gap), width: cell.width, height: cell.height)
    }

    func scrollToCursor() {
        guard pageCount > 0 else { return }
        scrollToVisible(rect(of: cursor).insetBy(dx: 0, dy: -gap))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let document else { return }
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        for i in 0..<document.pageCount {
            let r = rect(of: i)
            guard r.intersects(dirtyRect) else { continue }
            let box = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 24)
            let image = cache[i] ?? {
                let img = document.page(at: i)?.thumbnail(of: NSSize(width: box.width * 2, height: box.height * 2), for: .cropBox) ?? NSImage()
                cache[i] = img
                return img
            }()
            // fit the thumbnail in the box, centered
            let s = image.size
            let scale = s.width > 0 && s.height > 0 ? min(box.width / s.width, box.height / s.height) : 1
            let drawn = NSRect(x: box.midX - s.width * scale / 2, y: box.midY - s.height * scale / 2, width: s.width * scale, height: s.height * scale)
            NSColor.white.setFill()
            drawn.fill()
            image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: drawn.insetBy(dx: -0.5, dy: -0.5)).stroke()
            if i == cursor {
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(roundedRect: drawn.insetBy(dx: -4, dy: -4), xRadius: 3, yRadius: 3)
                path.lineWidth = 3
                path.stroke()
            }
            let label = "\(i + 1)" as NSString
            let size = label.size(withAttributes: labelAttrs)
            label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.maxY - 20), withAttributes: labelAttrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0..<pageCount where rect(of: i).contains(p) {
            cursor = i
            if event.clickCount == 2 { onPick?(i) }
            return
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let c = commands, keys.handle(event, c) else { return super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {}

    func move(_ delta: Int) {
        guard pageCount > 0 else { return }
        cursor = max(0, min(cursor + delta, pageCount - 1))
        scrollToCursor()
    }
}

/// `ViewerCommands` for the overview: navigation moves the cursor, Enter / `i` opens, Esc / `t` closes.
final class OverviewCommands: ViewerCommands {
    private weak var grid: PDFOverviewGrid?
    private let forward: ViewerCommands
    init(grid: PDFOverviewGrid, forward: ViewerCommands) { self.grid = grid; self.forward = forward }

    func scrollLines(_ n: Int) { grid.map { $0.move(n * $0.columns) } }
    func scrollHalfPages(_ n: Int) { grid.map { $0.move(n * $0.columns * 3) } }
    func scrollPages(_ n: Int) { grid.map { $0.move(n * $0.columns * 6) } }
    func scrollHorizontal(_ n: Int) { grid.map { $0.move(abs(n) >= 1_000_000 ? (n < 0 ? -$0.cursor % $0.columns : $0.columns - 1 - $0.cursor % $0.columns) : n) } }
    func scrollToTop() { grid.map { $0.move(-$0.pageCount) } }
    func scrollToBottom() { grid.map { $0.move($0.pageCount) } }
    func scrollToPercent(_ percent: Int) { grid.map { $0.move(($0.pageCount - 1) * percent / 100 - $0.cursor) } }
    func find() {}
    func filter() {}
    func sortRows() {}
    func unsortRows() {}
    func findNext(reverse: Bool) {}
    func copySelection() {}
    func copyRow() {}
    func clearSelection() { forward.toggleThumbnails() }
    func toggleDetail() {}
    func switchPane() { grid.map { $0.onPick?($0.cursor) } }
    func togglePanePosition() {}
    func togglePageMode() { forward.togglePageMode() }
    func toggleThumbnails() { forward.toggleThumbnails() }
    func selectSheet(offset: Int) { forward.selectSheet(offset: offset) }
    func showHelp() { forward.showHelp() }
    func togglePlayback() -> Bool { forward.togglePlayback() }
    func reload() {}
    func rotateBack() {}
    func openFile() { forward.openFile() }
    func closeWindow() { forward.closeWindow() }
    func selectTab(offset: Int) { forward.selectTab(offset: offset) }
    func selectTab(index: Int) { forward.selectTab(index: index) }
    func zoom(_ delta: Int) {}
    func resetZoom() {}
}

/// PDFView that routes keys through the vim key map.
final class VimPDFView: PDFView {
    weak var commands: ViewerCommands?
    private var keys = VimKeyMap()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = commands, keys.handle(event, c) else { return super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {}
}
