import Foundation
import AVFoundation

// MARK: - Szukanie plików

enum FileScanner {
    static let audioExtensions: Set<String> = ["mp3", "wav", "wave", "aif", "aiff", "aifc", "flac", "m4a", "mp4", "aac", "alac"]
    static let skipDirs: Set<String> = ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/opt",
                                        "/cores", "/dev", "/Applications", "/Volumes"]

    /// Szybkie sprawdzenie, czy na dysku jest jakakolwiek muzyka (do pytania o nowy dysk).
    static func containsAudio(at root: String, limit: Int = 4000) -> Bool {
        guard let en = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return false }
        var n = 0
        while let url = en.nextObject() as? URL {
            if audioExtensions.contains(url.pathExtension.lowercased()) { return true }
            n += 1
            if n >= limit { return false }
        }
        return false
    }

    static func findAudioFiles(in targets: [ScanTarget]) -> [FileInfo] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var out: [FileInfo] = []
        var seen = Set<String>()
        for target in targets {
            let root = target.path
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let en = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            while let url = en.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
                if v.isDirectory == true {
                    let p = url.path
                    if p != root, skipDirs.contains(p) || p.hasSuffix("/Library") { en.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true, audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let path = url.path
                if seen.insert(path).inserted {
                    out.append(FileInfo(path: path, size: Int64(v.fileSize ?? 0),
                                        modified: v.contentModificationDate ?? .distantPast,
                                        volumeID: target.volumeID,
                                        relPath: Volumes.relative(path, to: target.base)))
                }
            }
        }
        return out
    }
}

// MARK: - Budowanie wpisu utworu

enum TrackReader {
    static func read(_ f: FileInfo, previous: Track?, settings: AnalysisSettings) async -> Track {
        let url = URL(fileURLWithPath: f.path)
        let tags = await TagReader.read(url: url)

        let baseName = ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var title = tags.title ?? ""
        var artist = tags.artist ?? ""
        if title.isEmpty {
            if let r = baseName.range(of: " - ") {
                if artist.isEmpty { artist = String(baseName[..<r.lowerBound]).trimmed }
                title = String(baseName[r.upperBound...]).trimmed
            } else {
                title = baseName
            }
        }

        var duration = 0.0
        if let af = try? AVAudioFile(forReading: url), af.processingFormat.sampleRate > 0 {
            duration = Double(af.length) / af.processingFormat.sampleRate
        }

        var detected: Double? = nil
        var fileSize = f.size
        if tags.bpm == nil && settings.analyzeMissing {
            if let p = previous, p.fileSize == f.size, let d = p.bpmDetected {
                detected = d
            } else {
                detected = BPMAnalyzer.analyze(url: url, minBPM: settings.minBPM, seconds: settings.seconds)
            }
            // dopisz sugerowane tempo do pliku, żeby było widać je w innych programach
            if let d = detected, settings.writeToFiles, TagWriter.writeBPM(d, to: url),
               let size = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? NSNumber {
                fileSize = size.int64Value
            }
        }

        let genres = Categories.splitGenres(tags.genre ?? "")
        let grouping = Categories.normalizeGenre(tags.grouping ?? "")
        let styleAuto: String? = !grouping.isEmpty ? grouping : (genres.count > 1 ? genres[1] : nil)
        let camelot = Categories.camelot(fromKey: tags.key ?? "") ?? Categories.camelot(fromComment: tags.comment ?? "")

        return Track(
            path: f.path, fileSize: fileSize, modified: f.modified, addedAt: previous?.addedAt ?? Date(),
            title: title, artist: artist, album: tags.album ?? "", duration: duration,
            genreTag: tags.genre ?? "", groupingTag: tags.grouping ?? "", comment: tags.comment ?? "",
            keyTag: tags.key ?? "", bpmTag: tags.bpm, bpmDetected: detected,
            genreAuto: genres.first, styleAuto: styleAuto, camelot: camelot,
            genreOverride: previous?.genreOverride, styleOverride: previous?.styleOverride,
            bpmOverride: previous?.bpmOverride, preferDetected: false,
            volumeID: f.volumeID, relPath: f.relPath
        )
    }
}

// MARK: - Wykrywanie tempa (gdy brak BPM w tagach)

enum BPMAnalyzer {
    /// Analizuje fragment ze środka utworu (domyślnie 30 s): niskie tony (stopa) + całe pasmo,
    /// następnie przeszukuje siatkę tempa w zakresie [minBPM, 2*minBPM).
    static func analyze(url: URL, minBPM: Double = 85, seconds: Double = 30) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sr = format.sampleRate
        let total = file.length
        guard sr > 0, total > AVAudioFramePosition(sr * 12) else { return nil }

        let segLen = min(total, AVAudioFramePosition(sr * max(15, seconds)))
        let start = max(0, min(AVAudioFramePosition(Double(total) * 0.35), total - segLen))
        file.framePosition = start

        let factor = max(1, Int((sr / 11025).rounded()))
        let dsr = sr / Double(factor)
        let chunk: AVAudioFrameCount = 32768
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        let chans = Int(format.channelCount)
        guard chans > 0 else { return nil }

