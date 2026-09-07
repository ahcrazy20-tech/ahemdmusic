import Foundation
import AVFoundation

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
    var version: Int = 1

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
        f.analyzedAt = Date()
        return f
    }
}
