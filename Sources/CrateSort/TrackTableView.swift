import SwiftUI
import AppKit
import Quartz

/// NSTableView z podglądem Quick Look pod spacją (jak w Finderze).
final class PreviewTableView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var previewURLs: () -> [URL] = { [] }
    private var items: [URL] = []

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            togglePreview()
        } else {
            super.keyDown(with: event)
        }
    }

    func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            items = previewURLs()
            guard !items.isEmpty else { return }
            window?.makeFirstResponder(self)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func refreshPreviewIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, panel.dataSource === self else { return }
        items = previewURLs()
        panel.reloadData()
    }

    // Sterowanie panelem przez responder chain
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        items = previewURLs()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // Źródło danych
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < items.count else { return nil }
        return items[index] as NSURL
    }

    // Strzałki i spacja w otwartym podglądzie sterują listą
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }
}

/// Lista utworów na NSTableView: szybka przy dużych bibliotekach, sortowanie po kolumnach
/// i przeciąganie wielu plików naraz (Traktor przyjmuje je jak z Findera).
struct TrackTableView: NSViewRepresentable {
    let store: LibraryStore
    let tracks: [Track]
    let selection: Set<String>
    let fontSize: CGFloat

    static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("artist", "Wykonawca", 190), ("title", "Tytuł", 270), ("bpm", "BPM", 58),
        ("key", "Tonacja", 72), ("genre", "Gatunek", 140), ("style", "Styl", 120),
        ("time", "Czas", 52), ("file", "Plik", 220),
    ]

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let table = PreviewTableView()
        table.previewURLs = { [weak c] in c?.selectedURLs() ?? [] }
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = fontSize + 11
        table.intercellSpacing = NSSize(width: 6, height: 2)
        for spec in Self.columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            col.title = spec.title
            col.width = spec.width
            col.minWidth = 40
            col.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            if spec.id == "bpm" || spec.id == "time" { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        table.autosaveName = "CrateSortTracks"
        table.autosaveTableColumns = true
        table.dataSource = c
        table.delegate = c
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.target = c
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = c
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        c.table = table
        c.fontSize = fontSize
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.fontSize != fontSize {
            c.fontSize = fontSize
            c.table?.rowHeight = fontSize + 11
            c.table?.reloadData()
        }
        if c.source != tracks {
            c.source = tracks
            c.resort()
            c.table?.reloadData()
            c.syncSelection(selection)
        } else if c.currentSelection() != selection {
            c.syncSelection(selection)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let store: LibraryStore
        weak var table: PreviewTableView?
        var source: [Track] = []
        var rows: [Track] = []
        var fontSize: CGFloat = 13
        private var sortKey: String?
        private var ascending = true
        private var syncing = false

        init(store: LibraryStore) { self.store = store }

        // MARK: Dane

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let col = tableColumn, row < rows.count else { return nil }
            let id = col.identifier
            let numeric = id.rawValue == "bpm" || id.rawValue == "time"
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                if numeric { tf.alignment = .right }
                cell.addSubview(tf)
                cell.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            let t = rows[row]
            let tf = cell.textField
            tf?.stringValue = Self.text(id.rawValue, t)
            switch id.rawValue {
            case "bpm":
                tf?.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
                tf?.textColor = t.bpmIsDetected ? .secondaryLabelColor : .labelColor
                tf?.toolTip = t.bpmIsDetected ? "Tempo policzone z dźwięku" : nil
            case "time":
                tf?.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                tf?.textColor = .secondaryLabelColor
            case "artist", "title":
                tf?.font = .systemFont(ofSize: fontSize, weight: id.rawValue == "title" ? .medium : .regular)
                tf?.textColor = .labelColor
            case "file":
                tf?.font = .systemFont(ofSize: fontSize - 1)
                tf?.textColor = .secondaryLabelColor
                tf?.toolTip = t.path
            default:
                tf?.font = .systemFont(ofSize: fontSize)
                tf?.textColor = .labelColor
            }
            return cell
        }

        static func text(_ key: String, _ t: Track) -> String {
            switch key {
            case "artist": return t.artist
            case "title": return t.title
            case "bpm": return t.bpmText
            case "key": return t.keyDisplay
            case "genre": return t.genre == Categories.noGenre ? "" : t.genre
            case "style": return t.style == Categories.noStyle ? "" : t.style
            case "time": return t.durationText
            case "file": return t.fileName
            default: return ""
            }
        }

        // MARK: Sortowanie

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let d = tableView.sortDescriptors.first
            sortKey = d?.key
            ascending = d?.ascending ?? true
            let sel = currentSelection()
            resort()
            tableView.reloadData()
            syncSelection(sel)
        }

        func resort() {
            guard let key = sortKey else { rows = source; return }
            let asc = ascending
            rows = source.sorted { a, b in
                let r = Self.compare(a, b, key)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        }

        static func cmp<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }

        static func compare(_ a: Track, _ b: Track, _ key: String) -> ComparisonResult {
            switch key {
            case "bpm": return cmp(a.bpm ?? .infinity, b.bpm ?? .infinity)
            case "time": return cmp(a.duration, b.duration)
            case "key": return cmp(Categories.camelotSortIndex(a.camelot), Categories.camelotSortIndex(b.camelot))
            default:
                let x = text(key, a), y = text(key, b)
                if x.isEmpty != y.isEmpty { return x.isEmpty ? .orderedDescending : .orderedAscending }
                return x.localizedStandardCompare(y)
            }
        }

        // MARK: Zaznaczenie

        func currentSelection() -> Set<String> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        }

        func orderedSelection() -> [String] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil }
        }

        func syncSelection(_ ids: Set<String>) {
            guard let table else { return }
            var idx = IndexSet()
            for (i, t) in rows.enumerated() where ids.contains(t.id) { idx.insert(i) }
            syncing = true
            table.selectRowIndexes(idx, byExtendingSelection: false)
            syncing = false
        }

        func selectedURLs() -> [URL] {
            orderedSelection().map { URL(fileURLWithPath: $0) }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            table?.refreshPreviewIfVisible()
            guard !syncing else { return }
            let ids = currentSelection()
            Task { @MainActor [weak self] in self?.store.selection = ids }
        }

        // MARK: Przeciąganie do Traktora

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < rows.count else { return nil }
            return URL(fileURLWithPath: rows[row].path) as NSURL
        }

        // MARK: Akcje

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            store.matchTempo(of: rows[table.clickedRow].id)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
            let ids = orderedSelection()
            guard !ids.isEmpty else { return }
            menu.addItem(item("Podgląd (spacja)", #selector(preview)))
            menu.addItem(.separator())
            if ids.count == 1 {
                menu.addItem(item("Pokaż utwory w podobnym tempie", #selector(matchTempo)))
                menu.addItem(item("Pokaż ten sam gatunek", #selector(sameGenre)))
                menu.addItem(.separator())
            }
            menu.addItem(item(ids.count == 1 ? "Edytuj gatunek / styl / BPM…" : "Edytuj \(ids.count) utworów…", #selector(edit)))
            menu.addItem(item("Policz BPM z dźwięku", #selector(reanalyze)))
            menu.addItem(item("Przywróć dane z tagów", #selector(clearOverrides)))
            menu.addItem(.separator())
            menu.addItem(item("Pokaż w Finderze", #selector(showInFinder)))
        }

        private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            return i
        }

        @objc func preview() { table?.togglePreview() }
        @objc func showInFinder() { store.revealInFinder(ids: orderedSelection()) }
        @objc func matchTempo() { if let id = orderedSelection().first { store.matchTempo(of: id) } }
        @objc func sameGenre() { if let id = orderedSelection().first { store.showGenre(of: id) } }
        @objc func edit() { store.requestEdit(ids: orderedSelection()) }
        @objc func reanalyze() { store.reanalyze(ids: orderedSelection()) }
        @objc func clearOverrides() { store.clearOverrides(ids: orderedSelection()) }
    }
}
