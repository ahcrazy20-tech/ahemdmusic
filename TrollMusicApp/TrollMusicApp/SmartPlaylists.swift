import Foundation
import SwiftUI
import UIKit

// ===========================================================================
// MARK: - Smart Playlists (the auto-DJ)
//
// The "make playlists for me" brain. It works in three layers, and the first
// two need NO internet and NO API key:
//
//   1. MEASURE  — AudioLab scans each song's actual audio (loudness, tempo,
//                 band balance, how vocal-forward the mix is, dynamics…).
//   2. CURATE   — recipes score every song for a situation (gym, wind-down,
//                 focus, farah, Arabic nights, fresh finds, best-sounding…)
//                 and k-means groups whatever is left into "vibe" clusters
//                 with generated names. Tracks are then ordered DJ-style:
//                 smallest tempo/energy jumps, no back-to-back same artist.
//   3. UPGRADE  — if a Gemini key is configured, a plain-language request
//                 ("حماسية للجلد", "quiet arabic for a rainy drive") is turned
//                 into a named playlist by the model, using YOUR library as the
//                 catalog. Without a key the same request is handled by a local
//                 Arabic + English keyword parser.
//
// Playlists it creates are tracked in `SmartPlaylistStore`, so refreshing
// updates the same playlist in place instead of piling up duplicates.
// ===========================================================================

// MARK: - The one number-space a song lives in

struct SongVector {
    let song: Song
    let features: TrackFeatures?

    let energy: Double       // 0…1 loudness + liveness
    let brightness: Double   // 0…1 treble share
    let warmth: Double       // 0…1 low-mid share
    let vocal: Double        // 0…1 centered-voice dominance
    let tempoN: Double       // 0…1 over 60…180 BPM
    let beat: Double         // 0…1 regularity
    let hype: Double         // 0…1 combined "go" factor
    let valence: Double      // 0…1 bright+fast+dynamic ≈ "up" feeling
    let familiarity: Double  // 0…1 play count, squashed
    let liked: Double        // 0 or 1
    let recency: Double      // 0…1 (1 = added in the last few days)
    let arabic: Double       // 0…1 Arabic script / Arabic genre
    let quality: Double      // 0…1 how clean the master looks
    let hourFit: Double      // 0…1 "you usually play this at THIS hour"
    let genre: String
    let artistKey: String
    let hours: [Int: Int]    // play history per hour of day

    /// Feature axes used for clustering and flow ordering (all 0…1).
    var dims: [Double] { [energy, brightness, warmth, vocal, tempoN] }

    var isAnalyzed: Bool { features != nil }
}

// MARK: - Recipes

/// One auto-playlist idea: a hard gate plus a preference score.
struct PlaylistRecipe {
    let kind: String
    let title: String
    let titleAr: String
    let icon: String
    let minSongs: Int
    let maxSongs: Int
    let gate: (SongVector) -> Bool
    let score: (SongVector) -> Double

    static let all: [PlaylistRecipe] = [
        PlaylistRecipe(kind: "gym", title: "Gym & Run", titleAr: "جلد وجري",
                       icon: "figure.run", minSongs: 6, maxSongs: 45,
                       gate: { $0.hype > 0.40 && $0.tempoN > 0.30 },
                       score: { 1.25 * $0.hype + 0.6 * $0.tempoN + 0.25 * $0.beat + 0.3 * $0.familiarity }),

        PlaylistRecipe(kind: "party", title: "Farah / Party", titleAr: "فرح وحفلة",
                       icon: "sparkles", minSongs: 6, maxSongs: 50,
                       gate: { $0.energy > 0.42 && $0.beat > 0.18 },
                       score: { 1.1 * $0.energy + 0.7 * $0.hype + 0.4 * $0.arabic + 0.3 * $0.liked }),

        PlaylistRecipe(kind: "calm", title: "Wind Down", titleAr: "هدوء",
                       icon: "moon.stars.fill", minSongs: 6, maxSongs: 40,
                       gate: { $0.energy < 0.55 },
                       score: { 1.3 * (1 - $0.energy) + 0.5 * $0.warmth + 0.35 * $0.familiarity }),

        PlaylistRecipe(kind: "sleep", title: "Sleep", titleAr: "نوم",
                       icon: "zzz", minSongs: 6, maxSongs: 35,
                       gate: { $0.energy < 0.42 && $0.tempoN < 0.45 },
                       score: { 1.5 * (1 - $0.energy) + 0.6 * (1 - $0.brightness) + 0.4 * (1 - $0.beat) }),

        PlaylistRecipe(kind: "focus", title: "Focus / No Words", titleAr: "مذاكرة",
                       icon: "brain.head.profile", minSongs: 6, maxSongs: 45,
                       gate: { $0.vocal < 0.62 || $0.genre.contains("Instrumental") || $0.genre.contains("Soundtrack") || $0.genre.contains("Classical") },
                       score: { 1.4 * (1 - $0.vocal) + 0.5 * (1 - $0.energy) + 0.3 * (1 - $0.beat) }),

        PlaylistRecipe(kind: "drive", title: "Road Trip", titleAr: "سهرية طريق",
                       icon: "car.fill", minSongs: 6, maxSongs: 45,
                       gate: { $0.hype > 0.32 && $0.hype < 0.92 },
                       score: { 0.9 * $0.hype + 0.5 * $0.valence + 0.35 * $0.quality + 0.25 * $0.arabic }),

        PlaylistRecipe(kind: "arabic", title: "Arabic Nights", titleAr: "ليالي عربية",
                       icon: "moon.fill", minSongs: 4, maxSongs: 50,
                       gate: { $0.arabic > 0.45 },
                       score: { 1.6 * $0.arabic + 0.5 * $0.warmth + 0.45 * $0.vocal + 0.3 * $0.familiarity }),

        PlaylistRecipe(kind: "night", title: "Late Night", titleAr: "بعد منتصف الليل",
                       icon: "cloud.moon.fill", minSongs: 5, maxSongs: 40,
                       gate: { $0.energy < 0.5 && ($0.warmth > 0.30 || $0.arabic > 0.4) },
                       score: { 1.2 * (1 - $0.brightness) + 0.8 * (1 - $0.energy) + 0.5 * $0.arabic }),

        PlaylistRecipe(kind: "fresh", title: "Fresh Finds", titleAr: "جديد المكتبة",
                       icon: "sparkle.magnifyingglass", minSongs: 3, maxSongs: 25,
                       gate: { $0.recency > 0.35 && $0.familiarity < 0.2 },
                       score: { 1.7 * $0.recency - 0.6 * $0.familiarity + 0.3 * $0.energy }),

        PlaylistRecipe(kind: "repeat", title: "On Repeat", titleAr: "الأكثر تشغيلًا",
                       icon: "arrow.triangle.2.circlepath", minSongs: 4, maxSongs: 30,
                       gate: { $0.familiarity > 0.25 },
                       score: { 1.8 * $0.familiarity + 0.4 * $0.liked }),

        PlaylistRecipe(kind: "gems", title: "Hidden Gems", titleAr: "جواهر منسية",
                       icon: "gem", minSongs: 4, maxSongs: 30,
                       gate: { $0.familiarity < 0.12 },
                       score: { 1.1 * $0.liked + 0.55 * $0.valence + 0.45 * $0.quality - 0.3 * $0.energy }),

        PlaylistRecipe(kind: "master", title: "Best Sounding", titleAr: "أفضل صوت",
                       icon: "waveform.path.ecg", minSongs: 4, maxSongs: 25,
                       gate: { $0.isAnalyzed },
                       score: { 1.9 * $0.quality + 0.3 * $0.liked }),
    ]

