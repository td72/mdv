import AppKit

enum Source {
    case file(URL)
    case text(String, title: String)

    var url: URL? { if case .file(let u) = self { return u } else { return nil } }
    var title: String {
        switch self {
        case .file(let u): return u.lastPathComponent
        case .text(_, let t): return t
        }
    }
    /// Directory shown as the window subtitle, with `~` for home.
    var subtitle: String {
        guard let url else { return "" }
        let dir = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }
}

/// How a file is rendered, decided by its name.
enum FileKind {
    case markdown
    case code(String) // tree-sitter language (fence info string)
    case json         // pretty-printed, highlighted as JSON
    case jsonl        // JSON Lines: one pretty-printed record per block
    case table        // CSV / TSV: grid view
    case workbook     // xlsx / xlsm: grid view with a sheet bar
    case pdf          // PDFKit
    case image        // png / jpg / gif / heic / …
    case plain        // unknown extension: one monochrome code block

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "txt"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico"]

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if ["json", "jsonc", "json5"].contains(ext) { return .json }
        if ["jsonl", "ndjson"].contains(ext) { return .jsonl }
        if ["csv", "tsv", "tab"].contains(ext) { return .table }
        if ["xlsx", "xlsm"].contains(ext) { return .workbook }
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if ext.isEmpty {
            // "Dockerfile" & co. carry the language in the name; anything else without an extension reads as markdown.
            return Highlighter.language(for: url.lastPathComponent) != nil ? .code(url.lastPathComponent) : .markdown
        }
        return Highlighter.language(for: ext) != nil ? .code(ext) : .plain
    }

    static func of(_ source: Source) -> FileKind {
        if case .file(let url) = source { return of(url) } else { return .markdown }
    }

    /// Something viw can show as text (used to decide whether a clicked file link opens in place).
    var isViewable: Bool { if case .plain = self { return false } else { return true } }
}

/// The content area of one tab. `TextDocumentView` (NSTextView) is the only implementation
/// today; tables (CSV / xlsx), PDF and images add their own, and `DocumentController` picks
/// one by `FileKind`. Everything a format must offer to the tab, the vim keys and the menus
/// is here, so the rest of the app never touches the concrete view.
protocol DocumentView: AnyObject {
    init()
    /// Root view, sized by the window to the tab's content area.
    var view: NSView { get }
    /// Tells the controller what to do with a file link the user clicked inside the content.
    var onOpenFile: ((URL) -> Void)? { get set }
    /// Receiver of the vim keys typed into the content.
    var commands: ViewerCommands? { get set }
    /// Extra for the window subtitle ("3 / 12" pages, image size); `onStatusChange` fires when it changes.
    var status: String? { get }
    var onStatusChange: (() -> Void)? { get set }

    /// (Re)load the content. `preserveScroll` keeps the position on reload (file change, zoom).
    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool)
    /// Make the right subview first responder so vim keys reach it.
    func focus()

    func scrollLines(_ n: Int)
    func scrollHalfPages(_ n: Int)
    func scrollPages(_ n: Int)
    func scrollHorizontal(_ n: Int)
    func scrollToTop()
    func scrollToBottom()
    func scrollToPercent(_ percent: Int)
    func find()
    /// `f`: filter rows, where the view has rows.
    func filter()
    /// `s` / `S`: sort rows / restore file order, where the view has rows.
    func sortRows()
    func unsortRows()
    func findNext(reverse: Bool)
    /// `y`: put the selection on the pasteboard.
    func copySelection()
    /// `Y`: the whole row (tables); the same as `y` elsewhere.
    func copyRow()
    /// Esc: drop the selection (and any search state).
    func clearSelection()
    /// `.`: show / hide a detail pane, where the view has one.
    func toggleDetail()
    /// Enter / `i` / `⌃w w`: move focus between the main view and its pane, where the view has one.
    func switchPane()

    /// `+` / `-` / `=`: views with their own scale (PDF, images) return true; text views leave it
    /// to the theme (font size).
    func zoomView(_ delta: Int) -> Bool
    func resetZoomView() -> Bool
    /// `r` / `R`: quarter turns clockwise; views that can rotate (PDF, images) return true, and
    /// then `r` rotates instead of reloading (the file watcher and ⌘R still reload).
    func rotate(_ quarterTurns: Int) -> Bool
    /// `p`: PDF page view ⇄ continuous; views without pages return false.
    func togglePageMode() -> Bool
    /// `t`: PDF page overview; nil where there is none.
    func toggleThumbnails() -> Bool?
    /// `]` / `[`: next / previous sheet of a workbook; other views ignore it.
    func selectSheet(offset: Int)
    /// The view's own keys for the `?` overlay (after the common ones).
    var helpSections: [KeyHelp.Section] { get }
    /// Space: play / pause (animated images); false where there is nothing to play.
    func togglePlayback() -> Bool

    /// Debug: render the whole content to a PNG (VIW_SNAPSHOT).
    func snapshot(to path: String)
}

