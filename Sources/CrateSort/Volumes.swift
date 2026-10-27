import Foundation

/// Podłączony dysk rozpoznany po identyfikatorze (UUID) — nazwa i punkt montowania mogą się zmieniać.
struct VolumeRef: Sendable, Hashable {
    let id: String
    let name: String
    let mountPath: String
    let isInternal: Bool
}

/// Zapamiętany dysk wraz ze skanowanymi folderami (ścieżki względne).
struct VolumeInfo: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    /// true = ścieżki liczone od "/" (dysk systemowy), false = od punktu montowania (/Volumes/…)
    var usesRootBase: Bool
    var isInternal: Bool
    var roots: [String]
    var lastMountPath: String
    var lastSeen: Date
    var lastScan: Date?
}

struct VolumeFile: Codable {
    var version: Int
    var volume: VolumeInfo
    var tracks: [Track]
}

struct ScanTarget: Sendable {
    let path: String
    let volumeID: String
    let base: String
}

enum Volumes {
    static let resourceKeys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeLocalizedNameKey,
        .volumeIsInternalKey, .volumeTotalCapacityKey,
    ]

    static func ref(forVolumeURL url: URL) -> VolumeRef? {
        guard let r = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
        let name = r.volumeLocalizedName ?? r.volumeName ?? url.lastPathComponent
        let id = r.volumeUUIDString ?? "name-\(name)-\(r.volumeTotalCapacity ?? 0)"
        return VolumeRef(id: id, name: name, mountPath: url.standardizedFileURL.path,
                         isInternal: r.volumeIsInternal ?? false)
    }

    static func ref(forPath path: String) -> VolumeRef? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.volumeURLKey]), let vurl = v.volume else { return nil }
        return ref(forVolumeURL: vurl)
    }

    /// Wszystkie zamontowane dyski (łącznie z ukrytymi woluminami systemowymi, żeby dysk wewnętrzny był rozpoznany).
    static func mounted() -> [VolumeRef] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(resourceKeys), options: []) ?? []
        var seen = Set<String>()
        return urls.compactMap { ref(forVolumeURL: $0) }.filter { seen.insert($0.id).inserted }
    }

    /// Czy ścieżka leży pod punktem montowania (dla dysku systemowego bywa inaczej przez firmlinki).
    static func isUnder(_ path: String, _ mount: String) -> Bool {
        mount == "/" || path == mount || path.hasPrefix(mount + "/")
    }

    static func relative(_ path: String, to base: String) -> String {
        if base == "/" { return String(path.drop(while: { $0 == "/" })) }
        if path == base { return "" }
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    static func join(_ base: String, _ rel: String) -> String {
        if rel.isEmpty { return base }
        return base == "/" ? "/" + rel : base + "/" + rel
    }

    static func fileName(for id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }) + ".json"
    }
}