    static func named(_ kind: String) -> PlaylistRecipe? { all.first { $0.kind == kind } }
}

// MARK: - Suggestions

struct SmartPlaylistSuggestion: Identifiable, Equatable {
    let kind: String
    let title: String
    let blurb: String
    let icon: String
    let songIDs: [UUID]
    let usesAI: Bool

    var id: String { kind }
    var count: Int { songIDs.count }
    static func == (l: SmartPlaylistSuggestion, r: SmartPlaylistSuggestion) -> Bool {
        l.kind == r.kind && l.title == r.title && l.songIDs == r.songIDs
    }
}

// MARK: - Registry: which playlists are ours, so refresh is in-place

final class SmartPlaylistStore {
    static let shared = SmartPlaylistStore()

    struct Entry: Codable {
        var kind: String
        var playlistID: UUID
        var name: String
        var songCount: Int
        var updatedAt: Date
    }

    private(set) var entries: [Entry] = []
    private let key = "asmusic_smart_playlists"
    private let lock = NSLock()

    private init() { load() }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([Entry].self, from: d) else { return }
        entries = arr
    }

    private func save() {
        let snapshot = entries
        guard let d = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    func entry(for kind: String) -> Entry? { entries.first { $0.kind == kind } }
    func playlistID(for kind: String) -> UUID? { entry(for: kind)?.playlistID }
    func isSmart(_ playlistID: UUID) -> Bool { entries.contains { $0.playlistID == playlistID } }
    func kind(for playlistID: UUID) -> String? { entries.first { $0.playlistID == playlistID }?.kind }

    func set(kind: String, playlistID: UUID, name: String, count: Int) {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.kind == kind }) {
            entries[i] = Entry(kind: kind, playlistID: playlistID, name: name,
                               songCount: count, updatedAt: Date())
        } else {
            entries.append(Entry(kind: kind, playlistID: playlistID, name: name,
                                 songCount: count, updatedAt: Date()))
        }
        save()
    }

    func remove(kind: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.kind == kind }
        save()
    }

    /// Forgets entries whose playlist the user deleted by hand.
    func prune(existing: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        let before = entries.count
        entries = entries.filter { existing.contains($0.playlistID) }
        if entries.count != before { save() }
    }
}

// MARK: - The engine

final class SmartPlaylistEngine: ObservableObject {
    static let shared = SmartPlaylistEngine()

    @Published private(set) var suggestions: [SmartPlaylistSuggestion] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var lastRun: Date? = nil
    @Published private(set) var coverage: Double = 0
    @Published var lastNote: String? = nil
    @Published var lastError: String? = nil

    /// Create/refresh smart playlists automatically (on launch + after a
    /// download), at most once every `minHoursBetweenAutoRuns`.
    @Published var autoCreate: Bool {
        didSet { UserDefaults.standard.set(autoCreate, forKey: Self.autoKey) }
    }
    /// Order tracks for smooth transitions instead of just by score.
    @Published var flowOrdering: Bool {
        didSet { UserDefaults.standard.set(flowOrdering, forKey: Self.flowKey) }
    }
    /// How many vibe clusters to build (0 = off).
    @Published var clusterCount: Int {
        didSet { UserDefaults.standard.set(clusterCount, forKey: Self.clusterKey) }
    }

    private static let autoKey = "asmusic_smart_auto"
    private static let flowKey = "asmusic_smart_flow"
    private static let clusterKey = "asmusic_smart_clusters"
    private static let lastRunKey = "asmusic_smart_automation_at"
    private static let lastSigKey = "asmusic_smart_library_sig"
    private let minHoursBetweenAutoRuns = 6.0

    private var inFlight = false
    private var autoSyncItem: DispatchWorkItem?

    private init() {
        autoCreate = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
        flowOrdering = UserDefaults.standard.object(forKey: Self.flowKey) as? Bool ?? true
        clusterCount = UserDefaults.standard.object(forKey: Self.clusterKey) as? Int ?? 3
    }

    // MARK: Build

