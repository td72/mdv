import AppKit

/// One window, many documents. Tabs are drawn by `TabBarView` inside the window instead of
/// using native NSWindow tabs: those are separate windows under the hood, which tiling window
/// managers (AeroSpace, yabai) treat as such — every tab switch re-tiles. Here the window
/// manager only ever sees one window.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, DocumentHost {
    private(set) var documents: [DocumentController] = []
    private(set) var selectedIndex = -1
    private let tabBar = TabBarView()
    private let container = NSView()

    var onClose: ((ViewerWindowController) -> Void)?
    var current: DocumentController? { documents.indices.contains(selectedIndex) ? documents[selectedIndex] : nil }

    init(source: Source) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 960),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 240)
        super.init(window: window)
        window.delegate = self
        buildViews()
        window.setFrameAutosaveName("viw.viewer")
        if !window.setFrameUsingName("viw.viewer") { window.center() }
        addTab(source)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func buildViews() {
        guard let window else { return }
        let content = DropView(frame: window.contentLayoutRect)
        content.onDrop = { [weak self] urls in self?.open(urls) }
        window.contentView = content

        tabBar.autoresizingMask = [.width, .minYMargin]
        tabBar.onSelect = { [weak self] i in self?.selectTab(index: i) }
        tabBar.onClose = { [weak self] i in
            guard let self, self.documents.indices.contains(i) else { return }
            self.close(self.documents[i])
        }
        container.autoresizingMask = [.width, .height]
        content.addSubview(container)
        content.addSubview(tabBar)
        layoutChrome()
    }

    /// The tab bar is only shown with two or more tabs (like Safari).
    private func layoutChrome() {
        guard let content = window?.contentView else { return }
        let h: CGFloat = documents.count > 1 ? TabBarView.height : 0
        let b = content.bounds
        tabBar.frame = NSRect(x: 0, y: b.height - h, width: b.width, height: h)
        tabBar.isHidden = h == 0
        container.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - h)
        current?.view.frame = container.bounds
        tabBar.items = documents.map { ($0.title, $0.source.url?.path ?? $0.title) }
        tabBar.selected = selectedIndex
    }

    // MARK: - Tabs

    func addTab(_ source: Source) {
        let doc = DocumentController(source: source)
        doc.host = self
        documents.append(doc)
        selectTab(index: documents.count - 1)
    }

    func selectTab(index: Int) {
        guard !documents.isEmpty else { return }
        let i = max(0, min(index, documents.count - 1)) // `9gt` with fewer tabs → last, like vim
        if i != selectedIndex {
            current?.view.removeFromSuperview()
            selectedIndex = i
            let v = documents[i].view
            v.frame = container.bounds
            container.addSubview(v)
        }
        layoutChrome()
        updateTitle()
        documents[i].focus()
    }

    func selectTab(offset: Int) {
        let n = documents.count
        guard n > 1 else { return }
        selectTab(index: ((selectedIndex + offset) % n + n) % n)
    }

    func close(_ doc: DocumentController) {
        guard let i = documents.firstIndex(where: { $0 === doc }) else { return }
        if documents.count == 1 {
            window?.close()
            return
        }
        doc.stop()
        doc.view.removeFromSuperview()
        documents.remove(at: i)
        if i == selectedIndex {
            selectedIndex = -1
            selectTab(index: i) // the tab to the right takes over (clamped to last)
        } else {
            if i < selectedIndex { selectedIndex -= 1 }
            layoutChrome()
        }
    }

    func open(_ urls: [URL]) {
        for u in urls { addTab(.file(u.standardizedFileURL)) }
    }

    private func updateTitle() {
        guard let window, let doc = current else { return }
        window.title = doc.title
        window.representedURL = doc.source.url
        window.subtitle = doc.source.subtitle
    }

    // MARK: - DocumentHost

    func documentDidChangeTitle(_ doc: DocumentController) {
        if doc === current { updateTitle() }
        tabBar.items = documents.map { ($0.title, $0.source.url?.path ?? $0.title) }
    }

    func documentDidChangeTheme(_ doc: DocumentController) {
        for other in documents where other !== doc { other.load() }
    }

    func documentDidReplaceView(_ doc: DocumentController) {
        guard doc === current else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        doc.view.frame = container.bounds
        container.addSubview(doc.view)
        doc.focus()
    }

    // MARK: - NSWindowDelegate

    /// ⌘W / `q` close the current tab; the window goes with the last one.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard documents.count > 1, let doc = current else { return true }
        close(doc)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        documents.forEach { $0.stop() }
        onClose?(self)
    }

    // MARK: - Menu targets (responder chain)

    @objc func zoomIn(_ sender: Any?) { current?.zoom(1) }
    @objc func zoomOut(_ sender: Any?) { current?.zoom(-1) }
    @objc func actualSize(_ sender: Any?) { current?.resetZoom() }
    @objc func reloadDocument(_ sender: Any?) { current?.reload() }
    @objc func revealInFinder(_ sender: Any?) { current?.revealInFinder() }
    @objc func selectNextTab(_ sender: Any?) { selectTab(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { selectTab(offset: -1) }

    func snapshot(to path: String) { current?.snapshot(to: path) }
}

/// Safari-style strip of equal-width tabs. Click selects, middle-click closes.
final class TabBarView: NSView {
    static let height: CGFloat = 28

    var items: [(title: String, tooltip: String)] = [] { didSet { needsDisplay = true; resetToolTips() } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var tabWidth: CGFloat { items.isEmpty ? bounds.width : bounds.width / CGFloat(items.count) }
    private func index(at p: NSPoint) -> Int? {
        guard !items.isEmpty, bounds.contains(p) else { return nil }
        return min(items.count - 1, Int(p.x / tabWidth))
    }

    private func resetToolTips() {
        removeAllToolTips()
        for (i, item) in items.enumerated() {
            addToolTip(NSRect(x: CGFloat(i) * tabWidth, y: 0, width: tabWidth, height: bounds.height), owner: item.tooltip as NSString, userData: nil)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resetToolTips()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let w = tabWidth
        let font = NSFont.systemFont(ofSize: 12)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        for (i, item) in items.enumerated() {
            let rect = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
            let isSelected = i == selected
            if isSelected {
                NSColor.textBackgroundColor.setFill()
                rect.fill()
            }
            NSColor.separatorColor.setFill()
            if i > 0 { NSRect(x: rect.minX, y: 0, width: 1, height: rect.height).fill() }
            if !isSelected { NSRect(x: rect.minX, y: rect.maxY - 1, width: w, height: 1).fill() }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: para,
                .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let textHeight = font.ascender - font.descender
            let textRect = rect.insetBy(dx: 12, dy: 0)
                .offsetBy(dx: 0, dy: ((rect.height - textHeight) / 2).rounded(.down))
            (item.title as NSString).draw(with: NSRect(origin: textRect.origin, size: NSSize(width: textRect.width, height: textHeight)),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onSelect?(i) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onClose?(i) }
    }
}

/// Content view accepting file drops.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}
