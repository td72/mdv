import AppKit

/// `DocumentView` for images: an NSImageView in a scroll view, fitted to the width (never
/// enlarged), centered; `+` / `-` zoom, `=` refits, `h` / `l` / `j` / `k` scroll when larger
/// than the window.
final class ImageDocumentView: NSObject, DocumentView {
    private let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let canvas = VimImageCanvas()
    private let imageView = NSImageView()
    private var original: NSImage?
    private var image: NSImage?
    private var scale: CGFloat = 1
    private var fit = true
    private var turns = 0 // quarter turns clockwise
    private let badge = StatusBadge(frame: .zero)

    var view: NSView { scrollView }
    var onOpenFile: ((URL) -> Void)?
    var onStatusChange: (() -> Void)?
    var commands: ViewerCommands? {
        get { canvas.commands }
        set { canvas.commands = newValue }
    }
    var status: String? {
        guard let image else { return nil }
        return "\(Int(image.size.width)) × \(Int(image.size.height)) · \(Int((scale * 100).rounded()))%"
    }

    override init() {
        super.init()
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        canvas.addSubview(imageView)
        canvas.onResize = { [weak self] in self?.relayout() } // also re-anchors the badge
        scrollView.documentView = canvas
    }

    func focus() { scrollView.window?.makeFirstResponder(canvas) }

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        guard let url = source.url, let img = NSImage(contentsOf: url) else { original = nil; image = nil; imageView.image = nil; return }
        original = img
        applyRotation()
    }

    /// `r` / `R`.
    func rotate(_ quarterTurns: Int) -> Bool {
        guard original != nil else { return false }
        turns = ((turns + quarterTurns) % 4 + 4) % 4
        applyRotation()
        return true
    }

    private func applyRotation() {
        guard let original else { return }
        if turns == 0 {
            image = original
        } else {
            let s = original.size
            let swapped = turns % 2 == 1
            let out = NSImage(size: swapped ? NSSize(width: s.height, height: s.width) : s)
            out.lockFocus()
            let t = NSAffineTransform()
            t.translateX(by: out.size.width / 2, yBy: out.size.height / 2)
            t.rotate(byDegrees: CGFloat(-90 * turns))
            t.translateX(by: -s.width / 2, yBy: -s.height / 2)
            t.concat()
            original.draw(in: NSRect(origin: .zero, size: s))
            out.unlockFocus()
            image = out
        }
        imageView.image = image
        relayout()
        onStatusChange?()
    }

    /// Size the canvas to the clip view (or the scaled image, if larger) and center the image.
    private func relayout() {
        guard let image else { return }
        let clipSize = scrollView.contentSize
        if fit { scale = min(1, clipSize.width / max(1, image.size.width)) }
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        canvas.setFrameSize(NSSize(width: max(size.width, clipSize.width), height: max(size.height, clipSize.height)))
        imageView.frame = NSRect(x: ((canvas.frame.width - size.width) / 2).rounded(), y: ((canvas.frame.height - size.height) / 2).rounded(),
                                 width: size.width, height: size.height)
        badge.update(status ?? "", in: scrollView)
        onStatusChange?()
    }

    // MARK: - Scrolling

    private var clip: NSClipView { scrollView.contentView }
    private func scroll(dx: CGFloat, dy: CGFloat) {
        var o = clip.bounds.origin
        o.x = min(max(0, o.x + dx), max(0, canvas.frame.width - clip.bounds.width))
        o.y = min(max(0, o.y + dy), max(0, canvas.frame.height - clip.bounds.height))
        clip.scroll(to: o)
        scrollView.reflectScrolledClipView(clip)
    }
    func scrollLines(_ n: Int) { scroll(dx: 0, dy: CGFloat(n) * 48) }
    func scrollHalfPages(_ n: Int) { scroll(dx: 0, dy: CGFloat(n) * clip.bounds.height / 2) }
    func scrollPages(_ n: Int) { scroll(dx: 0, dy: CGFloat(n) * clip.bounds.height) }
    func scrollHorizontal(_ n: Int) { scroll(dx: CGFloat(n) * 48, dy: 0) }
    func scrollToTop() { scroll(dx: 0, dy: -1_000_000) }
    func scrollToBottom() { scroll(dx: 0, dy: 1_000_000) }
    func scrollToPercent(_ percent: Int) {
        let maxY = max(0, canvas.frame.height - clip.bounds.height)
        scroll(dx: 0, dy: maxY * CGFloat(percent) / 100 - clip.bounds.origin.y)
    }

    func find() {}
    func filter() {}
    func findNext(reverse: Bool) {}
    func copySelection() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        Toast.show(in: scrollView, "Copied image")
    }
    func copyRow() { copySelection() }
    func clearSelection() {}
    func toggleDetail() {}
    func switchPane() {}
    func sortRows() {}
    func unsortRows() {}

    func zoomView(_ delta: Int) -> Bool {
        fit = false
        scale = max(0.05, min(20, scale * (delta > 0 ? 1.25 : 0.8)))
        relayout()
        return true
    }
    func resetZoomView() -> Bool {
        fit = true
        relayout()
        return true
    }

    func snapshot(to path: String) {
        guard path != "/dev/null", let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// Flipped canvas (so the image hangs from the top) that takes the vim keys.
final class VimImageCanvas: NSView {
    weak var commands: ViewerCommands?
    var onResize: (() -> Void)?
    private var keys = VimKeyMap()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = commands, keys.handle(event, c) else { return super.keyDown(with: event) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        if let clip = enclosingScrollView?.contentView {
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.onResize?() }
        }
    }

    override func cancelOperation(_ sender: Any?) {}
}
