import Foundation

/// The values of an `.xlsx` / `.xlsm` workbook, read with no dependencies: `ZipArchive` opens
/// the container, a byte-level scanner streams the big parts (sheets, shared strings) and
/// `XMLParser` reads the small ones. Formulas are not evaluated (the cached `<v>` is shown);
/// styles only decide how numbers are spelled (dates, decimals, percent, grouping). Sheets
/// are parsed on demand, so a 20-sheet book opens as fast as its first sheet.
final class Workbook {
    struct Sheet {
        let name: String
        let path: String   // zip entry, e.g. "xl/worksheets/sheet1.xml"
        let hidden: Bool
    }

    let sheets: [Sheet]
    private let zip: ZipArchive
    private let sharedStrings: [String]
    private let styles: Styles
    private let date1904: Bool

    init(url: URL) throws {
        zip = try ZipArchive(url: url)
        let (sheets, date1904) = try Self.readWorkbook(zip)
        self.sheets = sheets
        self.date1904 = date1904
        sharedStrings = zip.entries["xl/sharedStrings.xml"] != nil ? Self.readSharedStrings(try zip.data(for: "xl/sharedStrings.xml")) : []
        styles = zip.entries["xl/styles.xml"] != nil ? Styles(try zip.data(for: "xl/styles.xml")) : Styles()
    }

    private var parsedSheets: [Int: ParsedSheet] = [:]

    /// The sheet's cells, parsed once and kept (formulas on other sheets may refer to them).
    func parsed(sheet i: Int) throws -> ParsedSheet {
        if let p = parsedSheets[i] { return p }
        let parser = SheetParser(strings: sharedStrings)
        parser.run(try zip.data(for: sheets[i].path))
        parsedSheets[i] = parser.sheet
        return parser.sheet
    }

    /// The sheet as a table: the first row is the header, like a CSV. Formulas without a
    /// cached value are evaluated where `Formula` can (references, arithmetic). Rows past
    /// `CSV.maxRows` are dropped (the dimension tells how many there were).
    func table(forSheet i: Int) throws -> TableData {
        let sheet = try parsed(sheet: i)
        let spelling = Spelling(date1904: date1904)
        let cells = WorkbookCells(workbook: self, sheet: i)
        var rows: [[String]] = []
        var formulas: [Int: [Int: String]] = [:] // by sheet row index (header included), then column
        rows.reserveCapacity(sheet.cells.count)
        for (r, row) in sheet.cells.enumerated() {
            var out: [String] = []
            out.reserveCapacity(row.count)
            for (c, cell) in row.enumerated() {
                var value = cell.value
                if let f = cell.formula {
                    formulas[r, default: [:]][c] = f
                    if !cell.hasCachedValue { value = cells.value(sheetIndex: i, row: r + 1, column: c) ?? .empty }
                }
                out.append(Self.spell(value, format: styles.format(forStyle: cell.style), spelling: spelling))
            }
            rows.append(out)
        }
        // Formatting-only cells leave empty rows / columns at the edges: drop them (a formula counts as content).
        func filled(_ r: Int, _ c: Int) -> Bool { (c < rows[r].count && !rows[r][c].isEmpty) || formulas[r]?[c] != nil }
        while let last = rows.indices.last, !rows[last].indices.contains(where: { filled(last, $0) }) { rows.removeLast(); formulas[last] = nil }
        var width = rows.map(\.count).max() ?? 0
        while width > 0, !rows.indices.contains(where: { filled($0, width - 1) }) { width -= 1 }
        for r in rows.indices {
            if rows[r].count < width { rows[r].append(contentsOf: repeatElement("", count: width - rows[r].count)) }
            else if rows[r].count > width { rows[r].removeSubrange(width...) }
        }
        guard !rows.isEmpty else { return TableData(header: [], rows: [], totalRows: 0) }
        var table = TableData(header: rows[0], rows: Array(rows.dropFirst()), totalRows: max(rows.count, sheet.truncatedTotal ?? 0))
        table.columnWidths = (0..<width).map { sheet.columnWidths[$0] }
        for (r, cols) in formulas where r >= 1 { table.formulas[r - 1] = cols } // data rows: header formulas are not shown
        table.inferTypes()
        return table
    }

