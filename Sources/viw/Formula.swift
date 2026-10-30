import Foundation

/// Where a formula's references come from: the workbook. `nil` when the cell's own value
/// cannot be worked out (its formula is beyond this evaluator), `#REF!` for an unknown sheet.
protocol FormulaCells {
    func value(sheet: String?, row: Int, column: Int) -> Formula.Value?
}

/// Just enough of Excel's formula language to fill in cells that a file saved without
/// cached values (openpyxl and friends): numbers, strings, references (`A1`, `$A$1`,
/// `Sheet2!B3`, `'My sheet'!C4`), `+ - * / ^ & %`, comparisons, parentheses and the common
/// functions (`Formula.functions`), with ranges as their arguments. Anything else throws
/// `Unsupported`, and the cell stays empty with the formula text in the detail pane.
enum Formula {
    enum Value: Equatable {
        case number(Double)
        case text(String)
        case bool(Bool)
        case error(String)
        case empty
    }

    struct Ref: Equatable {
        var sheet: String?
        var row: Int      // 1-based, as written
        var column: Int   // 0-based
        var absRow = false
        var absColumn = false

        /// "B3" / "$B$3" / "Sheet!B3".
        var text: String {
            var s = ""
            if let sheet {
                let plain = sheet.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
                s = (plain ? sheet : "'" + sheet.replacingOccurrences(of: "'", with: "''") + "'") + "!"
            }
            return s + (absColumn ? "$" : "") + Formula.columnLetters(column) + (absRow ? "$" : "") + String(row)
        }
    }

    struct Unsupported: Error { let what: String }

    // MARK: - Lexer

    enum Token: Equatable {
        case number(Double)
        case string(String)
        case ref(Ref)
        case range(Ref, Ref)
        case name(String)     // function or defined name (followed by `(` for a call)
        case op(String)       // + - * / ^ & = <> < > <= >=
        case percent, lparen, rparen, comma, semicolon
    }

    /// Tokens with the source range each came from (the shifter rewrites references in place).
    static func tokenize(_ s: String) throws -> [(Token, Range<String.Index>)] {
        var out: [(Token, Range<String.Index>)] = []
        var i = s.startIndex
        func peek(_ off: Int = 0) -> Character? { s.index(i, offsetBy: off, limitedBy: s.endIndex).flatMap { $0 < s.endIndex ? s[$0] : nil } }
        while i < s.endIndex {
            let c = s[i]
            let start = i
            if c.isWhitespace { i = s.index(after: i); continue }
            if c.isNumber || (c == "." && (peek(1)?.isNumber ?? false)) {
                var j = i
                while j < s.endIndex, s[j].isNumber || s[j] == "." { j = s.index(after: j) }
                if j < s.endIndex, s[j] == "E" || s[j] == "e" { // 1E-5
                    var k = s.index(after: j)
                    if k < s.endIndex, s[k] == "+" || s[k] == "-" { k = s.index(after: k) }
                    if k < s.endIndex, s[k].isNumber { j = k; while j < s.endIndex, s[j].isNumber { j = s.index(after: j) } }
                }
                guard let v = Double(s[i..<j]) else { throw Unsupported(what: "number") }
                out.append((.number(v), i..<j)); i = j; continue
            }
            if c == "\"" {
                var j = s.index(after: i)
                var text = ""
                while j < s.endIndex {
                    if s[j] == "\"" {
                        if s.index(after: j) < s.endIndex, s[s.index(after: j)] == "\"" { text.append("\""); j = s.index(j, offsetBy: 2); continue }
                        break
                    }
                    text.append(s[j]); j = s.index(after: j)
                }
                guard j < s.endIndex else { throw Unsupported(what: "string") }
                i = s.index(after: j)
                out.append((.string(text), start..<i)); continue
            }
            if c == "'" || c.isLetter || c == "_" || c == "$" {
                // Sheet name ('quoted' or bare) followed by `!`, then a reference; or a name / function.
                var sheet: String?
                var j = i
                if c == "'" {
                    var name = ""
                    j = s.index(after: j)
                    while j < s.endIndex {
                        if s[j] == "'" {
                            if s.index(after: j) < s.endIndex, s[s.index(after: j)] == "'" { name.append("'"); j = s.index(j, offsetBy: 2); continue }
                            break
                        }
                        name.append(s[j]); j = s.index(after: j)
                    }
                    guard j < s.endIndex, s.index(after: j) < s.endIndex, s[s.index(after: j)] == "!" else { throw Unsupported(what: "quoted name") }
                    sheet = name
                    j = s.index(j, offsetBy: 2)
                } else {
                    var k = i
                    while k < s.endIndex, s[k].isLetter || s[k].isNumber || s[k] == "_" || s[k] == "." { k = s.index(after: k) }
                    if k < s.endIndex, s[k] == "!" { sheet = String(s[i..<k]); j = s.index(after: k) }
                }
                // Reference: $?[A-Z]{1,3}$?[0-9]+
                if let (ref, end) = Self.reference(in: s, from: j, sheet: sheet) {
                    var tokenEnd = end
                    if end < s.endIndex, s[end] == ":", let (ref2, end2) = Self.reference(in: s, from: s.index(after: end), sheet: sheet) {
                        out.append((.range(ref, ref2), start..<end2)); tokenEnd = end2
                    } else {
                        out.append((.ref(ref), start..<end))
                    }
                    i = tokenEnd; continue
                }
                if sheet != nil { throw Unsupported(what: "sheet reference") } // Sheet!A:A, Sheet!name
                var k = i
                while k < s.endIndex, s[k].isLetter || s[k].isNumber || s[k] == "_" || s[k] == "." { k = s.index(after: k) }
                guard k > i else { throw Unsupported(what: "character \(c)") }
                out.append((.name(String(s[i..<k])), i..<k)); i = k; continue
            }
            switch c {
            case "(": out.append((.lparen, i..<s.index(after: i)))
            case ")": out.append((.rparen, i..<s.index(after: i)))
            case ",": out.append((.comma, i..<s.index(after: i)))
            case ";": out.append((.semicolon, i..<s.index(after: i)))
            case "%": out.append((.percent, i..<s.index(after: i)))
            case "+", "-", "*", "/", "^", "&", "=": out.append((.op(String(c)), i..<s.index(after: i)))
            case "<", ">":
                if let n = peek(1), n == "=" || (c == "<" && n == ">") {
                    out.append((.op(String(c) + String(n)), i..<s.index(i, offsetBy: 2))); i = s.index(i, offsetBy: 2); continue
                }
                out.append((.op(String(c)), i..<s.index(after: i)))
            default: throw Unsupported(what: "character \(c)")
            }
            i = s.index(after: i)
        }
        return out
    }