        var mono = [Float]()
        mono.reserveCapacity(Int(segLen) / factor + 1)
        var acc: Float = 0
        var accN = 0
        var remaining = segLen
        let inv = 1 / Float(chans)
        while remaining > 0 {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            do { try file.read(into: buf, frameCount: want) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<chans { s += data[c][i] }
                acc += s * inv
                accN += 1
                if accN == factor {
                    mono.append(acc / Float(factor))
                    acc = 0
                    accN = 0
                }
            }
            remaining -= AVAudioFramePosition(n)
        }
        return estimate(samples: mono, sampleRate: dsr, minBPM: minBPM)
    }

    static func estimate(samples x: [Float], sampleRate sr: Double, minBPM: Double) -> Double? {
        let hop = 128
        let nFrames = x.count / hop
        guard nFrames > 400 else { return nil }
        let low = lowpass(lowpass(x, cutoff: 150, sr: sr), cutoff: 150, sr: sr)

        var eLow = [Double](repeating: 0, count: nFrames)
        var eAll = [Double](repeating: 0, count: nFrames)
        for f in 0..<nFrames {
            var a = 0.0
            var l = 0.0
            let base = f * hop
            for i in base..<(base + hop) {
                let v = Double(x[i]); a += v * v
                let w = Double(low[i]); l += w * w
            }
            eLow[f] = log(1 + 1000 * l / Double(hop))
            eAll[f] = log(1 + 1000 * a / Double(hop))
        }

        var onset = [Double](repeating: 0, count: nFrames)
        for f in 1..<nFrames {
            onset[f] = max(0, eLow[f] - eLow[f - 1]) + 0.35 * max(0, eAll[f] - eAll[f - 1])
        }

        // odjęcie lokalnej średniej
        let w = 8
        var prefix = [Double](repeating: 0, count: nFrames + 1)
        for i in 0..<nFrames { prefix[i + 1] = prefix[i] + onset[i] }
        var flux = [Double](repeating: 0, count: nFrames)
        for i in 0..<nFrames {
            let a = max(0, i - w)
            let b = min(nFrames, i + w + 1)
            flux[i] = max(0, onset[i] - (prefix[b] - prefix[a]) / Double(b - a))
        }

        // lekkie wygładzenie
        let kernel = [0.06, 0.24, 0.4, 0.24, 0.06]
        var smooth = [Double](repeating: 0, count: nFrames)
        for i in 0..<nFrames {
            var s = 0.0
            for (k, kv) in kernel.enumerated() {
                let j = i + k - 2
                if j >= 0 && j < nFrames { s += flux[j] * kv }
            }
            smooth[i] = s
        }
        guard let mx = smooth.max(), mx > 0 else { return nil }
        for i in 0..<nFrames { smooth[i] /= mx }

        let fps = sr / Double(hop)
        let maxBPM = minBPM * 2
        var coarse: [(bpm: Double, s: Double)] = []
        var b = minBPM
        while b < maxBPM {
            coarse.append((b, score(smooth, fps: fps, bpm: b)))
            b += 0.5
        }
        var best: (bpm: Double, s: Double) = (0, -1)
        for c in coarse.sorted(by: { $0.s > $1.s }).prefix(4) {
            var f = c.bpm - 0.6
            while f <= c.bpm + 0.6 {
                if f >= minBPM * 0.98 && f < maxBPM * 1.02 {
                    let s = score(smooth, fps: fps, bpm: f)
                    if s > best.s { best = (f, s) }
                }
                f += 0.02
            }
        }
        guard best.s > 0 else { return nil }
        let r = best.bpm
        return abs(r - r.rounded()) < 0.12 ? r.rounded() : (r * 10).rounded() / 10
    }

    static func score(_ o: [Double], fps: Double, bpm: Double) -> Double {
        let period = 60 * fps / bpm
        let n = o.count
        var best = 0.0
        var phase = 0.0
        while phase < period {
            var sum = 0.0
            var cnt = 0
            var p = phase
            while p < Double(n - 1) {
                let i = Int(p)
                let fr = p - Double(i)
                sum += o[i] * (1 - fr) + o[i + 1] * fr
                cnt += 1
                p += period
            }
            if cnt > 0 { best = max(best, sum / Double(cnt)) }
            phase += 0.5
        }
        return best
    }

    static func lowpass(_ x: [Float], cutoff: Double, sr: Double) -> [Float] {
        let w0 = 2 * Double.pi * cutoff / sr
        let alpha = sin(w0) / (2 * 0.7071)
        let cs = cos(w0)
        let a0 = 1 + alpha
        let b0 = Float((1 - cs) / 2 / a0)
        let b1 = Float((1 - cs) / a0)
        let b2 = b0
        let a1 = Float(-2 * cs / a0)
        let a2 = Float((1 - alpha) / a0)
        var y = [Float](repeating: 0, count: x.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<x.count {
            let v = x[i]
            let o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = o
            y[i] = o
        }
        return y
    }
}