extension DocumentView {
    var status: String? { nil }
    func zoomView(_ delta: Int) -> Bool { false }
    func resetZoomView() -> Bool { false }
    func rotate(_ quarterTurns: Int) -> Bool { false }
    func togglePageMode() -> Bool { false }
    func toggleThumbnails() -> Bool? { nil }
    func selectSheet(offset: Int) {}
    var helpSections: [KeyHelp.Section] { [] }
    func togglePlayback() -> Bool { false }
}

/// What a document needs from the window that hosts it as a tab.
protocol DocumentHost: AnyObject {
    func documentDidChangeTitle(_ doc: DocumentController)
    func documentDidChangeTheme(_ doc: DocumentController)
    /// The document swapped its `DocumentView` (a link led to a different kind of file).
    func documentDidReplaceView(_ doc: DocumentController)
    func open(_ urls: [URL])
    func close(_ doc: DocumentController)
    func selectTab(offset: Int)
    func selectTab(index: Int)
    /// `?`: show the key list over the window.
    func showHelp(for doc: DocumentController)
}

/// One document = one tab: the source, its kind, the theme, the file watcher and the
/// `DocumentView` that draws it. Implements the vim commands by forwarding navigation to
/// the view and handling the rest (reload, zoom, open, close, tabs) itself.
final class DocumentController: NSObject, ViewerCommands {
    private(set) var source: Source
    private(set) var kind: FileKind
    private var theme = Theme.load()
    private(set) var documentView: DocumentView
    private var watcher: FileWatcher?
    weak var host: DocumentHost?

    var view: NSView { documentView.view }
    var title: String { source.title }

    init(source: Source) {
        self.source = source
        self.kind = FileKind.of(source)
        self.documentView = Self.viewType(for: kind).init()
        super.init()
        bind(documentView)
        load()
        startWatching()
    }

    /// Stop watching the file (the tab is going away).
    func stop() { watcher = nil }

    func focus() { documentView.focus() }

    private func bind(_ v: DocumentView) {
        v.onOpenFile = { [weak self] url in self?.open(url) }
        v.onStatusChange = { [weak self] in self.map { $0.host?.documentDidChangeTitle($0) } }
        v.commands = self
    }

    /// Which `DocumentView` draws `kind`; the same class is reused across loads.
    private static func viewType(for kind: FileKind) -> DocumentView.Type {
        switch kind {
        case .table, .workbook: return TableDocumentView.self
        case .pdf: return PDFDocumentView.self
        case .image: return ImageDocumentView.self
        default: return TextDocumentView.self
        }
    }