    // MARK: - workbook.xml + rels

    private static func readWorkbook(_ zip: ZipArchive) throws -> ([Sheet], Bool) {
        let rels = SimpleXML.elements(in: try zip.data(for: "xl/_rels/workbook.xml.rels"), named: "Relationship")
        var targets: [String: String] = [:]
        for r in rels {
            guard let id = r["Id"], let target = r["Target"], (r["Type"] ?? "").hasSuffix("/worksheet") else { continue }
            targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        }
        let wb = try zip.data(for: "xl/workbook.xml")
        let date1904 = SimpleXML.elements(in: wb, named: "workbookPr").first.map { ["1", "true"].contains($0["date1904"] ?? "") } ?? false
        var sheets: [Sheet] = []
        for s in SimpleXML.elements(in: wb, named: "sheet") {
            // The relationship id is namespaced (r:id); chartsheets have no worksheet target and are skipped.
            guard let rid = s["r:id"] ?? s["id"], let path = targets[rid] else { continue }
            sheets.append(Sheet(name: s["name"] ?? "Sheet \(sheets.count + 1)", path: path, hidden: (s["state"] ?? "visible") != "visible"))
        }
        guard !sheets.isEmpty else { throw ZipArchive.Error.entryNotFound("worksheet") }
        return (sheets, date1904)
    }

    // MARK: - sharedStrings.xml

    /// `<si>` → one string: plain `<t>` or rich-text runs `<r><t>` joined; phonetic `<rPh>` runs
    /// (furigana that Excel on Japanese systems stores next to the text) are left out.
    private static func readSharedStrings(_ data: Data) -> [String] {
        var strings: [String] = []
        var current = ""
        var inRPh = false, inT = false
        XMLScanner.scan(data) { token in
            switch token {
            case .start(let tag, let selfClosing):
                if tag.is("t") { inT = !inRPh && !selfClosing }
                else if tag.is("rPh") { inRPh = !selfClosing }
                else if tag.is("si") { current = "" }
            case .end(let tag):
                if tag.is("t") { inT = false }
                else if tag.is("rPh") { inRPh = false }
                else if tag.is("si") { strings.append(current) }
            case .text(let s):
                if inT { current += s() }
            }
        }
        return strings
    }

    // MARK: - styles.xml

    /// Cell style index (`s="…"`) → how a number in that cell is spelled.
    struct Styles {
        enum Format: Equatable {
            case general
            /// `elapsed`: `[h]:mm:ss`, hours past 24 instead of a clock time.
            case date(date: Bool, time: Bool, seconds: Bool, elapsed: Bool)
            case number(decimals: Int, grouping: Bool, percent: Bool)
            case text
        }

        private var formats: [Format] = [] // by cellXfs index

        init() {}

        init(_ data: Data) {
            var custom: [Int: String] = [:]
            for f in SimpleXML.elements(in: data, named: "numFmt") {
                if let id = f["numFmtId"].flatMap(Int.init), let code = f["formatCode"] { custom[id] = code }
            }
            // cellXfs is the list that `s` indexes; cellStyleXfs (the named styles) also holds <xf>
            // elements, so take the ones after the cellXfs tag.
            formats = SimpleXML.elements(in: data, named: "xf", after: "cellXfs").map { xf in
                let id = xf["numFmtId"].flatMap(Int.init) ?? 0
                return Self.format(forNumFmt: id, code: custom[id])
            }
        }

        func format(forStyle s: Int?) -> Format {
            guard let s, s >= 0, s < formats.count else { return .general }
            return formats[s]
        }

