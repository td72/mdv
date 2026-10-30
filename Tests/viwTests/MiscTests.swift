import Foundation
import Testing
@testable import viw

@Suite struct JSONPrettyTests {
    @Test func keepsKeyOrderAndNumberSpelling() throws {
        let out = try #require(JSONPretty.format(#"{"b":1,"a":[1,2,{"c":null}],"n":1.50,"big":12345678901234567890}"#))
        let b = try #require(out.range(of: "\"b\""))
        let a = try #require(out.range(of: "\"a\""))
        #expect(b.lowerBound < a.lowerBound)
        #expect(out.contains("1.50"))                    // not re-serialised as 1.5
        #expect(out.contains("12345678901234567890"))    // not rounded through Double
        #expect(out.contains("null"))
        #expect(out.hasPrefix("{\n"))
    }

    @Test func invalidJSONIsNil() {
        #expect(JSONPretty.format("not json") == nil)
        #expect(JSONPretty.format("{\"a\": }") == nil)
    }

    @Test func jsonLines() {
        let lines = JSONPretty.formatLines("{\"a\":1}\nbroken\n\n{\"b\":[1,2]}\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("\"a\": 1"))
        #expect(lines[1] == "broken")                    // shown as written
        #expect(lines[2].contains("\"b\""))
    }
}

@Suite struct ZipArchiveTests {
    @Test func entriesAndData() throws {
        let zip = try ZipArchive(url: try fixture("mixed.zip"))
        #expect(zip.names == ["deflate.txt", "dir/日本語.txt", "empty.txt", "stored.txt"])
        #expect(zip.entries["stored.txt"]?.method == 0)
        #expect(zip.entries["deflate.txt"]?.method == 8)
        #expect(try zip.data(for: "stored.txt") == Data("stored bytes".utf8))
        #expect(try zip.data(for: "deflate.txt") == Data(String(repeating: "hello zip\n", count: 500).utf8))
        #expect(try zip.data(for: "dir/日本語.txt") == Data("こんにちは".utf8))
        #expect(try zip.data(for: "empty.txt").isEmpty)
        #expect(throws: ZipArchive.Error.self) { try zip.data(for: "missing.txt") }
    }

    @Test func corruptArchives() throws {
        let bad = try ZipArchive(url: try fixture("badcrc.zip"))
        #expect(throws: ZipArchive.Error.self) { try bad.data(for: "stored.txt") }
        #expect(try bad.data(for: "deflate.txt").count == 5000)     // the other entries are fine
        #expect(throws: ZipArchive.Error.self) { try ZipArchive(url: try fixture("truncated.zip")) }
        #expect(throws: ZipArchive.Error.self) { try ZipArchive(data: Data("PK but not a zip".utf8)) }
    }

    @Test func crc32() {
        #expect(ZipArchive.crc32(Data()) == 0)
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)  // the standard check value
    }
}

@Suite struct ConfigTests {
    @Test func parsesFlatToml() {
        let c = Config.parse("""
        # comment
        font = "Hiragino Sans"   # trailing comment
        code_font = 'JetBrains Mono'
        size = 15
        code-scale = 0.9
        max_width = 100000
        detail_pane = "Bottom"
        pdf_mode = "sideways"
        close_empty = "keep"
        [section]
        ignored = 1
        """)
        #expect(c.font == "Hiragino Sans")
        #expect(c.codeFont == "JetBrains Mono")
        #expect(c.size == 15)
        #expect(c.codeScale == 0.9)             // `-` and `_` are the same key
        #expect(c.maxWidth == 10_000)           // clamped
        #expect(c.detailPane == "bottom")
        #expect(c.pdfMode == nil)               // unknown value is dropped
        #expect(c.closeEmpty == "keep")
    }

    @Test func emptyAndOdd() {
        let c = Config.parse("font = \"\"\nsize = big\nfont = \"a # not a comment\"\n")
        #expect(c.font == "a # not a comment")
        #expect(c.size == nil)
    }
}

@Suite struct HighlighterTests {
    @Test func languageAliases() {
        #expect(Highlighter.language(for: "jsonl")?.tsName == "json")
        #expect(Highlighter.language(for: "Dockerfile")?.tsName == "dockerfile")
        #expect(Highlighter.language(for: "cxx")?.tsName == "cpp")
        #expect(Highlighter.language(for: "zsh")?.tsName == "bash")
        #expect(Highlighter.language(for: "c++ title=\"x\"")?.tsName == "cpp")
        #expect(Highlighter.language(for: "py")?.tsName == "python")
        #expect(Highlighter.language(for: "nope123") == nil)
        #expect(Highlighter.language(for: nil) == nil)
    }
}

@Suite struct FileKindTests {
    private func kind(_ name: String) -> FileKind { FileKind.of(URL(fileURLWithPath: "/x/" + name)) }

    @Test func byExtension() {
        #expect({ if case .markdown = kind("README.md") { return true } else { return false } }())
        #expect({ if case .markdown = kind("LICENSE") { return true } else { return false } }())
        #expect({ if case .code("Dockerfile") = kind("Dockerfile") { return true } else { return false } }())
        #expect({ if case .code("swift") = kind("a.swift") { return true } else { return false } }())
        #expect({ if case .json = kind("a.json") { return true } else { return false } }())
        #expect({ if case .json = kind("a.json5") { return true } else { return false } }())
        #expect({ if case .markdown = kind("a.mdwn") { return true } else { return false } }())
        #expect({ if case .code("jl") = kind("a.jl") { return true } else { return false } }())
        #expect({ if case .code("pl") = kind("a.pl") { return true } else { return false } }())
        #expect({ if case .code("ts") = kind("a.ts") { return true } else { return false } }())   // TypeScript, not MPEG-TS
        #expect({ if case .code("c++") = kind("a.c++") { return true } else { return false } }())
        #expect({ if case .code("xml") = kind("a.xml") { return true } else { return false } }())
        #expect({ if case .jsonl = kind("a.ndjson") { return true } else { return false } }())
        #expect({ if case .table = kind("a.tsv") { return true } else { return false } }())
        #expect({ if case .workbook = kind("a.XLSX") { return true } else { return false } }())
        #expect({ if case .pdf = kind("a.pdf") { return true } else { return false } }())
        #expect({ if case .image = kind("a.webp") { return true } else { return false } }())
        #expect({ if case .video = kind("a.mkv") { return true } else { return false } }())
        #expect({ if case .audio = kind("a.flac") { return true } else { return false } }())
        #expect({ if case .plain = kind("a.unknownext") { return true } else { return false } }())
        #expect(!kind("a.unknownext").isViewable)
    }
}