    /// Recomputes suggestions from the current library. Cheap enough to run on
    /// the main thread for a normal library (it only touches cached numbers).
    func rebuild(force: Bool = false) {
        let mm = MusicManager.shared
        guard !mm.songs.isEmpty else {
            suggestions = []
            coverage = 0
            lastNote = "Nothing in the Library yet — download a few songs first."
            return
        }
        if isGenerating, !force { return }
        isGenerating = true
        AudioLab.shared.prime(mm.songs)
        coverage = AudioLab.shared.coverage(of: mm.songs)

        let vs = vectors()
        var out: [SmartPlaylistSuggestion] = []

        for recipe in PlaylistRecipe.all {
            let matched = vs.filter { recipe.gate($0) }
            guard matched.count >= recipe.minSongs else { continue }
            let ranked = matched
                .map { (v: $0, s: recipe.score($0) + 0.3 * $0.hourFit) }
                .sorted { $0.s > $1.s }
                .prefix(recipe.maxSongs)
                .map { $0.v }
            guard ranked.count >= recipe.minSongs else { continue }
            let ordered = flowOrdering ? PlaylistFlow.order(ranked) : ranked
            let blurb = PlaylistFlow.describe(ordered, basis: "for \(recipe.title)")
            out.append(SmartPlaylistSuggestion(kind: recipe.kind, title: recipe.title,
                                               blurb: blurb, icon: recipe.icon,
                                               songIDs: ordered.map { $0.song.id },
                                               usesAI: false))
        }

        // Vibe clusters, named from what they actually sound like.
        for (i, c) in clusters(from: vs).enumerated() {
            guard c.vectors.count >= 5 else { continue }
            let ordered = flowOrdering ? PlaylistFlow.order(c.vectors) : c.vectors
            out.append(SmartPlaylistSuggestion(kind: "vibe\(i + 1)", title: c.name,
                                               blurb: c.blurb, icon: "circle.hexagongrid.fill",
                                               songIDs: ordered.map { $0.song.id },
                                               usesAI: false))
        }

        suggestions = out
        SmartPlaylistStore.shared.prune(existing: Set(mm.playlists.map { $0.id }))
        isGenerating = false
    }

