import Foundation
import Testing
@testable import viw

/// `sample.xlsx` is written by openpyxl (see the generator in the PR that added it): shared
/// strings, number formats, a hidden sheet and a Formulas sheet without cached values.
/// `edge.xlsx` is hand-written XML covering the cell types and the odd corners.
@Suite struct WorkbookTests {
    @Test func sampleSheetsAndValues() throws {
        let wb = try Workbook(url: try fixture("sample.xlsx"))
        #expect(wb.sheets.map(\.name) == ["売上", "Regions", "Notes", "Formulas"])
        #expect(wb.sheets.map(\.hidden) == [false, false, true, false])

        let sales = try wb.table(forSheet: 0)
        #expect(sales.header == ["日付", "商品", "数量", "単価", "金額", "割引率", "在庫あり", "備考"])
        #expect(sales.rows.count == 6)
        #expect(sales.rows[0] == ["2026-10-01", "りんご", "120", "150", "18,000", "5.0%", "TRUE", "青森産。朝採れ"])
        #expect(sales.rows[2][7] == "フィリピン産\n箱入り (20本)")
        #expect(sales.types == [.date, .text, .integer, .integer, .integer, .number, .boolean, .text])
        #expect(sales.columnWidths[0] == 12)
        #expect(sales.columnWidths[2] == nil)

        let regions = try wb.table(forSheet: 1)
        #expect(regions.rows[0][1] == "1,250.50")
        #expect(regions.rows[0][6] == "22.25%")
        #expect(regions.rows[0][7] == "2026-10-28 09:30")
        #expect(regions.rows[5][0] == "merged title cell")
        #expect(regions.rows[5][2] == "0.3")              // 0.1 + 0.2 under General
        #expect(regions.rows[5][3] == "1234567890123")     // integers stay exact
        #expect(regions.rows[5][4] == "25888.7")           // =SUM(B2:E5) with no cached value, evaluated
        #expect(regions.formulas[5]?[4] == "SUM(B2:E5)")
    }

    @Test func formulasWithoutCachedValues() throws {
        let wb = try Workbook(url: try fixture("sample.xlsx"))
        let t = try wb.table(forSheet: 3)
        #expect(t.header == ["item", "qty", "price", "total", "check"])
        #expect(t.rows[0] == ["apple", "120", "150", "18000", "apple x 120"])
        #expect(t.rows[1][4] == "FALSE")
        #expect(t.rows[2] == ["sum", "150", "151", "24000", "135"])
        #expect(t.rows[3] == ["cross", "120", "18000", "15", "#DIV/0!"])   // other sheet, quoted name
        #expect(t.rows[4] == ["chain", "240", "57600", "-18000", "TRUE"])
        #expect(t.rows[5] == ["func", "150", "3", "TRUE", "#REF!"])         // SUM over a range; E7/E8 circular
        #expect(t.rows[6][1] == "#REF!")
        #expect(t.rows[7] == ["func2", "many", "2571.43", "8", "18,000"])
        #expect(t.formulas[0]?[3] == "B2*C2")
        #expect(t.formulas[3]?[2] == "'売上'!E2")
        #expect(t.formulas[5]?[1] == "SUM(B2:B3)")
        #expect(t.formulas[0]?[0] == nil)
    }

    @Test func edgeCellTypesAndFormats() throws {
        let wb = try Workbook(url: try fixture("edge.xlsx"))
        #expect(wb.sheets.map(\.name) == ["Types & formats", "Sparse"]) // the chartsheet is skipped
        let t = try wb.table(forSheet: 0)
        #expect(t.header == ["plain", "rich text runs", "東京", "  spaces  ", "inline", "inline rich", "ab", "TRUE", "FALSE", "#DIV/0!", "2026-10-28T12:00:00", "3.5"])
        // 1904 date system; builtin and custom formats; [h] elapsed; text format keeps "00123"
        #expect(t.rows[0] == ["2025-11-01", "2025-11-01 18:00", "2025-11-01", "2025-11-01", "12.34%", "1,234,568", "-1,234.6", "36:00:00", "98,000", "00123", "12345.678", "0.3"])
        #expect(t.rows[1][0] == "1234567890123")
        #expect(t.rows[1][1] == "1.5E-7")   // General keeps the stored spelling when it would change
        #expect(t.rows[1][2] == "0")        // -0
        #expect(t.rows[1][4] == "100.00%")
        #expect(t.rows[1][5] == "1,000")
        #expect(t.rows[1][6] == "0.0")
        #expect(t.rows[1][7] == "0:00:01")
        #expect(t.rows[2].allSatisfy { $0.isEmpty }) // row 4: formatting-only cells, kept because rows below have content
    }