    /// Window subtitle: the directory, plus the view's status (page, image size).
    var subtitle: String {
        [source.subtitle, documentView.status ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    // MARK: - Loading

    func load(preserveScroll: Bool = true) {
        theme = Theme.load() // re-read config on every (re)load so `r` picks up edits
        let wanted = Self.viewType(for: kind)
        if type(of: documentView) != wanted {
            documentView = wanted.init()
            bind(documentView)
            host?.documentDidReplaceView(self)
        }
        documentView.load(source: source, kind: kind, theme: theme, preserveScroll: preserveScroll)
        host?.documentDidChangeTitle(self)
    }

    private func startWatching() {
        watcher = nil
        guard let url = source.url else { return }
        watcher = FileWatcher(path: url.path) { [weak self] in self?.load() }
    }

    /// Replace this tab's document (relative links navigate in place).
    func open(_ url: URL) {
        source = .file(url.standardizedFileURL)
        kind = FileKind.of(source)
        load(preserveScroll: false)
        documentView.scrollToTop()
        startWatching()
    }

    // MARK: - ViewerCommands

    func scrollLines(_ n: Int) { documentView.scrollLines(n) }
    func scrollHalfPages(_ n: Int) { documentView.scrollHalfPages(n) }
    func scrollPages(_ n: Int) { documentView.scrollPages(n) }
    func scrollHorizontal(_ n: Int) { documentView.scrollHorizontal(n) }
    func scrollToTop() { documentView.scrollToTop() }
    func scrollToBottom() { documentView.scrollToBottom() }
    func scrollToPercent(_ percent: Int) { documentView.scrollToPercent(percent) }
    func find() { documentView.find() }
    func filter() { documentView.filter() }
    func sortRows() { documentView.sortRows() }
    func unsortRows() { documentView.unsortRows() }
    func findNext(reverse: Bool) { documentView.findNext(reverse: reverse) }
    func copySelection() { documentView.copySelection() }
    func copyRow() { documentView.copyRow() }
    func clearSelection() { documentView.clearSelection() }
    func toggleDetail() { documentView.toggleDetail() }
    func switchPane() { documentView.switchPane() }

    func reload() { if !documentView.rotate(1) { load() } }
    func rotateBack() { _ = documentView.rotate(-1) }
    func closeWindow() { host?.close(self) }
    func selectTab(offset: Int) { host?.selectTab(offset: offset) }
    func selectTab(index: Int) { host?.selectTab(index: index) }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = source.url?.deletingLastPathComponent()
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let self else { return }
            self.host?.open(panel.urls)
        }
    }

    /// `p` / View › PDF Page View: one page at a time ⇄ continuous, remembered like the zoom level.
    func togglePageMode() {
        guard documentView.togglePageMode() else { return }
        theme.pdfContinuous.toggle()
        theme.save()
        host?.documentDidChangeTitle(self)
    }

    /// `t` / View › PDF Thumbnails: the page overview.
    func toggleThumbnails() { _ = documentView.toggleThumbnails() }

    /// `]` / `[` / View › Next / Previous Sheet (xlsx).
    func selectSheet(offset: Int) { documentView.selectSheet(offset: offset) }

    func showHelp() { host?.showHelp(for: self) }
    func togglePlayback() -> Bool { documentView.togglePlayback() }
    var helpSections: [KeyHelp.Section] { documentView.helpSections }

    /// `I` / View › Detail Pane: right ⇄ bottom, remembered like the zoom level.
    func togglePanePosition() {
        theme.detailPaneOnRight.toggle()
        theme.save()
        load()
        host?.documentDidChangeTheme(self)
    }

    func zoom(_ delta: Int) {
        if documentView.zoomView(delta) { host?.documentDidChangeTitle(self); return }
        let steps: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 36]
        let i = steps.firstIndex { $0 >= theme.baseSize } ?? 5
        theme.baseSize = steps[max(0, min(steps.count - 1, i + delta))]
        theme.save()
        load()
        host?.documentDidChangeTheme(self)
    }

    func resetZoom() {
        if documentView.resetZoomView() { host?.documentDidChangeTitle(self); return }
        theme.baseSize = theme.defaultSize
        theme.save()
        load()
        host?.documentDidChangeTheme(self)
    }

    func revealInFinder() {
        if let u = source.url { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    func snapshot(to path: String) { documentView.snapshot(to: path) }
}
