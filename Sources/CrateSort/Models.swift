import Foundation

struct FileInfo: Sendable {
    let path: String
    let size: Int64
    let modified: Date
    let volumeID: String
    let relPath: String
}

struct Track: Identifiable, Codable, Hashable, Sendable {
    var id: String { path }

    var path: String
    var fileSize: Int64
    var modified: Date
    var addedAt: Date

    var title: String
    var artist: String
    var album: String
    var duration: Double

    // Surowe tagi z pliku
    var genreTag: String
    var groupingTag: String
    var comment: String
    var keyTag: String
    var bpmTag: Double?
    var bpmDetected: Double?

    // Wyliczone przy skanowaniu
    var genreAuto: String?
    var styleAuto: String?
    var camelot: String?

    // Ręczne zmiany (tylko w bibliotece CrateSort, pliki zostają nietknięte)
    var genreOverride: String?
    var styleOverride: String?
    var bpmOverride: Double?
    var preferDetected: Bool

    // Dysk, na którym leży plik, i ścieżka względem niego (żeby rozpoznać dysk pod inną ścieżką)
    var volumeID: String?
    var relPath: String?
}

extension Track {
    var bpm: Double? {
        if let o = bpmOverride { return o }
        if preferDetected, let d = bpmDetected { return d }
        return bpmTag ?? bpmDetected
    }

    var bpmIsDetected: Bool {
        bpmOverride == nil && (preferDetected || bpmTag == nil) && bpmDetected != nil
    }

    var genre: String {
        if let g = genreOverride?.trimmed, !g.isEmpty { return g }
        return genreAuto ?? Categories.noGenre
    }

    var style: String {
        if let s = styleOverride?.trimmed, !s.isEmpty { return s }
        return styleAuto ?? Categories.noStyle
    }

    var tempoBucket: String { Categories.tempoBucket(for: bpm) }
    var keyFacet: String { camelot ?? Categories.noKey }

    var keyDisplay: String {
        guard let c = camelot else { return "" }
        return c + "  " + (Categories.musicalName(camelot: c) ?? "")
    }

    var bpmText: String {
        guard let b = bpm else { return "" }
        return Categories.formatBPM(b)
    }

    var durationText: String {
        guard duration > 0 else { return "" }
        let s = Int(duration.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    var fileName: String { (path as NSString).lastPathComponent }
}

enum Facet: String, CaseIterable, Identifiable, Hashable {
    case genre, style, tempo, key, disk, folder
    var id: String { rawValue }

    var title: String {
        switch self {
        case .genre: return "Gatunek"
        case .style: return "Styl"
        case .tempo: return "Tempo (BPM)"
        case .key: return "Tonacja"
        case .disk: return "Dyski"
        case .folder: return "Foldery"
        }
    }

    var icon: String {
        switch self {
        case .genre: return "music.note.list"
        case .style: return "sparkles"
        case .tempo: return "metronome"
        case .key: return "pianokeys"
        case .disk: return "externaldrive"
        case .folder: return "folder"
        }
    }
}

struct CategoryCount: Identifiable, Hashable {
    let name: String
    let count: Int
    var id: String { name }
}

struct Filters: Equatable {
    var facets: [Facet: String] = [:]
    var bpmCenter: Double? = nil
    var bpmTolerance: Double = 4
    var includeHalfDouble = false
    var isEmpty: Bool { facets.isEmpty && bpmCenter == nil }
}

enum FieldChange<T> {
    case keep
    case reset
    case set(T)
}

struct AnalysisSettings: Sendable {
    var analyzeMissing: Bool
    var minBPM: Double
    /// Długość analizowanego fragmentu (s): 30 = szybka, 75 = dokładniejsza
    var seconds: Double
    /// Zapis wykrytego BPM do tagu pliku MP3, gdy plik nie ma BPM
    var writeToFiles: Bool

    static var autoCheckDisks: Bool {
        UserDefaults.standard.object(forKey: "autoCheckDisks") as? Bool ?? true
    }

    static var current: AnalysisSettings {
        let d = UserDefaults.standard
        return AnalysisSettings(
            analyzeMissing: d.object(forKey: "analyzeMissingBPM") as? Bool ?? true,
            minBPM: d.object(forKey: "bpmRangeMin") as? Double ?? 85,
            seconds: d.object(forKey: "analysisSeconds") as? Double ?? 30,
            writeToFiles: d.object(forKey: "writeBPMToFiles") as? Bool ?? true
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
