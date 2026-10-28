import AppKit

/// Visual parameters for rendering. All colors are dynamic (light/dark aware).
struct Theme {
    /// Current body size. Starts at `defaultSize`; `+`/`-` zoom changes it and the value persists.
    // Defaults follow GitHub's markdown CSS: 16px body, 85% code, 1.5 line height, 948px column.
    var baseSize: CGFloat = 16
    /// Size from the config file (or 16). `=` resets to this.
    var defaultSize: CGFloat = 16
    var bodyFamily: String?
    var codeFamily: String?
    var codeScale: CGFloat = 0.85
    var maxWidth: CGFloat = 948

    static let defaultsKey = "viw.baseSize"

    /// Config file first, then the persisted zoom level on top.
    static func load() -> Theme {
        var t = Theme()
        let c = Config.load()
        t.defaultSize = c.size ?? 16
        t.baseSize = t.defaultSize
        t.bodyFamily = c.font.flatMap { NSFont(name: $0, size: 12) != nil ? $0 : nil }
        t.codeFamily = c.codeFont.flatMap { NSFont(name: $0, size: 12) != nil ? $0 : nil }
        if let f = c.font, t.bodyFamily == nil { warn("font \"\(f)\" not found, using the system font") }
        if let f = c.codeFont, t.codeFamily == nil { warn("code_font \"\(f)\" not found, using SF Mono") }
        t.codeScale = c.codeScale ?? 0.85
        t.maxWidth = c.maxWidth ?? 948
        var saved = UserDefaults.standard.double(forKey: defaultsKey)
        if saved == 0 { saved = UserDefaults.standard.double(forKey: "mdv.baseSize") } // pre-rename key
        if saved >= 8, saved <= 48 { t.baseSize = CGFloat(saved) }
        return t
    }

    func save() { UserDefaults.standard.set(Double(baseSize), forKey: Theme.defaultsKey) }

    private static var warned: Set<String> = []
    private static func warn(_ msg: String) {
        guard warned.insert(msg).inserted else { return } // once per process, not on every reload
        FileHandle.standardError.write("viw: \(Config.path.path): \(msg)\n".data(using: .utf8)!)
    }

    var body: NSFont { font(bodyFamily, size: baseSize, weight: .regular) }
    var mono: NSFont { codeFont(size: (baseSize * codeScale).rounded(), weight: .regular) }
    var lineHeight: CGFloat { (baseSize * 1.5).rounded() }

    func heading(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [2.0, 1.5, 1.25, 1.0, 0.875, 0.85]
        let i = max(1, min(level, 6)) - 1
        return font(bodyFamily, size: (baseSize * scale[i]).rounded(), weight: .semibold)
    }

    func codeFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard let family = codeFamily else { return .monospacedSystemFont(ofSize: size, weight: weight) }
        return font(family, size: size, weight: weight)
    }

    /// A font of `family` (nil → system font) at the given size and weight.
    private func font(_ family: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard let family else { return .systemFont(ofSize: size, weight: weight) }
        let base = NSFont(name: family, size: size) ?? .systemFont(ofSize: size, weight: weight)
        guard weight != .regular else { return base }
        // Prefer a real bold/semibold face from the family; fall back to the regular face.
        let traits: NSFontDescriptor.SymbolicTraits = .bold
        let desc = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: size) ?? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
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

    // MARK: Syntax colors (GitHub's light / dark code palette)

    private static let syntax: [String: NSColor] = [
        "comment": hex(0x59636E, dark: 0x8B949E),
        "keyword": hex(0xCF222E, dark: 0xFF7B72),
        "include": hex(0xCF222E, dark: 0xFF7B72),
        "conditional": hex(0xCF222E, dark: 0xFF7B72),
        "repeat": hex(0xCF222E, dark: 0xFF7B72),
        "exception": hex(0xCF222E, dark: 0xFF7B72),
        "storageclass": hex(0xCF222E, dark: 0xFF7B72),
        "string": hex(0x0A3069, dark: 0xA5D6FF),
        "string.special.key": hex(0x0550AE, dark: 0x79C0FF),
        "string.escape": hex(0x0550AE, dark: 0x79C0FF),
        "string.regexp": hex(0x116329, dark: 0x7EE787),
        "escape": hex(0x0550AE, dark: 0x79C0FF),
        "property": hex(0x0550AE, dark: 0x79C0FF),
        "field": hex(0x0550AE, dark: 0x79C0FF),
        "variable.member": hex(0x0550AE, dark: 0x79C0FF),
        "variable.builtin": hex(0x0550AE, dark: 0x79C0FF),
        "number": hex(0x0550AE, dark: 0x79C0FF),
        "float": hex(0x0550AE, dark: 0x79C0FF),
        "boolean": hex(0x0550AE, dark: 0x79C0FF),
        "constant": hex(0x0550AE, dark: 0x79C0FF),
        "attribute": hex(0x0550AE, dark: 0x79C0FF),
        "function": hex(0x8250DF, dark: 0xD2A8FF),
        "method": hex(0x8250DF, dark: 0xD2A8FF),
        "constructor": hex(0x8250DF, dark: 0xD2A8FF),
        "type": hex(0x953800, dark: 0xFFA657),
        "class": hex(0x953800, dark: 0xFFA657),
        "struct": hex(0x953800, dark: 0xFFA657),
        "tag": hex(0x116329, dark: 0x7EE787),
        "label": hex(0x116329, dark: 0x7EE787),
        "text.title": hex(0x0550AE, dark: 0x79C0FF),
        "markup.heading": hex(0x0550AE, dark: 0x79C0FF),
    ]

    /// Color for a tree-sitter capture name ("string.special.key" → itself, then "string.special",
    /// then "string"); nil means plain code text (operators, punctuation, variables).
    func codeColor(for capture: String) -> NSColor? {
        var parts = capture.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            if let c = Theme.syntax[parts.joined(separator: ".")] { return c }
            parts.removeLast()
        }
        return nil
    }

    private static func hex(_ light: UInt32, dark: UInt32) -> NSColor {
        func c(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return dynamic(light: c(light), dark: c(dark))
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