        static let builtin: [Int: String] = [
            1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??",
            14: "mm-dd-yy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM", 20: "h:mm",
            21: "h:mm:ss", 22: "m/d/yy h:mm", 37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)",
            40: "#,##0.00;[Red](#,##0.00)", 45: "mm:ss", 46: "[h]:mm:ss", 47: "mmss.0", 48: "##0.0E+0", 49: "@",
            // 27–36 and 50–58 are locale (Japanese / Chinese / Korean) date formats.
            27: "yyyy/m/d", 28: "m/d", 29: "m/d", 30: "m/d/yy", 31: "yyyy/m/d", 32: "h:mm", 33: "h:mm:ss", 34: "h:mm AM/PM",
            35: "h:mm:ss AM/PM", 36: "yyyy/m/d", 50: "yyyy/m/d", 51: "m/d", 52: "yyyy/m/d", 53: "m/d", 54: "yyyy/m/d",
            55: "h:mm AM/PM", 56: "h:mm:ss AM/PM", 57: "yyyy/m/d", 58: "m/d",
        ]

        static func format(forNumFmt id: Int, code: String?) -> Format {
            guard let code = code ?? builtin[id] else { return .general }
            return parse(code)
        }

        /// Classify a format code by its first section: `@` is text, any of `y m d h s` outside
        /// quotes / brackets is a date or time, digit placeholders give decimals / grouping / `%`.
        static func parse(_ code: String) -> Format {
            if code == "General" { return .general }
            // First section (positive numbers); `;` inside quotes or brackets does not split.
            var section = ""
            var quoted = false, bracket = false, escaped = false
            for ch in code {
                if escaped { section.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; section.append(ch); continue }
                if ch == "\"" { quoted.toggle() } else if !quoted, ch == "[" { bracket = true } else if !quoted, ch == "]" { bracket = false }
                if ch == ";", !quoted, !bracket { break }
                section.append(ch)
            }
            let lowerSection = section.lowercased()
            let elapsed = lowerSection.contains("[h") || lowerSection.contains("[m") || lowerSection.contains("[s")
            // Strip literals: "…", [...], \x, _x (padding), *x (fill).
            var bare = ""
            quoted = false; bracket = false
            var skip = false
            for ch in section {
                if skip { skip = false; continue }
                if quoted { if ch == "\"" { quoted = false }; continue }
                if bracket { if ch == "]" { bracket = false }; continue }
                switch ch {
                case "\"": quoted = true
                case "[": bracket = true
                case "\\", "_", "*": skip = true
                default: bare.append(ch)
                }
            }
            if bare.contains("@") { return .text }
            let lower = bare.lowercased().replacingOccurrences(of: "am/pm", with: "").replacingOccurrences(of: "a/p", with: "")
            let ampm = bare.lowercased().contains("am/pm") || bare.lowercased().contains("a/p")
            let hasTime = lower.contains("h") || lower.contains("s") || ampm || elapsed
            let hasDate = lower.contains("y") || lower.contains("d") || (lower.contains("m") && !hasTime)
                || (lower.contains("m") && (lower.contains("y") || lower.contains("d")))
            if hasDate || hasTime {
                return .date(date: hasDate, time: hasTime, seconds: lower.contains("s"), elapsed: elapsed)
            }
            let percent = bare.contains("%")
            var decimals = 0
            if let dot = bare.firstIndex(of: ".") {
                for ch in bare[bare.index(after: dot)...] { if ch == "0" || ch == "#" || ch == "?" { decimals += 1 } else { break } }
            }
            // A comma between digit placeholders groups thousands (a trailing comma scales instead).
            var grouping = false
            let chars = Array(bare)
            for (i, ch) in chars.enumerated() where ch == "," && i + 1 < chars.count {
                if ["0", "#", "?"].contains(chars[i + 1]) { grouping = true; break }
            }
            if bare.contains("E") || bare.contains("e") || bare.contains("/") { return .general } // scientific / fractions: as stored
            return .number(decimals: decimals, grouping: grouping, percent: percent)
        }
    }

    // MARK: - Number spelling

    /// `NumberFormatter`s by (decimals, grouping): one per sheet, not one per cell.
    final class Spelling {
        private var formatters: [Int: NumberFormatter] = [:]
        let date1904: Bool
        init(date1904: Bool) { self.date1904 = date1904 }

        func formatter(decimals: Int, grouping: Bool) -> NumberFormatter {
            let key = decimals * 2 + (grouping ? 1 : 0)
            if let f = formatters[key] { return f }
            let f = NumberFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.numberStyle = .decimal
            f.usesGroupingSeparator = grouping
            f.minimumFractionDigits = decimals
            f.maximumFractionDigits = decimals
            f.roundingMode = .halfUp
            formatters[key] = f
            return f
        }
    }

    /// A cell's value → what the grid shows for its style.
    static func spell(_ v: Formula.Value, format: Styles.Format, spelling: Spelling) -> String {
        switch v {
        case .empty: return ""
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e
        case .number(let d): return spell(number: d, format: format, spelling: spelling)
        }
    }

    /// Numbers: `General` keeps integers exact and shows ~10 significant digits otherwise
    /// (hiding 0.1 + 0.2 noise); number formats give decimals / grouping / percent; date
    /// formats turn the serial into a date / time.
    static func spell(number d: Double, format: Styles.Format, spelling: Spelling) -> String {
        switch format {
        case .text, .general: return Formula.spellGeneral(d)
        case .number(let decimals, let grouping, let percent):
            let v = percent ? d * 100 : d
            guard let s = spelling.formatter(decimals: decimals, grouping: grouping).string(from: v as NSNumber) else { return Formula.spellGeneral(d) }
            return percent ? s + "%" : s
        case .date(let date, let time, let seconds, let elapsed):
            return spellDate(serial: d, date: date, time: time, seconds: seconds, elapsed: elapsed, date1904: spelling.date1904)
        }
    }

    /// Excel serial (days since 1899-12-30, or 1904-01-01) → `yyyy-MM-dd[ HH:mm[:ss]]`;
    /// `elapsed` (`[h]:mm:ss`) → total hours.
    static func spellDate(serial: Double, date: Bool, time: Bool, seconds: Bool, elapsed: Bool, date1904: Bool) -> String {
        if elapsed {
            let total = Int((serial * 86_400).rounded())
            let h = total / 3600, m = abs(total) % 3600 / 60, s = abs(total) % 60
            return seconds ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", h, m)
        }
        var days = Int(serial.rounded(.down))
        var secs = Int(((serial - Double(days)) * 86_400).rounded())
        if secs >= 86_400 { days += 1; secs -= 86_400 }
        var out = ""
        if date {
            // Days since 1970-01-01. Excel's 1900 system counts the nonexistent 1900-02-29 as serial 60,
            // so dates before it are one day closer.
            let unixDays = days + (date1904 ? -24_107 : (days < 61 ? -25_568 : -25_569))
            let (y, m, d) = civil(fromDays: unixDays)
            out = String(format: "%04d-%02d-%02d", y, m, d)
        }
        if time {
            let h = secs / 3600, m = secs % 3600 / 60, s = secs % 60
            let hm = String(format: "%02d:%02d", h, m)
            out += (date ? " " : "") + (seconds ? hm + String(format: ":%02d", s) : hm)
        }
        return out
    }

    /// Proleptic Gregorian date of a day count from 1970-01-01 (Howard Hinnant's civil_from_days).
    static func civil(fromDays z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return (y, m, d)
    }

    // MARK: - Cell references

    /// "AB12" → (column 27, row 12), zero-based column, one-based row as written.
    static func reference(_ ref: String) -> (column: Int, row: Int)? {
        var col = 0, row = 0, letters = 0
        for b in ref.utf8 {
            if b >= 65 && b <= 90 { col = col * 26 + Int(b - 64); letters += 1 }
            else if b >= 97 && b <= 122 { col = col * 26 + Int(b - 96); letters += 1 }
            else if b >= 48 && b <= 57 { row = row * 10 + Int(b - 48) }
            else { return nil }
        }
        guard letters > 0, row > 0 else { return nil }
        return (col - 1, row)
    }
}

