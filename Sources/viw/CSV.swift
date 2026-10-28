import Foundation

/// What every non-empty cell of a column parses as. Drives alignment and sorting; the cell
/// text itself is never changed.
enum ColumnType: String {
    case integer, number, boolean, date, text

    var isNumeric: Bool { self == .integer || self == .number }

    /// Strictest type that fits all non-empty cells (an all-empty column is text).
    static func infer(_ cells: [String]) -> ColumnType {
        var candidates: Set<ColumnType> = [.integer, .number, .boolean, .date]
        var any = false
        for cell in cells where !cell.isEmpty {
            any = true
            if candidates.contains(.integer), integer(cell) == nil { candidates.remove(.integer) }
            if candidates.contains(.number), number(cell) == nil { candidates.remove(.number) }
            if candidates.contains(.boolean), !booleans.contains(cell.lowercased()) { candidates.remove(.boolean) }
            if candidates.contains(.date), dateParts(cell) == nil { candidates.remove(.date) }
            if candidates.isEmpty { return .text }
        }
        guard any else { return .text }
        for t in [ColumnType.integer, .number, .boolean, .date] where candidates.contains(t) { return t }
        return .text
    }

    static let booleans: Set<String> = ["true", "false", "yes", "no"]

    /// `Double` of a cell, also accepting thousands separators and a trailing `%` as spreadsheets
    /// format them ("1,234.5", "12.5%"); the text is never altered, only read.
    static func number(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        guard let stripped = stripFormatting(s) else { return nil }
        return Double(stripped)
    }

    static func integer(_ s: String) -> Int? {
        if let i = Int(s) { return i }
        guard let stripped = stripFormatting(s) else { return nil }
        return Int(stripped)
    }

