import AppKit

/// `DocumentView` for delimited data (CSV / TSV; xlsx later): an NSTableView with a fixed
/// header, a row-number column, auto-sized columns, vim row navigation, an incremental
/// search bar and TSV copy. Rows are drawn lazily, so 100k × 20 stays smooth.
final class TableDocumentView: NSObject, DocumentView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSSplitViewDelegate {
    private let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let split = NSSplitView()
    private let scrollView = NSScrollView()
    private let table = VimTableView()
    /// Detail pane: a title ("Row 3 / 6"), then the selected row as "column  value" lines, wrapped, selectable.
    private let pane = NSBox()
    private let paneTitle = NSTextField(labelWithString: "")
    private let paneRule = NSBox()
    private let detailScroll = NSScrollView()
    private let detail = VimTextView(usingTextLayoutManager: false)
    private var detailEnabled = true
    private var detailSize: CGFloat = 320 // pane width (right) or height (bottom)
    private var paneCommands: PaneCommands?
    /// One entry per column: the "name  value" line's range in the pane text, and the value's range.
    private var fieldRanges: [(line: NSRange, value: NSRange)] = []
    /// Field cursor in the pane (`j` / `k`); drawn only while the pane has the keyboard.
    private var fieldIndex = 0
    private var paneFocused = false
    private let searchBar = NSView()
    private let searchField = NSSearchField()
    private let footer = NSTextField(labelWithString: "")
    private var data = TableData(header: [], rows: [], totalRows: 0)
    private var theme = Theme.load()
    private var font = NSFont.systemFont(ofSize: 14)
    private var digitFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    private var query = ""
    private var match: (row: Int, column: Int)?
    /// Visible → original row indices while a filter or a sort is active (nil: file order, all rows).
    private var filtered: [Int]?
    private var filterQuery = ""
    private var sortColumn: Int?
    private var sortAscending = true
    private enum BarMode { case find, filter }
    private var barMode = BarMode.find
    private let barLabel = NSTextField(labelWithString: "FIND")
    /// Where the user was when `/` opened the bar; Esc goes back there (vim's incsearch).
    private var searchOrigin: (row: Int, scroll: NSPoint)?

    static let searchBarHeight: CGFloat = 34
    static let footerHeight: CGFloat = 24
    private static let rowNumberID = NSUserInterfaceItemIdentifier("#")

    var view: NSView { root }
    var onOpenFile: ((URL) -> Void)?
    var commands: ViewerCommands? {
        get { table.commands }
        set {
            table.commands = newValue
            // In the pane, j / k etc. scroll the pane itself; everything else goes to the controller.
            paneCommands = newValue.map { PaneCommands(view: self, scrollView: detailScroll, lineHeight: table.rowHeight, forward: $0) }
            detail.commands = paneCommands
        }
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
        barLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        barLabel.textColor = .secondaryLabelColor
        barLabel.alignment = .right
        searchBar.addSubview(barLabel)
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
        detail.isEditable = false
        detail.isSelectable = true
        detail.isRichText = true
        detail.drawsBackground = false
        detail.maxContentWidth = .greatestFiniteMagnitude // full width, not the reading column
        detail.minInset = NSSize(width: 14, height: 14)
        detail.onFocusChange = { [weak self] focused in // title lights up, field cursor appears
            guard let self else { return }
            self.paneFocused = focused
            self.paneTitle.textColor = focused ? .controlAccentColor : .secondaryLabelColor
            self.drawFieldCursor()
        }
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detail.textContainer?.lineFragmentPadding = 0
        detailScroll.documentView = detail

        paneTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        paneTitle.textColor = .secondaryLabelColor
        paneRule.boxType = .separator
        pane.boxType = .custom
        pane.borderWidth = 0
        pane.cornerRadius = 0
        pane.contentViewMargins = .zero
        pane.fillColor = .controlBackgroundColor
        detailScroll.drawsBackground = false
        pane.contentView?.addSubview(paneTitle)
        pane.contentView?.addSubview(paneRule)
        pane.contentView?.addSubview(detailScroll)
        pane.isHidden = true

        split.isVertical = true // grid | pane; `detail_pane = "bottom"` in the config stacks them
        split.delegate = self
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        split.addArrangedSubview(scrollView)
        split.addArrangedSubview(pane)
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
        barLabel.frame = NSRect(x: 8, y: 9, width: 48, height: 16)
        searchField.frame = NSRect(x: 64, y: 6, width: b.width - 72, height: 22)
        searchField.autoresizingMask = [.width]
        split.frame = NSRect(x: 0, y: bottom, width: b.width, height: b.height - top - bottom)
        footer.frame = NSRect(x: 0, y: 4, width: b.width, height: 16)
        if !pane.isHidden {
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            split.setPosition(max(total * 0.3, total - detailSize), ofDividerAt: 0)
            layoutPane()
        }
    }

