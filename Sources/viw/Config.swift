import Foundation

/// User configuration, read from `$XDG_CONFIG_HOME/viw/config.toml`
/// (default `~/.config/viw/config.toml`) or the file named by `VIW_CONFIG`.
///
/// Only a flat `key = value` subset of TOML is understood (strings, numbers,
/// `#` comments), so no TOML dependency is needed.
struct Config {
    var font: String?          // body font family, e.g. "Hiragino Sans"
    var codeFont: String?      // code font family, e.g. "JetBrains Mono"
    var size: CGFloat?         // base font size in points
    var codeScale: CGFloat?    // code size relative to body (default 0.88)
    var maxWidth: CGFloat?     // readable column width in points (default 900)
    var detailPane: String?    // table detail pane: "right" (default) or "bottom"

    static var path: URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["VIW_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: NSString(string: p).expandingTildeInPath) }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.config"
        let new = URL(fileURLWithPath: base + "/viw/config.toml")
        if FileManager.default.fileExists(atPath: new.path) { return new }
        // The app was called mdv before; keep reading its config until the user moves it.
        let old = URL(fileURLWithPath: base + "/mdv/config.toml")
        return FileManager.default.fileExists(atPath: old.path) ? old : new
    }

    static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: path.path) else { return Config() }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> Config {
        var c = Config()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("["), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_")
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "font": c.font = value.isEmpty ? nil : value
            case "code_font": c.codeFont = value.isEmpty ? nil : value
            case "size": c.size = number(value, min: 8, max: 48)
            case "code_scale": c.codeScale = number(value, min: 0.5, max: 1.5)
            case "max_width": c.maxWidth = number(value, min: 300, max: 10_000)
            case "detail_pane": c.detailPane = ["right", "bottom"].contains(value.lowercased()) ? value.lowercased() : nil
            default: break
            }
        }
        return c
    }

    private static func number(_ s: String, min lo: CGFloat, max hi: CGFloat) -> CGFloat? {
        guard let d = Double(s) else { return nil }
        return Swift.max(lo, Swift.min(hi, CGFloat(d)))
    }

    /// Remove a `#` comment unless the `#` is inside quotes.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        for (i, ch) in line.enumerated() {
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "#" { return String(line.prefix(i)) }
        }
        return line
    }
}
