import Testing
@testable import viw

@Suite struct FormulaTokenizerTests {
    private func tokens(_ s: String) throws -> [Formula.Token] { try Formula.tokenize(s).map(\.0) }

    @Test func referencesAndOperators() throws {
        let t = try tokens("A1+$B$2*'My Sheet'!C3-Sheet2!D4")
        #expect(t == [
            .ref(.init(sheet: nil, row: 1, column: 0)), .op("+"),
            .ref(.init(sheet: nil, row: 2, column: 1, absRow: true, absColumn: true)), .op("*"),
            .ref(.init(sheet: "My Sheet", row: 3, column: 2)), .op("-"),
            .ref(.init(sheet: "Sheet2", row: 4, column: 3)),
        ])
    }

    @Test func stringsNumbersAndComparisons() throws {
        #expect(try tokens(#""a""b"&"c""#) == [.string("a\"b"), .op("&"), .string("c")])
        #expect(try tokens("1.5E-3<>2<=3>=4<5>6=7") == [
            .number(0.0015), .op("<>"), .number(2), .op("<="), .number(3), .op(">="), .number(4), .op("<"), .number(5), .op(">"), .number(6), .op("="), .number(7),
        ])
        #expect(try tokens("10%") == [.number(10), .percent])
    }

    @Test func functionsAndRanges() throws {
        let t = try tokens("SUM(A1:B2, 3)")
        #expect(t == [.name("SUM"), .lparen, .range(.init(sheet: nil, row: 1, column: 0), .init(sheet: nil, row: 2, column: 1)), .comma, .number(3), .rparen])
        #expect(try tokens("TRUE") == [.name("TRUE")])
    }

    @Test func columnLetters() {
        #expect(Formula.columnLetters(0) == "A")
        #expect(Formula.columnLetters(25) == "Z")
        #expect(Formula.columnLetters(26) == "AA")
        #expect(Formula.columnLetters(27) == "AB")
        #expect(Formula.columnLetters(701) == "ZZ")
        #expect(Formula.columnLetters(702) == "AAA")
        #expect(Formula.Ref(sheet: "a b", row: 3, column: 1, absRow: true).text == "'a b'!B$3")
    }

    @Test func sharedFormulaShift() {
        #expect(Formula.shift("A1*10", rows: 1, columns: 0) == "A2*10")
        #expect(Formula.shift("$A$5+A5", rows: 2, columns: 0) == "$A$5+A7")
        #expect(Formula.shift("SUM(A1:B2)", rows: 0, columns: 1) == "SUM(B1:C2)")
        #expect(Formula.shift("A1&\"A1\"", rows: 1, columns: 1) == "B2&\"A1\"")
        #expect(Formula.shift("Sheet!A1+'x y'!$B2", rows: 1, columns: 1) == "Sheet!B2+'x y'!$B3")
        #expect(Formula.shift("A1", rows: -5, columns: -5) == "A1") // never off the sheet
    }
}

@Suite struct FormulaEvaluationTests {
    private func evaluate(_ s: String, _ cells: MockCells = MockCells()) -> Formula.Value? { Formula.evaluate(s, cells: cells) }

    @Test func arithmeticPrecedence() {
        #expect(evaluate("1+2*3") == .number(7))
        #expect(evaluate("(1+2)*3") == .number(9))
        #expect(evaluate("2^3^2") == .number(64))   // left to right, like Excel
        #expect(evaluate("-2^2") == .number(4))     // unary minus binds tighter than ^, like Excel
        #expect(evaluate("10/4") == .number(2.5))
        #expect(evaluate("50%*200") == .number(100))
        #expect(evaluate("1.5E2+0.5") == .number(150.5))
    }

    @Test func textAndComparison() {
        #expect(evaluate("\"a\"&1") == .text("a1"))
        #expect(evaluate("1&2") == .text("12"))
        #expect(evaluate("\"A\"=\"a\"") == .bool(true))
        #expect(evaluate("\"b\">\"a\"") == .bool(true))
        #expect(evaluate("1<\"a\"") == .bool(true))   // numbers sort before text
        #expect(evaluate("TRUE>1") == .bool(true))    // booleans after everything
        #expect(evaluate("2<>2") == .bool(false))
        #expect(evaluate("3>=3") == .bool(true))
    }

