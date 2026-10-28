import AppKit

/// Actions a content view forwards to its owner (the document controller).
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
    func copySelection()
    func clearSelection()
    /// `.`: show / hide the detail pane (tables: the selected row in full).
    func toggleDetail()
    /// Enter / `i` (or `⌃w w` / `⌃w h/j/k/l`): move the keyboard focus between the main view and its pane.
    func switchPane()
    /// `I`: move the detail pane between the right side and the bottom.
    func togglePanePosition()
    func reload()
    func openFile()
    func closeWindow()
    func selectTab(offset: Int)
    func selectTab(index: Int)
    func zoom(_ delta: Int)
    func resetZoom()
}

/// vim-style key handling shared by the text view and the table view: counts (`5j`),
/// `gg` / `G` / `50G`, tabs (`gt`, `⌘1`…), scrolling, find, zoom. Mouse / trackpad scrolling
/// and ⌘ menu shortcuts are untouched.
struct VimKeyMap {
    private var count = 0
    private var pendingG = false
    private var pendingWindow = false // after ⌃w

    /// Returns false when the view's own `keyDown` should run (⌘ shortcuts for the menu bar).
    mutating func handle(_ event: NSEvent, _ c: ViewerCommands) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        let n = max(count, 1)
        let hasCount = count > 0
        defer { if !(chars.first?.isNumber ?? false) && chars != "g" { count = 0; pendingG = false } }

        if pendingWindow { // ⌃w + w / h / j / k / l / p: the only other window is the pane
            pendingWindow = false
            if ["w", "h", "j", "k", "l", "p"].contains(chars) { c.switchPane() }
            return true
        }

        if flags.contains(.command) {
            // ⌘1…⌘8 → nth tab, ⌘9 → last tab (browser convention); the rest is the menu bar's.
            if flags == .command, let d = Int(chars), 1...9 ~= d {
                c.selectTab(index: d == 9 ? .max : d - 1)
                return true
            }
            return false
        }

        if flags.contains(.control) {
            switch chars {
            case "e": c.scrollLines(n)
            case "y": c.scrollLines(-n)
            case "d": c.scrollHalfPages(n)
            case "u": c.scrollHalfPages(-n)
            case "f": c.scrollPages(n)
            case "b": c.scrollPages(-n)
            case "[": c.clearSelection() // like Esc
            case "w": pendingWindow = true
            default: break
            }
            return true
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
            case .carriageReturn, .enter: c.switchPane() // Enter: into the detail pane (Esc comes back)
            default: break
            }
            return true
        }

        switch chars {
        case "0"..."9":
            if chars == "0" && !hasCount { c.scrollHorizontal(-1_000_000) } // `0` → far left
            else { count = count * 10 + Int(chars)! }
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
        case "y": c.copySelection()
        case "i": c.switchPane()       // like Enter: into the detail pane
        case ".": c.toggleDetail()     // show / hide the detail pane
        case "I": c.togglePanePosition()
        case "r": c.reload()
        case "o": c.openFile()
        case "q": c.closeWindow()
        case "+", "=": chars == "=" && !flags.contains(.shift) ? c.resetZoom() : c.zoom(1)
        case "-": c.zoom(-1)
        case "\u{1B}": c.clearSelection() // Esc: clear pending count & selection
        default:
            break // swallow silently (no beep) — read-only views
        }
        return true
    }
}