    /// `$B$3` at `from` → the reference and where it ends; nil when the text there is not one.
    private static func reference(in s: String, from: String.Index, sheet: String?) -> (Ref, String.Index)? {
        var j = from
        var absCol = false, absRow = false
        if j < s.endIndex, s[j] == "$" { absCol = true; j = s.index(after: j) }
        var col = 0, letters = 0
        while j < s.endIndex, s[j].isLetter, s[j].isASCII, letters < 3 {
            col = col * 26 + Int(s[j].uppercased().unicodeScalars.first!.value - 64)
            letters += 1; j = s.index(after: j)
        }
        guard letters > 0 else { return nil }
        if j < s.endIndex, s[j] == "$" { absRow = true; j = s.index(after: j) }
        var row = 0, digits = 0
        while j < s.endIndex, s[j].isNumber, s[j].isASCII { row = row * 10 + Int(s[j].wholeNumberValue!); digits += 1; j = s.index(after: j) }
        guard digits > 0, row > 0 else { return nil }
        // "A1B" or "SUM1" style names are not references.
        if j < s.endIndex, s[j].isLetter || s[j] == "_" { return nil }
        return (Ref(sheet: sheet, row: row, column: col - 1, absRow: absRow, absColumn: absCol), j)
    }

    static func columnLetters(_ c: Int) -> String {
        var n = c + 1, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }

    /// A shared formula moved from its master cell to another: relative references shift.
    static func shift(_ formula: String, rows dr: Int, columns dc: Int) -> String {
        guard let tokens = try? tokenize(formula) else { return formula }
        var out = ""
        var pos = formula.startIndex
        for (token, range) in tokens {
            out += formula[pos..<range.lowerBound]
            switch token {
            case .ref(var r):
                if !r.absRow { r.row = max(1, r.row + dr) }
                if !r.absColumn { r.column = max(0, r.column + dc) }
                out += r.text
            case .range(var a, var b):
                if !a.absRow { a.row = max(1, a.row + dr) }
                if !a.absColumn { a.column = max(0, a.column + dc) }
                if !b.absRow { b.row = max(1, b.row + dr) }
                if !b.absColumn { b.column = max(0, b.column + dc) }
                var second = b; second.sheet = nil
                out += a.text + ":" + second.text
            default:
                out += formula[range]
            }
            pos = range.upperBound
        }
        out += formula[pos...]
        return out
    }

