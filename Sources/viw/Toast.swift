import AppKit

/// A short-lived pill at the bottom of a view ("Copied  Alice, Tokyo, …"), used for feedback
/// on actions that otherwise show nothing, such as `y`. One per container; a new message
/// replaces the one still showing.
final class Toast: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    static func show(in container: NSView, _ message: String, detail: String? = nil) {
        let toast = container.subviews.compactMap { $0 as? Toast }.first ?? {
            let t = Toast(frame: .zero)
            container.addSubview(t, positioned: .above, relativeTo: nil)
            return t
        }()
        toast.present(message, detail: detail, in: container)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.92).cgColor
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func present(_ message: String, detail: String?, in container: NSView) {
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
        let width = min(container.bounds.width - 32, label.attributedStringValue.size().width + 28)
        let size = NSSize(width: max(80, width), height: 28)
        frame = NSRect(x: ((container.bounds.width - size.width) / 2).rounded(), y: 20, width: size.width, height: size.height)
        autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
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
