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
        #expect(evaluate("SUM(A1:B1)") == nil)
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
