import SwiftUI
import AppKit

struct ScanState {
    var phase: String
    var done: Int
    var total: Int
}

struct EditRequest: Identifiable {
    let id = UUID()
    let ids: [String]
}

/// Wiersz w sekcji „Dyski” panelu bocznego.
struct DiskRow: Identifiable {
    let id: String
    let name: String
    let online: Bool
    let trackCount: Int
    let lastScan: Date?
}

@MainActor
final class LibraryStore: ObservableObject {
    /// Utwory z PODŁĄCZONYCH dysków (klucz: aktualna ścieżka). Odłączone są w `offline`.
    @Published private(set) var tracks: [String: Track] = [:]
    @Published private(set) var volumes: [String: VolumeInfo] = [:]
    @Published private(set) var mountedBases: [String: String] = [:]
    @Published var filters = Filters() {
        didSet { if filters != oldValue { recompute() } }
    }
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var visible: [Track] = []
    @Published private(set) var facetCounts: [Facet: [CategoryCount]] = [:]
    @Published var selection: Set<String> = []
    @Published private(set) var scanState: ScanState?
    @Published var editRequest: EditRequest?
    /// Podłączony nowy dysk z muzyką, którego nie ma w bibliotece.
    @Published var newDiskPrompt: VolumeRef?
    /// Krótki komunikat po sprawdzeniu dysku („USB: 3 nowe utwory”).
    @Published private(set) var lastSummary: String?

    private var offline: [String: [Track]] = [:]
    private var dirty: Set<String> = []
    private var scanTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var pendingTargets: [ScanTarget] = []
    private var searchIndex: [String: String] = [:]
    private var folderLabels: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []

    var isScanning: Bool { scanState != nil }

    /// Bezwzględne ścieżki skanowanych folderów na podłączonych dyskach.
    var roots: [String] {
        volumes.values.flatMap { v -> [String] in
            guard let base = mountedBases[v.id] else { return [] }
            return v.roots.map { Volumes.join(base, $0) }
        }.sorted()
    }

