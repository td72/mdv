import Foundation
import Testing
@testable import viw

/// A file under Tests/viwTests/Fixtures.
func fixture(_ name: String) throws -> URL {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    let url = Bundle.module.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil, subdirectory: "Fixtures")
    return try #require(url, "fixture \(name)")
}

/// `FormulaCells` over a dictionary: "A1" for the current sheet, "Sheet!A1" for others.
/// Unknown sheets are `#REF!`; a value of `nil` marks a cell the evaluator cannot resolve.
struct MockCells: FormulaCells {
    var cells: [String: Formula.Value?] = [:]
    var sheets: Set<String> = []

    func value(sheet: String?, row: Int, column: Int) -> Formula.Value? {
        if let sheet, !sheets.contains(sheet) { return .error("#REF!") }
        let key = (sheet.map { $0 + "!" } ?? "") + Formula.columnLetters(column) + String(row)
        guard let v = cells[key] else { return .empty }
        return v
    }
}