    // MARK: - Evaluation

    /// The value of `formula` (without the leading `=`), or nil when it uses something this
    /// evaluator does not do (functions, ranges in arithmetic, names).
    static func evaluate(_ formula: String, cells: FormulaCells) -> Value? {
        guard let tokens = try? tokenize(formula) else { return nil }
        var p = Parser(tokens: tokens.map(\.0), cells: cells)
        guard let v = try? p.comparison(), p.atEnd else { return nil }
        return v
    }

    private struct Parser {
        let tokens: [Token]
        let cells: FormulaCells
        var i = 0

        init(tokens: [Token], cells: FormulaCells) { self.tokens = tokens; self.cells = cells }

        var atEnd: Bool { i >= tokens.count }
        private var current: Token? { i < tokens.count ? tokens[i] : nil }
        private mutating func take() -> Token? { defer { i += 1 }; return current }
        private mutating func takeOp(_ ops: Set<String>) -> String? {
            if case .op(let o)? = current, ops.contains(o) { i += 1; return o }
            return nil
        }

        mutating func comparison() throws -> Value {
            var left = try concat()
            while let o = takeOp(["=", "<>", "<", ">", "<=", ">="]) {
                let right = try concat()
                left = compare(left, right, o)
            }
            return left
        }

        private mutating func concat() throws -> Value {
            var left = try additive()
            while takeOp(["&"]) != nil {
                let right = try additive()
                if case .error = left { continue }
                if case .error = right { left = right; continue }
                left = .text(Formula.text(of: left) + Formula.text(of: right))
            }
            return left
        }

        private mutating func additive() throws -> Value {
            var left = try term()
            while let o = takeOp(["+", "-"]) {
                let right = try term()
                left = arithmetic(left, right) { o == "+" ? $0 + $1 : $0 - $1 }
            }
            return left
        }

        private mutating func term() throws -> Value {
            var left = try power()
            while let o = takeOp(["*", "/"]) {
                let right = try power()
                if o == "/" {
                    if case .error = left { continue }
                    if let d = Formula.number(of: right), d == 0 { left = .error("#DIV/0!"); continue }
                }
                left = arithmetic(left, right) { o == "*" ? $0 * $1 : $0 / $1 }
            }
            return left
        }

        private mutating func power() throws -> Value {
            var left = try unary()
            while takeOp(["^"]) != nil {
                let right = try unary()
                left = arithmetic(left, right) { pow($0, $1) }
            }
            return left
        }

        private mutating func unary() throws -> Value {
            if let o = takeOp(["-", "+"]) {
                let v = try unary()
                if o == "+" { return v }
                return arithmetic(.number(0), v) { $0 - $1 }
            }
            return try postfix()
        }

        private mutating func postfix() throws -> Value {
            var v = try primary()
            while current == .percent { i += 1; v = arithmetic(v, .number(100)) { $0 / $1 } }
            return v
        }

        private mutating func primary() throws -> Value {
            switch take() {
            case .number(let d)?: return .number(d)
            case .string(let s)?: return .text(s)
            case .ref(let r)?:
                guard let v = cells.value(sheet: r.sheet, row: r.row, column: r.column) else { throw Unsupported(what: "reference") }
                return v
            case .lparen?:
                let v = try comparison()
                guard take() == .rparen else { throw Unsupported(what: ")") }
                return v
            case .name(let n)?:
                let upper = n.uppercased()
                if current == .lparen { i += 1; return try Formula.call(upper, try arguments()) }
                if upper == "TRUE" { return .bool(true) }
                if upper == "FALSE" { return .bool(false) }
                throw Unsupported(what: n) // defined names
            case .range?: throw Unsupported(what: "range outside a function")
            default: throw Unsupported(what: "syntax")
            }
        }