    private static let paneTitleHeight: CGFloat = 30

    private func layoutPane() {
        let b = pane.bounds
        paneTitle.frame = NSRect(x: 14, y: b.height - Self.paneTitleHeight + 8, width: b.width - 28, height: 16)
        paneRule.frame = NSRect(x: 0, y: b.height - Self.paneTitleHeight, width: b.width, height: 1)
        detailScroll.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - Self.paneTitleHeight)
        detail.frame.size.width = detailScroll.contentSize.width
    }

    // MARK: - Loading

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        self.theme = theme
        let size = (theme.baseSize * 0.875).rounded()
        font = .systemFont(ofSize: size)
        digitFont = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        table.rowHeight = (size * 1.6).rounded()
        footer.font = .systemFont(ofSize: max(10, size - 2))
        paneCommands?.lineHeight = table.rowHeight
        if split.isVertical != theme.detailPaneOnRight {
            split.isVertical = theme.detailPaneOnRight
            detailSize = theme.detailPaneOnRight ? 320 : 180
            split.adjustSubviews()
        }

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
        if let c = sortColumn, c >= data.columnCount { sortColumn = nil }
        rebuildVisible()
        table.reloadData()
        updateFooter()
        if preserveScroll {
            if savedRow >= 0, savedRow < rowCount { select(row: savedRow, scroll: false) }
            scrollView.contentView.scroll(to: savedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func updateFooter() {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        var parts: [String] = []
        if !filterQuery.isEmpty, let filtered {
            parts.append("Filter “\(filterQuery)”: \(f.string(from: filtered.count as NSNumber)!) of \(f.string(from: data.rows.count as NSNumber)!) rows (Esc clears)")
        }
        if let c = sortColumn, c < data.header.count {
            parts.append("sorted by \(data.header[c].isEmpty ? "column \(c + 1)" : data.header[c]) \(sortAscending ? "↑" : "↓") (S restores file order)")
        }
        if data.truncated {
            parts.append("showing the first \(f.string(from: data.rows.count as NSNumber)!) of \(f.string(from: (data.totalRows - 1) as NSNumber)!) rows")
        }
        footer.stringValue = parts.joined(separator: " · ")
        footer.isHidden = parts.isEmpty
        layout()
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

    /// Rows currently shown; `original` maps a visible index back into `data.rows`.
    private var rowCount: Int { filtered?.count ?? data.rows.count }
    private func original(_ visible: Int) -> Int { filtered?[visible] ?? visible }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }

    func splitViewDidResizeSubviews(_ notification: Notification) { layoutPane() }

    // MARK: - Detail pane

    /// Shown while a row is selected (and `i` has not hidden it): every column of the row in
    /// full, so long or multi-line cells that the grid truncates can be read and copied.
    private func updateDetail() {
        let row = table.selectedRow
        let show = detailEnabled && row >= 0 && row < rowCount
        if show {
            if !pane.isHidden { // keep the size the user dragged to
                detailSize = split.isVertical ? pane.frame.width : pane.frame.height
            }
            let f = NumberFormatter()
            f.numberStyle = .decimal
            paneTitle.stringValue = "ROW \(f.string(from: (original(row) + 1) as NSNumber)!) / \(f.string(from: data.rows.count as NSNumber)!)"
            let text = NSMutableAttributedString()
            let keyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: font.pointSize), .foregroundColor: NSColor.secondaryLabelColor]
            let valueAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = font.pointSize * 0.4
            style.headIndent = 0
            fieldRanges = []
            for (i, name) in data.header.enumerated() {
                let record = data.rows[original(row)]
                let value = i < record.count ? record[i] : ""
                let line = NSMutableAttributedString(string: name.isEmpty ? "(column \(i + 1))" : name, attributes: keyAttrs)
                line.append(NSAttributedString(string: "  ", attributes: keyAttrs))
                let valueStart = line.length
                line.append(NSAttributedString(string: value + "\n", attributes: valueAttrs))
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                fieldRanges.append((NSRange(location: text.length, length: line.length),
                                    NSRange(location: text.length + valueStart, length: (value as NSString).length)))
                text.append(line)
            }
            detail.textStorage?.setAttributedString(text)
            fieldIndex = min(fieldIndex, max(0, fieldRanges.count - 1))
            drawFieldCursor()
        }
        if pane.isHidden == show {
            pane.isHidden = !show
            split.adjustSubviews()
            layout()
        }
        if show { // always start at the first column, whatever the pane was scrolled to
            detailScroll.contentView.scroll(to: .zero)
            detailScroll.reflectScrolledClipView(detailScroll.contentView)
        }
    }

    // MARK: Field cursor (keyboard in the pane)

    /// Highlight the current field's line while the pane has focus; `scroll` keeps it visible.
    private func drawFieldCursor(scroll: Bool = false) {
        guard let storage = detail.textStorage else { return }
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        if paneFocused, fieldRanges.indices.contains(fieldIndex) {
            storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.2), range: fieldRanges[fieldIndex].line)
        }
        storage.endEditing()
        if scroll, fieldRanges.indices.contains(fieldIndex) { detail.scrollRangeToVisible(fieldRanges[fieldIndex].line) }
    }

    /// `j` / `k` in the pane.
    func moveField(by n: Int) { setField(fieldIndex + n) }

    /// `gg` / `G` / `50G` in the pane.
    func setField(_ i: Int) {
        guard !fieldRanges.isEmpty else { return }
        fieldIndex = max(0, min(i, fieldRanges.count - 1))
        drawFieldCursor(scroll: true)
    }

    var fieldCount: Int { fieldRanges.count }
    var fieldIndexValue: Int { fieldIndex }

    func toggleDetail() {
        detailEnabled.toggle()
        if table.selectedRow < 0, detailEnabled { select(row: 0) } // `.` with nothing selected: start at the top
        updateDetail()
        if !detailEnabled { focus() }
    }

    /// Enter / i / ⌃w w: grid ⇄ pane (opening the pane on the first row if nothing is selected).
    func switchPane() {
        if root.window?.firstResponder === detail {
            focus()
        } else {
            if table.selectedRow < 0 { select(row: 0) }
            if !detailEnabled { detailEnabled = true; updateDetail() }
            fieldIndex = 0 // entering from the grid always starts at the first field
            root.window?.makeFirstResponder(detail)
        }
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
            tf.stringValue = String(original(row) + 1) // the file's row number, filter or not
            tf.font = digitFont
            tf.textColor = .tertiaryLabelColor
            tf.alignment = .right
            tf.drawsBackground = false
            return cell
        }
        let col = Int(tableColumn.identifier.rawValue) ?? 0
        let record = data.rows[original(row)]
        let value = col < record.count ? record[col] : ""
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
        guard rowCount > 0 else { return }
        let r = max(0, min(row, rowCount - 1))
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
    func scrollToBottom() { select(row: rowCount - 1) }
    func scrollToPercent(_ percent: Int) { select(row: (rowCount - 1) * percent / 100) }

    func scrollHorizontal(_ n: Int) {
        let clip = scrollView.contentView
        let maxX = max(0, table.frame.width - clip.bounds.width)
        var o = clip.bounds.origin
        o.x = min(max(0, o.x + CGFloat(n) * 160), maxX)
        clip.scroll(to: o)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Find

    func find() { openBar(.find) }

    /// `F`: only rows with a cell containing the text stay visible (incremental); Enter keeps
    /// the filter, Esc (here or later in the grid) shows all rows again.
    func filter() { openBar(.filter) }

    private func openBar(_ mode: BarMode) {
        barMode = mode
        switch mode {
        case .find:
            searchOrigin = (table.selectedRow, scrollView.contentView.bounds.origin)
            barLabel.stringValue = "FIND"
            searchField.placeholderString = "Find in table (Enter: keep, Esc: back)"
            searchField.stringValue = query
        case .filter:
            barLabel.stringValue = "FILTER"
            searchField.placeholderString = "Show only rows containing… (Enter: keep, Esc: clear)"
            searchField.stringValue = filterQuery
        }
        searchBar.isHidden = false
        layout()
        root.window?.makeFirstResponder(searchField)
    }

    /// Original indices of the rows with any cell containing `text` (ASCII case-insensitive).
    private static func rows(matching text: String, in data: TableData) -> [Int] {
        let needle = Array(text.lowercased().utf8)
        return data.rows.indices.filter { r in data.rows[r].contains { contains($0, needle) } }
    }

    private func applyFilter(_ text: String) {
        filterQuery = text
        reorder()
    }

    /// Recompute the visible rows (sort order, then filter) and keep the selected record if it
    /// is still visible.
    private func reorder() {
        let keep = table.selectedRow >= 0 ? original(table.selectedRow) : -1
        rebuildVisible()
        match = nil
        table.reloadData()
        updateFooter()
        if keep >= 0, let v = filtered?.firstIndex(of: keep) ?? (filtered == nil ? keep : nil) {
            select(row: v, scroll: true)
        } else if rowCount > 0 {
            select(row: 0, scroll: true)
        } else {
            updateDetail()
        }
    }

    private func rebuildVisible() {
        var base: [Int]? = sortColumn.map { Self.order(by: $0, ascending: sortAscending, in: data) }
        if !filterQuery.isEmpty {
            let needle = Array(filterQuery.lowercased().utf8)
            base = (base ?? Array(data.rows.indices)).filter { r in data.rows[r].contains { Self.contains($0, needle) } }
        }
        filtered = base
    }

    // MARK: - Sort

    /// Original row indices sorted by `column`: numerically when every non-empty cell parses as
    /// a number, otherwise as case-insensitive text; empty cells go last either way.
    private static func order(by column: Int, ascending: Bool, in data: TableData) -> [Int] {
        let cells = data.rows.map { column < $0.count ? $0[column] : "" }
        let numbers = cells.map { $0.isEmpty ? nil : Double($0) }
        let numeric = zip(cells, numbers).allSatisfy { $0.isEmpty || $1 != nil }
        var idx = Array(data.rows.indices)
        if numeric {
            idx.sort { a, b in
                switch (numbers[a], numbers[b]) {
                case let (x?, y?): return ascending ? x < y : x > y
                case (nil, nil): return a < b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        } else {
            let keys = cells.map { $0.lowercased() }
            idx.sort { a, b in
                if keys[a].isEmpty != keys[b].isEmpty { return keys[b].isEmpty }
                let c = keys[a].compare(keys[b])
                if c == .orderedSame { return a < b }
                return ascending ? c == .orderedAscending : c == .orderedDescending
            }
        }
        return idx
    }

    /// Sort by `column`; the same column again flips the direction. `nil` restores file order.
    func sort(by column: Int?) {
        if let column {
            if sortColumn == column { sortAscending.toggle() } else { sortColumn = column; sortAscending = true }
        } else {
            sortColumn = nil
            sortAscending = true
        }
        for c in table.tableColumns { table.setIndicatorImage(nil, in: c) }
        table.highlightedTableColumn = nil
        if let c = sortColumn, c + 1 < table.tableColumns.count {
            let col = table.tableColumns[c + 1] // +1: the row-number column
            table.setIndicatorImage(NSImage(named: sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"), in: col)
            table.highlightedTableColumn = col
        }
        reorder()
    }

    /// `s` in the grid: flip the current sort, or sort by the first column; `S`: file order.
    func sortRows() { sort(by: sortColumn ?? 0) }
    func unsortRows() { if sortColumn != nil { sort(by: nil) } }
    var currentSortColumn: Int? { sortColumn }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard tableColumn.identifier != Self.rowNumberID, let c = Int(tableColumn.identifier.rawValue) else { return }
        sort(by: c)
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
        guard !query.isEmpty, rowCount > 0 else { return false }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            if ProcessInfo.processInfo.environment["VIW_TIMING"] != nil {
                FileHandle.standardError.write("table search: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms\n".data(using: .utf8)!)
            }
        }
        let n = rowCount
        let needle = Array(query.lowercased().utf8)
        var r = max(0, min(row, n - 1))
        if !includeStart { r += reverse ? -1 : 1 }
        for _ in 0..<n {
            if r < 0 { r = n - 1 }
            if r >= n { r = 0 }
            if let c = data.rows[original(r)].firstIndex(where: { Self.contains($0, needle) }) {
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

    // Incremental: every edit searches again from where `/` was pressed (vim's incsearch), or
    // re-filters.
    func controlTextDidChange(_ obj: Notification) {
        switch barMode {
        case .find:
            query = searchField.stringValue
            if !query.isEmpty { _ = search(fromRow: searchOrigin?.row ?? 0, reverse: false, includeStart: true) }
        case .filter:
            applyFilter(searchField.stringValue)
        }
    }

    /// Enter: keep the match / filter and hand the keyboard back to the table.
    private func searchEntered() {
        switch barMode {
        case .find:
            query = searchField.stringValue
            if query.isEmpty { cancelSearch(); return }
            if match == nil { _ = search(fromRow: searchOrigin?.row ?? 0, reverse: false, includeStart: true) }
        case .filter:
            applyFilter(searchField.stringValue)
        }
        hideSearch()
    }

    /// Esc in the bar: find → back to where the search started, highlight gone; filter → all rows.
    private func cancelSearch() {
        if barMode == .filter {
            applyFilter("")
            hideSearch()
            return
        }
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

    /// `y` / ⌘C: in the pane, the selected text if any, else the current field's value; in the
    /// grid, the selected row as a tab-separated line.
    func copySelection() {
        if root.window?.firstResponder === detail {
            if detail.selectedRange().length > 0 { detail.copy(nil); return }
            guard table.selectedRow >= 0, fieldIndex < data.rows[original(table.selectedRow)].count else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(data.rows[original(table.selectedRow)][fieldIndex], forType: .string)
            return
        }
        guard table.selectedRow >= 0 else { return }
        let line = data.rows[original(table.selectedRow)].joined(separator: "\t")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    /// Esc: in the pane, drop its text selection and go back to the grid; in the grid, drop the
    /// row selection (which closes the pane), the search highlight and any filter.
    func clearSelection() {
        if root.window?.firstResponder === detail {
            detail.setSelectedRange(NSRange(location: 0, length: 0))
            focus()
            return
        }
        if filtered != nil { applyFilter("") }
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

/// `ViewerCommands` for the detail pane: `j` / `k` / `gg` / `G` / `50G` move a cursor over the
/// fields (columns) of the record, `h` / `l` go to the previous / next record, `d` / `u` / `f` / `b`
/// scroll the pane's own text, the rest is forwarded.
final class PaneCommands: ViewerCommands {
    private weak var view: TableDocumentView?
    private let scrollView: NSScrollView
    var lineHeight: CGFloat
    private let forward: ViewerCommands

    init(view: TableDocumentView, scrollView: NSScrollView, lineHeight: CGFloat, forward: ViewerCommands) {
        self.view = view
        self.scrollView = scrollView
        self.lineHeight = lineHeight
        self.forward = forward
    }

    private var clip: NSClipView { scrollView.contentView }
    private var maxY: CGFloat { max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height) }
    private func scroll(toY y: CGFloat) {
        var o = clip.bounds.origin
        o.y = min(max(0, y), maxY)
        clip.scroll(to: o)
        scrollView.reflectScrolledClipView(clip)
    }
    private func scroll(by dy: CGFloat) { scroll(toY: clip.bounds.origin.y + dy) }

    func scrollLines(_ n: Int) { view?.moveField(by: n) }
    func scrollHalfPages(_ n: Int) { scroll(by: CGFloat(n) * clip.bounds.height / 2) }
    func scrollPages(_ n: Int) { scroll(by: CGFloat(n) * max(clip.bounds.height - lineHeight, lineHeight)) }
    func scrollHorizontal(_ n: Int) { // h / l: previous / next record (`0` / `$` are ignored)
        if abs(n) < 1_000_000 { forward.scrollLines(n); view?.setField(view?.fieldIndexValue ?? 0) }
    }
    func scrollToTop() { view?.setField(0) }
    func scrollToBottom() { view?.setField(.max) }
    func scrollToPercent(_ percent: Int) { view?.setField(((view?.fieldCount ?? 1) - 1) * percent / 100) }

    func find() { forward.find() }
    func filter() { forward.filter() }
    func sortRows() { view?.sort(by: view?.fieldIndexValue ?? 0) } // `s` in the pane: by the highlighted field
    func unsortRows() { forward.unsortRows() }
    func findNext(reverse: Bool) { forward.findNext(reverse: reverse) }
    func copySelection() { forward.copySelection() }
    func clearSelection() { forward.clearSelection() }
    func toggleDetail() { forward.toggleDetail() }
    func switchPane() { forward.switchPane() }
    func togglePanePosition() { forward.togglePanePosition() }
    func reload() { forward.reload() }
    func openFile() { forward.openFile() }
    func closeWindow() { forward.closeWindow() }
    func selectTab(offset: Int) { forward.selectTab(offset: offset) }
    func selectTab(index: Int) { forward.selectTab(index: index) }
    func zoom(_ delta: Int) { forward.zoom(delta) }
    func resetZoom() { forward.resetZoom() }
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
