import Foundation
import AVFoundation

struct RawTags: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var grouping: String?
    var comment: String?
    var key: String?
    var bpm: Double?

    var isEmpty: Bool { title == nil && artist == nil && genre == nil && bpm == nil && key == nil }

    mutating func set(_ kp: WritableKeyPath<RawTags, String?>, _ value: String?) {
        guard let v = value?.trimmed, !v.isEmpty, self[keyPath: kp] == nil else { return }
        self[keyPath: kp] = v
    }

    mutating func setBPM(_ value: String?) {
        guard bpm == nil, let s = value?.trimmed.replacingOccurrences(of: ",", with: "."),
              var v = Double(s), v > 0 else { return }
        if v > 300, (40...250).contains(v / 100) { v /= 100 }
        if (40...250).contains(v) { bpm = v }
    }

    mutating func fill(from o: RawTags) {
        set(\.title, o.title); set(\.artist, o.artist); set(\.album, o.album)
        set(\.genre, o.genre); set(\.grouping, o.grouping); set(\.comment, o.comment); set(\.key, o.key)
        if bpm == nil { bpm = o.bpm }
    }
}

enum TagReader {
    static func read(url: URL) async -> RawTags {
        let ext = url.pathExtension.lowercased()
        var tags = RawTags()
        switch ext {
        case "mp3":
            tags = ID3Parser.readFile(url: url) ?? RawTags()
        case "flac":
            tags = FLACParser.read(url: url) ?? RawTags()
        case "wav", "wave", "aif", "aiff", "aifc":
            tags = ChunkParser.read(url: url) ?? RawTags()
        default:
            break
        }
        if tags.isEmpty {
            tags.fill(from: await readAVFoundation(url: url))
        }
        return tags
    }

    static func readAVFoundation(url: URL) async -> RawTags {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return RawTags() }
        var r = RawTags()
        for item in items {
            let str: String? = (try? await item.load(.stringValue)) ?? nil
            let num: NSNumber? = (try? await item.load(.numberValue)) ?? nil
            guard let id = item.identifier else { continue }
            switch id {
            case .commonIdentifierTitle, .iTunesMetadataSongName, .id3MetadataTitleDescription, .quickTimeMetadataTitle:
                r.set(\.title, str)
            case .commonIdentifierArtist, .iTunesMetadataArtist, .id3MetadataLeadPerformer, .quickTimeMetadataArtist:
                r.set(\.artist, str)
            case .commonIdentifierAlbumName, .iTunesMetadataAlbum, .id3MetadataAlbumTitle:
                r.set(\.album, str)
            case .iTunesMetadataUserGenre, .quickTimeMetadataGenre:
                r.set(\.genre, str)
            case .id3MetadataContentType:
                r.set(\.genre, str.map(Categories.resolveID3Genre))
            case .iTunesMetadataPredefinedGenre:
                if let n = num?.intValue { r.set(\.genre, ID3Genres.name(n - 1)) }
            case .iTunesMetadataGrouping, .id3MetadataContentGroupDescription:
                r.set(\.grouping, str)
            case .iTunesMetadataUserComment, .id3MetadataComments:
                r.set(\.comment, str)
            case .id3MetadataInitialKey:
                r.set(\.key, str)
            case .iTunesMetadataBeatsPerMin, .id3MetadataBeatsPerMinute:
                if let n = num?.doubleValue, n > 0 { r.setBPM(String(n)) } else { r.setBPM(str) }
            default:
                let raw = id.rawValue.lowercased()
                if raw.contains("initialkey") { r.set(\.key, str) }
                else if raw.hasSuffix("bpm") { r.setBPM(str ?? num?.stringValue) }
            }
        }
        return r
    }
}

// MARK: - Pomocnicze funkcje bajtowe

enum Bytes {
    static func be32(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 3 < b.count else { return 0 }
        return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }
    static func le32(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 3 < b.count else { return 0 }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }
    static func synchsafe(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 3 < b.count else { return 0 }
        return (Int(b[o]) & 0x7f) << 21 | (Int(b[o + 1]) & 0x7f) << 14 | (Int(b[o + 2]) & 0x7f) << 7 | (Int(b[o + 3]) & 0x7f)
    }
    static func ascii(_ b: [UInt8], _ o: Int, _ n: Int) -> String {
        guard o + n <= b.count else { return "" }
        return String(bytes: b[o..<(o + n)], encoding: .ascii) ?? ""
    }
}