    @Test func coercionAndErrors() {
        #expect(evaluate("1+\"2\"") == .number(3))
        #expect(evaluate("\"x\"+1") == .error("#VALUE!"))
        #expect(evaluate("1/0") == .error("#DIV/0!"))
        #expect(evaluate("1/0+5") == .error("#DIV/0!"))   // errors propagate
        #expect(evaluate("\"a\"&1/0") == .error("#DIV/0!"))
        #expect(evaluate("TRUE+1") == .number(2))
        #expect(evaluate("10^400") == .error("#NUM!"))
    }

    @Test func references() {
        var cells = MockCells()
        cells.cells = ["A1": .number(2), "B1": .number(3), "C1": .text("12"), "D1": .bool(true), "Other!A1": .number(10), "E1": nil]
        cells.sheets = ["Other"]
        #expect(evaluate("A1*B1", cells) == .number(6))
        #expect(evaluate("A1+Z99", cells) == .number(2))           // empty cell is 0
        #expect(evaluate("C1+1", cells) == .number(13))            // numeric text counts
        #expect(evaluate("D1+A1", cells) == .number(3))            // TRUE is 1
        #expect(evaluate("Other!A1/A1", cells) == .number(5))
        #expect(evaluate("Nope!A1", cells) == .error("#REF!"))     // unknown sheet
        #expect(evaluate("E1+1", cells) == nil)                    // depends on something unresolvable
        #expect(evaluate("A1=\"\"", cells) == .bool(false))
        #expect(evaluate("Z9=\"\"", cells) == .bool(true))         // empty equals the empty string
    }

    @Test func unsupportedIsNil() {
        #expect(evaluate("VLOOKUP(A1,B1:C2,2)") == nil)
        #expect(evaluate("A1:B1") == nil)
        #expect(evaluate("FOO") == nil)
        #expect(evaluate("1+") == nil)
        #expect(evaluate("(1") == nil)
        #expect(evaluate("1 2") == nil)
        #expect(evaluate("TRUE") == .bool(true))
    }

    @Test func generalSpelling() {
        #expect(Formula.spellGeneral(3) == "3")
        #expect(Formula.spellGeneral(-0.0) == "0")
        #expect(Formula.spellGeneral(0.1 + 0.2) == "0.3")
        #expect(Formula.spellGeneral(1234567890123) == "1234567890123")
        #expect(Formula.spellGeneral(1e20) == "1.000000E+20")
        #expect(Formula.spellGeneral(2.5) == "2.5")
        #expect(Formula.text(of: .bool(false)) == "FALSE")
        #expect(Formula.number(of: .text(" 1,234 ")) == 1234)
        #expect(Formula.number(of: .text("abc")) == nil)
    }
}

@Suite struct FormulaFunctionTests {
    private let cells: MockCells = {
        var c = MockCells()
        // A1:C3 — numbers, text and a boolean mixed in, one empty cell
        c.cells = ["A1": .number(1), "B1": .number(2), "C1": .text("x"),
                   "A2": .number(3), "B2": .text("4"), "C2": .bool(true),
                   "A3": .number(5), "B3": .empty, "C3": .number(-2),
                   "D1": .error("#DIV/0!"), "E1": .text("  a   b  ")]
        return c
    }()
    private func evaluate(_ s: String) -> Formula.Value? { Formula.evaluate(s, cells: cells) }

    @Test func aggregates() {
        #expect(evaluate("SUM(A1:C3)") == .number(9))          // text / bool / empty cells are skipped
        #expect(evaluate("SUM(A1:A3, \"10\", TRUE)") == .number(20)) // direct arguments coerce
        #expect(evaluate("SUM(1;2;3)") == .number(6))            // `;` separators (some locales)
        #expect(evaluate("AVERAGE(A1:A3)") == .number(3))
        #expect(evaluate("AVERAGE(B3)") == .error("#DIV/0!"))
        #expect(evaluate("COUNT(A1:C3)") == .number(5))
        #expect(evaluate("COUNT(1, \"2\", \"x\")") == .number(2))
        #expect(evaluate("COUNTA(A1:C3)") == .number(8))
        #expect(evaluate("COUNTBLANK(A1:C3)") == .number(1))
        #expect(evaluate("MIN(A1:C3)") == .number(-2))
        #expect(evaluate("MAX(A1:C3)") == .number(5))
        #expect(evaluate("PRODUCT(A1:A3)") == .number(15))
        #expect(evaluate("SUM(A1:C3, D1)") == .error("#DIV/0!"))   // errors propagate
        #expect(evaluate("SUM(\"x\")") == .error("#VALUE!"))
    }