    /// One tap on "Create all": updates existing smart playlists in place.
    @discardableResult
    func applyAll() -> Int {
        rebuildIfNeeded()
        var made = 0
        for s in suggestions where apply(s) { made += 1 }
        if made > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            lastNote = "Updated \(made) smart playlist\(made == 1 ? "" : "s")."
        }
        return made
    }

    /// Create or refresh one suggestion.
    @discardableResult
    func apply(_ s: SmartPlaylistSuggestion) -> Bool {
        guard !s.songIDs.isEmpty else { return false }
        let mm = MusicManager.shared
        let id = SmartPlaylistStore.shared.playlistID(for: s.kind)
        if let id = id, let idx = mm.playlists.firstIndex(where: { $0.id == id }) {
            mm.playlists[idx].songIDs = s.songIDs
            mm.savePlaylists()
            SmartPlaylistStore.shared.set(kind: s.kind, playlistID: id,
                                           name: s.title, count: s.songIDs.count)
            return true
        }
        mm.createPlaylist(name: s.title)
        guard let idx = mm.playlists.indices.last else { return false }
        let newID = mm.playlists[idx].id
        mm.playlists[idx].songIDs = s.songIDs
        mm.savePlaylists()
        SmartPlaylistStore.shared.set(kind: s.kind, playlistID: newID,
                                       name: s.title, count: s.songIDs.count)
        return true
    }

    func removeSmart(kind: String) {
        let mm = MusicManager.shared
        if let id = SmartPlaylistStore.shared.playlistID(for: kind),
           let idx = mm.playlists.firstIndex(where: { $0.id == id }) {
            mm.playlists.remove(at: idx)
            mm.savePlaylists()
        }
        SmartPlaylistStore.shared.remove(kind: kind)
        if let i = suggestions.firstIndex(where: { $0.kind == kind }) {
            suggestions.remove(at: i)
        }
    }

    // MARK: Automation

    private func rebuildIfNeeded() {
        if suggestions.isEmpty { rebuild(force: true) }
    }

    /// Called after the library loads and after each download. Throttled: it
    /// only re-runs when the library actually changed or the last run is stale.
    func autoSyncIfNeeded() {
        let defaults = UserDefaults.standard
        let sig = librarySignature()
        let lastRunTime = defaults.double(forKey: Self.lastRunKey)
        let lastSig = defaults.string(forKey: Self.lastSigKey) ?? ""
        let hoursOld = Date().timeIntervalSince(Date(timeIntervalSince1970: lastRunTime)) / 3600
        let changed = sig != lastSig
        // Run when the library moved, or when the last refresh is stale.
        guard autoCreate, changed || hoursOld > minHoursBetweenAutoRuns else { return }

        // Never fight the user for the CPU while they are doing something.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, !self.inFlight else { return }
            self.inFlight = true
            self.rebuild(force: true)
            let n = self.applyAll()
            self.inFlight = false
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)
            defaults.set(sig, forKey: Self.lastSigKey)
            if n > 0 {
                NotificationCenter.default.post(name: .smartPlaylistsChanged, object: nil,
                                                userInfo: ["count": n])
            }
        }
    }

    func forceAutoSync() {
        UserDefaults.standard.set(0, forKey: Self.lastRunKey)
        autoSyncIfNeeded()
    }

    /// Debounce for "a song was just downloaded" — rebuild once after the
    /// queue settles instead of once per file while a batch is running.
    func scheduleAutoSync(delay: TimeInterval) {
        autoSyncItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.autoSyncIfNeeded() }
        autoSyncItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, delay), execute: item)
    }

    /// Siri/Shortcuts entry point: build or refresh the recipe for a moment and
    /// start playing it. Returns the title so the intent can speak it.
    func playMoment(_ kind: String) -> String {
        if suggestions.isEmpty { rebuild(force: true) }
        let target = suggestions.first { $0.kind == kind }
            ?? suggestions.max(by: { $0.count < $1.count })
        guard let target = target, target.count > 0, apply(target) else {
            MusicManager.shared.shuffleAll()
            return "your library"
        }
        if let id = SmartPlaylistStore.shared.playlistID(for: target.kind),
           let pl = MusicManager.shared.playlists.first(where: { $0.id == id }) {
            MusicManager.shared.playPlaylist(pl)
        }
        return target.title
    }

    /// Stable across launches on purpose: `String.hashValue` is randomized
    /// every process, which would make every signature "new" and rebuild the
    /// playlists on each launch.
    private func librarySignature() -> String {
        let mm = MusicManager.shared
        let ids = mm.songs.map { $0.id.uuidString }.sorted().joined(separator: ",")
        return "\(mm.songs.count)-\(StableKey.make(ids))"
    }

    // MARK: Vectors

    /// Turns the library into the 0…1 space everything else reasons about.
    func vectors() -> [SongVector] {
        let mm = MusicManager.shared
        let liked = Set(mm.playlists.first(where: { $0.name == "Liked Songs" })?.songIDs ?? [])
        let history = ListenHistory.shared
        let now = Date()
        var out: [SongVector] = []
        out.reserveCapacity(mm.songs.count)

        for s in mm.songs {
            let f = AudioLab.shared.features(for: s)
            let plays = history.playCount(for: s)
            let rec = history.hours(for: s.id)
            let recency = recencyOf(s.url, now: now)
            let hour = Calendar.current.component(.hour, from: now)
            let hourFit = min(1.0, Double(rec[hour] ?? 0) / 3.0)
            let genre = (s.genre ?? "").trimmingCharacters(in: .whitespaces)
            let arabicFlag: Double = WikipediaAPI.hasArabicScript("\(s.artist) \(s.title)") ? 1
                : (genre.lowercased().contains("arabic") || genre.lowercased().contains("african") || genre.lowercased().contains("middle east") ? 0.8 : 0)

            let energy = f?.energy ?? 0.5
            let bright = f.map { FeatureMath.clamp01($0.presence * 1.6 + $0.air * 1.1) } ?? 0.5
            let warm = f.map { FeatureMath.clamp01($0.warmth * 1.7) } ?? 0.5
            let vocal = f?.vocalCenter ?? 0.55
            let tempoN = f.map { FeatureMath.norm($0.tempo, 60, 180) } ?? 0.45
            let beat = f?.beatStrength ?? 0.3
            let valence = min(1, max(0, 0.45 * bright + 0.35 * energy + 0.2 * (1 - warm * 0.6)))
            let hype = f?.hype ?? (0.55 * energy + 0.25 * tempoN + 0.2 * beat)
            let quality: Double = {
                guard let f = f else { return 0.5 }
                let clipPenalty = min(0.5, f.clipRatio * 60)
                let tooQuiet = f.loudness < -24 ? min(0.4, (-24 - f.loudness) / 22) : 0
                let crushed = f.dynRange < 3.5 ? 0.25 : (f.dynRange < 6 ? 0.1 : 0)
                let bonus = f.dynRange > 8 ? 0.1 : 0
                return FeatureMath.clamp01(0.75 + bonus - clipPenalty - tooQuiet - crushed)
            }()

            out.append(SongVector(song: s, features: f,
                                  energy: energy, brightness: bright, warmth: warm,
                                  vocal: vocal, tempoN: tempoN, beat: beat, hype: hype,
                                  valence: valence,
                                  familiarity: min(1, Double(plays) / 12),
                                  liked: liked.contains(s.id) ? 1 : 0,
                                  recency: recency, arabic: arabicFlag, quality: quality,
                                  genre: genre,
                                  hourFit: hourFit,
                                  artistKey: s.artist.trimmingCharacters(in: .whitespaces).lowercased(),
                                  hours: rec))
        }
        return out
    }

    /// 1.0 = added today, 0 = older than a month. Uses the file's own
    /// timestamp, so it also works for songs copied in via Files/AirDrop.
    private func recencyOf(_ url: URL, now: Date) -> Double {
        guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { return 0.5 }
        let days = max(0, now.timeIntervalSince(d) / 86400)
        if days < 2 { return 1 }
        if days > 30 { return 0 }
        return 1 - (days - 2) / 28
    }

    // MARK: Vibe clusters (deterministic k-means)

    struct VibeCluster {
        var name: String
        var blurb: String
        var vectors: [SongVector]
    }

    /// Groups the library by sound, then names each group from its centroid.
    /// Deterministic (farthest-point seeding, fixed iteration count) so the
    /// same library always produces the same playlists.
    func clusters(from vs: [SongVector]) -> [VibeCluster] {
        let k = max(0, min(clusterCount, 5))
        let analyzed = vs.filter { $0.isAnalyzed }
        guard k > 0, analyzed.count >= 10 else { return [] }

        let dimCount = 5
        func centroid(_ group: [SongVector]) -> [Double] {
            guard !group.isEmpty else { return [Double](repeating: 0.5, count: dimCount) }
            var acc = [Double](repeating: 0, count: dimCount)
            for v in group {
                let d = v.dims
                for i in 0..<dimCount where i < d.count { acc[i] += d[i] }
            }
            return acc.map { $0 / Double(group.count) }
        }

        // Seed: start at the "most central" song, then repeatedly take the
        // point farthest from every seed so far.
        var seeds: [[Double]] = []
        let allDims = analyzed.map { $0.dims }
        var bestCentral = 0
        var bestScore = Double.greatestFiniteMagnitude
        for (i, a) in allDims.enumerated() {
            var s = 0.0
            for b in allDims { s += FeatureMath.distance(a, b) }
            if s < bestScore { bestScore = s; bestCentral = i }
        }
        seeds.append(allDims[bestCentral])

        while seeds.count < k {
            var far = 0
            var farDist = -1.0
            for (i, a) in allDims.enumerated() {
                let d = seeds.map { FeatureMath.distance(a, $0) }.min() ?? 0
                if d > farDist { farDist = d; far = i }
            }
            if farDist <= 0.02 { break }
            seeds.append(allDims[far])
        }
        guard seeds.count >= 2 else { return [] }

        var cents = seeds
        var groups = [[SongVector]](repeating: [], count: cents.count)
        var iter = 0
        while iter < 8 {
            iter += 1
            groups = [[SongVector]](repeating: [], count: cents.count)
            for v in analyzed {
                let d = v.dims
                var bestIdx = 0
                var bestD = Double.greatestFiniteMagnitude
                for (i, c) in cents.enumerated() {
                    let dist = FeatureMath.distance(d, c)
                    if dist < bestD { bestD = dist; bestIdx = i }
                }
                groups[bestIdx].append(v)
            }
            var moved = false
            for i in 0..<cents.count where !groups[i].isEmpty {
                let newC = centroid(groups[i])
                if FeatureMath.distance(newC, cents[i]) > 0.01 { moved = true }
                cents[i] = newC
            }
            if !moved { break }
        }

        return groups.enumerated().compactMap { (i, g) -> VibeCluster? in
            guard g.count >= 5 else { return nil }
            let c = centroid(g)
            let name = VibeNamer.name(centroid: c, group: g)
            let blurb = PlaylistFlow.describe(g, basis: name)
            _ = i
            return VibeCluster(name: name, blurb: blurb, vectors: g)
        }
    }
}

