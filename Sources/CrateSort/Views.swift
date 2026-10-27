import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("listFontSize") private var fontSize = 14.0

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if let disk = store.newDiskPrompt {
                    NewDiskBanner(disk: disk)
                    Divider()
                }
                if store.tracks.isEmpty && !store.isScanning {
                    EmptyLibraryView()
                } else {
                    FilterBar()
                    Divider()
                    TrackTableView(store: store, tracks: store.visible,
                                   selection: store.selection, fontSize: CGFloat(fontSize))
                    Divider()
                    StatusBar()
                }
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Wykonawca, tytuł, gatunek, 8A…")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isScanning {
                    ProgressView().controlSize(.small)
                    Button { store.cancelScan() } label: { Label("Zatrzymaj", systemImage: "stop.circle") }
                        .help("Zatrzymaj skanowanie")
                }
                Button { store.addFoldersViaPanel() } label: { Label("Dodaj folder", systemImage: "folder.badge.plus") }
                    .help("Dodaj folder lub dysk z muzyką")
                Button { store.rescanAll() } label: { Label("Skanuj ponownie", systemImage: "arrow.clockwise") }
                    .help("Wyszukaj nowe i zmienione pliki")
                    .disabled(store.isScanning || store.roots.isEmpty)
            }
        }
        .sheet(item: $store.editRequest) { req in
            EditTracksSheet(request: req).environmentObject(store)
        }
        .navigationTitle("CrateSort")
    }
}

// MARK: - Panel kategorii

