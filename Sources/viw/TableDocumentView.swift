import AppKit

/// `DocumentView` for delimited data (CSV / TSV; xlsx later): an NSTableView with a fixed
/// header, a row-number column, auto-sized columns, vim row navigation, an incremental
/// search bar and TSV copy. Rows are drawn lazily, so 100k × 20 stays smooth.
final class TableDocumentView: NSObject, DocumentView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let split = NSSplitView()
    private let scrollView = NSScrollView()
    private let table = VimTableView()
    /// Bottom pane: the selected row as "column: value" lines, wrapped, selectable.
    private let detailScroll = NSScrollView()
    private let detail = VimTextView(usingTextLayoutManager: false)
    private var detailEnabled = true
    private var detailHeight: CGFloat = 180
    private let searchBar = NSView()
    private let searchField = NSSearchField()
    private let footer = NSTextField(labelWithString: "")
    private var data = TableData(header: [], rows: [], totalRows: 0)
    private var theme = Theme.load()
    private var font = NSFont.systemFont(ofSize: 14)
    private var digitFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    private var query = ""
    private var match: (row: Int, column: Int)?
    /// Where the user was when `/` opened the bar; Esc goes back there (vim's incsearch).
    private var searchOrigin: (row: Int, scroll: NSPoint)?

    static let searchBarHeight: CGFloat = 34
    static let footerHeight: CGFloat = 24
    private static let rowNumberID = NSUserInterfaceItemIdentifier("#")

    var view: NSView { root }
    var onOpenFile: ((URL) -> Void)?
    var commands: ViewerCommands? {
        get { table.commands }
        set { table.commands = newValue; detail.commands = newValue } // vim keys work in the pane too
    }

    override init() {
        super.init()
        buildViews()
    }

    func focus() { root.window?.makeFirstResponder(table) }

    // MARK: - Views

    private func buildViews() {
        root.autoresizingMask = [.width, .height]

        searchBar.autoresizingMask = [.width, .minYMargin]
        searchBar.wantsLayer = true
        searchField.placeholderString = "Find in table (Enter: next, Esc: back to table)"
        searchField.delegate = self
        // Typing is handled in controlTextDidChange (incremental); Enter / Esc in
        // control(_:textView:doCommandBy:). No target/action: NSSearchField would fire it
        // on every keystroke and the focus hand-off would swallow the rest of the query.
        searchBar.addSubview(searchField)
        searchBar.isHidden = true
        root.addSubview(searchBar)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.borderType = .noBorder
        detailScroll.drawsBackground = true
        detailScroll.backgroundColor = .controlBackgroundColor
        detail.isEditable = false
        detail.isSelectable = true
        detail.isRichText = true
        detail.drawsBackground = false
        detail.maxContentWidth = .greatestFiniteMagnitude // full width, not the reading column
        detail.minInset = NSSize(width: 12, height: 10)
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detail.textContainer?.lineFragmentPadding = 0
        detailScroll.documentView = detail
        detailScroll.isHidden = true

        split.isVertical = false // top / bottom
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        split.addArrangedSubview(scrollView)
        split.addArrangedSubview(detailScroll)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        root.addSubview(split)

        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = []
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 12, height: 2)
        table.headerView = NSTableHeaderView()
        scrollView.documentView = table

        footer.autoresizingMask = [.width, .maxYMargin]
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.isHidden = true
        root.addSubview(footer)
        layout()
    }

    private func layout() {
        let b = root.bounds
        let top: CGFloat = searchBar.isHidden ? 0 : Self.searchBarHeight
        let bottom: CGFloat = footer.isHidden ? 0 : Self.footerHeight
        searchBar.frame = NSRect(x: 0, y: b.height - top, width: b.width, height: top)
        searchField.frame = NSRect(x: 8, y: 6, width: b.width - 16, height: 22)
        searchField.autoresizingMask = [.width]
        split.frame = NSRect(x: 0, y: bottom, width: b.width, height: b.height - top - bottom)
        footer.frame = NSRect(x: 0, y: 4, width: b.width, height: 16)
        if !detailScroll.isHidden {
            detail.frame.size.width = detailScroll.contentSize.width
            split.setPosition(max(80, split.bounds.height - detailHeight), ofDividerAt: 0)
        }
    }

    // MARK: - Loading

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        self.theme = theme
        let size = (theme.baseSize * 0.875).rounded()
        font = .systemFont(ofSize: size)
        digitFont = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        table.rowHeight = (size * 1.6).rounded()
        footer.font = .systemFont(ofSize: max(10, size - 2))

        let savedRow = table.selectedRow
        let savedOrigin = scrollView.contentView.bounds.origin
        switch source {
        case .file(let url):
            guard let bytes = FileManager.default.contents(atPath: url.path) else {
                data = TableData(header: ["Cannot read \(url.path)"], rows: [], totalRows: 0)
                break
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            data = CSV.table(from: bytes, url: url)
            if ProcessInfo.processInfo.environment["VIW_TIMING"] != nil {
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                FileHandle.standardError.write("csv parse: \(ms) ms (\(data.rows.count) rows × \(data.columnCount) cols)\n".data(using: .utf8)!)
            }
        case .text(let s, _):
            data = CSV.table(from: Data(s.utf8), url: URL(fileURLWithPath: "stdin.csv"))
        }
        match = nil
        rebuildColumns()
        table.reloadData()
        if data.truncated {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            footer.stringValue = "Showing the first \(f.string(from: data.rows.count as NSNumber)!) of \(f.string(from: (data.totalRows - 1) as NSNumber)!) rows — the rest is cut off to keep the viewer responsive."
        }
        footer.isHidden = !data.truncated
        layout()
        if preserveScroll {
            if savedRow >= 0, savedRow < data.rows.count { select(row: savedRow, scroll: false) }
            scrollView.contentView.scroll(to: savedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// One NSTableColumn per data column plus the row-number column; widths from the header
    /// and a sample of rows, clamped so one long cell cannot take the whole window.
    private func rebuildColumns() {
        for c in table.tableColumns { table.removeTableColumn(c) }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }

        let numbers = NSTableColumn(identifier: Self.rowNumberID)
        numbers.title = ""
        numbers.width = width(String(data.rows.count)) + 16
        numbers.resizingMask = []
        table.addTableColumn(numbers)

        let sample = data.rows.prefix(200)
        for (i, name) in data.header.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
            col.title = name
            var w = width(name) + 8
            for row in sample where i < row.count { w = max(w, width(row[i])) }
            col.width = min(max(w + 12, 48), 480)
            col.minWidth = 32
            table.addTableColumn(col)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { data.rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }

    // MARK: - Detail pane

    /// Shown while a row is selected (and `i` has not hidden it): every column of the row in
    /// full, so long or multi-line cells that the grid truncates can be read and copied.
    private func updateDetail() {
        let row = table.selectedRow
        let show = detailEnabled && row >= 0 && row < data.rows.count
        if show {
            if !detailScroll.isHidden { detailHeight = detailScroll.frame.height } // keep the user's drag
            let text = NSMutableAttributedString()
            let keyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: font.pointSize), .foregroundColor: NSColor.secondaryLabelColor]
            let valueAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = font.pointSize * 0.4
            style.headIndent = 0
            for (i, name) in data.header.enumerated() {
                let value = i < data.rows[row].count ? data.rows[row][i] : ""
                let line = NSMutableAttributedString(string: name.isEmpty ? "(column \(i + 1))" : name, attributes: keyAttrs)
                line.append(NSAttributedString(string: "  ", attributes: keyAttrs))
                line.append(NSAttributedString(string: value + "\n", attributes: valueAttrs))
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                text.append(line)
            }
            detail.textStorage?.setAttributedString(text)
        }
        if detailScroll.isHidden == show {
            detailScroll.isHidden = !show
            split.adjustSubviews()
            layout()
        }
        if show { // always start at the first column, whatever the pane was scrolled to
            detailScroll.contentView.scroll(to: .zero)
            detailScroll.reflectScrolledClipView(detailScroll.contentView)
        }
    }

    func toggleDetail() {
        detailEnabled.toggle()
        if table.selectedRow < 0, detailEnabled { select(row: 0) } // `i` with nothing selected: start at the top
        updateDetail()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.cell?.truncatesLastVisibleLine = true
            tf.autoresizingMask = [.width, .height]
            tf.frame = cell.bounds
            cell.addSubview(tf)
            cell.textField = tf
        }
        guard let tf = cell.textField else { return cell }
        if tableColumn.identifier == Self.rowNumberID {
            tf.stringValue = String(row + 1)
            tf.font = digitFont
            tf.textColor = .tertiaryLabelColor
            tf.alignment = .right
            tf.drawsBackground = false
            return cell
        }
        let col = Int(tableColumn.identifier.rawValue) ?? 0
        let value = col < data.rows[row].count ? data.rows[row][col] : ""
        let numeric = Double(value) != nil
        tf.stringValue = value
        tf.toolTip = value.contains("\n") || value.count > 40 ? value : nil // the full text of a truncated cell
        tf.font = numeric ? digitFont : font
        tf.alignment = numeric ? .right : .left
        tf.textColor = .labelColor
        if let m = match, m.row == row, m.column == col {
            tf.drawsBackground = true
            tf.backgroundColor = .findHighlightColor
            tf.textColor = .black
        } else {
            tf.drawsBackground = false
        }
        return cell
    }

    // MARK: - Navigation (vim)

    private var visibleRows: Int {
        max(1, Int(scrollView.contentView.bounds.height / (table.rowHeight + table.intercellSpacing.height)))
    }

    private func select(row: Int, scroll: Bool = true) {
        guard !data.rows.isEmpty else { return }
        let r = max(0, min(row, data.rows.count - 1))
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(r) }
    }

    private func move(by n: Int) {
        select(row: table.selectedRow < 0 ? (n > 0 ? n - 1 : 0) : table.selectedRow + n)
    }

    func scrollLines(_ n: Int) { move(by: n) }
    func scrollHalfPages(_ n: Int) { move(by: n * max(1, visibleRows / 2)) }
    func scrollPages(_ n: Int) { move(by: n * max(1, visibleRows - 1)) }
    func scrollToTop() { select(row: 0) }
    func scrollToBottom() { select(row: data.rows.count - 1) }
    func scrollToPercent(_ percent: Int) { select(row: (data.rows.count - 1) * percent / 100) }

    func scrollHorizontal(_ n: Int) {
        let clip = scrollView.contentView
        let maxX = max(0, table.frame.width - clip.bounds.width)
        var o = clip.bounds.origin
        o.x = min(max(0, o.x + CGFloat(n) * 160), maxX)
        clip.scroll(to: o)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Find

    func find() {
        searchOrigin = (table.selectedRow, scrollView.contentView.bounds.origin)
        searchBar.isHidden = false
        layout()
        root.window?.makeFirstResponder(searchField)
    }

    private func hideSearch() {
        searchBar.isHidden = true
        layout()
        focus()
    }

    /// Row-wise search: the next row after `row` (or `row` itself with `includeStart`) with a
    /// cell containing `query`, case-insensitive, wrapping around; the first matching cell is
    /// highlighted. Row-wise so that `n` always moves to a new row.
    private func search(fromRow row: Int, reverse: Bool, includeStart: Bool) -> Bool {
        guard !query.isEmpty, !data.rows.isEmpty else { return false }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            if ProcessInfo.processInfo.environment["VIW_TIMING"] != nil {
                FileHandle.standardError.write("table search: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms\n".data(using: .utf8)!)
            }
        }
        let n = data.rows.count
        let needle = Array(query.lowercased().utf8)
        var r = max(0, min(row, n - 1))
        if !includeStart { r += reverse ? -1 : 1 }
        for _ in 0..<n {
            if r < 0 { r = n - 1 }
            if r >= n { r = 0 }
            if let c = data.rows[r].firstIndex(where: { Self.contains($0, needle) }) {
                show(match: (r, c))
                return true
            }
            r += reverse ? -1 : 1
        }
        NSSound.beep()
        return false
    }

    /// Byte-level substring test, ASCII case-insensitive (`needle` is already lowercased).
    /// Foundation's `range(of:options:)` costs ~0.5 µs per cell through bridging, which is a
    /// second per keystroke on 2M cells; this is ~20× faster. Non-ASCII letters match exactly.
    private static func contains(_ cell: String, _ needle: [UInt8]) -> Bool {
        let m = needle.count
        guard m > 0 else { return true }
        var cell = cell
        return cell.withUTF8 { hay -> Bool in
            let n = hay.count
            guard n >= m else { return false }
            let first = needle[0]
            var i = 0
            while i <= n - m {
                var b = hay[i]
                if b >= 65 && b <= 90 { b += 32 }
                if b == first {
                    var j = 1
                    while j < m {
                        var h = hay[i + j]
                        if h >= 65 && h <= 90 { h += 32 }
                        if h != needle[j] { break }
                        j += 1
                    }
                    if j == m { return true }
                }
                i += 1
            }
            return false
        }
    }

    private func show(match m: (row: Int, column: Int)) {
        let old = match
        match = m
        var rows = IndexSet(integer: m.row)
        if let old { rows.insert(old.row) }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        select(row: m.row)
        table.scrollColumnToVisible(m.column + 1) // +1: the row-number column
    }

    func findNext(reverse: Bool) {
        if query.isEmpty { find(); return }
        _ = search(fromRow: match?.row ?? table.selectedRow, reverse: reverse, includeStart: false)
    }

    // Incremental: every edit searches again from where `/` was pressed, like vim's incsearch.
    func controlTextDidChange(_ obj: Notification) {
        query = searchField.stringValue
        if !query.isEmpty { _ = search(fromRow: searchOrigin?.row ?? 0, reverse: false, includeStart: true) }
    }

    /// Enter: keep the match and hand the keyboard back to the table (n / N continue).
    private func searchEntered() {
        query = searchField.stringValue
        if query.isEmpty { cancelSearch(); return }
        if match == nil { _ = search(fromRow: searchOrigin?.row ?? 0, reverse: false, includeStart: true) }
        hideSearch()
    }

    /// Esc in the bar: back to where the search started, highlight gone.
    private func cancelSearch() {
        if let m = match {
            match = nil
            table.reloadData(forRowIndexes: IndexSet(integer: m.row), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        if let o = searchOrigin {
            if o.row >= 0 { select(row: o.row, scroll: false) } else { table.deselectAll(nil) }
            scrollView.contentView.scroll(to: o.scroll)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        hideSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): cancelSearch(); return true
        case #selector(NSResponder.insertNewline(_:)): searchEntered(); return true
        default: return false
        }
    }

    // MARK: - Selection

    /// `y` / ⌘C: text selected in the detail pane if there is any, else the selected row as a
    /// tab-separated line.
    func copySelection() {
        if root.window?.firstResponder === detail, detail.selectedRange().length > 0 {
            detail.copy(nil)
            return
        }
        guard table.selectedRow >= 0 else { return }
        let line = data.rows[table.selectedRow].joined(separator: "\t")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    /// Esc: drop the row selection (which closes the pane) and the search highlight.
    func clearSelection() {
        table.deselectAll(nil)
        focus()
        if let m = match {
            match = nil
            table.reloadData(forRowIndexes: IndexSet(integer: m.row), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        if !searchBar.isHidden { hideSearch() }
    }

    // MARK: - Debug snapshot (the visible grid at the current size)

    func snapshot(to path: String) {
        guard path != "/dev/null" else { return }
        if let w = ProcessInfo.processInfo.environment["VIW_SNAPSHOT_WIDTH"].flatMap(Double.init) {
            root.setFrameSize(NSSize(width: CGFloat(w), height: root.frame.height))
            layout()
        }
        if let r = ProcessInfo.processInfo.environment["VIW_SNAPSHOT_ROW"].flatMap(Int.init) { select(row: r) } // show the pane in snapshots
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// NSTableView that routes keys through the vim key map (same as VimTextView).
final class VimTableView: NSTableView {
    weak var commands: ViewerCommands?
    private var keys = VimKeyMap()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = commands, keys.handle(event, c) else { return super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {} // no beep on Esc

    /// Edit › Copy / ⌘C while the grid has focus.
    @objc func copy(_ sender: Any?) { commands?.copySelection() }
}
