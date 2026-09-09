import Foundation
import AVFoundation
import Accelerate

// ===========================================================================
// MARK: - AudioAnalysis  (on-device listening lab)
//
// Everything in AS Music that wants to be "smart" — auto playlists, smart EQ,
// loudness matching, karaoke, DJ-style track ordering — needs to know what a
// track actually SOUNDS like, not just what its file name says.
//
// This file does that locally: it reads a song with AVAudioFile, scans the PCM
// once, and derives a compact feature vector:
//
//   loudness (gated, EBU R128-style)   tempo + beat strength (autocorrelation)
//   band energy split (sub/warm/body/presence/air)
//   center-vs-side ratio (how vocal-forward the mix is)
//   stereo width, dynamic range, clipping, leading/trailing silence
//
// Deliberately dependency-free: plain Swift over the samples + one-pole
// filters. No FFT, no model download, no network, no API key — nothing leaves
// the device. Results are cached in `.asmusic_audio.json`, so a 200-song
// library costs a few seconds once and then reads as instant.
// ===========================================================================

/// What we learn about one track. Plain values with defaults: if the cache
/// ever fails to decode (schema change) we just re-analyze.
struct TrackFeatures: Codable, Equatable {
    /// v2 (Pack 6) added the chroma vector + detected musical key. Bumping the
    /// number makes AudioLab drop v1 entries and re-measure — which is exactly
    /// what we want, because the key is what the harmonic mixing runs on.
    var version: Int = 2

    var duration: Double = 0          // seconds
    var loudness: Double = -70        // gated window RMS, dBFS (≈ LUFS − 2)
    var peak: Double = 0              // dBFS
    var tempo: Double = 0             // BPM (folded into 70…180)
    var beatStrength: Double = 0      // 0…1 how regular the beat is
    var energy: Double = 0            // 0…1 perceived loudness/liveness
    var warmth: Double = 0            // 0…1 share below ~400 Hz
    var body: Double = 0              // 0…1 share 400 Hz…1.5 kHz
    var presence: Double = 0          // 0…1 share 1.5…5 kHz (vocals live here)
    var air: Double = 0               // 0…1 share above ~5 kHz
    var subBass: Double = 0           // 0…1 share below ~120 Hz
    var vocalCenter: Double = 0       // 0…1 center dominance in 300 Hz…5 kHz
    var stereoWidth: Double = 0       // 0…1 (1 = wide, 0 = effectively mono)
    var dynRange: Double = 0          // dB between loud and quiet thirds
    var clipRatio: Double = 0         // 0…1 of samples close to full scale
    var leadSilence: Double = 0       // seconds of dead air at the start
    var tailSilence: Double = 0       // seconds of dead air at the end
    var analyzedAt: Date = Date()

    // MARK: Harmonic content (v2)

    /// 12-bin pitch-class profile (C, C#, D … B), normalized so the strongest
    /// bin is 1.0. Empty when the track was too short/quiet to analyze.
    var chroma: [Double] = []
    /// 0…11 tonic pitch class, or -1 when unknown.
    var keyTonic: Int = -1
    /// true = major, false = minor. Only meaningful when keyTonic >= 0.
    var keyIsMajor: Bool = true
    /// 0…1 how strongly the chroma matched the winning key profile. Below
    /// ~0.18 the estimate is a coin-flip and the UI hides it.
    var keyConfidence: Double = 0

    /// "F# minor" / "C major", or "" when we could not tell.
    var keyName: String {
        guard keyTonic >= 0, keyTonic < 12, keyConfidence >= 0.18 else { return "" }
        return "\(MusicKey.noteNames[keyTonic]) \(keyIsMajor ? "major" : "minor")"
    }

    /// Camelot wheel code ("8A", "11B") used by DJs for harmonic mixing.
    var camelot: String {
        guard keyTonic >= 0, keyTonic < 12, keyConfidence >= 0.18 else { return "" }
        return MusicKey.camelotCode(tonic: keyTonic, isMajor: keyIsMajor)
    }

    // MARK: Derived hints used by the playlist / EQ engines