    var diskRows: [DiskRow] {
        volumes.values.map { v in
            let online = mountedBases[v.id] != nil
            let count = online ? tracks.values.reduce(0) { $0 + ($1.volumeID == v.id ? 1 : 0) } : (offline[v.id]?.count ?? 0)
            return DiskRow(id: v.id, name: v.name, online: online, trackCount: count, lastScan: v.lastScan)
        }.sorted { a, b in
            if a.online != b.online { return a.online }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    init() {
        load()
        refreshMounted(autoScan: AnalysisSettings.autoCheckDisks)
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            let o = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshMounted(autoScan: AnalysisSettings.autoCheckDisks)
                }
            }
            observers.append(o)
        }
    }

    func track(_ id: String) -> Track? { tracks[id] }

    var allGenres: [String] { uniqueSorted(tracks.values.map(\.genre)) }
    var allStyles: [String] { uniqueSorted(tracks.values.map(\.style)) }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Set(values).filter { !Categories.isPlaceholder($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Dyski: podłączanie i odłączanie

    /// Sprawdza, które dyski są podłączone: chowa utwory odłączonych, przywraca utwory
    /// ponownie podłączonych (pod aktualną ścieżką) i opcjonalnie dociąga tylko nowe pliki.
    func refreshMounted(autoScan: Bool) {
        let mounted = Volumes.mounted()
        var newBases: [String: String] = [:]
        var vols = volumes
        for ref in mounted {
            guard var v = vols[ref.id] else { continue }
            let base = v.usesRootBase ? "/" : ref.mountPath
            guard FileManager.default.fileExists(atPath: base) else { continue }
            newBases[ref.id] = base
            v.name = ref.name
            v.lastMountPath = ref.mountPath
            v.lastSeen = Date()
            vols[ref.id] = v
        }
        volumes = vols

        let wentOffline = mountedBases.keys.filter { newBases[$0] == nil }
        let cameOnline = newBases.keys.filter { mountedBases[$0] == nil }
        if !wentOffline.isEmpty || !cameOnline.isEmpty {
            var copy = tracks
            for vid in wentOffline {
                let gone = copy.values.filter { $0.volumeID == vid }
                offline[vid] = gone
                for t in gone { copy[t.path] = nil }
            }
            for vid in cameOnline {
                guard let base = newBases[vid] else { continue }
                for var t in offline[vid] ?? [] {
                    t.path = Volumes.join(base, t.relPath ?? "")
                    copy[t.path] = t
                }
                offline[vid] = nil
            }
            mountedBases = newBases
            tracks = copy
            if let f = filters.facets[.disk], !volumes.values.contains(where: { $0.name == f && newBases[$0.id] != nil }) {
                filters.facets[.disk] = nil
            }
            reindexAll()
            recompute()
        } else {
            mountedBases = newBases
        }

        if autoScan {
            let targets = cameOnline.flatMap { targetsFor(volume: $0) }
            if !targets.isEmpty { scan(targets: targets) }
        }
        lookForNewDisks(mounted)
    }

    private func lookForNewDisks(_ mounted: [VolumeRef]) {
        guard newDiskPrompt == nil else { return }
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredDisks") ?? [])
        let candidates = mounted.filter {
            volumes[$0.id] == nil && !$0.isInternal && $0.mountPath.hasPrefix("/Volumes/") && !ignored.contains($0.id)
        }
        guard let first = candidates.first else { return }
        let path = first.mountPath
        Task { [weak self] in
            let hasMusic = await Task.detached(priority: .utility) { FileScanner.containsAudio(at: path) }.value
            guard let self, hasMusic, self.volumes[first.id] == nil, self.newDiskPrompt == nil else { return }
            self.newDiskPrompt = first
        }
    }

    func acceptNewDisk() {
        guard let ref = newDiskPrompt else { return }
        newDiskPrompt = nil
        addRoots([ref.mountPath])
    }

    func ignoreNewDisk() {
        guard let ref = newDiskPrompt else { return }
        var ignored = UserDefaults.standard.stringArray(forKey: "ignoredDisks") ?? []
        ignored.append(ref.id)
        UserDefaults.standard.set(ignored, forKey: "ignoredDisks")
        newDiskPrompt = nil
    }

    private func targetsFor(volume vid: String) -> [ScanTarget] {
        guard let v = volumes[vid], let base = mountedBases[vid] else { return [] }
        return v.roots.map { ScanTarget(path: Volumes.join(base, $0), volumeID: vid, base: base) }
    }

    func checkDisk(_ vid: String) { scan(targets: targetsFor(volume: vid)) }

    func forgetDisk(_ vid: String) {
        guard volumes[vid] != nil else { return }
        volumes[vid] = nil
        offline[vid] = nil
        mountedBases[vid] = nil
        tracks = tracks.filter { $0.value.volumeID != vid }
        dirty.insert(vid)
        reindexAll()
        recompute()
        save()
    }

    // MARK: - Filtrowanie

    func toggle(_ facet: Facet, _ value: String) {
        var f = filters
        if f.facets[facet] == value {
            f.facets[facet] = nil
        } else {
            f.facets[facet] = value
            if facet == .tempo { f.bpmCenter = nil }
        }
        filters = f
    }

    func clearFilters() {
        var f = filters
        f.facets = [:]
        f.bpmCenter = nil
        filters = f
        if !searchText.isEmpty { searchText = "" }
    }

    func setBPMCenter(_ bpm: Double?) {
        var f = filters
        f.bpmCenter = bpm
        if bpm != nil { f.facets[.tempo] = nil }
        filters = f
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    private func facetValue(_ f: Facet, _ t: Track) -> String {
        switch f {
        case .genre: return t.genre
        case .style: return t.style
        case .tempo: return t.tempoBucket
        case .key: return t.keyFacet
        case .disk: return t.volumeID.flatMap { volumes[$0]?.name } ?? "Inny"
        case .folder: return folderLabels[t.path] ?? ""
        }
    }

    private func matchesTempo(_ t: Track) -> Bool {
        guard let c = filters.bpmCenter else { return true }
        guard let b = t.bpm else { return false }
        let tol = filters.bpmTolerance / 100
        var centers = [c]
        if filters.includeHalfDouble { centers += [c * 2, c / 2] }
        return centers.contains { abs(b - $0) <= $0 * tol }
    }

    func recompute() {
        let tokens = Self.fold(searchText).split(separator: " ").map(String.init)
        let active = filters.facets
        var counts: [Facet: [String: Int]] = [:]
        var vis: [Track] = []

        for t in tracks.values {
            if !tokens.isEmpty {
                let blob = searchIndex[t.path] ?? ""
                if !tokens.allSatisfy({ blob.contains($0) }) { continue }
            }
            if !matchesTempo(t) { continue }
            var values: [Facet: String] = [:]
            var mismatched: [Facet] = []
            for f in Facet.allCases {
                let v = facetValue(f, t)
                values[f] = v
                if let want = active[f], want != v { mismatched.append(f) }
            }
            if mismatched.isEmpty {
                vis.append(t)
                for f in Facet.allCases { counts[f, default: [:]][values[f] ?? "", default: 0] += 1 }
            } else if mismatched.count == 1 {
                let f = mismatched[0]
                counts[f, default: [:]][values[f] ?? "", default: 0] += 1
            }
        }
        for (f, v) in active where counts[f]?[v] == nil { counts[f, default: [:]][v] = 0 }

        var result: [Facet: [CategoryCount]] = [:]
        for f in Facet.allCases { result[f] = Categories.sorted(facet: f, counts: counts[f] ?? [:]) }

        vis.sort {
            let a = $0.artist.localizedStandardCompare($1.artist)
            if a != .orderedSame { return a == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        visible = vis
        facetCounts = result
    }

    // MARK: - Indeks

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private func index(_ t: Track) {
        let blob = [t.artist, t.title, t.album, t.genre, t.style, t.keyDisplay, t.fileName].joined(separator: " ")
        searchIndex[t.path] = Self.fold(blob)
        folderLabels[t.path] = folderLabel(for: t)
    }

    private func reindexAll() {
        searchIndex = [:]
        folderLabels = [:]
        for t in tracks.values { index(t) }
    }

    private func folderLabel(for t: Track) -> String {
        let dir = (t.path as NSString).deletingLastPathComponent
        guard let vid = t.volumeID, let v = volumes[vid], let base = mountedBases[vid] else {
            return (dir as NSString).lastPathComponent
        }
        let rel = Volumes.relative(dir, to: base)
        // folder względem skanowanego katalogu, np. "USB / House / 2024"
        let root = v.roots.filter { $0.isEmpty || rel == $0 || rel.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        let rootName: String
        let inside: String
        if let root, !root.isEmpty {
            rootName = (root as NSString).lastPathComponent
            inside = String(rel.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            rootName = v.name
            inside = rel
        }
        return inside.isEmpty ? rootName : rootName + " / " + inside.replacingOccurrences(of: "/", with: " / ")
    }

    // MARK: - Dodawanie folderów

    func addFoldersViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Dodaj"
        panel.message = "Wybierz foldery lub dyski z muzyką (np. pendrive, dysk zewnętrzny)"
        guard panel.runModal() == .OK else { return }
        addRoots(panel.urls.map { $0.standardizedFileURL.path })
    }

    func addMusicFolder() {
        if let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first {
            addRoots([music.path])
        }
    }

    func addRoots(_ paths: [String]) {
        var targets: [ScanTarget] = []
        for p in paths {
            guard let ref = Volumes.ref(forPath: p) else { continue }
            var v = volumes[ref.id] ?? VolumeInfo(
                id: ref.id, name: ref.name,
                usesRootBase: ref.mountPath == "/" || !Volumes.isUnder(p, ref.mountPath),
                isInternal: ref.isInternal, roots: [], lastMountPath: ref.mountPath,
                lastSeen: Date(), lastScan: nil
            )
            let base = v.usesRootBase ? "/" : ref.mountPath
            let rel = Volumes.relative(p, to: base)
            // już objęty istniejącym folderem?
            if v.roots.contains(where: { $0.isEmpty || rel == $0 || rel.hasPrefix($0 + "/") }) {
                targets.append(ScanTarget(path: p, volumeID: v.id, base: base))
                continue
            }
            v.roots.removeAll { rel.isEmpty || $0.hasPrefix(rel + "/") }
            v.roots.append(rel)
            v.roots.sort()
            volumes[v.id] = v
            mountedBases[v.id] = base
            dirty.insert(v.id)
            targets.append(ScanTarget(path: p, volumeID: v.id, base: base))
        }
        reindexAll()
        save()
        scan(targets: targets)
    }

    func removeRoot(volumeID vid: String, rel: String) {
        guard var v = volumes[vid] else { return }
        v.roots.removeAll { $0 == rel }
        if v.roots.isEmpty { forgetDisk(vid); return }
        volumes[vid] = v
        let covered: (String) -> Bool = { r in v.roots.contains { $0.isEmpty || r == $0 || r.hasPrefix($0 + "/") } }
        tracks = tracks.filter { $0.value.volumeID != vid || covered($0.value.relPath ?? "") }
        if let off = offline[vid] { offline[vid] = off.filter { covered($0.relPath ?? "") } }
        dirty.insert(vid)
        reindexAll()
        recompute()
        save()
    }

    // MARK: - Skanowanie

    func rescanAll() {
        scan(targets: mountedBases.keys.flatMap { targetsFor(volume: $0) })
    }

    func cancelScan() {
        pendingTargets = []
        scanTask?.cancel()
    }

    func scan(targets: [ScanTarget]) {
        guard !targets.isEmpty else { return }
        if scanTask != nil {
            pendingTargets.append(contentsOf: targets)
            return
        }
        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.performScan(targets)
            self.scanTask = nil
            if !self.pendingTargets.isEmpty {
                let next = self.pendingTargets
                self.pendingTargets = []
                self.scan(targets: next)
            }
        }
    }

    private func performScan(_ targets: [ScanTarget]) async {
        let vids = Array(Set(targets.map(\.volumeID)))
        let names = vids.compactMap { volumes[$0]?.name }.joined(separator: ", ")
        scanState = ScanState(phase: "Sprawdzam \(names)…", done: 0, total: 0)
        let files = await Task.detached(priority: .userInitiated) {
            FileScanner.findAudioFiles(in: targets)
        }.value
        if Task.isCancelled { scanState = nil; return }

        // Usuń pliki, których już nie ma — tylko z folderów, które nadal są dostępne
        // (odłączony w trakcie dysk nie może wyczyścić biblioteki).
        let found = Set(files.map(\.path))
        let reachable = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
        let prefixes = reachable.map { $0.path == "/" ? "/" : $0.path + "/" }
        var copy = tracks
        var removed = 0
        for p in copy.keys where prefixes.contains(where: { p.hasPrefix($0) }) && !found.contains(p) {
            copy[p] = nil
            searchIndex[p] = nil
            folderLabels[p] = nil
            removed += 1
        }
        tracks = copy
        for vid in vids { dirty.insert(vid) }

        let existing = tracks
        let todo = files.filter { f in
            guard let t = existing[f.path] else { return true }
            return t.fileSize != f.size || abs(t.modified.timeIntervalSince(f.modified)) > 1
        }
        let newCount = todo.filter { existing[$0.path] == nil }.count
        let changedCount = todo.count - newCount
        let settings = AnalysisSettings.current

        if !todo.isEmpty {
            scanState = ScanState(phase: "\(names): czytam tagi i tempo…", done: 0, total: todo.count)
            let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
            await withTaskGroup(of: Track.self) { group in
                var next = 0
                while next < min(workers, todo.count) {
                    let f = todo[next]
                    let prev = existing[f.path]
                    next += 1
                    group.addTask { await TrackReader.read(f, previous: prev, settings: settings) }
                }
                var buffer: [Track] = []
                var done = 0
                var lastFlush = Date()
                for await t in group {
                    buffer.append(t)
                    done += 1
                    if next < todo.count && !Task.isCancelled {
                        let f = todo[next]
                        let prev = existing[f.path]
                        next += 1
                        group.addTask { await TrackReader.read(f, previous: prev, settings: settings) }
                    }
                    if buffer.count >= 50 || Date().timeIntervalSince(lastFlush) > 1.0 {
                        await self.apply(buffer, done: done)
                        buffer.removeAll()
                        lastFlush = Date()
                    }
                }
                await self.apply(buffer, done: done)
            }
        }

        if !Task.isCancelled {
            for vid in vids where mountedBases[vid] != nil { volumes[vid]?.lastScan = Date() }
        }
        scanState = nil
        recompute()
        save()

        var parts: [String] = []
        if newCount > 0 { parts.append("\(newCount) nowych") }
        if changedCount > 0 { parts.append("\(changedCount) zmienionych") }
        if removed > 0 { parts.append("\(removed) usuniętych") }
        showSummary("\(names): " + (parts.isEmpty ? "bez zmian, wszystko było już dodane" : parts.joined(separator: ", ")))
    }

    private func apply(_ batch: [Track], done: Int) {
        // pomiń wyniki z dysku, który odłączono w trakcie skanu
        let accepted = batch.filter { t in t.volumeID.map { mountedBases[$0] != nil } ?? true }
        if !accepted.isEmpty {
            var copy = tracks
            for t in accepted { copy[t.path] = t }
            tracks = copy
            for t in accepted { index(t) }
            recompute()
        }
        scanState?.done = done
    }

    private func showSummary(_ text: String) {
        lastSummary = text
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastSummary = nil
        }
    }

    // MARK: - Akcje na utworach

    func revealInFinder(ids: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
    }

    func requestEdit(ids: [String]) {
        guard !ids.isEmpty else { return }
        editRequest = EditRequest(ids: ids)
    }

    func editSelection() { requestEdit(ids: orderedSelection()) }

    func orderedSelection() -> [String] {
        visible.map(\.id).filter { selection.contains($0) }
    }

    func matchTempo(of id: String) {
        guard let b = tracks[id]?.bpm else { return }
        setBPMCenter(b)
    }

    func matchTempoOfSelection() {
        if let id = orderedSelection().first { matchTempo(of: id) }
    }

    func showGenre(of id: String) {
        guard let g = tracks[id]?.genre else { return }
        var f = filters
        f.facets[.genre] = g
        filters = f
    }

    private func markDirty(_ ids: [String]) {
        for id in ids { if let vid = tracks[id]?.volumeID { dirty.insert(vid) } }
    }

    func applyEdit(ids: [String], genre: FieldChange<String>, style: FieldChange<String>, bpm: FieldChange<Double>) {
        var copy = tracks
        for id in ids {
            guard var t = copy[id] else { continue }
            switch genre {
            case .keep: break
            case .reset: t.genreOverride = nil
            case .set(let v): t.genreOverride = v
            }
            switch style {
            case .keep: break
            case .reset: t.styleOverride = nil
            case .set(let v): t.styleOverride = v
            }
            switch bpm {
            case .keep: break
            case .reset: t.bpmOverride = nil
            case .set(let v): t.bpmOverride = v
            }
            copy[id] = t
        }
        tracks = copy
        for id in ids { if let t = tracks[id] { index(t) } }
        markDirty(ids)
        recompute()
        save()
    }

    func clearOverrides(ids: [String]) {
        var copy = tracks
        for id in ids {
            copy[id]?.genreOverride = nil
            copy[id]?.styleOverride = nil
            copy[id]?.bpmOverride = nil
            copy[id]?.preferDetected = false
        }
        tracks = copy
        for id in ids { if let t = tracks[id] { index(t) } }
        markDirty(ids)
        recompute()
        save()
    }

    func reanalyze(ids: [String]) {
        let paths = ids.filter { tracks[$0] != nil }
        guard !paths.isEmpty, scanTask == nil else { return }
        let settings = AnalysisSettings.current
        scanTask = Task { [weak self] in
            guard let self else { return }
            self.scanState = ScanState(phase: "Analizuję tempo…", done: 0, total: paths.count)
            var done = 0
            for path in paths {
                if Task.isCancelled { break }
                let hasTag = self.tracks[path]?.bpmTag != nil
                let result = await Task.detached(priority: .userInitiated) { () -> (Double?, Int64?) in
                    let url = URL(fileURLWithPath: path)
                    let bpm = BPMAnalyzer.analyze(url: url, minBPM: settings.minBPM, seconds: settings.seconds)
                    var newSize: Int64? = nil
                    if let b = bpm, !hasTag, settings.writeToFiles, TagWriter.writeBPM(b, to: url) {
                        newSize = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
                    }
                    return (bpm, newSize)
                }.value
                let bpm = result.0
                if var t = self.tracks[path] {
                    if let s = result.1 { t.fileSize = s }
                    t.bpmDetected = bpm
                    t.preferDetected = bpm != nil
                    t.bpmOverride = nil
                    self.tracks[path] = t
                    self.index(t)
                }
                done += 1
                self.scanState?.done = done
            }
            self.markDirty(paths)
            self.scanState = nil
            self.scanTask = nil
            self.recompute()
            self.save()
        }
    }

    // MARK: - Zapis: osobny plik dla każdego dysku

    private static var volumesDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrateSort/Volumes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func load() {
        let dir = Self.volumesDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(VolumeFile.self, from: data) else { continue }
            volumes[file.volume.id] = file.volume
            offline[file.volume.id] = file.tracks   // refreshMounted przeniesie podłączone do `tracks`
        }
    }

    func save() {
        guard !dirty.isEmpty else { return }
        let dir = Self.volumesDir
        var writes: [(URL, VolumeFile)] = []
        var deletes: [URL] = []
        for vid in dirty {
            let url = dir.appendingPathComponent(Volumes.fileName(for: vid))
            guard let v = volumes[vid] else { deletes.append(url); continue }
            let ts: [Track] = mountedBases[vid] != nil
                ? tracks.values.filter { $0.volumeID == vid }
                : (offline[vid] ?? [])
            writes.append((url, VolumeFile(version: 1, volume: v, tracks: ts)))
        }
        dirty = []
        Task.detached(priority: .utility) {
            for url in deletes { try? FileManager.default.removeItem(at: url) }
            let enc = JSONEncoder()
            for (url, file) in writes {
                if let data = try? enc.encode(file) { try? data.write(to: url, options: .atomic) }
            }
        }
    }
}