        /// `(` has been taken: the arguments up to and including `)`; a range argument becomes its cells.
        private mutating func arguments() throws -> [Arg] {
            var args: [Arg] = []
            if current == .rparen { i += 1; return args }
            while true {
                if case .range(let a, let b)? = current {
                    i += 1
                    args.append(.cells(try rangeValues(a, b)))
                } else if case .ref(let r)? = current, i + 1 < tokens.count, [.comma, .semicolon, .rparen].contains(tokens[i + 1]) {
                    // A lone reference is a one-cell range: an empty or text cell is skipped, not coerced (AVERAGE(B3) → #DIV/0!)
                    i += 1
                    args.append(.cells(try rangeValues(r, r)))
                } else {
                    args.append(.value(try comparison()))
                }
                switch take() {
                case .comma?, .semicolon?: continue
                case .rparen?: return args
                default: throw Unsupported(what: "argument list")
                }
            }
        }

        private func rangeValues(_ a: Ref, _ b: Ref) throws -> [Value] {
            let rows = min(a.row, b.row)...max(a.row, b.row), cols = min(a.column, b.column)...max(a.column, b.column)
            guard rows.count * cols.count <= 200_000 else { throw Unsupported(what: "range too large") }
            var out: [Value] = []
            out.reserveCapacity(rows.count * cols.count)
            for r in rows {
                for c in cols {
                    guard let v = cells.value(sheet: a.sheet, row: r, column: c) else { throw Unsupported(what: "reference") }
                    out.append(v)
                }
            }
            return out
        }

        private func arithmetic(_ a: Value, _ b: Value, _ f: (Double, Double) -> Double) -> Value {
            if case .error = a { return a }
            if case .error = b { return b }
            guard let x = Formula.number(of: a), let y = Formula.number(of: b) else { return .error("#VALUE!") }
            let r = f(x, y)
            return r.isFinite ? .number(r) : .error("#NUM!")
        }

        private func compare(_ a: Value, _ b: Value, _ op: String) -> Value {
            if case .error = a { return a }
            if case .error = b { return b }
            // Excel orders numbers < text < booleans; text compares case-insensitively.
            func rank(_ v: Value) -> Int { switch v { case .number, .empty: return 0; case .text: return 1; case .bool: return 2; case .error: return 3 } }
            let order: Int
            switch (a, b) {
            case (.text(let x), .text(let y)): order = x.lowercased().compare(y.lowercased()).rawValue
            case (.bool(let x), .bool(let y)): order = (x ? 1 : 0) - (y ? 1 : 0)
            case (.text(let x), .empty): order = x.isEmpty ? 0 : 1
            case (.empty, .text(let y)): order = y.isEmpty ? 0 : -1
            default:
                if rank(a) != rank(b) { order = rank(a) < rank(b) ? -1 : 1 }
                else { let x = Formula.number(of: a) ?? 0, y = Formula.number(of: b) ?? 0; order = x < y ? -1 : (x > y ? 1 : 0) }
            }
            switch op {
            case "=": return .bool(order == 0)
            case "<>": return .bool(order != 0)
            case "<": return .bool(order < 0)
            case ">": return .bool(order > 0)
            case "<=": return .bool(order <= 0)
            default: return .bool(order >= 0)
            }
        }
    }

    // MARK: - Functions

    enum Arg {
        case value(Value)
        case cells([Value]) // a range: text, booleans and empties are skipped by the numeric functions, as in Excel
    }

    /// What `call` understands (for the help / docs).
    static let functions = ["SUM", "PRODUCT", "AVERAGE", "COUNT", "COUNTA", "COUNTBLANK", "MIN", "MAX", "ABS", "INT", "SQRT", "MOD", "POWER",
                            "ROUND", "ROUNDUP", "ROUNDDOWN", "IF", "IFERROR", "AND", "OR", "NOT", "TRUE", "FALSE",
                            "LEN", "UPPER", "LOWER", "TRIM", "LEFT", "RIGHT", "MID", "CONCAT", "CONCATENATE", "TEXT", "VALUE",
                            "ISBLANK", "ISNUMBER", "ISTEXT", "ISERROR"]

    /// Numbers from the arguments: direct values coerce (and a non-number is `#VALUE!`), cells
    /// from ranges count only when they hold numbers. The first error wins.
    private static func numbers(_ args: [Arg]) -> (values: [Double], error: Value?) {
        var out: [Double] = []
        for arg in args {
            switch arg {
            case .value(let v):
                if case .error = v { return ([], v) }
                guard let d = number(of: v) else { return ([], .error("#VALUE!")) }
                out.append(d)
            case .cells(let vs):
                for v in vs {
                    if case .error = v { return ([], v) }
                    if case .number(let d) = v { out.append(d) }
                }
            }
        }
        return (out, nil)
    }