    /// Instrumental-ish: little centered content in the vocal band.
    var looksInstrumental: Bool { vocalCenter < 0.52 }
    /// Vocal-forward (typical pop / SHAABI masters): the voice sits mid.
    var vocalForward: Bool { vocalCenter > 0.58 && presence > 0.24 }
    /// A beat you can dance to.
    var isBeatDriven: Bool { beatStrength > 0.30 && tempo >= 92 }
    /// Likely a rough rip: clipping, very quiet, or dead air at the head.
    var isLowQualityRip: Bool { clipRatio > 0.004 || loudness < -26 || leadSilence > 0.8 }
    /// Fast / slow split used by the workout and wind-down recipes.
    var isUpTempo: Bool { tempo >= 112 && energy > 0.45 }

    /// 0…1 "how much energy does this feel like" — mixes loudness, tempo and
    /// beat regularity so a quiet-but-fast track still ranks above a slow one.
    var hype: Double {
        let tempoN = FeatureMath.norm(tempo, 60, 160)
        return min(1, 0.5 * energy + 0.3 * tempoN + 0.2 * beatStrength)
    }
}

// MARK: - Musical key (Krumhansl–Schmuckler over a chroma vector)

/// Turns a 12-bin pitch-class profile into a key estimate, and maps that key
/// onto the Camelot wheel so the playlist engine can mix harmonically.
///
/// The maths is the standard K-S correlation: rotate each of the two profiles
/// (major / minor) through all 12 tonics and keep the best correlation. It is
/// cheap (24 dot products over 12 numbers) and needs no model.
enum MusicKey {

    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Krumhansl–Kessler key profiles (perceived stability of each degree).
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Camelot: 1A…12A are minor keys, 1B…12B major. 8B = C major, 8A = A minor.
    /// Neighbours on the wheel (±1, or the A/B pair) mix cleanly.
    static func camelotCode(tonic: Int, isMajor: Bool) -> String {
        // Circle of fifths position for each pitch class.
        let majorNumbers = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
        let minorNumbers = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
        let n = isMajor ? majorNumbers[tonic % 12] : minorNumbers[tonic % 12]
        return "\(n)\(isMajor ? "B" : "A")"
    }

    /// Parses "11A" back into (number, isMajor). nil for an empty/garbled code.
    static func parseCamelot(_ code: String) -> (number: Int, isMajor: Bool)? {
        guard code.count >= 2, let last = code.last else { return nil }
        let isMajor: Bool
        switch last {
        case "B", "b": isMajor = true
        case "A", "a": isMajor = false
        default: return nil
        }
        guard let n = Int(code.dropLast()), (1...12).contains(n) else { return nil }
        return (n, isMajor)
    }

    /// 0 = same key, 1 = a perfect neighbour (±1 on the wheel or the relative
    /// major/minor), rising to 1.0 for a clash. Used as a transition cost.
    ///
    /// Returns nil when either track has no usable key, so callers can fall
    /// back to their tempo/energy-only ordering instead of guessing.
    static func harmonicDistance(_ a: String, _ b: String) -> Double? {
        guard let x = parseCamelot(a), let y = parseCamelot(b) else { return nil }
        if x.number == y.number && x.isMajor == y.isMajor { return 0 }
        // Relative major/minor: same number, different letter.
        if x.number == y.number { return 0.15 }
        // Distance around the 12-hour wheel.
        let raw = abs(x.number - y.number)
        let steps = min(raw, 12 - raw)
        if steps == 1 && x.isMajor == y.isMajor { return 0.2 }
        // Everything else scales with how far apart they sit.
        return min(1.0, 0.3 + Double(steps) / 12.0)
    }

    /// Best (tonic, isMajor, confidence) for a chroma vector.
    static func estimate(chroma: [Double]) -> (tonic: Int, isMajor: Bool, confidence: Double) {
        guard chroma.count == 12 else { return (-1, true, 0) }
        let total = chroma.reduce(0, +)
        guard total > 1e-9 else { return (-1, true, 0) }

        var best = (tonic: -1, isMajor: true, score: -Double.greatestFiniteMagnitude)
        var second = -Double.greatestFiniteMagnitude

        for tonic in 0..<12 {
            for isMajor in [true, false] {
                let profile = isMajor ? majorProfile : minorProfile
                // Correlate the chroma against the profile rotated to `tonic`.
                var rotated = [Double](repeating: 0, count: 12)
                for i in 0..<12 { rotated[i] = profile[(i - tonic + 12) % 12] }
                let score = correlation(chroma, rotated)
                if score > best.score {
                    second = best.score
                    best = (tonic, isMajor, score)
                } else if score > second {
                    second = score
                }
            }
        }
        guard best.tonic >= 0 else { return (-1, true, 0) }
        // Confidence = how far the winner sits above the runner-up. A tonal
        // track separates clearly; noise/percussion produces a flat field.
        let margin = second > -1e30 ? max(0, best.score - second) : 0
        let confidence = FeatureMath.clamp01(margin * 2.2)
        return (best.tonic, best.isMajor, confidence)
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n
        let mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y
            da += x * x
            db += y * y
        }
        let den = sqrt(da * db)
        return den > 1e-12 ? num / den : 0
    }
}