// MARK: - ID3v2 / ID3v1

enum ID3Parser {
    static func readFile(url: URL) -> RawTags? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 10), head.count == 10 else { return nil }
        let b = [UInt8](head)
        var tags: RawTags?
        if Bytes.ascii(b, 0, 3) == "ID3" {
            let total = min(Bytes.synchsafe(b, 6) + 10, 64 * 1024 * 1024)
            try? h.seek(toOffset: 0)
            if let data = try? h.read(upToCount: total) { tags = parse([UInt8](data)) }
        }
        if tags == nil || tags?.isEmpty == true,
           let end = try? h.seekToEnd(), end >= 128 {
            try? h.seek(toOffset: end - 128)
            if let d = try? h.read(upToCount: 128), let v1 = parseV1([UInt8](d)) {
                if tags == nil { tags = v1 } else { tags?.fill(from: v1) }
            }
        }
        return tags
    }

    static func parse(_ raw: [UInt8]) -> RawTags? {
        guard raw.count >= 10, Bytes.ascii(raw, 0, 3) == "ID3" else { return nil }
        let ver = raw[3]
        let flags = raw[5]
        guard ver >= 2 && ver <= 4 else { return nil }
        let size = Bytes.synchsafe(raw, 6)
        var b = Array(raw[10..<min(raw.count, 10 + size)])
        if flags & 0x80 != 0 && ver < 4 { b = removeUnsync(b) }

        var pos = 0
        if flags & 0x40 != 0 && ver >= 3 {
            guard b.count >= 4 else { return nil }
            pos = ver == 4 ? Bytes.synchsafe(b, 0) : Bytes.be32(b, 0) + 4
        }

        var t = RawTags()
        let hdr = ver == 2 ? 6 : 10
        let idLen = ver == 2 ? 3 : 4
        while pos >= 0, pos + hdr <= b.count {
            if b[pos] == 0 { break }
            let id = Bytes.ascii(b, pos, idLen)
            guard !id.isEmpty else { break }
            let frameSize: Int
            switch ver {
            case 2: frameSize = Int(b[pos + 3]) << 16 | Int(b[pos + 4]) << 8 | Int(b[pos + 5])
            case 4: frameSize = Bytes.synchsafe(b, pos + 4)
            default: frameSize = Bytes.be32(b, pos + 4)
            }
            let fmt: UInt8 = ver == 2 ? 0 : b[pos + 9]
            let start = pos + hdr
            let end = start + frameSize
            guard frameSize > 0, end <= b.count else { break }
            pos = end
            var f = Array(b[start..<end])
            if ver == 4 {
                if fmt & 0x0C != 0 { continue }
                if fmt & 0x40 != 0 { guard f.count > 1 else { continue }; f.removeFirst() }
                if fmt & 0x02 != 0 { f = removeUnsync(f) }
                if fmt & 0x01 != 0 { guard f.count > 4 else { continue }; f.removeFirst(4) }
            } else if ver == 3 {
                if fmt & 0xC0 != 0 { continue }
                if fmt & 0x20 != 0 { guard f.count > 1 else { continue }; f.removeFirst() }
            }
            handle(id, f, &t)
        }
        return t
    }

    static func handle(_ id: String, _ f: [UInt8], _ t: inout RawTags) {
        switch id {
        case "TIT2", "TT2": t.set(\.title, text(f))
        case "TPE1", "TP1": t.set(\.artist, text(f))
        case "TALB", "TAL": t.set(\.album, text(f))
        case "TCON", "TCO": t.set(\.genre, Categories.resolveID3Genre(text(f)))
        case "TIT1", "TT1", "GRP1": t.set(\.grouping, text(f))
        case "TKEY", "TKE": t.set(\.key, text(f))
        case "TBPM", "TBP": t.setBPM(text(f))
        case "COMM", "COM":
            guard f.count > 4 else { return }
            let enc = f[0]
            let (desc, rest) = splitTerminated(Array(f[4...]), enc)
            let d = decode(desc, enc)
            if d.hasPrefix("iTun") || d.lowercased().hasPrefix("songs-db") { return }
            t.set(\.comment, decode(rest, enc))
        case "TXXX", "TXX":
            guard f.count > 1 else { return }
            let enc = f[0]
            let (desc, rest) = splitTerminated(Array(f[1...]), enc)
            let d = decode(desc, enc).uppercased()
            let v = decode(rest, enc)
            if d == "INITIALKEY" || d == "KEY" { t.set(\.key, v) }
            else if d == "BPM" || d == "TEMPO" { t.setBPM(v) }
            else if d == "GROUPING" { t.set(\.grouping, v) }
        default:
            break
        }
    }

    static func text(_ f: [UInt8]) -> String {
        guard let enc = f.first else { return "" }
        return decode(Array(f.dropFirst()), enc)
    }

    static func decode(_ bytes: [UInt8], _ enc: UInt8) -> String {
        var b = bytes
        if (enc == 1 || enc == 2) && b.count % 2 == 1 { b.removeLast() }
        var s: String
        switch enc {
        case 0: s = String(bytes: b, encoding: .isoLatin1) ?? ""
        case 1: s = String(bytes: b, encoding: .utf16) ?? ""
        case 2: s = String(bytes: b, encoding: .utf16BigEndian) ?? ""
        default: s = String(bytes: b, encoding: .utf8) ?? String(bytes: b, encoding: .isoLatin1) ?? ""
        }
        s = s.replacingOccurrences(of: "\u{FEFF}", with: "")
        return s.components(separatedBy: "\u{0}").map { $0.trimmed }.filter { !$0.isEmpty }.joined(separator: ";")
    }

    static func splitTerminated(_ b: [UInt8], _ enc: UInt8) -> ([UInt8], [UInt8]) {
        if enc == 1 || enc == 2 {
            var i = 0
            while i + 1 < b.count {
                if b[i] == 0 && b[i + 1] == 0 { return (Array(b[0..<i]), Array(b[(i + 2)...])) }
                i += 2
            }
        } else if let i = b.firstIndex(of: 0) {
            return (Array(b[0..<i]), Array(b[(i + 1)...]))
        }
        return (b, [])
    }

    static func removeUnsync(_ b: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0 { i += 2 } else { i += 1 }
        }
        return out
    }

    static func parseV1(_ b: [UInt8]) -> RawTags? {
        guard b.count == 128, Bytes.ascii(b, 0, 3) == "TAG" else { return nil }
        func str(_ r: Range<Int>) -> String {
            let s = Array(b[r])
            let cut = s.firstIndex(of: 0) ?? s.count
            return (String(bytes: s[0..<cut], encoding: .isoLatin1) ?? "").trimmed
        }
        var t = RawTags()
        t.set(\.title, str(3..<33))
        t.set(\.artist, str(33..<63))
        t.set(\.album, str(63..<93))
        t.set(\.comment, str(97..<125))
        t.set(\.genre, ID3Genres.name(Int(b[127])))
        return t
    }
}

