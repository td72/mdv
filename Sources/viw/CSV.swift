import Foundation

/// A parsed delimited file: the first row is the header.
struct TableData {
    var header: [String]
    var rows: [[String]]
    /// Rows dropped past `CSV.maxRows` (total rows in the file, including the header).
    var totalRows: Int
    var columnCount: Int { header.count }
    var truncated: Bool { rows.count + 1 < totalRows }
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
        return TableData(header: rows[0], rows: Array(rows.dropFirst()), totalRows: total)
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