// MARK: - Naming

/// Turns a cluster centroid into a human name. English + Arabic-aware, no
/// network, no randomness: same sound → same name.
enum VibeNamer {
    static func name(centroid c: [Double], group: [SongVector]) -> String {
        let energy = c.count > 0 ? c[0] : 0.5
        let bright = c.count > 1 ? c[1] : 0.5
        let warm = c.count > 2 ? c[2] : 0.5
        let vocal = c.count > 3 ? c[3] : 0.5
        let tempo = c.count > 4 ? c[4] : 0.5

        let speed = tempo > 0.62 ? "Fast" : (tempo < 0.34 ? "Slow" : "Mid-Tempo")
        let texture = bright > 0.62 ? "Bright" : (warm > 0.55 ? "Warm" : (vocal < 0.5 ? "Instrumental" : "Clean"))
        let power = energy > 0.65 ? "Loud" : (energy < 0.35 ? "Soft" : "Steady")

        let arabicHeavy = FeatureMath.mean(group.map { $0.arabic }) > 0.5
        let noun = arabicHeavy ? "Set" : "Mix"

        if arabicHeavy {
            let aSpeed = tempo > 0.62 ? "نشيط" : (tempo < 0.34 ? "هادئ" : "متوازن")
            return "\(aSpeed) · \(power) \(noun)"
        }
        return "\(speed) \(texture) \(noun)"
    }
}

// MARK: - Flow ordering (make it play like a DJ mixed it)

enum PlaylistFlow {
    /// Weighted distance between two songs — small = they follow each other
    /// cleanly. Tempo jumps count double, and an artist repeat is penalized.
    static func transitionCost(_ a: SongVector, _ b: SongVector) -> Double {
        let d = FeatureMath.distance(a.dims, b.dims)
        var cost = d * 1.0
        cost += abs(a.tempoN - b.tempoN) * 1.6
        cost += abs(a.energy - b.energy) * 0.8
        if !a.artistKey.isEmpty, a.artistKey == b.artistKey { cost += 0.55 }
        if a.genre == b.genre, !a.genre.isEmpty { cost -= 0.06 }
        return max(0.01, cost)
    }

    /// Greedy nearest-neighbour chain from the best opener, then one smoothing
    /// pass of adjacent swaps. O(n²) — for a 50-song playlist that's 2 500
    /// cheap comparisons, invisible on the main thread.
    static func order(_ vs: [SongVector]) -> [SongVector] {
        guard vs.count > 2 else { return vs }
        var pool = vs
        var out: [SongVector] = []
        pool.sort { openerScore($0) > openerScore($1) }
        let first = pool.removeFirst()
        out.append(first)

        while !pool.isEmpty {
            let last = out[out.count - 1]
            var bestIdx = 0
            var bestCost = Double.greatestFiniteMagnitude
            for (i, c) in pool.enumerated() {
                let cost = transitionCost(last, c)
                if cost < bestCost { bestCost = cost; bestIdx = i }
            }
            out.append(pool.remove(at: bestIdx))
        }

        // Smoothing pass: swap neighbours when it shortens the chain.
        var improved = true
        var passes = 0
        while improved, passes < 3 {
            improved = false
            passes += 1
            var i = 1
            while i + 1 < out.count {
                let prev = out[i - 1]
                let a = out[i], b = out[i + 1]
                let cur = transitionCost(prev, a) + transitionCost(a, b)
                let alt = transitionCost(prev, b) + transitionCost(b, a)
                if alt + 0.001 < cur {
                    out.swapAt(i, i + 1)
                    improved = true
                }
                i += 1
            }
        }
        return out
    }

    /// A good opener is familiar, liked, and mid-to-high energy (never the
    /// quietest song in the list).
    static func openerScore(_ v: SongVector) -> Double {
        0.8 * v.liked + 0.6 * v.familiarity + 0.5 * (1 - abs(v.energy - 0.62)) + 0.3 * v.quality
    }

    /// One-line explanation the UI shows under each playlist.
    static func describe(_ vs: [SongVector], basis: String) -> String {
        guard !vs.isEmpty else { return basis }
        let tempo = FeatureMath.mean(vs.compactMap { f -> Double? in
            guard let t = f.features?.tempo, t > 0 else { return nil }
            return t
        })
        var parts: [String] = ["\(vs.count) songs"]
        if tempo > 0 { parts.append("~\(Int(tempo.rounded())) BPM") }
        let e = FeatureMath.mean(vs.map { $0.energy })
        parts.append(e > 0.6 ? "high energy" : (e < 0.38 ? "calm" : "mid energy"))
        if FeatureMath.mean(vs.map { $0.arabic }) > 0.5 { parts.append("Arabic-heavy") }
        if FeatureMath.mean(vs.map { $0.liked }) > 0.3 { parts.append("mostly liked") }
        _ = basis
        return parts.joined(separator: " · ")
    }
}

// MARK: - Natural-language generation (AI when configured, local parser always)

/// A parsed playlist request.
struct PlaylistBrief {
    var title: String
    var weights: [String: Double] = [:]
    var minTempo: Double? = nil
    var maxTempo: Double? = nil
    var wantInstrumental = false
    var wantVocal = false
    var wantArabic = false
    var genreWords: [String] = []
    var artistWords: [String] = []
    var banned: [String] = []
}

