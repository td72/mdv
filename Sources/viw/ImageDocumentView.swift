import AppKit
import ImageIO

/// `DocumentView` for images: an NSImageView in a scroll view, fitted to the width (never
/// enlarged), centered; `+` / `-` zoom, `=` refits, `h` / `l` / `j` / `k` scroll when larger
/// than the window. Animated GIF / WebP / APNG / HEICS play frame by frame from ImageIO so
/// that rotation and zoom apply to every frame; Space pauses, `n` / `N` step.
final class ImageDocumentView: NSObject, DocumentView {
    private let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let canvas = VimImageCanvas()
    private let imageView = NSImageView()
    private var original: NSImage?   // the current frame, unrotated
    private var image: NSImage?      // what is shown (rotated)
    private var scale: CGFloat = 1
    private var fit = true
    private var turns = 0 // quarter turns clockwise
    private let badge = StatusBadge(frame: .zero)

    // Animation: the ImageIO source stays open; frames are decoded as they come up and kept
    // while the whole sequence fits a memory budget.
    private var frames: CGImageSource?
    private var frameDelays: [TimeInterval] = []
    private var frameCache: [Int: NSImage] = [:]
    private var cacheFrames = false
    private var frameIndex = 0
    private var playing = false
    private var timer: Timer?
    private var frameCount: Int { frameDelays.count }
    private var animated: Bool { frameCount > 1 }

    var view: NSView { scrollView }
    var onOpenFile: ((URL) -> Void)?
    var onStatusChange: (() -> Void)?
    var commands: ViewerCommands? {
        get { canvas.commands }
        set { canvas.commands = newValue }
    }
    var status: String? {
        guard let image else { return nil }
        var s = "\(Int(image.size.width)) × \(Int(image.size.height)) · \(Int((scale * 100).rounded()))%"
        if animated { s += " · \(frameIndex + 1) / \(frameCount)" + (playing ? "" : " ⏸") }
        return s
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
        imageView.animates = false // frames are driven here, so rotation / zoom apply to them
        canvas.addSubview(imageView)
        canvas.onResize = { [weak self] in self?.relayout() } // also re-anchors the badge
        canvas.onWindowChange = { [weak self] visible in // a hidden tab or a closed window stops the timer
            guard let self else { return }
            if visible { if self.playing { self.scheduleNextFrame() } } else { self.timer?.invalidate(); self.timer = nil }
        }
        scrollView.documentView = canvas
    }

    deinit { timer?.invalidate() }

    func focus() { scrollView.window?.makeFirstResponder(canvas) }
    var helpSections: [KeyHelp.Section] { [KeyHelp.image] }

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        timer?.invalidate()
        timer = nil
        frames = nil
        frameDelays = []
        frameCache = [:]
        let keepFrame = preserveScroll ? frameIndex : 0
        frameIndex = 0
        guard let url = source.url, let img = NSImage(contentsOf: url) else { original = nil; image = nil; imageView.image = nil; return }
        original = img
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 1 {
            frames = src
            frameDelays = (0..<CGImageSourceGetCount(src)).map { Self.delay(of: src, at: $0) }
            // Keep decoded frames when the whole sequence is under ~256 MB.
            let bytes = Int(img.size.width * img.size.height) * 4 * frameCount
            cacheFrames = bytes <= 256 << 20
            frameIndex = min(keepFrame, frameCount - 1)
            original = frame(frameIndex)
            playing = true
        } else {
            playing = false
        }
        applyRotation()
        if playing { scheduleNextFrame() }
    }

    // MARK: - Animation

    /// Delay before the next frame, from whichever container dictionary the file has
    /// (GIF, PNG / APNG, WebP, HEICS). Browsers treat ≤ 10 ms as 100 ms; so does this.
    private static func delay(of src: CGImageSource, at i: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dict, unclamped, clamped) in containers {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            let v = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0.1
            return v <= 0.01 ? 0.1 : v
        }
        return 0.1
    }

    private func frame(_ i: Int) -> NSImage? {
        if let cached = frameCache[i] { return cached }
        guard let frames, let cg = CGImageSourceCreateImageAtIndex(frames, i, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if cacheFrames { frameCache[i] = img }
        return img
    }

    private func show(frame i: Int) {
        guard animated else { return }
        frameIndex = ((i % frameCount) + frameCount) % frameCount
        original = frame(frameIndex)
        applyRotation()
    }

    private func scheduleNextFrame() {
        timer?.invalidate()
        guard animated, playing, canvas.window != nil else { return }
        let t = Timer(timeInterval: frameDelays[frameIndex], repeats: false) { [weak self] _ in
            guard let self, self.playing else { return }
            self.show(frame: self.frameIndex + 1)
            self.scheduleNextFrame()
        }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Space.
    func togglePlayback() -> Bool {
        guard animated else { return false }
        playing.toggle()
        if playing { scheduleNextFrame() } else { timer?.invalidate(); timer = nil }
        badge.update(status ?? "", in: scrollView)
        onStatusChange?()
        return true
    }

    /// `n` / `N`: one frame on, one back; playing stops so the frame stays.
    func findNext(reverse: Bool) {
        guard animated else { return }
        playing = false
        timer?.invalidate()
        timer = nil
        show(frame: frameIndex + (reverse ? -1 : 1))
    }

    // MARK: - Rotation

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
    func copySelection() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        Toast.show(in: scrollView, animated ? "Copied frame \(frameIndex + 1)" : "Copied image")
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
    /// true when the canvas is in a window (its tab is showing), false when it leaves.
    var onWindowChange: ((Bool) -> Void)?
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }

    override func cancelOperation(_ sender: Any?) {}
}