    @Test func sharedFormulasAndCachedValues() throws {
        let wb = try Workbook(url: try fixture("edge.xlsx"))
        let t = try wb.table(forSheet: 0)
        // sheet rows 5–7 are data rows 3–5
        #expect(t.rows[3].prefix(5) == ["1", "10", "2", "999", "cached"])   // cached values win over evaluation
        #expect(t.rows[4].prefix(4) == ["2", "20", "3", "20,000"])          // evaluated, then formatted (#,##0)
        #expect(t.rows[5].prefix(5) == ["3", "30", "4", "2", "6"])          // Sparse!B3+1, 'Types & formats'!A7*2
        #expect(t.formulas[3]?[1] == "A5*10")
        #expect(t.formulas[4]?[1] == "A6*10")        // shared formula, shifted from the master
        #expect(t.formulas[5]?[2] == "$A$5+A7")      // absolute part stays
        #expect(t.formulas[3]?[3] == "A5*100")
        #expect(t.formulas[5]?[4] == "'Types & formats'!A7*2")
    }

    @Test func sparseSheet() throws {
        let wb = try Workbook(url: try fixture("edge.xlsx"))
        let t = try wb.table(forSheet: 1)
        #expect(t.header == ["h1", "h2", "", "h4"])       // cells without r= follow the previous one
        #expect(t.rows.count == 4)                        // formatting-only rows at the end are dropped
        #expect(t.rows[0] == ["", "", "", ""])            // a skipped row number stays an empty row
        #expect(t.rows[1] == ["", "1", "2", ""])
        #expect(t.rows[3] == ["5", "", "", ""])           // the formatting-only Z5 does not widen the table
        #expect(t.totalRows == 5)
    }

    @Test func numberFormatClassification() {
        typealias F = Workbook.Styles.Format
        #expect(Workbook.Styles.parse("General") == .general)
        #expect(Workbook.Styles.parse("0.00") == .number(decimals: 2, grouping: false, percent: false))
        #expect(Workbook.Styles.parse("#,##0") == .number(decimals: 0, grouping: true, percent: false))
        #expect(Workbook.Styles.parse("0.0%") == .number(decimals: 1, grouping: false, percent: true))
        #expect(Workbook.Styles.parse("#,##0.0_);[Red]\\(#,##0.0\\)") == .number(decimals: 1, grouping: true, percent: false))
        #expect(Workbook.Styles.parse("\"¥\"#,##0;\"¥\"\\-#,##0") == .number(decimals: 0, grouping: true, percent: false))
        #expect(Workbook.Styles.parse("yyyy\"年\"m\"月\"d\"日\"") == .date(date: true, time: false, seconds: false, elapsed: false))
        #expect(Workbook.Styles.parse("[$-411]ge.m.d;@") == .date(date: true, time: false, seconds: false, elapsed: false))
        #expect(Workbook.Styles.parse("h:mm:ss AM/PM") == .date(date: false, time: true, seconds: true, elapsed: false))
        #expect(Workbook.Styles.parse("m/d/yy h:mm") == .date(date: true, time: true, seconds: false, elapsed: false))
        #expect(Workbook.Styles.parse("[h]:mm:ss") == .date(date: false, time: true, seconds: true, elapsed: true))
        #expect(Workbook.Styles.parse("@") == .text)
        #expect(Workbook.Styles.parse("0.00E+00") == .general)
        #expect(Workbook.Styles.format(forNumFmt: 14, code: nil) == .date(date: true, time: false, seconds: false, elapsed: false))
        #expect(Workbook.Styles.format(forNumFmt: 10, code: nil) == .number(decimals: 2, grouping: false, percent: true))
    }

    @Test func dateSerials() {
        #expect(Workbook.spellDate(serial: 45000, date: true, time: false, seconds: false, elapsed: false, date1904: false) == "2023-03-15")
        #expect(Workbook.spellDate(serial: 59, date: true, time: false, seconds: false, elapsed: false, date1904: false) == "1900-02-28")
        #expect(Workbook.spellDate(serial: 61, date: true, time: false, seconds: false, elapsed: false, date1904: false) == "1900-03-01")
        #expect(Workbook.spellDate(serial: 44500, date: true, time: false, seconds: false, elapsed: false, date1904: true) == "2025-11-01")
        #expect(Workbook.spellDate(serial: 0.75, date: false, time: true, seconds: true, elapsed: false, date1904: false) == "18:00:00")
        #expect(Workbook.spellDate(serial: 1.5, date: false, time: true, seconds: true, elapsed: true, date1904: false) == "36:00:00")
        #expect(Workbook.spellDate(serial: 45000.999999, date: true, time: true, seconds: false, elapsed: false, date1904: false) == "2023-03-16 00:00") // rounds up into the next day
        #expect(Workbook.civil(fromDays: 0) == (1970, 1, 1))
        #expect(Workbook.civil(fromDays: -1) == (1969, 12, 31))
    }

    @Test func cellReferences() {
        #expect(Workbook.reference("A1")! == (0, 1))
        #expect(Workbook.reference("AB12")! == (27, 12))
        #expect(Workbook.reference("zz3")! == (701, 3))
        #expect(Workbook.reference("12") == nil)
        #expect(Workbook.reference("A") == nil)
        #expect(Workbook.reference("A0") == nil)
    }
}
