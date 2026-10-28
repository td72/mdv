import AppKit

/// Read-only NSTextView with vim-style key handling. Mouse/trackpad scrolling
/// is untouched (NSScrollView handles it), as are Cmd-shortcuts (menu bar).
final class VimTextView: NSTextView {
    weak var commands: ViewerCommands?

    /// Readable column: the text container never exceeds this width and is centered.
    var maxContentWidth: CGFloat = 948
    var minInset = NSSize(width: 32, height: 28)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayoutColumn()
    }

    func relayoutColumn() {
        guard let container = textContainer else { return }
        let available = max(0, bounds.width - minInset.width * 2)
        let width = min(available, maxContentWidth)
        let inset = NSSize(width: ((bounds.width - width) / 2).rounded(.down), height: minInset.height)
        // Inset first (display only), then the width (invalidates layout) followed at once by a
        // full layout pass, so no display request ever finds layout holes to fill — that path is
        // quadratic in TextKit 1 and hangs on ~100k-paragraph documents.
        if textContainerInset != inset { textContainerInset = inset }
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layoutManager?.ensureLayout(for: container)
        }
    }

    private var keys = VimKeyMap()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = commands, keys.handle(event, c) else { return super.keyDown(with: event) }
    }

    // Do not let the find bar's Esc reach `cancelOperation` → beep
    override func cancelOperation(_ sender: Any?) {}
}