/// One cell as read from the sheet: its typed value (`.empty` when a formula has no cached
/// value), the style index and the formula text, if any.
struct RawCell {
    var value: Formula.Value
    var style: Int?
    var formula: String?
    var hasCachedValue: Bool
}

/// The cells of one sheet, by row (sheet row r is `cells[r - 1]`; rows are ragged).
final class ParsedSheet {
    var cells: [[RawCell]] = []
    /// Custom widths from `<cols>`, in characters, by zero-based column.
    var columnWidths: [Int: Double] = [:]
    /// Row count from `<dimension>`, when rows had to be dropped.
    var truncatedTotal: Int?

    func cell(row: Int, column: Int) -> RawCell? {
        guard row >= 1, row <= cells.count, column >= 0, column < cells[row - 1].count else { return nil }
        return cells[row - 1][column]
    }
}

/// Reference resolution for `Formula`: cells by sheet name, with formulas that have no
/// cached value evaluated on demand (memoised; a cycle or an unsupported formula in the
/// chain leaves the dependent cell empty too).
final class WorkbookCells: FormulaCells {
    private unowned let workbook: Workbook
    private var currentSheet: Int
    private var memo: [String: Formula.Value?] = [:]
    private var visiting: Set<String> = []

    init(workbook: Workbook, sheet: Int) {
        self.workbook = workbook
        currentSheet = sheet
    }