enum PlaylistBriefParser {
    /// Keyword tables for English, Arabic and "Franco" (Arabic typed in Latin
    /// letters), because that's how people actually search in this app.
    private static let table: [(words: [String], apply: (inout PlaylistBrief) -> Void)] = [
        (["gym", "workout", "run", "running", "cardio", "hype", "جلد", "جيم", "رياضة", "جري", "حماس", "sport"], { b in
            b.title = "Gym Hype"
            b.weights["energy"] = 1.4; b.weights["hype"] = 1.2; b.weights["tempoN"] = 0.8
            b.minTempo = 112
        }),
        (["party", "farah", "wedding", "dance", "حفلة", "فرح", "عرس", "رقص", "دلع"], { b in
            b.title = "Party Mix"
            b.weights["energy"] = 1.2; b.weights["beat"] = 1.0; b.weights["hype"] = 0.7
            b.minTempo = 100; b.wantArabic = true
        }),
        (["chill", "relax", "calm", "quiet", "cozy", "tea", "هادي", "هدوء", "استرخاء", "شاي", "قهاوة"], { b in
            b.title = "Chill"
            b.weights["energy"] = -1.3; b.weights["warmth"] = 0.6
            b.maxTempo = 104
        }),
        (["sleep", "bed", "night", "insomnia", "نوم", "ليل", "ليلي", "مص"], { b in
            b.title = "Sleep"
            b.weights["energy"] = -1.5; b.weights["brightness"] = -0.7; b.weights["beat"] = -0.6
            b.maxTempo = 92
        }),
        (["focus", "study", "work", "code", "read", "مذاكرة", "شغل", "تركيز", "قرايه", "دراسة"], { b in
            b.title = "Focus Flow"
            b.weights["vocal"] = -1.4; b.weights["energy"] = -0.5
            b.wantInstrumental = true
        }),
        (["drive", "road", "car", "trip", "taxi", "سهره", "سهر", "مشوار", "سيارة", "طريق", "تاكسي"], { b in
            b.title = "Drive"
            b.weights["hype"] = 0.8; b.weights["quality"] = 0.7; b.weights["valence"] = 0.5
        }),
        (["arabic", "araby", "masry", "egypt", "egyptian", "shaabi", "mahraganat", "tarab",
          "عربي", "مصري", "شعبي", "مهرجانات", "طرب", "ام كلثوم", "عبد الحليم"], { b in
            b.title = "Arabic Cuts"
            b.wantArabic = true; b.weights["warmth"] = 0.5; b.weights["vocal"] = 0.4
        }),
        (["love", "romantic", "slow jam", "غرام", "رومانسي", "حب", "رومانس"], { b in
            b.title = "Romance"
            b.weights["vocal"] = 0.7; b.weights["warmth"] = 0.6; b.weights["energy"] = -0.4
            b.maxTempo = 108; b.wantArabic = false
        }),
        (["sad", "melancholy", "lonely", "حزين", "زعلان", "كآبة"], { b in
            b.title = "Sad Songs"
            b.weights["brightness"] = -0.9; b.weights["energy"] = -0.7
        }),
        (["happy", "upbeat", "good vibe", "sunn", "فرحه", "مبهج", "نور", "صافي"], { b in
            b.title = "Good Vibes"
            b.weights["valence"] = 1.2; b.weights["brightness"] = 0.6; b.weights["energy"] = 0.5
        }),
        (["old", "classic", "retro", "70s", "80s", "90s", "قديم", "كلاسيك", "زمان"], { b in
            b.title = "Classics"
            b.weights["warmth"] = 0.8; b.weights["quality"] = -0.2; b.weights["recency"] = -1.2
        }),
        (["new", "fresh", "recent", "جديد", "حديث", "النزلة"], { b in
            b.title = "Fresh Cuts"
            b.weights["recency"] = 2.0
        }),
        (["top", "best", "favourite", "favorite", "favorite", "أفضل", "أحلي", "المفضلة"], { b in
            b.title = "Best Of"
            b.weights["liked"] = 1.6; b.weights["familiarity"] = 0.9
        }),
        (["instrumental", "no vocals", "no words", "music only", "بدون غنا", "موسيقي", "فقط موسيقي", "من غير غنا"], { b in
            b.title = "Instrumental"
            b.wantInstrumental = true; b.weights["vocal"] = -1.5
        }),
        (["vocal", "a cappella", "acapella", "غنا", "صوت"], { b in
            b.weights["vocal"] = 0.9
            if b.title.isEmpty { b.title = "Vocal Forward" }
        }),
        (["loud", "mastered", "good sound", "صوت نضيف", "جودة عالية"], { b in
            b.title = "Well Mastered"
            b.weights["quality"] = 1.8
        }),
    ]

    private static let bannedMarkers = ["no ", "not ", "without ", "avoid ", "بدون ", "من غير ", "مش "]

    static func parse(_ text: String) -> PlaylistBrief {
        let lower = " " + text.lowercased() + " "
        var brief = PlaylistBrief(title: "")
        var hits = 0
        for row in table where row.words.contains(where: { lower.contains($0.lowercased()) }) {
            row.apply(&brief)
            hits += 1
        }

        // "no rap", "بدون مهرجانات" → exclusion list.
        for marker in bannedMarkers {
            guard let r = lower.range(of: marker) else { continue }
            let tail = lower[r.upperBound...].split(separator: " ").prefix(3)
            for w in tail where w.count > 2 { brief.banned.append(String(w)) }
        }

        // Any 3+ letter word that looks like a genre name also filters.
        for g in ["rock", "pop", "rap", "hip hop", "electro", "techno", "jazz", "blues", "reggaeton",
                  "lofi", "lo-fi", "country", "metal", "indie", "soul", "funk", "trap", "dj"]
        where lower.contains(g) {
            brief.genreWords.append(g)
        }

        // A word that matches an artist in the library is a strong signal.
        let artists = Set(MusicManager.shared.songs.map { $0.artist.lowercased() })
        for word in lower.split(separator: " ") where word.count >= 4 {
            let w = String(word).trimmingCharacters(in: .alphanumerics.inverted)
            if artists.contains(w) { brief.artistWords.append(w) }
        }

        if brief.title.isEmpty || hits == 0 {
            // Fall back to something honest instead of a fake name.
            let key = lower.split(separator: " ").prefix(3).joined(separator: " ")
            brief.title = key.isEmpty ? "My Mix" : String(key.prefix(24)).capitalized
        }
        return brief
    }
}