// MARK: - FLAC (Vorbis comments)

enum FLACParser {
    static func read(url: URL) -> RawTags? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let magic = try? h.read(upToCount: 4), String(data: magic, encoding: .ascii) == "fLaC" else { return nil }
        var offset: UInt64 = 4
        for _ in 0..<64 {
            try? h.seek(toOffset: offset)
            guard let hd = try? h.read(upToCount: 4), hd.count == 4 else { return nil }
            let b = [UInt8](hd)
            let last = b[0] & 0x80 != 0
            let type = b[0] & 0x7f
            let len = Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            if type == 4 {
                guard let d = try? h.read(upToCount: len) else { return nil }
                return parseVorbis([UInt8](d))
            }
            offset += 4 + UInt64(len)
            if last { break }
        }
        return nil
    }

    static func parseVorbis(_ b: [UInt8]) -> RawTags {
        var fields: [String: [String]] = [:]
        var pos = 0
        let vendor = Bytes.le32(b, pos)
        pos += 4 + vendor
        let count = Bytes.le32(b, pos)
        pos += 4
        var i = 0
        while i < count, pos + 4 <= b.count {
            let len = Bytes.le32(b, pos)
            pos += 4
            guard len >= 0, pos + len <= b.count else { break }
            if let s = String(bytes: b[pos..<(pos + len)], encoding: .utf8), let eq = s.firstIndex(of: "=") {
                let k = s[..<eq].uppercased()
                fields[k, default: []].append(String(s[s.index(after: eq)...]))
            }
            pos += len
            i += 1
        }
        func get(_ keys: String...) -> String? {
            for k in keys { if let v = fields[k], !v.isEmpty { return v.joined(separator: ";") } }
            return nil
        }
        var t = RawTags()
        t.set(\.title, get("TITLE"))
        t.set(\.artist, get("ARTIST", "ALBUMARTIST"))
        t.set(\.album, get("ALBUM"))
        t.set(\.genre, get("GENRE"))
        t.set(\.grouping, get("GROUPING", "CONTENTGROUP"))
        t.set(\.comment, get("COMMENT", "DESCRIPTION"))
        t.set(\.key, get("INITIALKEY", "KEY"))
        t.setBPM(get("BPM", "TEMPO", "TBPM"))
        return t
    }
}