    func value(sheet name: String?, row: Int, column: Int) -> Formula.Value? {
        var index = currentSheet
        if let name {
            guard let i = workbook.sheets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return .error("#REF!") }
            index = i
        }
        return value(sheetIndex: index, row: row, column: column)
    }

    /// nil: the cell depends on something the evaluator cannot do (so stays empty).
    func value(sheetIndex i: Int, row: Int, column: Int) -> Formula.Value? {
        guard let sheet = try? workbook.parsed(sheet: i) else { return .error("#REF!") }
        guard let cell = sheet.cell(row: row, column: column) else { return .empty }
        guard let f = cell.formula, !cell.hasCachedValue else { return cell.value }
        let key = "\(i):\(row):\(column)"
        if let v = memo[key] { return v }
        if visiting.contains(key) || visiting.count > 64 { return .error("#REF!") } // circular
        visiting.insert(key)
        let saved = currentSheet
        currentSheet = i
        let v = Formula.evaluate(f, cells: self)
        currentSheet = saved
        visiting.remove(key)
        memo[key] = v
        return v
    }
}

/// Streams one `sheetN.xml`: `<row>` / `<c r= s= t=>` / `<v>` / `<f>` / `<is><t>` into typed cells.
private final class SheetParser {
    private let strings: [String]
    let sheet = ParsedSheet()
    private var dimensionRows = 0

    private var row: [RawCell] = []
    private var rowNumber = 0        // 1-based, of the row being filled
    private var column = -1          // last filled column in the row
    private enum CellType { case number, shared, boolean, error, other } // t= absent / "n", "s", "b", "e", the rest (str, inlineStr, d)
    private var cellType = CellType.number
    private var cellStyle: Int?
    private var text = ""
    private var hasValue = false
    private var formula: String?
    private var formulaText = ""
    private var formulaShared: (si: String, master: Bool)?
    /// Shared formulas: the master cell's text and position, by `si`; dependents shift its references.
    private var sharedMasters: [String: (text: String, row: Int, column: Int)] = [:]
    private var collecting = false
    private var collectingFormula = false
    private var inInlineString = false
    private var inRPh = false

    init(strings: [String]) { self.strings = strings }

    func run(_ data: Data) {
        XMLScanner.scan(data) { token in
            switch token {
            case .start(let tag, let selfClosing): start(tag, selfClosing)
            case .end(let tag): end(tag)
            case .text(let s):
                if collecting { text += s() } else if collectingFormula { formulaText += s() }
            }
        }
        flushRow()
    }