    private static func flatten(_ args: [Arg]) -> [Value] {
        args.flatMap { arg -> [Value] in
            switch arg { case .value(let v): return [v]; case .cells(let vs): return vs }
        }
    }

    /// Booleans as Excel coerces them: numbers are non-zero, "TRUE" / "FALSE" text counts, other text is nil.
    static func bool(of v: Value) -> Bool? {
        switch v {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .empty: return false
        case .text(let s): return s.uppercased() == "TRUE" ? true : (s.uppercased() == "FALSE" ? false : nil)
        case .error: return nil
        }
    }

    private static func firstError(_ vs: [Value]) -> Value? { vs.first { if case .error = $0 { return true } else { return false } } }

    private static func call(_ name: String, _ args: [Arg]) throws -> Value {
        func nums() -> (values: [Double], error: Value?) { numbers(args) }
        func arg(_ i: Int) -> Value? {
            guard i < args.count else { return nil }
            switch args[i] { case .value(let v): return v; case .cells(let vs): return vs.first ?? .empty }
        }
        func num(_ i: Int) -> Value { // one numeric argument, or the error that explains why not
            guard let v = arg(i) else { return .error("#VALUE!") }
            if case .error = v { return v }
            return number(of: v).map { .number($0) } ?? .error("#VALUE!")
        }
        func text(_ i: Int) -> String? { arg(i).map { Formula.text(of: $0) } }
        func math(_ f: ([Double]) -> Double) -> Value {
            let (xs, e) = nums()
            if let e { return e }
            let r = f(xs)
            return r.isFinite ? .number(r) : .error("#NUM!")
        }
        func round(_ mode: FloatingPointRoundingRule) -> Value {
            guard case .number(let x) = num(0) else { return num(0) }
            let digits = args.count > 1 ? num(1) : .number(0)
            guard case .number(let n) = digits else { return digits }
            let p = pow(10, Double(Int(n)))
            return .number((x * p).rounded(mode) / p)
        }

        switch name {
        case "SUM": return math { $0.reduce(0, +) }
        case "PRODUCT": return math { $0.reduce(1, *) }
        case "AVERAGE":
            let (xs, e) = nums()
            if let e { return e }
            return xs.isEmpty ? .error("#DIV/0!") : .number(xs.reduce(0, +) / Double(xs.count))
        case "MIN": return math { $0.min() ?? 0 }
        case "MAX": return math { $0.max() ?? 0 }
        case "COUNT":
            // direct arguments count when they read as numbers; cells only when they hold numbers
            var n = 0
            for a in args {
                switch a {
                case .value(let v): if case .number = v { n += 1 } else if case .text(let s) = v, ColumnType.number(s) != nil { n += 1 }
                case .cells(let vs): n += vs.filter { if case .number = $0 { return true } else { return false } }.count
                }
            }
            return .number(Double(n))
        case "COUNTA": return .number(Double(flatten(args).filter { $0 != .empty }.count))
        case "COUNTBLANK": return .number(Double(flatten(args).filter { $0 == .empty || $0 == .text("") }.count))
        case "ABS": if case .number(let x) = num(0) { return .number(abs(x)) } else { return num(0) }
        case "INT": if case .number(let x) = num(0) { return .number(x.rounded(.down)) } else { return num(0) }
        case "SQRT":
            guard case .number(let x) = num(0) else { return num(0) }
            return x < 0 ? .error("#NUM!") : .number(x.squareRoot())
        case "MOD":
            guard case .number(let a) = num(0) else { return num(0) }
            guard case .number(let b) = num(1) else { return num(1) }
            return b == 0 ? .error("#DIV/0!") : .number(a - b * (a / b).rounded(.down)) // sign follows the divisor, as in Excel
        case "POWER":
            guard case .number(let a) = num(0) else { return num(0) }
            guard case .number(let b) = num(1) else { return num(1) }
            let r = pow(a, b)
            return r.isFinite ? .number(r) : .error("#NUM!")
        case "ROUND": return round(.toNearestOrAwayFromZero)
        case "ROUNDUP": return round(.awayFromZero)
        case "ROUNDDOWN": return round(.towardZero)
        case "IF":
            guard let c = arg(0) else { throw Unsupported(what: "IF()") }
            if case .error = c { return c }
            guard let b = bool(of: c) else { return .error("#VALUE!") }
            return b ? (arg(1) ?? .bool(true)) : (arg(2) ?? .bool(false))
        case "IFERROR":
            guard let v = arg(0) else { throw Unsupported(what: "IFERROR()") }
            if case .error = v { return arg(1) ?? .empty }
            return v
        case "AND", "OR":
            let vs = flatten(args)
            if let e = firstError(vs) { return e }
            var bools: [Bool] = []
            for v in vs {
                switch v {
                case .bool(let b): bools.append(b)
                case .number(let d): bools.append(d != 0)
                case .text(let s): if let b = bool(of: .text(s)) { bools.append(b) } // other text in ranges is ignored
                default: break
                }
            }
            guard !bools.isEmpty else { return .error("#VALUE!") }
            return .bool(name == "AND" ? bools.allSatisfy { $0 } : bools.contains(true))
        case "NOT":
            guard let v = arg(0) else { throw Unsupported(what: "NOT()") }
            if case .error = v { return v }
            guard let b = bool(of: v) else { return .error("#VALUE!") }
            return .bool(!b)
        case "TRUE": return .bool(true)
        case "FALSE": return .bool(false)
        case "LEN": return text(0).map { .number(Double($0.count)) } ?? .error("#VALUE!")
        case "UPPER": return text(0).map { .text($0.uppercased()) } ?? .error("#VALUE!")
        case "LOWER": return text(0).map { .text($0.lowercased()) } ?? .error("#VALUE!")
        case "TRIM":
            guard let t = text(0) else { return .error("#VALUE!") }
            return .text(t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
        case "LEFT", "RIGHT":
            guard let t = text(0) else { return .error("#VALUE!") }
            let count = args.count > 1 ? num(1) : .number(1)
            guard case .number(let n) = count else { return count }
            guard n >= 0 else { return .error("#VALUE!") }
            return .text(name == "LEFT" ? String(t.prefix(Int(n))) : String(t.suffix(Int(n))))
        case "MID":
            guard let t = text(0) else { return .error("#VALUE!") }
            guard case .number(let start) = num(1) else { return num(1) }
            guard case .number(let n) = num(2) else { return num(2) }
            guard start >= 1, n >= 0 else { return .error("#VALUE!") }
            return .text(String(t.dropFirst(Int(start) - 1).prefix(Int(n))))
        case "CONCAT", "CONCATENATE":
            let vs = flatten(args)
            if let e = firstError(vs) { return e }
            return .text(vs.map(Formula.text(of:)).joined())
        case "TEXT":
            guard let v = arg(0), let fmt = text(1) else { return .error("#VALUE!") }
            if case .error = v { return v }
            guard let d = number(of: v) else { return .text(Formula.text(of: v)) }
            return .text(Workbook.spell(number: d, format: Workbook.Styles.parse(fmt), spelling: Workbook.Spelling(date1904: false)))
        case "VALUE":
            guard let v = arg(0) else { return .error("#VALUE!") }
            if case .error = v { return v }
            return number(of: v).map { .number($0) } ?? .error("#VALUE!")
        case "ISBLANK": return .bool(arg(0) == .empty)
        case "ISNUMBER": if case .number? = arg(0) { return .bool(true) } else { return .bool(false) }
        case "ISTEXT": if case .text? = arg(0) { return .bool(true) } else { return .bool(false) }
        case "ISERROR": if case .error? = arg(0) { return .bool(true) } else { return .bool(false) }
        default: throw Unsupported(what: name)
        }
    }

    // MARK: - Coercion

    /// Numbers as Excel coerces them: text that reads as a number counts, booleans are 1 / 0,
    /// an empty cell is 0; other text is nil (#VALUE!).
    static func number(of v: Value) -> Double? {
        switch v {
        case .number(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .text(let s): return s.isEmpty ? 0 : ColumnType.number(s.trimmingCharacters(in: .whitespaces))
        case .error: return nil
        }
    }

    static func text(of v: Value) -> String {
        switch v {
        case .number(let d): return spellGeneral(d)
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e
        case .empty: return ""
        }
    }

    /// A number the way `General` shows it: integers plain, otherwise up to 10 significant digits.
    static func spellGeneral(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        let s = String(format: "%.10g", d)
        return s.contains("e") ? String(format: "%.6E", d) : s
    }
}