    @Test func mathAndRounding() {
        #expect(evaluate("ABS(C3)") == .number(2))
        #expect(evaluate("INT(-1.5)") == .number(-2))
        #expect(evaluate("SQRT(16)") == .number(4))
        #expect(evaluate("SQRT(-1)") == .error("#NUM!"))
        #expect(evaluate("MOD(-7, 3)") == .number(2))              // sign of the divisor, like Excel
        #expect(evaluate("MOD(7, 0)") == .error("#DIV/0!"))
        #expect(evaluate("POWER(2, 10)") == .number(1024))
        #expect(evaluate("ROUND(2.5)") == .number(3))              // half away from zero
        #expect(evaluate("ROUND(-2.5)") == .number(-3))
        #expect(evaluate("ROUND(1234.5678, 2)") == .number(1234.57))
        #expect(evaluate("ROUND(1234.5678, -2)") == .number(1200))
        #expect(evaluate("ROUNDUP(1.21, 1)") == .number(1.3))
        #expect(evaluate("ROUNDDOWN(-1.29, 1)") == .number(-1.2))
    }

    @Test func logic() {
        #expect(evaluate("IF(A1<B1, \"yes\", \"no\")") == .text("yes"))
        #expect(evaluate("IF(0, 1)") == .bool(false))               // the missing else is FALSE
        #expect(evaluate("IF(\"x\", 1, 2)") == .error("#VALUE!"))
        #expect(evaluate("IF(D1, 1, 2)") == .error("#DIV/0!"))
        #expect(evaluate("IF(B1=0, \"n/a\", A1/B1)") == .number(0.5))
        #expect(evaluate("IFERROR(1/0, \"-\")") == .text("-"))
        #expect(evaluate("IFERROR(A1, \"-\")") == .number(1))
        #expect(evaluate("AND(TRUE, 1, A1<B1)") == .bool(true))
        #expect(evaluate("AND(A1:B1, 0)") == .bool(false))
        #expect(evaluate("OR(FALSE, A1>B1, C2)") == .bool(true))    // C2 is TRUE
        #expect(evaluate("OR(\"x\")") == .error("#VALUE!"))
        #expect(evaluate("NOT(A1=1)") == .bool(false))
        #expect(evaluate("TRUE()") == .bool(true))
        #expect(evaluate("ISBLANK(B3)") == .bool(true))
        #expect(evaluate("ISNUMBER(B2)") == .bool(false))           // "4" is text
        #expect(evaluate("ISTEXT(B2)") == .bool(true))
        #expect(evaluate("ISERROR(D1)") == .bool(true))
    }

    @Test func text() {
        #expect(evaluate("LEN(\"héllo\")") == .number(5))
        #expect(evaluate("LEN(A1)") == .number(1))
        #expect(evaluate("UPPER(\"aé\")") == .text("AÉ"))
        #expect(evaluate("LOWER(\"ÀB\")") == .text("àb"))
        #expect(evaluate("TRIM(E1)") == .text("a b"))
        #expect(evaluate("LEFT(\"abc\")") == .text("a"))
        #expect(evaluate("LEFT(\"abc\", 2)") == .text("ab"))
        #expect(evaluate("RIGHT(\"abc\", 5)") == .text("abc"))
        #expect(evaluate("MID(\"abcdef\", 2, 3)") == .text("bcd"))
        #expect(evaluate("MID(\"abc\", 0, 1)") == .error("#VALUE!"))
        #expect(evaluate("CONCAT(A1:B1, \"-\", C2)") == .text("12-TRUE"))
        #expect(evaluate("CONCATENATE(\"a\", 1.5)") == .text("a1.5"))
        #expect(evaluate("TEXT(18000, \"#,##0\")") == .text("18,000"))
        #expect(evaluate("TEXT(0.125, \"0.0%\")") == .text("12.5%"))
        #expect(evaluate("TEXT(45000, \"yyyy-mm-dd\")") == .text("2023-03-15"))
        #expect(evaluate("TEXT(\"x\", \"0\")") == .text("x"))
        #expect(evaluate("VALUE(\"1,234\")") == .number(1234))
        #expect(evaluate("VALUE(\"abc\")") == .error("#VALUE!"))
    }

    @Test func nestingAndCase() {
        #expect(evaluate("sum(Round(a1*10/3, 0), max(A2:A3))") == .number(8))
        #expect(evaluate("SUM()") == .number(0))
        #expect(evaluate("SUM(A1:A3") == nil)                        // unbalanced
        #expect(evaluate("SUM(A1:A3)+A1:A3") == nil)                  // a range outside a function
        #expect(evaluate("IF(TRUE, 1, VLOOKUP(1,A1:B2,2))") == nil)  // an unsupported branch still fails the formula
    }
}