// MARK: - WAV / AIFF (chunk "id3 " oraz RIFF LIST/INFO)

enum ChunkParser {
    static func read(url: URL) -> RawTags? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let hd = try? h.read(upToCount: 12), hd.count == 12 else { return nil }
        let b = [UInt8](hd)
        let riff = Bytes.ascii(b, 0, 4) == "RIFF" && Bytes.ascii(b, 8, 4) == "WAVE"
        let aiff = Bytes.ascii(b, 0, 4) == "FORM" && ["AIFF", "AIFC"].contains(Bytes.ascii(b, 8, 4))
        guard riff || aiff, let fileSize = try? h.seekToEnd() else { return nil }

        var id3: RawTags?
        var info = RawTags()
        var offset: UInt64 = 12
        var guardCount = 0
        while offset + 8 <= fileSize, guardCount < 512 {
            guardCount += 1
            try? h.seek(toOffset: offset)
            guard let ch = try? h.read(upToCount: 8), ch.count == 8 else { break }
            let c = [UInt8](ch)
            let cid = Bytes.ascii(c, 0, 4)
            let size = UInt64(riff ? Bytes.le32(c, 4) : Bytes.be32(c, 4))
            if cid.lowercased() == "id3 ", size < 64 * 1024 * 1024,
               let d = try? h.read(upToCount: Int(size)) {
                id3 = ID3Parser.parse([UInt8](d))
            } else if riff, cid == "LIST", size >= 4, size < 1024 * 1024,
                      let d = try? h.read(upToCount: Int(size)) {
                parseInfo([UInt8](d), into: &info)
            }
            offset += 8 + size + (size % 2)
        }
        var result = id3 ?? RawTags()
        result.fill(from: info)
        return result.isEmpty ? nil : result
    }

    static func parseInfo(_ b: [UInt8], into t: inout RawTags) {
        guard Bytes.ascii(b, 0, 4) == "INFO" else { return }
        var pos = 4
        while pos + 8 <= b.count {
            let id = Bytes.ascii(b, pos, 4)
            let len = Bytes.le32(b, pos + 4)
            let start = pos + 8
            guard len >= 0, start + len <= b.count else { break }
            let raw = Array(b[start..<(start + len)])
            let cut = raw.firstIndex(of: 0) ?? raw.count
            let s = String(bytes: raw[0..<cut], encoding: .utf8) ?? String(bytes: raw[0..<cut], encoding: .isoLatin1) ?? ""
            switch id {
            case "INAM": t.set(\.title, s)
            case "IART": t.set(\.artist, s)
            case "IPRD": t.set(\.album, s)
            case "IGNR": t.set(\.genre, s)
            case "ICMT": t.set(\.comment, s)
            default: break
            }
            pos = start + len + (len % 2)
        }
    }
}
