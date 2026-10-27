import Foundation

enum Categories {
    static let noGenre = "Bez gatunku"
    static let noStyle = "Bez stylu"
    static let noKey = "Brak tonacji"
    static let noBPM = "Brak BPM"

    static func isPlaceholder(_ s: String) -> Bool {
        s == noGenre || s == noStyle || s == noKey || s == noBPM
    }

    // MARK: Tempo

    static let tempoBuckets: [(label: String, lo: Double, hi: Double)] = [
        ("< 90", 0, 90), ("90–99", 90, 100), ("100–109", 100, 110), ("110–117", 110, 118),
        ("118–121", 118, 122), ("122–123", 122, 124), ("124–125", 124, 126), ("126–127", 126, 128),
        ("128–129", 128, 130), ("130–133", 130, 134), ("134–137", 134, 138), ("138–144", 138, 145),
        ("145–159", 145, 160), ("160+", 160, 10_000),
    ]

    static func tempoBucket(for bpm: Double?) -> String {
        guard let b = bpm else { return noBPM }
        let v = ((b * 10).rounded() / 10).rounded(.down)
        for t in tempoBuckets where v >= t.lo && v < t.hi { return t.label }
        return noBPM
    }

    static func formatBPM(_ b: Double) -> String {
        abs(b - b.rounded()) < 0.05 ? String(Int(b.rounded())) : String(format: "%.1f", b)
    }

    // MARK: Gatunki

    static let genreAliases: [String: String] = [
        "dnb": "Drum & Bass", "db": "Drum & Bass", "drumbass": "Drum & Bass",
        "drumandbass": "Drum & Bass", "drumnbass": "Drum & Bass",
        "hiphop": "Hip-Hop", "rnb": "R&B", "rb": "R&B", "triphop": "Trip-Hop", "lofi": "Lo-Fi",
        "techhouse": "Tech House", "deephouse": "Deep House", "progressivehouse": "Progressive House",
        "afrohouse": "Afro House", "melodichousetechno": "Melodic House & Techno",
        "melodichouseandtechno": "Melodic House & Techno", "ukgarage": "UK Garage", "ukg": "UK Garage",
        "edm": "EDM", "idm": "IDM", "ebm": "EBM", "nudisco": "Nu Disco", "bigroom": "Big Room",
        "hardtechno": "Hard Techno", "electronic": "Electronic", "electronica": "Electronica",
        "dance": "Dance", "house": "House", "techno": "Techno", "trance": "Trance",
    ]

    static func compactKey(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func normalizeGenre(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "_", with: " ")
        let s = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        guard !s.isEmpty else { return "" }
        let key = compactKey(s)
        guard !key.isEmpty else { return "" }
        if let alias = genreAliases[key] { return alias }
        if s == s.lowercased() || s == s.uppercased() { return titleCase(s) }
        return s
    }

