import AppKit

/// A short-lived pill ("Copied  Alice, Tokyo, …") for actions that otherwise show nothing,
/// such as `y`. Placed just under the thing that was acted on (`near`, in the container's
/// coordinates), or in the top-right corner when there is nothing to anchor to. One per
/// container; a new message replaces the one still showing.
final class Toast: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    static func show(in container: NSView, _ message: String, detail: String? = nil, near anchor: NSRect? = nil) {
        let toast = container.subviews.compactMap { $0 as? Toast }.first ?? {
            let t = Toast(frame: .zero)
            container.addSubview(t, positioned: .above, relativeTo: nil)
            return t
        }()
        toast.present(message, detail: detail, in: container, near: anchor)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.92).cgColor
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.usesSingleLineMode = true // never wrap a word out of sight below the pill
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func present(_ message: String, detail: String?, in container: NSView, near anchor: NSRect?) {
        let text = NSMutableAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        if let detail, !detail.isEmpty {
            let oneLine = detail.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\t", with: " · ")
            let clipped = oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
            text.append(NSAttributedString(string: "   " + clipped, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.8),
            ]))
        }
        label.attributedStringValue = text
        let b = container.bounds
        let width = min(b.width - 32, label.attributedStringValue.size().width + 36)
        let size = NSSize(width: max(80, width), height: 28)
        var origin: NSPoint
        if let a = anchor, a.intersects(b) {
            // Below the anchor, or above it when there is no room below (origin is bottom-left).
            let flipped = container.isFlipped
            let below = flipped ? a.maxY + 4 : a.minY - size.height - 4
            let above = flipped ? a.minY - size.height - 4 : a.maxY + 4
            let fits = flipped ? below + size.height <= b.maxY : below >= b.minY
            origin = NSPoint(x: a.minX, y: fits ? below : above)
        } else {
            origin = NSPoint(x: b.maxX - size.width - 16, y: container.isFlipped ? b.minY + 16 : b.maxY - size.height - 16)
        }
        origin.x = max(b.minX + 8, min(origin.x, b.maxX - size.width - 8))
        frame = NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
        autoresizingMask = []
        label.frame = bounds.insetBy(dx: 12, dy: 6)
        alphaValue = 1
        isHidden = false

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.alphaValue == 0 { self?.isHidden = true }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never swallow clicks
}