    private func flushRow() {
        guard rowNumber > 0 else { return }
        // Skipped (empty) rows between r attributes become empty rows, so row numbers stay true.
        while sheet.cells.count < rowNumber - 1 { sheet.cells.append([]) }
        sheet.cells.append(row)
        row = []
        rowNumber = 0
        column = -1
    }

    private func start(_ tag: XMLScanner.Tag, _ selfClosing: Bool) {
        if tag.is("c") {
            if let r = tag.attribute("r"), let ref = Workbook.reference(r) { column = ref.column } else { column += 1 }
            switch tag.attribute("t") {
            case nil, "n": cellType = .number
            case "s": cellType = .shared
            case "b": cellType = .boolean
            case "e": cellType = .error
            default: cellType = .other
            }
            cellStyle = tag.attribute("s").flatMap(Int.init)
            text = ""
            hasValue = false
            formula = nil
            if selfClosing { cellType = .other } // formatting only: no value
        } else if tag.is("v") {
            text = ""
            collecting = !selfClosing
            hasValue = true
        } else if tag.is("f") {
            formulaText = ""
            collectingFormula = !selfClosing
            formulaShared = tag.attribute("t") == "shared" ? (tag.attribute("si") ?? "", tag.attribute("ref") != nil) : nil
            if selfClosing { endFormula() }
        } else if tag.is("t") {
            // <t> inside <is> (inline string); <rPh> (phonetic) is skipped.
            collecting = inInlineString && !inRPh && !selfClosing
        } else if tag.is("row") {
            flushRow()
            rowNumber = tag.attribute("r").flatMap(Int.init) ?? sheet.cells.count + 1
            if rowNumber > CSV.maxRows + 1 {
                sheet.truncatedTotal = max(dimensionRows, rowNumber)
                rowNumber = 0
                XMLScanner.stop()
            }
        } else if tag.is("is") { inInlineString = !selfClosing }
        else if tag.is("rPh") { inRPh = !selfClosing }
        else if tag.is("dimension") {
            if let ref = tag.attribute("ref"), let end = ref.split(separator: ":").last, let r = Workbook.reference(String(end)) { dimensionRows = r.row }
        } else if tag.is("col") {
            guard let min = tag.attribute("min").flatMap(Int.init), let max = tag.attribute("max").flatMap(Int.init),
                  let w = tag.attribute("width").flatMap(Double.init), w > 0 else { return }
            for c in min...Swift.min(max, min + 1000) { sheet.columnWidths[c - 1] = w }
        }
    }

    /// `</f>`: a plain formula is its text; a shared master registers itself; a shared
    /// dependent (empty `<f t="shared" si="n"/>`) takes the master's text with references moved.
    private func endFormula() {
        collectingFormula = false
        if let shared = formulaShared {
            if shared.master || !formulaText.isEmpty {
                sharedMasters[shared.si] = (formulaText, rowNumber, column)
                formula = formulaText
            } else if let m = sharedMasters[shared.si] {
                formula = Formula.shift(m.text, rows: rowNumber - m.row, columns: column - m.column)
            }
        } else if !formulaText.isEmpty {
            formula = formulaText
        }
        formulaShared = nil
    }

    private func end(_ tag: XMLScanner.Tag) {
        if tag.is("c") {
            let value: Formula.Value
            switch cellType {
            case .shared: value = Int(text).flatMap { $0 < strings.count ? .text(strings[$0]) : nil } ?? .empty
            case .boolean: value = hasValue ? .bool(text == "1") : .empty
            case .number: value = Double(text).map { .number($0) } ?? .empty
            case .error: value = text.isEmpty ? .empty : .error(text)
            case .other: value = text.isEmpty ? .empty : .text(text) // str (formula result), inlineStr, d (ISO date)
            }
            if column >= 0, value != .empty || formula != nil {
                while row.count < column { row.append(RawCell(value: .empty, style: nil, formula: nil, hasCachedValue: false)) }
                let cell = RawCell(value: value, style: cellStyle, formula: formula, hasCachedValue: hasValue && !text.isEmpty)
                if row.count == column { row.append(cell) } else { row[column] = cell }
            }
            text = ""
            cellType = .number
            formula = nil
        } else if tag.is("v") || tag.is("t") { collecting = false }
        else if tag.is("f") { if collectingFormula { endFormula() } }
        else if tag.is("row") { flushRow() }
        else if tag.is("is") { inInlineString = false }
        else if tag.is("rPh") { inRPh = false }
    }
}