extension SmartPlaylistEngine {

    /// Generate a playlist from a sentence. With a Gemini key configured the
    /// model picks and names it from your library; without one the local
    /// Arabic/English parser does the same job offline.
    func generate(from request: String, completion: ((String?) -> Void)? = nil) {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { completion?(nil); return }
        let mm = MusicManager.shared
        guard mm.songs.count >= 4 else {
            lastError = "Add a few more songs first — I need at least 4 to build a mix."
            completion?(lastError)
            return
        }

        let vs = vectors()
        let brief = PlaylistBriefParser.parse(text)
        let aiOn = GeminiAI.shared.isConfigured

        let finish: (PlaylistBrief) -> Void = { b in
            let picked = self.pick(with: b, from: vs)
            guard picked.count >= 4 else {
                self.lastError = "I couldn't find \(picked.count) songs matching “\(text)”. Try a broader mood."
                completion?(self.lastError)
                return
            }
            let ordered = self.flowOrdering ? PlaylistFlow.order(picked) : picked
            let title = b.title.isEmpty ? String(text.prefix(24)) : b.title
            let sug = SmartPlaylistSuggestion(kind: "req-" + StableKey.make(text.lowercased()),
                                               title: title,
                                               blurb: PlaylistFlow.describe(ordered, basis: title)
                                                + (aiOn ? " · AI picks" : " · on-device picks"),
                                               icon: "wand.and.stars",
                                               songIDs: ordered.map { $0.song.id },
                                               usesAI: aiOn)
            if self.apply(sug) {
                self.suggestions.insert(sug, at: 0)
                self.lastNote = "“\(title)” — \(ordered.count) songs, ready in Playlists."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                completion?(nil)
            } else {
                self.lastError = "Could not save the playlist."
                completion?(self.lastError)
            }
        }

        guard aiOn else { finish(brief); return }

        // Ask the model to name + re-rank the candidate set, not to invent
        // songs: it only ever sees (and chooses from) your own library.
        let catalog = vs.enumerated().prefix(160).map { i, v -> String in
            let e = Int((v.energy * 100).rounded())
            let b = Int((v.brightness * 100).rounded())
            let t = Int(v.tempoN * 180 + 60)
            return "\(i)|\(v.song.title)|\(v.song.artist)|\(v.genre)|E\(e)B\(b)T\(t)"
        }.joined(separator: "\n")
        let system = """
        You are a DJ inside a personal offline music player. The user wants a playlist built from their OWN library.
        You receive one line per track: index|title|artist|genre|energy0-100,brightness0-100,tempoBPM.
        Reply with ONLY valid JSON, no markdown:
        {"name":"short punchy playlist title (max 30 chars, same language as the user's request)","selection":[indexes],"why":"max 9 words"}
        Rules: pick only indexes from the list; choose 8-30 that genuinely fit the mood; keep a smooth energy arc; never invent titles or artists; if the request is Arabic reply in Arabic.
        """
        let user = "Request: \(text)\n\nLibrary:\n\(catalog)"
        GeminiAI.shared.completeJSON(system: system, user: user) { [weak self] obj in
            guard let self = self else { completion?(nil); return }
            if let obj = obj, let sel = obj["selection"] as? [Any] {
                var chosen: [SongVector] = []
                for any in sel {
                    let i: Int
                    if let n = any as? Int { i = n }
                    else if let s = any as? String, let n = Int(s) { i = n }
                    else { continue }
                    if i >= 0, i < vs.count { chosen.append(vs[i]) }
                }
                if chosen.count >= 4 {
                    var b = brief
                    if let name = obj["name"] as? String,
                       !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        b.title = String(name.prefix(40))
                    }
                    let ordered = self.flowOrdering ? PlaylistFlow.order(chosen) : chosen
                    let why = (obj["why"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let sug = SmartPlaylistSuggestion(kind: "req-" + StableKey.make(text.lowercased()),
                                                       title: b.title,
                                                       blurb: why ?? PlaylistFlow.describe(ordered, basis: b.title),
                                                       icon: "wand.and.stars",
                                                       songIDs: ordered.map { $0.song.id },
                                                       usesAI: true)
                    if self.apply(sug) {
                        self.suggestions.insert(sug, at: 0)
                        self.lastNote = "AI built “\(b.title)” · \(ordered.count) songs"
                        completion?(nil)
                        return
                    }
                }
            }
            // Model unavailable / refused → the local parser still delivers.
            finish(brief)
        }
    }

    /// Scores every song against a brief and keeps the best.
    private func pick(with b: PlaylistBrief, from vs: [SongVector]) -> [SongVector] {
        var scored: [(v: SongVector, s: Double)] = []
        for v in vs {
            if !b.banned.isEmpty {
                let hay = "\(v.song.title) \(v.song.artist) \(v.genre)".lowercased()
                if b.banned.contains(where: { hay.contains($0) }) { continue }
            }
            if b.wantInstrumental, v.vocal > 0.66, !v.looksInstrumentalish { continue }
            if b.wantArabic, v.arabic < 0.4 { continue }
            if let mt = b.minTempo, v.features != nil, (v.features?.tempo ?? 0) < mt - 6 { continue }
            if let xt = b.maxTempo, v.features != nil, (v.features?.tempo ?? 0) > xt + 10 { continue }

            var s = 0.0
            for (k, w) in b.weights { s += w * v.axis(k) }
            if !b.genreWords.isEmpty {
                let hay = v.genre.lowercased()
                if b.genreWords.contains(where: { hay.contains($0) }) { s += 1.1 }
            }
            if !b.artistWords.isEmpty, b.artistWords.contains(v.artistKey) { s += 1.4 }
            if v.liked > 0 { s += 0.35 }
            s += 0.3 * v.hourFit
            if b.wantVocal, v.vocal > 0.6 { s += 0.5 }
            scored.append((v, s))
        }
        let sorted = scored.sorted { $0.s > $1.s }
        return sorted.prefix(30).map { $0.v }
    }
}

private extension SongVector {
    /// True when we can be reasonably sure the song has no lead voice: either
    /// the analysis says so, or we never measured it and it's a genre that
    /// usually is instrumental.
    var looksInstrumentalish: Bool {
        if let f = features { return f.looksInstrumental }
        let g = genre.lowercased()
        return g.contains("instrumental") || g.contains("classical") || g.contains("soundtrack")
    }

