import AppKit

/// Visual parameters for rendering. All colors are dynamic (light/dark aware).
struct Theme {
    var baseSize: CGFloat = 15

    static let defaultsKey = "mdv.baseSize"

    static func load() -> Theme {
        var t = Theme()
        let saved = UserDefaults.standard.double(forKey: defaultsKey)
        if saved >= 8, saved <= 48 { t.baseSize = CGFloat(saved) }
        return t
    }

    func save() { UserDefaults.standard.set(Double(baseSize), forKey: Theme.defaultsKey) }

    var body: NSFont { .systemFont(ofSize: baseSize) }
    var mono: NSFont { .monospacedSystemFont(ofSize: (baseSize * 0.88).rounded(), weight: .regular) }
    var lineHeight: CGFloat { (baseSize * 1.5).rounded() }

    func heading(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [2.0, 1.55, 1.3, 1.1, 1.0, 0.9]
        let i = max(1, min(level, 6)) - 1
        return .systemFont(ofSize: (baseSize * scale[i]).rounded(), weight: level <= 2 ? .bold : .semibold)
    }

    var text: NSColor { .labelColor }
    var secondary: NSColor { .secondaryLabelColor }
    var separator: NSColor { .separatorColor }
    var quoteBar: NSColor { .tertiaryLabelColor }
    var link: NSColor { .linkColor }

    var codeBackground: NSColor {
        Theme.dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.08))
    }
    var tableHeaderBackground: NSColor {
        Theme.dynamic(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.06))
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