    static func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { word -> String in
            word.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    static func splitGenres(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for part in raw.components(separatedBy: CharacterSet(charactersIn: ";,|\u{0}")) {
            let g = normalizeGenre(part)
            if !g.isEmpty, seen.insert(compactKey(g)).inserted { out.append(g) }
        }
        return out
    }

    /// TCON w ID3 bywa zapisany jako "(17)", "17" albo "(17)Rock".
    static func resolveID3Genre(_ s: String) -> String {
        var out: [String] = []
        for part in s.components(separatedBy: ";") {
            var p = part.trimmed
            var refs: [Int] = []
            while p.hasPrefix("("), let close = p.firstIndex(of: ")") {
                let inner = String(p[p.index(after: p.startIndex)..<close])
                guard Int(inner) != nil || inner == "RX" || inner == "CR" else { break }
                if let n = Int(inner) { refs.append(n) }
                p = String(p[p.index(after: close)...]).trimmed
            }
            if !p.isEmpty {
                if let n = Int(p), let name = ID3Genres.name(n) { out.append(name) } else { out.append(p) }
            } else {
                out.append(contentsOf: refs.compactMap { ID3Genres.name($0) })
            }
        }
        return out.filter { !$0.isEmpty }.joined(separator: ";")
    }

    // MARK: Tonacja (Camelot)

    static let minorCamelot = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
    static let majorCamelot = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    static let minorNames = [1: "A♭m", 2: "E♭m", 3: "B♭m", 4: "Fm", 5: "Cm", 6: "Gm",
                             7: "Dm", 8: "Am", 9: "Em", 10: "Bm", 11: "F♯m", 12: "D♭m"]
    static let majorNames = [1: "B", 2: "F♯", 3: "D♭", 4: "A♭", 5: "E♭", 6: "B♭",
                             7: "F", 8: "C", 9: "G", 10: "D", 11: "A", 12: "E"]

    static func camelot(fromKey raw: String) -> String? {
        var s = raw.lowercased().trimmed
        s = s.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        s = s.replacingOccurrences(of: " ", with: "")
        for (a, b) in [("minor", "m"), ("min", "m"), ("major", ""), ("maj", "")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        guard let first = s.first else { return nil }

        if first.isNumber {
            let digits = s.prefix { $0.isNumber }
            let rest = s.dropFirst(digits.count)
            guard let n = Int(digits), (1...12).contains(n), rest.count == 1, let l = rest.first else { return nil }
            let fromOpenKey = ((n + 6) % 12) + 1
            switch l {
            case "a": return "\(n)A"
            case "b": return "\(n)B"
            case "m": return "\(fromOpenKey)A"
            case "d": return "\(fromOpenKey)B"
            default: return nil
            }
        }

        let chars = Array(s)
        let base: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]
        guard let p0 = base[chars[0]] else { return nil }
        var pc = p0
        var i = 1
        if i < chars.count, chars[i] == "#" { pc += 1; i += 1 }
        else if i < chars.count, chars[i] == "b" { pc -= 1; i += 1 }
        pc = (pc + 12) % 12
        let rest = String(chars[i...])
        if rest == "m" { return "\(minorCamelot[pc])A" }
        if rest.isEmpty { return "\(majorCamelot[pc])B" }
        return nil
    }

    /// Mixed In Key i inne programy wpisują np. "8A - Energy 6" do komentarza.
    static func camelot(fromComment comment: String) -> String? {
        guard let r = comment.range(of: #"(?<![0-9])(1[0-2]|[1-9])[AB](?![A-Za-z0-9])"#,
                                    options: .regularExpression) else { return nil }
        return camelot(fromKey: String(comment[r]))
    }

    static func parseCamelot(_ c: String) -> (Int, Bool)? {
        guard let last = c.last, let n = Int(c.dropLast()) else { return nil }
        return (n, last == "B")
    }

    static func musicalName(camelot c: String) -> String? {
        guard let p = parseCamelot(c) else { return nil }
        return p.1 ? majorNames[p.0] : minorNames[p.0]
    }

    static func camelotSortIndex(_ c: String?) -> Int {
        guard let c, let p = parseCamelot(c) else { return 999 }
        return p.0 * 2 + (p.1 ? 1 : 0)
    }

    // MARK: Sortowanie kategorii w menu

    static func sorted(facet: Facet, counts: [String: Int]) -> [CategoryCount] {
        let items = counts.map { CategoryCount(name: $0.key, count: $0.value) }
        switch facet {
        case .tempo:
            let order = Dictionary(uniqueKeysWithValues: tempoBuckets.enumerated().map { ($0.element.label, $0.offset) })
            return items.sorted { (order[$0.name] ?? 999) < (order[$1.name] ?? 999) }
        case .key:
            return items.sorted {
                camelotSortIndex($0.name == noKey ? nil : $0.name) < camelotSortIndex($1.name == noKey ? nil : $1.name)
            }
        default:
            return items.sorted { a, b in
                let pa = isPlaceholder(a.name), pb = isPlaceholder(b.name)
                if pa != pb { return !pa }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

enum ID3Genres {
    static let list = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]

    static func name(_ n: Int) -> String? {
        n >= 0 && n < list.count ? list[n] : nil
    }
}