// MARK: - Small shared math helpers

enum FeatureMath {
    static func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }

    /// Maps a value from one range onto 0…1.
    static func norm(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return 0 }
        return max(0, min(1, (x - lo) / (hi - lo)))
    }

    static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    /// Euclidean distance over 0…1 features — how different two songs sound.
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        var i = 0
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        while i < n {
            let d = a[i] - b[i]
            s += d * d
            i += 1
        }
        return sqrt(s / Double(n))
    }
}

// MARK: - The lab (analysis queue + cache)

final class AudioLab: ObservableObject {
    static let shared = AudioLab()

    /// Cached features by song id (UUID string — stable across launches).
    /// Published copy for the UI; `store` is the authoritative one and is only
    /// ever touched on `work`.
    @Published private(set) var cache: [String: TrackFeatures] = [:]
    @Published private(set) var queueDepth: Int = 0
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var doneCount: Int = 0
    @Published private(set) var lastError: String? = nil

    /// Songs measured per app launch. A `var` because an explicit
    /// "analyze everything" from the Library Health screen lifts it.
    private var perSessionBudget = 60
    private let work = DispatchQueue(label: "asMusic.audioLab", qos: .utility)
    private let lock = NSLock()

    private var store: [String: TrackFeatures] = [:]
    private var queue: [Job] = []
    private var queued = Set<String>()
    private var startedThisSession = 0
    private var working = false
    private var saveItem: DispatchWorkItem?
    private let storeURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storeURL = docs.appendingPathComponent(".asmusic_audio.json")
        if let d = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([String: TrackFeatures].self, from: d) {
            // Drop entries written by an older schema — re-analysis is cheap.
            store = decoded.filter { $0.value.version == TrackFeatures().version }
        }
        cache = store
    }

    /// A queued measurement. The file URL and title are captured up front so
    /// the background queue never reads MusicManager's @Published arrays.
    private struct Job {
        let id: String
        let url: URL
        let title: String
    }

    // MARK: Lookups

    func features(for song: Song) -> TrackFeatures? {
        lock.lock(); defer { lock.unlock() }
        return store[song.id.uuidString]
    }

    func isAnalyzed(_ song: Song) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store[song.id.uuidString] != nil
    }

    /// How much of the library the lab has measured. The UI shows this so
    /// "why is my auto-playlist rough?" has an honest answer.
    func coverage(of songs: [Song]) -> Double {
        guard !songs.isEmpty else { return 1 }
        lock.lock(); defer { lock.unlock() }
        let have = songs.reduce(0) { $0 + (store[$1.id.uuidString] != nil ? 1 : 0) }
        return Double(have) / Double(songs.count)
    }

    // MARK: Queueing

    /// Queue every song still missing features, most useful first: the track
    /// that's playing, then liked songs, then everything else.
    func prime(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let liked = Set(MusicManager.shared.playlists
            .first(where: { $0.name == "Liked Songs" })?.songIDs ?? [])
        let current = MusicManager.shared.currentSong?.id
        let ordered = songs
            .filter { !self.isAnalyzed($0) }
            .sorted { a, b in
                let wa = (a.id == current ? 2 : 0) + (liked.contains(a.id) ? 1 : 0)
                let wb = (b.id == current ? 2 : 0) + (liked.contains(b.id) ? 1 : 0)
                if wa != wb { return wa > wb }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        enqueue(ordered)
    }

    /// The user explicitly asked for a full sweep (Library Health). Lifts the
    /// per-launch budget, queues everything still unmeasured and restarts the
    /// worker if it had parked itself.
    func analyzeAll(_ songs: [Song]) {
        lock.lock()
        perSessionBudget = max(perSessionBudget, startedThisSession + songs.count + 8)
        lock.unlock()
        prime(songs)
        lock.lock()
        let needsKick = !working && !queue.isEmpty
        if needsKick { working = true }
        lock.unlock()
        if needsKick { drain() }
    }

    /// How many songs are still waiting to be measured.
    func pending(of songs: [Song]) -> Int {
        lock.lock(); defer { lock.unlock() }
        return songs.reduce(0) { $0 + (store[$1.id.uuidString] == nil ? 1 : 0) }
    }

    /// Measure one song soon (right after a download, or when the player opens
    /// a track we never analyzed).
    func ensureAnalyzed(_ song: Song) {
        if isAnalyzed(song) { return }
        enqueue([song])
    }

    func enqueue(_ songs: [Song]) {
        var added = 0
        lock.lock()
        for s in songs {
            let key = s.id.uuidString
            if store[key] != nil || queued.contains(key) { continue }
            queued.insert(key)
            queue.append(Job(id: key, url: s.url, title: s.title))
            added += 1
        }
        let depth = queue.count
        let already = working
        if added > 0 { working = true }
        lock.unlock()

        guard added > 0 else { return }
        DispatchQueue.main.async { self.queueDepth = depth }
        if !already { drain() }
    }

    private func drain() {
        work.async { [weak self] in
            guard let self = self else { return }
            while true {
                self.lock.lock()
                guard !self.queue.isEmpty else {
                    self.working = false
                    self.lock.unlock()
                    DispatchQueue.main.async { self.isWorking = false; self.queueDepth = 0 }
                    return
                }
                let job = self.queue.removeFirst()
                self.queued.remove(job.id)
                let depth = self.queue.count
                let overBudget = self.startedThisSession >= self.perSessionBudget
                self.startedThisSession += 1
                self.lock.unlock()

                DispatchQueue.main.async { self.queueDepth = depth; self.isWorking = true }

                if overBudget {
                    // Park the rest for the next launch and STOP. The old code
                    // pushed the job back and `continue`d, which span this
                    // background queue at 100% CPU forever once the budget ran
                    // out on a big library.
                    self.lock.lock()
                    self.queue.insert(job, at: 0)
                    self.queued.insert(job.id)
                    self.working = false
                    let parked = self.queue.count
                    self.lock.unlock()
                    DispatchQueue.main.async {
                        self.isWorking = false
                        self.queueDepth = parked
                    }
                    return
                }

                if let f = AudioLab.compute(job.url) {
                    self.lock.lock()
                    self.store[job.id] = f
                    self.lock.unlock()
                    DispatchQueue.main.async {
                        self.cache[job.id] = f
                        self.doneCount += 1
                    }
                    self.scheduleSave()
                    // Write what we just measured back into the file, so the
                    // BPM and key survive a reinstall and show up in every
                    // other player. Off by default: this rewrites the file.
                    self.writeBackIfEnabled(job.url, f)
                } else {
                    DispatchQueue.main.async {
                        self.lastError = "Could not read “\(job.title)”"
                    }
                }
                // Yield so a big first-run sweep never makes the app feel slow.
                Thread.sleep(forTimeInterval: 0.12)
            }
        }
    }

    /// User setting: mirror the measured BPM/key/gain into the MP3's tag.
    /// Default off, because it rewrites the user's file. The tag writer
    /// itself refuses to touch anything that already carries an ID3 header.
    static let writeBackKey = "asmusic.analysis.writeTags"

    /// Copies the analysis into the file's ID3 tag when the user asked for it.
    /// Silent no-op for non-MP3s and for already-tagged files.
    private func writeBackIfEnabled(_ url: URL, _ f: TrackFeatures) {
        guard UserDefaults.standard.bool(forKey: Self.writeBackKey) else { return }
        guard url.pathExtension.lowercased() == "mp3" else { return }

        var analysis = ID3TagWriter.Analysis()
        // Only claim a tempo we actually believe in.
        if f.tempo >= 40, f.tempo <= 220, f.beatStrength > 0.12 {
            analysis.bpm = Int(f.tempo.rounded())
        }
        analysis.key = f.keyName       // "" unless keyConfidence cleared the gate
        analysis.camelot = f.camelot
        // ReplayGain: how far this track sits from the -14 dBFS reference we
        // normalize to elsewhere in the app. Skip nonsense from silent files.
        if f.loudness > -60 {
            analysis.replayGainDB = ((-14.0 - f.loudness) * 100).rounded() / 100
        }
        guard !analysis.isEmpty else { return }

        let title = url.deletingPathExtension().lastPathComponent
        _ = ID3TagWriter.tagIfNeeded(at: url, title: title, artist: "",
                                     album: "", artworkJPEG: nil,
                                     analysis: analysis)
    }

    /// Debounced so a 60-song sweep writes the cache once, not 60 times.
    private func scheduleSave() {
        lock.lock()
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeNow() }
        saveItem = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func writeNow() {
        lock.lock()
        let snapshot = store
        lock.unlock()
        guard let d = try? JSONEncoder().encode(snapshot) else { return }
        try? d.write(to: storeURL, options: .atomic)
    }

    /// Flush the cache to disk (called when the app backgrounds).
    func flush() {
        lock.lock()
        saveItem?.cancel()
        saveItem = nil
        lock.unlock()
        work.async { [weak self] in self?.writeNow() }
    }

    /// Forget everything (Settings → “re-analyze from scratch”).
    func reset() {
        lock.lock()
        queue.removeAll()
        queued.removeAll()
        startedThisSession = 0
        lock.unlock()
        work.async {
            try? FileManager.default.removeItem(at: self.storeURL)
            self.lock.lock()
            self.store.removeAll()
            self.lock.unlock()
            DispatchQueue.main.async {
                self.cache = [:]
                self.doneCount = 0
            }
        }
    }

    // MARK: - The actual measurement

    /// One sequential scan of the file. A 1024-sample window at 44.1 kHz is
    /// ~23 ms: fine enough for tempo autocorrelation, cheap enough that a whole
    /// song is a fraction of a second of work.
    static func compute(_ url: URL) -> TrackFeatures? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        guard sr > 1000, file.length > 0 else { return nil }
        let ch = max(1, Int(fmt.channelCount))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { return nil }

        // Chroma accumulator (v2): a 4096-point FFT every ~0.37 s of audio,
        // folded into 12 pitch classes. Allocated once, reused per frame.
        let chromaFFT = ChromaExtractor(sampleRate: sr)

        let winSamples = 1024
        let winDur = Double(winSamples) / sr          // seconds per window
        // One-pole coefficient: a = 1 − e^(−2π f / sr).
        func coef(_ hz: Double) -> Double { 1 - exp(-2 * Double.pi * hz / sr) }
        let a120 = coef(120), a300 = coef(300), a400 = coef(400)
        let a1500 = coef(1500), a5000 = coef(5000)

        var lp120 = 0.0, lp400 = 0.0, lp1500 = 0.0, lp5000 = 0.0
        var lpM300 = 0.0, lpM5000 = 0.0, lpS300 = 0.0, lpS5000 = 0.0
        var subE = 0.0, lowE = 0.0, midE = 0.0, presE = 0.0, airE = 0.0
        var midVocal = 0.0, sideVocal = 0.0
        var midEnergy = 0.0, sideEnergy = 0.0
        var peak = 0.0, clipped = 0.0, total = 0.0
        var winSq = 0.0
        var inWin = 0
        var env: [Double] = []

        while true {
            do { try file.read(into: buf, frameCount: 4096) } catch { break }
            let frames = Int(buf.frameLength)
            if frames <= 0 { break }
            guard let data = buf.floatChannelData else { break }
            let left = data[0]
            let right = ch >= 2 ? data[1] : data[0]

            for i in 0..<frames {
                let sl = Double(left[i])
                let rr = ch >= 2 ? Double(right[i]) : sl
                let m = 0.5 * (sl + rr)
                let s = 0.5 * (sl - rr)

                lp120 += a120 * (m - lp120)
                lp400 += a400 * (m - lp400)
                lp1500 += a1500 * (m - lp1500)
                lp5000 += a5000 * (m - lp5000)
                lpM300 += a300 * (m - lpM300)
                lpM5000 += a5000 * (m - lpM5000)
                lpS300 += a300 * (s - lpS300)
                lpS5000 += a5000 * (s - lpS5000)

                let b0 = lp120
                let b1 = lp400 - lp120
                let b2 = lp1500 - lp400
                let b3 = lp5000 - lp1500
                let b4 = m - lp5000
                subE += b0 * b0
                lowE += b1 * b1
                midE += b2 * b2
                presE += b3 * b3
                airE += b4 * b4
                midVocal += abs(lpM5000 - lpM300)
                sideVocal += abs(lpS5000 - lpS300)
                midEnergy += m * m
                sideEnergy += s * s

                let am = abs(sl) > abs(rr) ? abs(sl) : abs(rr)
                if am > peak { peak = am }
                if am > 0.94 { clipped += 1 }
                total += 1

                winSq += m * m
                inWin += 1
                if inWin >= winSamples {
                    let rms = sqrt(max(winSq, 1e-12) / Double(winSamples))
                    env.append(20 * log10(rms))
                    winSq = 0
                    inWin = 0
                }

                // Feed the mono sum to the chroma extractor; it buffers
                // internally and only runs an FFT once it has a full frame.
                chromaFFT.push(Float(m))
            }
        }

        if env.isEmpty || total <= 0 { return nil }

        var f = TrackFeatures()
        f.duration = Double(file.length) / sr

        // Band shares.
        let bands = [subE, lowE, midE, presE, airE]
        let bandTotal = max(1e-12, bands.reduce(0, +))
        f.subBass = bands[0] / bandTotal
        f.warmth = (bands[0] + bands[1]) / bandTotal
        f.body = bands[2] / bandTotal
        f.presence = bands[3] / bandTotal
        f.air = bands[4] / bandTotal

        // Center vs side.
        let vs = max(1e-12, midVocal + sideVocal)
        f.vocalCenter = midVocal / vs
        f.stereoWidth = sideEnergy > 0 && midEnergy > 0
            ? max(0, min(1, sqrt(sideEnergy / max(1e-12, midEnergy)))) : 0

        // Loudness: gate to the loudest 10 dB (EBU R128 style) then average.
        let maxWin = env.max() ?? -70
        let gate = max(-70.0, maxWin - 10)
        let kept = env.filter { $0 > gate }
        f.loudness = kept.isEmpty ? maxWin : FeatureMath.mean(kept) + 0.6
        f.peak = peak > 0 ? 20 * log10(peak) : -70
        f.clipRatio = clipped / max(1, total)
        // −34 dBFS (whisper) → 0, −12 dBFS (mastered) → 1.
        f.energy = FeatureMath.norm(f.loudness, -34, -12)

        // Dynamic range: upper quartile minus lower quartile of window levels.
        let sortedEnv = env.sorted()
        if sortedEnv.count >= 9 {
            f.dynRange = max(0, sortedEnv[(sortedEnv.count * 3) / 4] - sortedEnv[sortedEnv.count / 4])
        }

        // Tempo + beat strength from the onset envelope.
        var onset = [Double](repeating: 0, count: env.count)
        var idx = 1
        while idx < env.count {
            let d = env[idx] - env[idx - 1]
            onset[idx] = d > 0 ? min(d, 12) : 0
            idx += 1
        }
        var oMax = 0.0
        for v in onset where v > oMax { oMax = v }
        if oMax > 0, env.count > 140 {
            onset = onset.map { $0 / oMax }
            let minLag = max(4, Int((60.0 / 180.0) / winDur))
            let maxLag = min(onset.count / 2, Int((60.0 / 70.0) / winDur))
            var scores: [Double] = []
            scores.reserveCapacity(maxLag - minLag + 1)
            var lag = minLag
            while lag <= maxLag {
                var acc = 0.0
                var c = 0
                while c + lag < onset.count {
                    acc += onset[c] * onset[c + lag]
                    c += 1
                }
                scores.append(c > 0 ? acc / Double(c) : 0)
                lag += 1
            }
            if let best = scores.enumerated().max(by: { $0.element < $1.element }) {
                let avg = FeatureMath.mean(scores)
                var bpm = 60.0 / (Double(minLag + best.offset) * winDur)
                while bpm < 70 { bpm *= 2 }
                while bpm > 180 { bpm /= 2 }
                f.tempo = bpm
                // How much the beat period stands out from the average lag —
                // a steady 4/4 scores high, a rubato oud improvisation ≈ 0.
                f.beatStrength = best.element > 0
                    ? FeatureMath.clamp01((best.element - avg) / best.element) : 0
            }
        }

        // Dead air at the head/tail (used to skip silence on bad rips).
        let silenceGate = -55.0
        var firstLoud = -1, lastLoud = -1
        for (i, db) in env.enumerated() {
            if db > silenceGate {
                if firstLoud < 0 { firstLoud = i }
                lastLoud = i
            }
        }
        if firstLoud > 0 { f.leadSilence = Double(firstLoud) * winDur }
        if lastLoud >= 0, lastLoud < env.count - 1 {
            f.tailSilence = Double(env.count - 1 - lastLoud) * winDur
        }
        if f.duration < 3 { f.tempo = 0 }      // meaningless for jingles/fragments

        // Musical key from the accumulated chroma (v2). Short fragments and
        // pure percussion legitimately produce no key — keyName/camelot then
        // return "" and every caller falls back to tempo/energy ordering.
        if f.duration >= 8, let chroma = chromaFFT.normalized() {
            f.chroma = chroma
            let est = MusicKey.estimate(chroma: chroma)
            f.keyTonic = est.tonic
            f.keyIsMajor = est.isMajor
            f.keyConfidence = est.confidence
        }

        f.analyzedAt = Date()
        return f
    }
}

