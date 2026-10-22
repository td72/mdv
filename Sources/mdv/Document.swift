import AppKit
import Markdown

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

/// What a document needs from the window that hosts it as a tab.
protocol DocumentHost: AnyObject {
    func documentDidChangeTitle(_ doc: DocumentController)
    func documentDidChangeTheme(_ doc: DocumentController)
    func open(_ urls: [URL])
    func close(_ doc: DocumentController)
    func selectTab(offset: Int)
    func selectTab(index: Int)
}

/// One document = one tab. Hosts the scroll view, the text view and the file watcher;
/// the window (ViewerWindowController) swaps `view`s in and out.
final class DocumentController: NSObject, NSTextViewDelegate, ViewerCommands {
    private(set) var source: Source
    private var theme = Theme.load()
    private let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let textView = VimTextView(usingTextLayoutManager: false)
    private var watcher: FileWatcher?
    weak var host: DocumentHost?

    var view: NSView { scrollView }
    var title: String { source.title }

    init(source: Source) {
        self.source = source
        super.init()
        buildViews()
        load()
        startWatching()
    }

    /// Stop watching the file (the tab is going away).
    func stop() { watcher = nil }

    func focus() { scrollView.window?.makeFirstResponder(textView) }

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
        textView.commands = self
        scrollView.documentView = textView
    }

    // MARK: - Loading

    func load(preserveScroll: Bool = true) {
        let savedOrigin = scrollView.contentView.bounds.origin
        theme = Theme.load() // re-read config on every (re)load so `r` picks up edits
        textView.maxContentWidth = theme.maxWidth
        textView.relayoutColumn()
        let (markdown, baseURL): (String, URL?)
        switch source {
        case .file(let url):
            guard let data = FileManager.default.contents(atPath: url.path) else {
                show(error: "Cannot read \(url.path)")
                return
            }
            markdown = String(decoding: data, as: UTF8.self)
            baseURL = url
        case .text(let s, _):
            markdown = s
            baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/stdin")
        }

        let timing = ProcessInfo.processInfo.environment["MDV_TIMING"] != nil
        var t0 = CFAbsoluteTimeGetCurrent()
        func lap(_ label: String) {
            guard timing else { return }
            let t = CFAbsoluteTimeGetCurrent()
            FileHandle.standardError.write("\(label): \(Int((t - t0) * 1000)) ms\n".data(using: .utf8)!)
            t0 = t
        }

        let renderer = MarkdownRenderer(theme: theme, baseURL: baseURL)
        let (front, body) = splitFrontMatter(markdown)
        let attributed = NSMutableAttributedString()
        if let front {
            attributed.append(renderer.render(Document(parsing: "```yaml\n\(front)\n```\n")))
        }
        let document = Document(parsing: body)
        lap("parse")
        attributed.append(renderer.render(document))
        lap("render")

        textView.textStorage?.setAttributedString(attributed)
        lap("setAttributedString")
        if timing {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            lap("layout")
        }
        host?.documentDidChangeTitle(self)

        if preserveScroll, savedOrigin.y > 0 {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            scroll(toY: savedOrigin.y)
        }
    }

    private func show(error: String) {
        let s = NSAttributedString(string: error, attributes: [
            .font: theme.body, .foregroundColor: NSColor.systemRed,
        ])
        textView.textStorage?.setAttributedString(s)
    }

    private func startWatching() {
        watcher = nil
        guard let url = source.url else { return }
        watcher = FileWatcher(path: url.path) { [weak self] in self?.load() }
    }

    /// Replace this tab's document (relative links navigate in place).
    func open(_ url: URL) {
        source = .file(url.standardizedFileURL)
        load(preserveScroll: false)
        scrollToTop()
        startWatching()
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if ["md", "markdown", "mdown", "mkd", "mkdn", "txt", ""].contains(ext), exists, !isDir.boolValue {
                open(url)
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
        if ProcessInfo.processInfo.environment["MDV_TIMING"] != nil {
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

    // MARK: - Commands

    private func finderAction(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    func find() { finderAction(.showFindInterface) }
    func findNext(reverse: Bool) { finderAction(reverse ? .previousMatch : .nextMatch) }

    func reload() { load() }
    func closeWindow() { host?.close(self) }
    func selectTab(offset: Int) { host?.selectTab(offset: offset) }
    func selectTab(index: Int) { host?.selectTab(index: index) }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = source.url?.deletingLastPathComponent()
        guard let window = scrollView.window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let self else { return }
            self.host?.open(panel.urls)
        }
    }

    func zoom(_ delta: Int) {
        let steps: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 36]
        let i = steps.firstIndex { $0 >= theme.baseSize } ?? 5
        theme.baseSize = steps[max(0, min(steps.count - 1, i + delta))]
        theme.save()
        load()
        host?.documentDidChangeTheme(self)
    }

    func resetZoom() {
        theme.baseSize = theme.defaultSize
        theme.save()
        load()
        host?.documentDidChangeTheme(self)
    }

    func revealInFinder() {
        if let u = source.url { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    // MARK: - Debug snapshot (MDV_SNAPSHOT=/path.png renders the whole document and quits)

    func snapshot(to path: String) {
        guard path != "/dev/null" else { return }
        if let w = ProcessInfo.processInfo.environment["MDV_SNAPSHOT_WIDTH"].flatMap(Double.init) {
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
