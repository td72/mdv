import AppKit
import CodeEditLanguages
import SwiftTreeSitter

/// Syntax highlighting for fenced code blocks: tree-sitter grammars and `highlights.scm`
/// queries from CodeEditLanguages, mapped onto GitHub's colors by `Theme.codeColor(for:)`.
enum Highlighter {
    struct Span {
        let range: NSRange
        /// Capture name from the query, e.g. "keyword", "string.special.key".
        let name: String
    }

    /// All highlighting runs here (parsers and compiled queries are not thread-safe).
    static let queue = DispatchQueue(label: "viw.highlight", qos: .userInitiated)
    private static var parsers: [TreeSitterLanguage: Parser] = [:]
    private static var queries: [TreeSitterLanguage: Query?] = [:]

    /// Fence info strings people actually write → grammar names (`CodeLanguage.tsName`).
    private static let aliases: [String: String] = [
        "jsonl": "json", "ndjson": "json", "jsonc": "json", "json5": "json",
        "yml": "yaml",
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "shell-session": "bash",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "python3": "python",
        "rb": "ruby", "rs": "rust", "kt": "kotlin", "kts": "kotlin",
        "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "h": "c",
        "cs": "c-sharp", "csharp": "c-sharp",
        "objective-c": "objc", "objectivec": "objc",
        "docker": "dockerfile", "golang": "go", "md": "markdown", "htm": "html", "xml": "html",
        "ml": "ocaml", "mysql": "sql", "postgresql": "sql", "postgres": "sql", "sqlite": "sql",
    ]

    /// Grammar for a fence info string ("json", "jsonl", "sh", "c++ title=..."); nil when unknown.
    static func language(for info: String?) -> CodeLanguage? {
        guard let info else { return nil }
        let first = info.lowercased().split { $0 == " " || $0 == "," || $0 == "{" || $0 == ":" }.first.map(String.init) ?? ""
        guard !first.isEmpty else { return nil }
        let name = aliases[first] ?? first
        return CodeLanguage.allLanguages.first { $0.tsName == name || $0.extensions.contains(name) }
    }

    /// `highlights.scm` for the grammar (plus the parent grammar's for C++ / Objective-C / TS / TSX),
    /// compiled once. CodeEditLanguages' own `TreeSitterModel` is not used: it concatenates the
    /// editor queries (folds, indents, locals, tags) into the same Query, which fails to compile
    /// for some grammars (Swift among them) and then yields no highlighting at all.
    private static func query(for lang: CodeLanguage, _ tsLanguage: Language) -> Query? {
        if let cached = queries[lang.id] { return cached }
        var urls: [URL] = []
        if let parent = lang.parentQueryURL { urls.append(parent) }
        if let own = lang.queryURL { urls.append(own) }
        for extra in lang.additionalHighlights ?? [] where extra.hasPrefix("highlights") { // e.g. "highlights-jsx"
            if let dir = lang.queryURL?.deletingLastPathComponent() { urls.append(dir.appendingPathComponent(extra + ".scm")) }
        }
        let source = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            if ProcessInfo.processInfo.environment["VIW_TIMING"] != nil {
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                FileHandle.standardError.write("query compile (\(lang.tsName)): \(ms) ms\n".data(using: .utf8)!)
            }
        }
        let query: Query?
        do {
            query = source.isEmpty ? nil : try Query(language: tsLanguage, data: Data(source.utf8))
        } catch {
            FileHandle.standardError.write("viw: highlight query for \(lang.tsName) failed: \(error)\n".data(using: .utf8)!)
            query = nil
        }
        queries[lang.id] = query
        return query
    }

    /// Highlight spans for `code` (UTF-16 ranges into it), least specific first so later
    /// spans may override earlier ones. Empty when the language is unknown or unparsable.
    /// Call on `queue`.
    static func spans(_ code: String, info: String?) -> [Span] {
        guard let lang = language(for: info), let tsLanguage = lang.language,
              let query = query(for: lang, tsLanguage) else { return [] }
        let parser: Parser
        if let p = parsers[lang.id] {
            parser = p
        } else {
            parser = Parser()
            guard (try? parser.setLanguage(tsLanguage)) != nil else { return [] }
            parsers[lang.id] = parser
        }
        guard let tree = parser.parse(code) else { return [] }
        return query.execute(in: tree)
            .resolve(with: .init(string: code))
            .highlights()
            .map { Span(range: $0.range, name: $0.name) }
    }
}