struct SidebarView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var expanded: Set<Facet> = [.disk, .genre, .style, .tempo, .key]

    var body: some View {
        List {
            CategoryRow(icon: "music.note.house", name: "Wszystkie utwory",
                        count: store.tracks.count, selected: store.filters.isEmpty && store.searchText.isEmpty) {
                store.clearFilters()
            }
            .font(.headline)

            DisclosureGroup(isExpanded: binding(for: .disk)) {
                ForEach(store.diskRows) { disk in
                    DiskRowView(disk: disk,
                                selected: store.filters.facets[.disk] == disk.name) {
                        if disk.online { store.toggle(.disk, disk.name) }
                    }
                    .contextMenu {
                        if disk.online {
                            Button("Sprawdź nowe pliki") { store.checkDisk(disk.id) }
                        }
                        Button("Usuń dysk z biblioteki", role: .destructive) { store.forgetDisk(disk.id) }
                    }
                }
            } label: {
                Label(Facet.disk.title, systemImage: Facet.disk.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(store.filters.facets[.disk] != nil ? Color.accentColor : Color.primary)
            }

            ForEach(Facet.allCases.filter { $0 != .disk }) { facet in
                DisclosureGroup(isExpanded: binding(for: facet)) {
                    ForEach(store.facetCounts[facet] ?? []) { cat in
                        CategoryRow(icon: nil, name: cat.name, count: cat.count,
                                    selected: store.filters.facets[facet] == cat.name) {
                            store.toggle(facet, cat.name)
                        }
                        .opacity(cat.count == 0 ? 0.45 : 1)
                    }
                } label: {
                    Label(facet.title, systemImage: facet.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(store.filters.facets[facet] != nil ? Color.accentColor : Color.primary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func binding(for facet: Facet) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(facet) },
            set: { open in if open { expanded.insert(facet) } else { expanded.remove(facet) } }
        )
    }
}

struct CategoryRow: View {
    let icon: String?
    let name: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct DiskRowView: View {
    let disk: DiskRow
    let selected: Bool
    let action: () -> Void

    private var subtitle: String {
        if !disk.online { return "odłączony · zapamiętany" }
        guard let d = disk.lastScan else { return "jeszcze nie sprawdzony" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pl_PL")
        f.unitsStyle = .short
        return "sprawdzony " + f.localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: disk.online ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                    .foregroundStyle(disk.online ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(disk.name).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("\(disk.trackCount)").monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear)
            )
            .opacity(disk.online ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .help(disk.online ? "Kliknij, aby pokazać tylko utwory z tego dysku" : "Podłącz dysk, a jego utwory pojawią się automatycznie")
    }
}

struct NewDiskBanner: View {
    @EnvironmentObject var store: LibraryStore
    let disk: VolumeRef

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Podłączono dysk „\(disk.name)” z muzyką").font(.headline)
                Text("Nie ma go jeszcze w bibliotece. Dodać cały dysk?").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Nie pytaj o ten dysk") { store.ignoreNewDisk() }
            Button("Wybierz folder…") {
                store.newDiskPrompt = nil
                store.addFoldersViaPanel()
            }
            Button("Dodaj cały dysk") { store.acceptNewDisk() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }
}

// MARK: - Pasek filtrów

struct FilterBar: View {
    @EnvironmentObject var store: LibraryStore
    @State private var bpmText = ""

    var body: some View {
        HStack(spacing: 8) {
            if store.filters.isEmpty {
                Text(store.searchText.isEmpty ? "Wszystkie utwory" : "Wyniki wyszukiwania")
                    .font(.headline)
            } else {
                ForEach(Facet.allCases.filter { store.filters.facets[$0] != nil }) { f in
                    Chip(icon: f.icon, text: store.filters.facets[f] ?? "") {
                        store.filters.facets[f] = nil
                    }
                }
                if let c = store.filters.bpmCenter {
                    Chip(icon: "metronome", text: "≈ \(Categories.formatBPM(c)) BPM ±\(Int(store.filters.bpmTolerance))%") {
                        store.setBPMCenter(nil)
                    }
                }
                Button("Wyczyść") { store.clearFilters() }
                    .buttonStyle(.link)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Spacer()
            Text("Tempo ≈").foregroundStyle(.secondary)
            TextField("BPM", text: $bpmText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .onSubmit(applyBPM)
            Picker("", selection: $store.filters.bpmTolerance) {
                ForEach([2.0, 3.0, 4.0, 6.0, 8.0], id: \.self) { v in
                    Text("±\(Int(v))%").tag(v)
                }
            }
            .labelsHidden()
            .frame(width: 78)
            Toggle("½ / ×2", isOn: $store.filters.includeHalfDouble)
                .toggleStyle(.checkbox)
                .help("Pokaż też utwory w połowie i podwójnym tempie")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: store.filters.bpmCenter) { newValue in
            bpmText = newValue.map { Categories.formatBPM($0) } ?? ""
        }
    }

    private func applyBPM() {
        let s = bpmText.trimmed.replacingOccurrences(of: ",", with: ".")
        if s.isEmpty { store.setBPMCenter(nil); return }
        if let v = Double(s), v > 30, v < 300 { store.setBPMCenter(v) }
    }
}

struct Chip: View {
    let icon: String
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(text).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
    }
}

// MARK: - Pasek stanu

struct StatusBar: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        HStack(spacing: 10) {
            Text("\(store.visible.count) z \(store.tracks.count) utworów")
            if !store.selection.isEmpty {
                Text("· zaznaczono \(store.selection.count)").foregroundStyle(.secondary)
            }
            if let s = store.scanState {
                Divider().frame(height: 12)
                if s.total > 0 {
                    ProgressView(value: Double(s.done), total: Double(max(s.total, 1))).frame(width: 160)
                    Text("\(s.phase) \(s.done)/\(s.total)")
                } else {
                    ProgressView().controlSize(.small)
                    Text(s.phase)
                }
            } else if let summary = store.lastSummary {
                Divider().frame(height: 12)
                Label(summary, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("Przeciągnij na deck lub playlistę w Traktorze · dwuklik = utwory w podobnym tempie")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Pusta biblioteka

struct EmptyLibraryView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(store.diskRows.isEmpty ? "Dodaj swoją muzykę" : "Podłącz dysk z muzyką").font(.title.bold())
            Text(store.diskRows.isEmpty
                 ? "CrateSort przeskanuje foldery i dyski, odczyta z tagów gatunek, styl, tonację i BPM, a brakujące tempo policzy z dźwięku. Każdy dysk jest zapamiętywany osobno."
                 : "Zapamiętane dyski: \(store.diskRows.map(\.name).joined(separator: ", ")). Po podłączeniu ich utwory pojawią się od razu, a sprawdzone zostaną tylko nowe pliki.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button("Wybierz foldery lub dysk…") { store.addFoldersViaPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Skanuj folder Muzyka") { store.addMusicFolder() }
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Edycja

struct EditTracksSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let request: EditRequest

    @State private var genre = ""
    @State private var style = ""
    @State private var bpm = ""
    @State private var initialGenre = ""
    @State private var initialStyle = ""
    @State private var initialBPM = ""

    private var multi: Bool { request.ids.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(multi ? "Edytuj \(request.ids.count) utworów" : "Edytuj utwór").font(.title3.bold())
            if !multi, let t = store.track(request.ids[0]) {
                Text("\(t.artist) – \(t.title)").foregroundStyle(.secondary).lineLimit(2)
            }
            field("Gatunek", text: $genre, suggestions: store.allGenres)
            field("Styl", text: $style, suggestions: store.allStyles)
            HStack {
                Text("BPM").frame(width: 70, alignment: .leading)
                TextField(multi ? "bez zmian" : "", text: $bpm).frame(width: 100)
            }
            Text(multi ? "Puste pole = bez zmian. Zmiany zapisują się tylko w CrateSort, pliki zostają nietknięte."
                       : "Zmiany zapisują się tylko w CrateSort, pliki zostają nietknięte. Wyczyść pole, aby wrócić do wartości z tagów.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Przywróć dane z tagów") {
                    store.clearOverrides(ids: request.ids)
                    dismiss()
                }
                Spacer()
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zapisz") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: prefill)
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, suggestions: [String]) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            TextField(multi ? "bez zmian" : "", text: text)
            Menu {
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { text.wrappedValue = s }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .disabled(suggestions.isEmpty)
            .help("Wybierz z istniejących")
        }
    }

    private func prefill() {
        guard !multi, let t = store.track(request.ids[0]) else { return }
        genre = t.genre == Categories.noGenre ? "" : t.genre
        style = t.style == Categories.noStyle ? "" : t.style
        bpm = t.bpmText
        initialGenre = genre
        initialStyle = style
        initialBPM = bpm
    }

    private func change(_ now: String, _ was: String) -> FieldChange<String> {
        let n = now.trimmed
        if n == was.trimmed { return .keep }
        return n.isEmpty ? .reset : .set(n)
    }

    private func save() {
        let b = bpm.trimmed.replacingOccurrences(of: ",", with: ".")
        let bpmChange: FieldChange<Double>
        if b == initialBPM.trimmed {
            bpmChange = .keep
        } else if b.isEmpty {
            bpmChange = .reset
        } else if let v = Double(b), v > 30, v < 300 {
            bpmChange = .set(v)
        } else {
            bpmChange = .keep
        }
        store.applyEdit(ids: request.ids,
                        genre: change(genre, initialGenre),
                        style: change(style, initialStyle),
                        bpm: bpmChange)
    }
}

// MARK: - Ustawienia

struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("analyzeMissingBPM") private var analyzeMissing = true
    @AppStorage("bpmRangeMin") private var bpmRangeMin = 85.0
    @AppStorage("listFontSize") private var fontSize = 14.0
    @AppStorage("analysisSeconds") private var analysisSeconds = 30.0
    @AppStorage("writeBPMToFiles") private var writeToFiles = true
    @AppStorage("autoCheckDisks") private var autoCheckDisks = true

    var body: some View {
        Form {
            Section("Lista utworów") {
                Picker("Wielkość czcionki", selection: $fontSize) {
                    Text("Normalna (13)").tag(13.0)
                    Text("Większa (14)").tag(14.0)
                    Text("Duża (16)").tag(16.0)
                    Text("Bardzo duża (18) — na imprezę").tag(18.0)
                }
            }
            Section("Tempo") {
                Toggle("Licz BPM z dźwięku, gdy brak go w tagach", isOn: $analyzeMissing)
                Picker("Analiza", selection: $analysisSeconds) {
                    Text("Szybka — 30 s utworu (tempo sugerowane)").tag(30.0)
                    Text("Dokładniejsza — 75 s utworu").tag(75.0)
                }
                Picker("Zakres wykrywanego tempa", selection: $bpmRangeMin) {
                    Text("70–140 (hip-hop, downtempo)").tag(70.0)
                    Text("85–170 (house, techno — większość)").tag(85.0)
                    Text("100–200 (drum & bass, hardcore)").tag(100.0)
                }
                Toggle("Zapisuj wykryte BPM do plików MP3", isOn: $writeToFiles)
                Text("Wykryte tempo trafia do tagu BPM w oryginalnym pliku — tylko gdy plik nie ma jeszcze BPM. Dzięki temu widać je w Finderze, Traktorze i innych programach. Dźwięk, okładka, pozostałe tagi i data modyfikacji zostają bez zmian.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dyski") {
                Toggle("Po podłączeniu dysku sprawdzaj nowe pliki", isOn: $autoCheckDisks)
                ForEach(store.diskRows) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: disk.online ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                                .foregroundStyle(disk.online ? Color.green : Color.secondary)
                            Text(disk.name).bold()
                            Text(disk.online ? "podłączony" : "odłączony").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(disk.trackCount) utworów").foregroundStyle(.secondary)
                            Button("Usuń dysk") { store.forgetDisk(disk.id) }
                        }
                        ForEach(store.volumes[disk.id]?.roots ?? [], id: \.self) { rel in
                            HStack {
                                Text("   " + (rel.isEmpty ? "cały dysk" : rel))
                                    .font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Usuń folder") { store.removeRoot(volumeID: disk.id, rel: rel) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                Button("Dodaj folder lub dysk…") { store.addFoldersViaPanel() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 620)
    }
}

// MARK: - Menu „Kategorie” na pasku menu

struct CategoryMenuContent: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        Button("Wszystkie utwory") { store.clearFilters() }
            .keyboardShortcut("0", modifiers: .command)
        Button("Utwory w tempie zaznaczonego") { store.matchTempoOfSelection() }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(store.selection.isEmpty)
        Button("Edytuj zaznaczone…") { store.editSelection() }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(store.selection.isEmpty)
        Divider()
        ForEach(Facet.allCases) { facet in
            Menu(facet.title) {
                ForEach(store.facetCounts[facet] ?? []) { cat in
                    Button((store.filters.facets[facet] == cat.name ? "✓ " : "") + "\(cat.name)  (\(cat.count))") {
                        store.toggle(facet, cat.name)
                    }
                }
            }
        }
    }
}