    func axis(_ key: String) -> Double {
        switch key {
        case "energy": return energy
        case "brightness": return brightness
        case "warmth": return warmth
        case "vocal": return vocal
        case "tempoN": return tempoN
        case "beat": return beat
        case "hype": return hype
        case "valence": return valence
        case "familiarity": return familiarity
        case "liked": return liked
        case "recency": return recency
        case "arabic": return arabic
        case "quality": return quality
        default: return 0.5
        }
    }
}

// MARK: - UI

/// The "Smart Playlists" card shown in the For You tab.
struct SmartPlaylistsSection: View {
    @ObservedObject private var engine = SmartPlaylistEngine.shared
    @ObservedObject private var lab = AudioLab.shared
    @EnvironmentObject private var mm: MusicManager
    @State private var request = ""
    @State private var busy = false
    @FocusState private var requestFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if lab.isWorking || lab.queueDepth > 0 {
                measuringBar
            }
            requestCard
            list
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.stack.3d.up.fill").foregroundColor(AppTheme.accent)
            Text("Smart Playlists").font(.headline).foregroundColor(.white)
            Spacer()
            Toggle("", isOn: Binding(
                get: { engine.autoCreate },
                set: { engine.autoCreate = $0 }
            )).labelsHidden().tint(AppTheme.accent)
            Text("auto").font(.caption2).foregroundColor(.gray)
        }
    }

    private var measuringBar: some View {
        HStack(spacing: 8) {
            ProgressView().progressViewStyle(.circular).tint(AppTheme.accent).scaleEffect(0.8)
            Text("Listening to your library… \(Int((lab.coverage(of: mm.songs) * 100).rounded()))% known")
                .font(.caption).foregroundColor(.gray)
            Spacer()
        }
    }

    private var requestCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.plus").foregroundColor(AppTheme.accent).font(.caption)
                TextField("Describe a playlist — “quiet arabic for a drive”, “جيم حماسية”", text: $request)
                    .font(.subheadline).foregroundColor(.white)
                    .focused($requestFocused)
                    .autocorrectionDisabled()
                    .onSubmit { run() }
            }
            HStack(spacing: 8) {
                Button(action: run) {
                    Label(busy ? "Building…" : "Make it", systemImage: "wand.and.stars")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(request.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color.gray.opacity(0.4) : AppTheme.accent)
                        .cornerRadius(16)
                }
                .disabled(busy || request.trimmingCharacters(in: .whitespaces).isEmpty)

                if !GeminiAI.shared.isConfigured {
                    Text("Offline mode — works with no key")
                        .font(.caption2).foregroundColor(.gray).lineLimit(1)
                } else {
                    Text("AI curation on").font(.caption2).foregroundColor(.green)
                }
                Spacer()
            }
            if let note = engine.lastNote {
                Text(note).font(.caption).foregroundColor(.green).fixedSize(horizontal: false, vertical: true)
            }
            if let err = engine.lastError {
                Text(err).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06)).cornerRadius(14)
    }

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(engine.suggestions) { s in
                row(s)
            }
            if engine.suggestions.isEmpty {
                Button {
                    engine.rebuild(force: true)
                } label: {
                    Label("Analyze library and suggest playlists", systemImage: "arrow.clockwise")
                        .font(.subheadline.bold()).foregroundColor(AppTheme.accent)
                        .frame(maxWidth: .infinity).padding(10)
                        .background(Color.white.opacity(0.06)).cornerRadius(12)
                }
            }
        }
    }

    private func row(_ s: SmartPlaylistSuggestion) -> some View {
        let created = SmartPlaylistStore.shared.playlistID(for: s.kind) != nil
        return HStack(spacing: 10) {
            Image(systemName: s.icon)
                .font(.system(size: 15)).foregroundColor(AppTheme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(s.title).font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                    if s.usesAI {
                        Image(systemName: "sparkles").font(.system(size: 8)).foregroundColor(.purple)
                    }
                }
                Text(s.blurb).font(.caption2).foregroundColor(.gray).lineLimit(2)
            }
            Spacer()
            Button {
                if engine.apply(s) {
                    engine.lastNote = "“\(s.title)” · \(s.count) songs"
                }
            } label: {
                Text(created ? "Refresh" : "Create")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(created ? Color.gray.opacity(0.6) : AppTheme.accent)
                    .cornerRadius(14)
            }
            if created {
                Button {
                    engine.removeSmart(kind: s.kind)
                } label: {
                    Image(systemName: "trash").font(.caption).foregroundColor(.gray)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05)).cornerRadius(12)
        .contextMenu {
            Button { mm.playSmartPlaylist(kind: s.kind) } label: {
                Label("Play now", systemImage: "play.fill")
            }
        }
    }

    private func run() {
        guard !busy else { return }
        busy = true
        requestFocused = false
        hideKeyboard()
        engine.generate(from: request) { _ in
            DispatchQueue.main.async { self.busy = false }
        }
    }
}

extension Notification.Name {
    static let smartPlaylistsChanged = Notification.Name("asmusic.smartPlaylistsChanged")
}

/// Launch-stable short hash (djb2 → base 36). Used for playlist kinds and
/// library signatures, where `String.hashValue` would change every launch.
enum StableKey {
    static func make(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        return String(h, radix: 36)
    }
}
