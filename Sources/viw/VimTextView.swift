import AppKit

/// Actions the text view forwards to its owner (the window controller).
protocol ViewerCommands: AnyObject {
    func scrollLines(_ n: Int)
    func scrollHalfPages(_ n: Int)
    func scrollPages(_ n: Int)
    func scrollHorizontal(_ n: Int)
    func scrollToTop()
    func scrollToBottom()
    func scrollToPercent(_ percent: Int)
    func find()
    func findNext(reverse: Bool)
    func reload()
    func openFile()
    func closeWindow()
    func selectTab(offset: Int)
    func selectTab(index: Int)
    func zoom(_ delta: Int)
    func resetZoom()
}

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

    private var count = 0
    private var pendingG = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = commands else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        let n = max(count, 1)
        let hasCount = count > 0
        defer { if !(chars.first?.isNumber ?? false) && chars != "g" { count = 0; pendingG = false } }

        if flags.contains(.command) {
            // ⌘1…⌘8 → nth tab, ⌘9 → last tab (browser convention); the rest is the menu bar's.
            if flags == .command, let d = Int(chars), 1...9 ~= d {
                c.selectTab(index: d == 9 ? .max : d - 1)
                return
            }
            return super.keyDown(with: event)
        }

        if flags.contains(.control) {
            switch chars {
            case "e": c.scrollLines(n)
            case "y": c.scrollLines(-n)
            case "d": c.scrollHalfPages(n)
            case "u": c.scrollHalfPages(-n)
            case "f": c.scrollPages(n)
            case "b": c.scrollPages(-n)
            case "[": break // like Esc
            default: break
            }
            return
        }

        if let key = event.specialKey {
            switch key {
            case .downArrow: c.scrollLines(n)
            case .upArrow: c.scrollLines(-n)
            case .leftArrow: c.scrollHorizontal(-n)
            case .rightArrow: c.scrollHorizontal(n)
            case .pageDown: c.scrollPages(n)
            case .pageUp: c.scrollPages(-n)
            case .home: c.scrollToTop()
            case .end: c.scrollToBottom()
            case .tab: c.selectTab(offset: n) // Tab / Shift-Tab cycle through tabs
            case .backTab: c.selectTab(offset: -n)
            default: break
            }
            return
        }

        switch chars {
        case "0"..."9":
            if chars == "0" && !hasCount { c.scrollHorizontal(-1_000_000) } // `0` → far left
            else { count = count * 10 + Int(chars)!; }
            pendingG = false
        case "g":
            if pendingG { c.scrollToTop(); pendingG = false; count = 0 } else { pendingG = true }
        case "G":
            if hasCount { c.scrollToPercent(min(100, count)) } else { c.scrollToBottom() }
        case "t" where pendingG: // gt / 3gt
            if hasCount { c.selectTab(index: count - 1) } else { c.selectTab(offset: 1) }
        case "T" where pendingG: // gT
            c.selectTab(offset: -n)
        case "j": c.scrollLines(n)
        case "k": c.scrollLines(-n)
        case "h": c.scrollHorizontal(-n)
        case "l": c.scrollHorizontal(n)
        case "$": c.scrollHorizontal(1_000_000)
        case "d": c.scrollHalfPages(n)
        case "u": c.scrollHalfPages(-n)
        case " ": flags.contains(.shift) ? c.scrollPages(-n) : c.scrollPages(n)
        case "f": c.scrollPages(n)
        case "b": c.scrollPages(-n)
        case "/": c.find()
        case "n": c.findNext(reverse: false)
        case "N": c.findNext(reverse: true)
        case "y":
            if selectedRange().length > 0 { copy(nil) }
        case "r": c.reload()
        case "o": c.openFile()
        case "q": c.closeWindow()
        case "+", "=": chars == "=" && !flags.contains(.shift) ? c.resetZoom() : c.zoom(1)
        case "-": c.zoom(-1)
        case "\u{1B}": // Esc: clear state & selection
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        default:
            break // swallow silently (no beep) — read-only view
        }
    }

    // Do not let the find bar's Esc reach `cancelOperation` → beep
    override func cancelOperation(_ sender: Any?) {}
}