// MARK: - Chroma extraction (12 pitch classes from the audio)

/// Accumulates a pitch-class profile over a whole track.
///
/// Samples are pushed one at a time (the analysis loop is already walking the
/// PCM, so this costs nothing extra); every `frameSize` samples we window,
/// FFT, and add each bin's magnitude into the pitch class its frequency maps
/// to. Only 55 Hz…2 kHz is used: below that the fundamental is muddy, above it
/// harmonics dominate and blur the estimate.
///
/// One allocation set, reused for the whole file — deliberately matching the
/// no-allocations-in-the-loop discipline the rest of this file follows.
final class ChromaExtractor {
    private static let frameSize = 4096
    private static let log2n = vDSP_Length(12)          // 2^12 = 4096

    private let sampleRate: Double
    private var setup: FFTSetup?

    private var window: [Float]
    private var frame: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    /// Pitch class (0…11) for every usable FFT bin, -1 for bins we ignore.
    private var binToPitchClass: [Int]

    private var fill = 0
    private var bins = [Double](repeating: 0, count: 12)
    private var frames = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let n = Self.frameSize
        window = [Float](repeating: 0, count: n)
        frame = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)
        binToPitchClass = [Int](repeating: -1, count: n / 2)

        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))

        // Precompute which pitch class each bin belongs to.
        //   MIDI = 69 + 12 * log2(f / 440);  pitch class = MIDI % 12
        // Bin 0 is DC, so start at 1.
        let lowHz = 55.0      // A1
        let highHz = 2000.0
        for k in 1..<(n / 2) {
            let hz = Double(k) * sampleRate / Double(n)
            guard hz >= lowHz, hz <= highHz else { continue }
            let midi = 69.0 + 12.0 * log2(hz / 440.0)
            let pc = Int(midi.rounded()) % 12
            binToPitchClass[k] = (pc + 12) % 12
        }
    }

    deinit {
        if let s = setup { vDSP_destroy_fftsetup(s) }
    }

    /// Add one mono sample. Runs an FFT every `frameSize` samples.
    func push(_ sample: Float) {
        frame[fill] = sample
        fill += 1
        if fill == Self.frameSize {
            process()
            fill = 0
        }
    }

    private func process() {
        guard let setup = setup else { return }
        let n = Self.frameSize
        let half = n / 2

        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        windowed.withUnsafeBufferPointer { wptr in
            wptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cptr in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
                    }
                }
            }
        }

        // Fold bin power into pitch classes.
        var any = false
        for k in 1..<half {
            let pc = binToPitchClass[k]
            if pc < 0 { continue }
            let mag = Double(magnitudes[k])
            if mag > 0 {
                bins[pc] += sqrt(mag)   // amplitude, not power — less peaky
                any = true
            }
        }
        if any { frames += 1 }
    }

    /// The pitch-class profile scaled so its strongest bin is 1.0, or nil when
    /// the track produced too little tonal content to judge.
    func normalized() -> [Double]? {
        guard frames >= 8 else { return nil }
        guard let peak = bins.max(), peak > 1e-9 else { return nil }
        return bins.map { $0 / peak }
    }
}