/// A byte-level XML scanner for the large OOXML parts. Foundation's `XMLParser` costs about
/// 3 µs per cell through its delegate; this is a tenth of that. It assumes well-formed input
/// (Excel's), skips comments / PIs / doctype, understands CDATA and the five entities plus
/// numeric references, and ignores namespace prefixes on element names.
enum XMLScanner {
    struct Tag {
        fileprivate let base: UnsafePointer<UInt8>
        fileprivate let name: Range<Int>
        fileprivate let attrs: Range<Int>

        func `is`(_ s: StaticString) -> Bool {
            s.utf8CodeUnitCount == name.count && memcmp(base + name.lowerBound, s.utf8Start, s.utf8CodeUnitCount) == 0
        }

        /// The attribute's value, decoded, or nil.
        func attribute(_ key: StaticString) -> String? {
            guard let r = valueRange(key) else { return nil }
            return XMLScanner.decode(base, r)
        }

        private func valueRange(_ key: StaticString) -> Range<Int>? {
            var j = attrs.lowerBound
            let end = attrs.upperBound
            while j < end {
                while j < end, isSpace(base[j]) { j += 1 }
                let nameStart = j
                while j < end, base[j] != UInt8(ascii: "="), !isSpace(base[j]) { j += 1 }
                let nameEnd = j
                while j < end, base[j] != UInt8(ascii: "=") { j += 1 }
                j += 1
                while j < end, isSpace(base[j]) { j += 1 }
                guard j < end else { return nil }
                let q = base[j]
                j += 1
                let valueStart = j
                while j < end, base[j] != q { j += 1 }
                if nameEnd - nameStart == key.utf8CodeUnitCount, memcmp(base + nameStart, key.utf8Start, key.utf8CodeUnitCount) == 0 {
                    return valueStart..<j
                }
                j += 1
            }
            return nil
        }
    }

    enum Token {
        case start(Tag, selfClosing: Bool)
        case end(Tag)
        /// Character data; the closure decodes it (entities) only when asked.
        case text(() -> String)
    }

    private static var stopped = false
    /// Call from the handler to end the scan early.
    static func stop() { stopped = true }