    /// "1,234,567%" → "1234567" when the commas sit between digits in groups of three; nil otherwise.
    private static func stripFormatting(_ s: String) -> String? {
        var bytes = Array(s.utf8)
        guard !bytes.isEmpty else { return nil }
        if bytes.last == UInt8(ascii: "%") { bytes.removeLast() }
        guard bytes.contains(UInt8(ascii: ",")) || s.hasSuffix("%") else { return nil }
        var out: [UInt8] = []
        var sinceComma = -1
        for b in bytes {
            if b == UInt8(ascii: ",") {
                guard sinceComma == -1 ? out.contains(where: { $0 >= 48 && $0 <= 57 }) : sinceComma == 3 else { return nil }
                sinceComma = 0
            } else {
                if sinceComma >= 0 { if b >= 48 && b <= 57 { sinceComma += 1 } else { guard sinceComma == 3 else { return nil }; sinceComma = -1 } }
                out.append(b)
            }
        }
        if sinceComma >= 0, sinceComma != 3 { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    /// `yyyy-MM-dd` / `yyyy/MM/dd` with an optional ` HH:mm[:ss]` or `THH:mm[:ss]` → sortable parts.
    static func dateParts(_ s: String) -> [Int]? {
        var parts: [Int] = []
        var n = 0, digits = 0
        var expectSep: [UInt8] = [UInt8(ascii: "-"), UInt8(ascii: "/")]
        for b in s.utf8 {
            if b >= 48 && b <= 57 { n = n * 10 + Int(b - 48); digits += 1; continue }
            guard digits > 0 else { return nil }
            parts.append(n); n = 0; digits = 0
            switch parts.count {
            case 1: guard expectSep.contains(b) else { return nil }; expectSep = [b]
            case 2: guard expectSep.contains(b) else { return nil }
            case 3: guard b == UInt8(ascii: " ") || b == UInt8(ascii: "T") else { return nil }
            case 4, 5: guard b == UInt8(ascii: ":") else { return nil }
            default: return nil
            }
        }
        if digits > 0 { parts.append(n) }
        guard (3...6).contains(parts.count), parts[0] >= 1000, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return parts
    }
}

/// A parsed delimited file: the first row is the header.
struct TableData {
    var header: [String]
    var rows: [[String]]
    /// Rows dropped past `CSV.maxRows` (total rows in the file, including the header).
    var totalRows: Int
    var types: [ColumnType] = []
    /// Column widths in characters from the file (xlsx `<cols>`), nil where the data decides.
    var columnWidths: [Double?] = []
    var columnCount: Int { header.count }
    var truncated: Bool { rows.count + 1 < totalRows }

    mutating func inferTypes() {
        types = (0..<columnCount).map { c in ColumnType.infer(rows.map { c < $0.count ? $0[c] : "" }) }
    }
}

/// RFC 4180 reader with no dependencies: quoted fields (with `""` escapes and embedded
/// newlines), CR / LF / CRLF row ends, ragged rows padded. Delimiter and text encoding
/// are guessed from the file.
enum CSV {
    static let maxRows = 500_000

    static func table(from data: Data, url: URL) -> TableData {
        let text = decode(data)
        let delimiter = detectDelimiter(text, extension: url.pathExtension.lowercased())
        var rows = parse(text, delimiter: delimiter)
        let total = rows.count
        if rows.count > maxRows + 1 { rows.removeSubrange((maxRows + 1)...) }
        let width = rows.map(\.count).max() ?? 0
        for i in rows.indices where rows[i].count < width {
            rows[i].append(contentsOf: repeatElement("", count: width - rows[i].count))
        }
        guard !rows.isEmpty else { return TableData(header: [], rows: [], totalRows: 0) }
        var table = TableData(header: rows[0], rows: Array(rows.dropFirst()), totalRows: total)
        table.inferTypes()
        return table
    }

    /// UTF-8 (BOM or not) first, then Shift_JIS (what Excel on a Japanese Mac writes), then
    /// Latin-1 so that nothing is unreadable.
    static func decode(_ data: Data) -> String {
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        if let s = String(data: d, encoding: .utf8) { return s }
        if let s = String(data: d, encoding: .shiftJIS) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    /// `.tsv` / `.tab` → tab; otherwise whichever of `,` `\t` `;` appears most in the first lines.
    static func detectDelimiter(_ text: String, extension ext: String) -> UInt8 {
        if ext == "tsv" || ext == "tab" { return UInt8(ascii: "\t") }
        var counts: [UInt8: Int] = [UInt8(ascii: ","): 0, UInt8(ascii: "\t"): 0, UInt8(ascii: ";"): 0]
        var lines = 0
        var inQuotes = false
        for b in text.utf8 {
            if b == UInt8(ascii: "\"") { inQuotes.toggle() }
            if inQuotes { continue }
            if b == UInt8(ascii: "\n") { lines += 1; if lines >= 20 { break } }
            if counts[b] != nil { counts[b]! += 1 }
        }
        return counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }!.key
    }

    static func parse(_ text: String, delimiter: UInt8) -> [[String]] {
        let bytes = Array(text.utf8)
        let quote = UInt8(ascii: "\""), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var i = 0
        let n = bytes.count
        func endField() { row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true) }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < n {
            let b = bytes[i]
            if b == quote, field.isEmpty {
                // Quoted field: runs to the next lone quote; "" is a literal quote.
                i += 1
                while i < n {
                    let c = bytes[i]
                    if c == quote {
                        if i + 1 < n, bytes[i + 1] == quote { field.append(quote); i += 2; continue }
                        i += 1
                        break
                    }
                    field.append(c)
                    i += 1
                }
                // Anything between the closing quote and the delimiter is kept (lenient).
                while i < n, bytes[i] != delimiter, bytes[i] != cr, bytes[i] != lf { field.append(bytes[i]); i += 1 }
                continue
            }
            if b == delimiter { endField() }
            else if b == lf { endRow() }
            else if b == cr { endRow(); if i + 1 < n, bytes[i + 1] == lf { i += 1 } }
            else { field.append(b) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
