import Compression
import Foundation

/// Minimal zip reader for xlsx (a zip of XML files): central directory parsing, stored and
/// deflate entries, CRC-32 check. No zip64, no encryption, no dependencies — Foundation and
/// the Compression framework only. The whole archive is memory-mapped, entries are
/// decompressed on request.
struct ZipArchive {
    enum Error: Swift.Error, CustomStringConvertible {
        case notAZip, truncated, zip64Unsupported, unsupportedMethod(UInt16), entryNotFound(String), badData(String)

        var description: String {
            switch self {
            case .notAZip: return "not a zip archive"
            case .truncated: return "zip archive is truncated"
            case .zip64Unsupported: return "zip64 archives are not supported"
            case .unsupportedMethod(let m): return "unsupported zip compression method \(m)"
            case .entryNotFound(let n): return "no \(n) in the archive"
            case .badData(let n): return "\(n) is corrupt (CRC mismatch)"
            }
        }
    }

    struct Entry {
        let name: String
        let method: UInt16        // 0 stored, 8 deflate
        let compressedSize: Int
        let uncompressedSize: Int
        let crc32: UInt32
        let localHeaderOffset: Int
    }

    private let bytes: Data
    private(set) var entries: [String: Entry] = [:]
    var names: [String] { entries.keys.sorted() }

    init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        bytes = data
        entries = try Self.readCentralDirectory(data)
    }

    // MARK: - Reading

    /// The decompressed bytes of `name` (as the central directory spells it, e.g. "xl/workbook.xml").
    func data(for name: String) throws -> Data {
        guard let e = entries[name] else { throw Error.entryNotFound(name) }
        // Local header: signature(4) ver(2) flags(2) method(2) time(2) date(2) crc(4) csize(4) usize(4) nameLen(2) extraLen(2)
        let h = e.localHeaderOffset
        guard h + 30 <= bytes.count, u32(h) == 0x04034B50 else { throw Error.truncated }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        guard start + e.compressedSize <= bytes.count else { throw Error.truncated }
        let raw = bytes.subdata(in: start..<(start + e.compressedSize))
        let out: Data
        switch e.method {
        case 0: out = raw
        case 8: out = try Self.inflate(raw, expected: e.uncompressedSize)
        default: throw Error.unsupportedMethod(e.method)
        }
        guard out.count == e.uncompressedSize, Self.crc32(out) == e.crc32 else { throw Error.badData(name) }
        return out
    }

    /// Raw DEFLATE → bytes. `COMPRESSION_ZLIB` in the Compression framework is the raw stream
    /// (no zlib header), which is exactly what zip stores.
    private static func inflate(_ src: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var out = Data(count: expected)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            src.withUnsafeBytes { s -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expected else { throw Error.truncated }
        return out
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ d: Data) throws -> [String: Entry] {
        // End of central directory record: signature 0x06054B50, at the end minus the comment.
        guard d.count >= 22 else { throw Error.notAZip }
        var eocd = -1
        var i = d.count - 22
        let floor = max(0, d.count - 22 - 65_535)
        while i >= floor {
            if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x05, d[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Error.notAZip }
        let count = Int(le16(d, eocd + 10))
        let dirSize = Int(le32(d, eocd + 12))
        let dirOffset = Int(le32(d, eocd + 16))
        if count == 0xFFFF || dirSize == 0xFFFF_FFFF || dirOffset == 0xFFFF_FFFF { throw Error.zip64Unsupported }
        guard dirOffset + dirSize <= d.count else { throw Error.truncated }

        var entries: [String: Entry] = [:]
        var p = dirOffset
        for _ in 0..<count {
            // signature(4) verMade(2) verNeed(2) flags(2) method(2) time(2) date(2) crc(4) csize(4) usize(4)
            // nameLen(2) extraLen(2) commentLen(2) disk(2) intAttr(2) extAttr(4) localOffset(4) name extra comment
            guard p + 46 <= d.count, le32(d, p) == 0x02014B50 else { throw Error.truncated }
            let method = le16(d, p + 10)
            let crc = le32(d, p + 16)
            let csize = Int(le32(d, p + 20))
            let usize = Int(le32(d, p + 24))
            let nameLen = Int(le16(d, p + 28)), extraLen = Int(le16(d, p + 30)), commentLen = Int(le16(d, p + 32))
            let local = Int(le32(d, p + 42))
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || local == 0xFFFF_FFFF { throw Error.zip64Unsupported }
            guard p + 46 + nameLen <= d.count else { throw Error.truncated }
            let name = String(decoding: d[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, crc32: crc, localHeaderOffset: local)
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    private func u16(_ at: Int) -> UInt16 { Self.le16(bytes, at) }
    private func u32(_ at: Int) -> UInt32 { Self.le32(bytes, at) }
    private static func le16(_ d: Data, _ at: Int) -> UInt16 { UInt16(d[at]) | UInt16(d[at + 1]) << 8 }
    private static func le32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }

    // MARK: - CRC-32 (IEEE, as zip uses)

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for b in buf { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