    static func scan(_ data: Data, _ handler: (Token) -> Void) {
        stopped = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            while i < n, !stopped {
                if base[i] != UInt8(ascii: "<") {
                    // Text up to the next tag.
                    let start = i
                    while i < n, base[i] != UInt8(ascii: "<") { i += 1 }
                    let range = start..<i
                    handler(.text({ decode(base, range) }))
                    continue
                }
                i += 1
                guard i < n else { break }
                switch base[i] {
                case UInt8(ascii: "/"): // </name>
                    i += 1
                    let nameStart = i
                    while i < n, base[i] != UInt8(ascii: ">") { i += 1 }
                    handler(.end(Tag(base: base, name: localName(base, nameStart..<i), attrs: i..<i)))
                    i += 1
                case UInt8(ascii: "?"): // <?xml …?>
                    while i + 1 < n, !(base[i] == UInt8(ascii: "?") && base[i + 1] == UInt8(ascii: ">")) { i += 1 }
                    i += 2
                case UInt8(ascii: "!"):
                    if i + 7 < n, memcmp(base + i, "![CDATA[", 8) == 0 { // <![CDATA[ … ]]>
                        i += 8
                        let start = i
                        while i + 2 < n, !(base[i] == UInt8(ascii: "]") && base[i + 1] == UInt8(ascii: "]") && base[i + 2] == UInt8(ascii: ">")) { i += 1 }
                        let range = start..<min(i, n)
                        handler(.text({ String(decoding: UnsafeBufferPointer(start: base + range.lowerBound, count: range.count), as: UTF8.self) }))
                        i += 3
                    } else if i + 2 < n, base[i + 1] == UInt8(ascii: "-"), base[i + 2] == UInt8(ascii: "-") { // <!-- … -->
                        i += 3
                        while i + 2 < n, !(base[i] == UInt8(ascii: "-") && base[i + 1] == UInt8(ascii: "-") && base[i + 2] == UInt8(ascii: ">")) { i += 1 }
                        i += 3
                    } else { // <!DOCTYPE …>
                        while i < n, base[i] != UInt8(ascii: ">") { i += 1 }
                        i += 1
                    }
                default: // <name attrs> or <name attrs/>
                    let nameStart = i
                    while i < n, !isSpace(base[i]), base[i] != UInt8(ascii: ">"), base[i] != UInt8(ascii: "/") { i += 1 }
                    let name = localName(base, nameStart..<i)
                    let attrStart = i
                    var quote: UInt8 = 0
                    while i < n {
                        let b = base[i]
                        if quote != 0 { if b == quote { quote = 0 } }
                        else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") { quote = b }
                        else if b == UInt8(ascii: ">") { break }
                        i += 1
                    }
                    let selfClosing = i > attrStart && base[i - 1] == UInt8(ascii: "/")
                    let attrEnd = selfClosing ? i - 1 : i
                    let tag = Tag(base: base, name: name, attrs: attrStart..<max(attrStart, attrEnd))
                    handler(.start(tag, selfClosing: selfClosing))
                    if selfClosing { handler(.end(tag)) }
                    i += 1
                }
            }
        }
    }

    private static func localName(_ base: UnsafePointer<UInt8>, _ r: Range<Int>) -> Range<Int> {
        var j = r.upperBound - 1
        while j >= r.lowerBound { if base[j] == UInt8(ascii: ":") { return (j + 1)..<r.upperBound }; j -= 1 }
        return r
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 }

    /// Bytes → String with `&amp;` `&lt;` `&gt;` `&quot;` `&apos;` `&#NN;` `&#xHH;` resolved.
    fileprivate static func decode(_ base: UnsafePointer<UInt8>, _ r: Range<Int>) -> String {
        let buf = UnsafeBufferPointer(start: base + r.lowerBound, count: r.count)
        guard buf.contains(UInt8(ascii: "&")) else { return String(decoding: buf, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(buf.count)
        var i = 0
        while i < buf.count {
            let b = buf[i]
            guard b == UInt8(ascii: "&") else { out.append(b); i += 1; continue }
            var j = i + 1
            while j < buf.count, j - i < 12, buf[j] != UInt8(ascii: ";") { j += 1 }
            guard j < buf.count, buf[j] == UInt8(ascii: ";") else { out.append(b); i += 1; continue }
            let entity = String(decoding: UnsafeBufferPointer(rebasing: buf[(i + 1)..<j]), as: UTF8.self)
            let scalar: Unicode.Scalar?
            switch entity {
            case "amp": scalar = "&"
            case "lt": scalar = "<"
            case "gt": scalar = ">"
            case "quot": scalar = "\""
            case "apos": scalar = "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") { scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
                else if entity.hasPrefix("#") { scalar = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init) }
                else { scalar = nil }
            }
            if let scalar { out.append(contentsOf: Array(String(Character(scalar)).utf8)); i = j + 1 }
            else { out.append(b); i += 1 }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Just enough XML for the small parts (rels, workbook, styles): the attributes of every
/// element with a given name, in document order.
enum SimpleXML {
    static func elements(in data: Data, named name: String, after marker: String? = nil) -> [[String: String]] {
        final class D: NSObject, XMLParserDelegate {
            let name: String, marker: String?
            var armed: Bool
            var found: [[String: String]] = []
            init(name: String, marker: String?) { self.name = name; self.marker = marker; armed = marker == nil }
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                if let marker, e == marker { armed = true; return }
                if armed, e == name { found.append(a) }
            }
        }
        let d = D(name: name, marker: marker)
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.found
    }
}
