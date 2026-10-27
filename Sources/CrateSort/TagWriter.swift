import Foundation

/// Bezpieczny zapis BPM do pliku MP3 (ramka ID3v2 TBPM).
/// - Nie rusza plików, które mają nietypową budowę tagu (unsynchronisation, rozszerzony nagłówek, stopka).
/// - Gdy nowa ramka mieści się w obecnym tagu (padding), nadpisuje tylko nagłówek pliku.
/// - W przeciwnym razie buduje plik tymczasowy obok, sprawdza jego rozmiar i dopiero wtedy podmienia oryginał.
/// - Przywraca oryginalną datę modyfikacji.
enum TagWriter {
    static func writeBPM(_ bpm: Double, to url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "mp3", bpm > 30, bpm < 300 else { return false }
        let value = String(Int(bpm.rounded()))
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let originalSize = (attrs[.size] as? NSNumber)?.intValue, originalSize > 0 else { return false }
        let originalDate = attrs[.modificationDate] as? Date

        // 1. Odczyt obecnego tagu
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        let head = [UInt8]((try? h.read(upToCount: 10)) ?? Data())
        var version: UInt8 = 3
        var frames: [UInt8] = []
        var oldTagSize = 0
        if head.count == 10, Bytes.ascii(head, 0, 3) == "ID3" {
            version = head[3]
            let flags = head[5]
            guard version == 3 || version == 4, flags & 0xD0 == 0 else { try? h.close(); return false }
            let size = Bytes.synchsafe(head, 6)
            guard size >= 0, 10 + size <= originalSize,
                  let body = try? h.read(upToCount: size), body.count == size,
                  let kept = framesWithout("TBPM", in: [UInt8](body), version: version) else {
                try? h.close()
                return false
            }
            frames = kept
            oldTagSize = 10 + size
        }
        try? h.close()

        let newFrames = frames + textFrame("TBPM", value, version: version)

        if oldTagSize > 0 && 10 + newFrames.count <= oldTagSize {
            // 2a. Mieści się — nadpisujemy tylko obszar tagu, rozmiar pliku bez zmian
            let bodySize = oldTagSize - 10
            let tag = header(version: version, size: bodySize) + newFrames
                + [UInt8](repeating: 0, count: bodySize - newFrames.count)
            guard tag.count == oldTagSize, let w = try? FileHandle(forWritingTo: url) else { return false }
            do {
                try w.seek(toOffset: 0)
                try w.write(contentsOf: Data(tag))
                try w.synchronize()
                try w.close()
            } catch {
                try? w.close()
                return false
            }
        } else {
            // 2b. Nowy, większy tag — plik tymczasowy + kontrola rozmiaru + podmiana
            let padding = 2048
            let tag = header(version: version, size: newFrames.count + padding) + newFrames
                + [UInt8](repeating: 0, count: padding)
            let expected = tag.count + (originalSize - oldTagSize)
            let tmp = url.deletingLastPathComponent().appendingPathComponent(".cratesort-\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: tmp.path, contents: Data(tag)) else { return false }
            var ok = false
            if let out = try? FileHandle(forWritingTo: tmp), let inp = try? FileHandle(forReadingFrom: url) {
                do {
                    try out.seekToEnd()
                    try inp.seek(toOffset: UInt64(oldTagSize))
                    while let chunk = try inp.read(upToCount: 1 << 20), !chunk.isEmpty {
                        try out.write(contentsOf: chunk)
                    }
                    try out.synchronize()
                    ok = true
                } catch {
                    ok = false
                }
                try? out.close()
                try? inp.close()
            }
            let tmpSize = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.intValue ?? -1
            guard ok, tmpSize == expected else {
                try? fm.removeItem(at: tmp)
                return false
            }
            do {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } catch {
                try? fm.removeItem(at: tmp)
                return false
            }
        }

        if let d = originalDate {
            try? fm.setAttributes([.modificationDate: d], ofItemAtPath: url.path)
        }
        return true
    }

    /// Zwraca ramki tagu bez ramki o podanym ID (bez paddingu). nil = nieznana struktura, nie ruszamy pliku.
    static func framesWithout(_ skip: String, in b: [UInt8], version: UInt8) -> [UInt8]? {
        var out: [UInt8] = []
        var pos = 0
        while pos + 10 <= b.count {
            if b[pos] == 0 { break }   // padding
            let id = Bytes.ascii(b, pos, 4)
            guard id.count == 4, id.allSatisfy({ $0.isUppercase || $0.isNumber }) else { return nil }
            let size = version == 4 ? Bytes.synchsafe(b, pos + 4) : Bytes.be32(b, pos + 4)
            let end = pos + 10 + size
            guard size >= 0, end <= b.count else { return nil }
            if id != skip { out.append(contentsOf: b[pos..<end]) }
            pos = end
        }
        return out
    }

    static func textFrame(_ id: String, _ text: String, version: UInt8) -> [UInt8] {
        let data: [UInt8] = [0x00] + Array(text.utf8)   // 0 = ISO-8859-1
        let size = version == 4 ? synchsafe(data.count) : be32(data.count)
        return Array(id.utf8) + size + [0, 0] + data
    }

    static func header(version: UInt8, size: Int) -> [UInt8] {
        [0x49, 0x44, 0x33, version, 0, 0] + synchsafe(size)
    }

    static func synchsafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7f), UInt8((n >> 14) & 0x7f), UInt8((n >> 7) & 0x7f), UInt8(n & 0x7f)]
    }

    static func be32(_ n: Int) -> [UInt8] {
        [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
    }
}
