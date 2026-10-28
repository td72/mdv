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
        set { pdfView.commands = newValue }
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
        pdfView.go(to: page)
        scroll(toY: top ? 0 : .greatestFiniteMagnitude)
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
    }

    func focus() { root.window?.makeFirstResponder(pdfView) }

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
