import Foundation
import Testing
@testable import viw

@Suite struct CSVTests {
    private func table(_ text: String, name: String = "t.csv") -> TableData {
        CSV.table(from: Data(text.utf8), url: URL(fileURLWithPath: name))
    }

    @Test func rfc4180() {
        let t = table("a,b,c\r\n1,\"x, y\",\"he said \"\"hi\"\"\"\n2,\"multi\nline\",3\n")
        #expect(t.header == ["a", "b", "c"])
        #expect(t.rows == [["1", "x, y", "he said \"hi\""], ["2", "multi\nline", "3"]])
        #expect(t.totalRows == 3)
        #expect(!t.truncated)
    }

    @Test func raggedRowsArePadded() {
        let t = table("a,b,c\n1\n1,2,3,4\n")
        #expect(t.header == ["a", "b", "c", ""])
        #expect(t.rows == [["1", "", "", ""], ["1", "2", "3", "4"]])
    }

    @Test func delimiterDetection() {
        #expect(CSV.detectDelimiter("a;b;c\n1;2;3\n", extension: "csv") == UInt8(ascii: ";"))
        #expect(CSV.detectDelimiter("a\tb\n1\t2\n", extension: "csv") == UInt8(ascii: "\t"))
        #expect(CSV.detectDelimiter("a,b\n1,2\n", extension: "tsv") == UInt8(ascii: "\t"))   // the extension wins
        #expect(CSV.detectDelimiter("\"a;b\",c\n", extension: "csv") == UInt8(ascii: ","))   // quoted text does not count
        #expect(table("x\ty\n1\t2\n", name: "t.tsv").rows == [["1", "2"]])
    }

    @Test func encodings() {
        #expect(CSV.decode(Data([0xEF, 0xBB, 0xBF]) + Data("a,b".utf8)) == "a,b")
        let sjis = "名前,値".data(using: .shiftJIS)!
        #expect(CSV.decode(sjis) == "名前,値")
    }

    @Test func columnTypes() {
        #expect(ColumnType.infer(["1", "2", ""]) == .integer)
        #expect(ColumnType.infer(["1", "2.5"]) == .number)
        #expect(ColumnType.infer(["1,234", "12.5%"]) == .number)
        #expect(ColumnType.infer(["1,000", "2,000"]) == .integer)
        #expect(ColumnType.infer(["true", "No", "YES"]) == .boolean)
        #expect(ColumnType.infer(["2026-10-01", "2026/1/2 3:04", "2026-01-02T03:04:05"]) == .date)
        #expect(ColumnType.infer(["1", "x"]) == .text)
        #expect(ColumnType.infer(["", ""]) == .text)
        #expect(ColumnType.infer(["1e3", "2"]) == .number)
    }

    @Test func numberParsing() {
        #expect(ColumnType.number("1,234.5") == 1234.5)
        #expect(ColumnType.number("12.5%") == 12.5)
        #expect(ColumnType.number("1,23") == nil)        // not a thousands group
        #expect(ColumnType.number(",1") == nil)
        #expect(ColumnType.number("1,234,567") == 1_234_567)
        #expect(ColumnType.integer("1,000") == 1000)
        #expect(ColumnType.integer("1.5") == nil)
        #expect(ColumnType.dateParts("2026-10-01") == [2026, 10, 1])
        #expect(ColumnType.dateParts("2026/10/01 12:30") == [2026, 10, 1, 12, 30])
        #expect(ColumnType.dateParts("2026-13-01") == nil)
        #expect(ColumnType.dateParts("10-01-2026") == nil)
    }

    @Test func inferTypesOnTable() {
        var t = TableData(header: ["n", "s"], rows: [["1", "a"], ["2", "b"]], totalRows: 3)
        t.inferTypes()
        #expect(t.types == [.integer, .text])
        #expect(t.columnCount == 2)
    }
}
