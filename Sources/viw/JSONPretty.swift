import Foundation

/// Re-indents JSON without round-tripping through Foundation containers, so key order
/// and number spelling survive. `JSONSerialization` is only used to validate first.
enum JSONPretty {
    /// Above this size the text is shown as-is. Re-indenting is linear and cheap; this only
    /// bounds memory (the scalar array is ~4× the input). What reaches the screen is capped
    /// separately by `DocumentController.maxDisplayLength`.
    static let maxBytes = 64 << 20

    /// Pretty-printed `text`, or nil when it is not valid JSON (or too large).
    static func format(_ text: String) -> String? {
        guard text.utf8.count <= maxBytes, let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        return reindent(text)
    }

    /// One pretty-printed record per non-empty line (JSON Lines). Lines that are not valid
    /// JSON are kept verbatim so a broken record is visible in context.
    static func formatLines(_ text: String) -> [String] {
        let tooBig = text.utf8.count > maxBytes
        return text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let s = String(line)
            guard !tooBig, let data = s.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return s }
            return reindent(s)
        }
    }

    /// Token-level re-indent of valid JSON: 2-space indent, `key: value`, one element per line,
    /// empty `{}` / `[]` kept inline. Strings (with escapes) are copied through untouched.
    static func reindent(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(chars.count + chars.count / 4)
        var depth = 0
        var i = 0
        func newline() {
            out.append("\n")
            for _ in 0..<(depth * 2) { out.append(" ") }
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"":
                out.append(c)
                i += 1
                while i < chars.count {
                    let s = chars[i]
                    out.append(s)
                    i += 1
                    if s == "\\" { if i < chars.count { out.append(chars[i]); i += 1 } }
                    else if s == "\"" { break }
                }
                continue
            case "{", "[":
                // Peek past whitespace for an immediately closing bracket → keep `{}` / `[]` inline.
                var j = i + 1
                while j < chars.count, chars[j].properties.isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out.append(c)
                    out.append(chars[j])
                    i = j + 1
                    continue
                }
                out.append(c)
                depth += 1
                newline()
            case "}", "]":
                depth = max(0, depth - 1)
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(c)
                out.append(" ")
            case " ", "\t", "\n", "\r":
                break
            default:
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }
}
