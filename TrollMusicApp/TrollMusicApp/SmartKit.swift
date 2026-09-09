import Foundation
import SwiftUI
import UIKit

// ===========================================================================
// MARK: - SmartKit
//
// The intelligence layer for AS Music. Everything here is built on FREE APIs:
//
//   • ListenHistory  — on-device listening stats (plays, recently played,
//                      most played) that make recommendations taste-driven.
//   • ITunesEnricher — Apple iTunes Search API (free, NO key): auto-fills
//                      missing cover art, real artist names and genres.
//   • WikipediaAPI   — Wikipedia REST API (free, NO key): artist bios +
//                      photos. Tries Arabic first for Arabic names.
//   • GeminiAI       — the multi-provider AI engine (Settings → AI
//                      Intelligence): APInex (apinex.bond — ONE key, 20+
//                      models incl. free tiers) or the user's own free
//                      Google Gemini key. It suggests real songs that
//                      download into the Library with one tap, and rotates
//                      models/providers automatically so a dead model never
//                      stops a feature. With no key set, NOTHING is sent
//                      anywhere — everything falls back to on-device logic.
//
// Free chart regions (Deezer, no key) are defined at the bottom.
// ===========================================================================

// MARK: - Listening history & stats

struct ListenRecord: Codable {
    var playCount: Int
    var lastPlayed: Date
    /// Plays bucketed by hour of day (0…23). Optional so history written before
    /// this existed still decodes — the smart playlists use it to learn that a
    /// song is a "morning" or "after-midnight" track.
    var hourCounts: [Int: Int]? = nil
}

struct ListeningStats: Equatable {
    var totalPlays: Int = 0
    var weekPlays: Int = 0
    var topSongTitle: String = ""
    var topArtistName: String = ""
}

/// Tracks what you actually play, on-device. Feeds "Recently Played",
/// "Your Listening" stats and taste weighting in recommendations.
final class ListenHistory: ObservableObject {
    static let shared = ListenHistory()

    @Published private(set) var records: [UUID: ListenRecord] = [:]

    private let fileURL: URL
    private static let storeKey = ".asmusic_history.json"

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent(Self.storeKey)
        if let d = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([UUID: ListenRecord].self, from: d) {
            records = decoded
        }
    }

    /// Call from the main thread (playback code already is).
    func recordPlay(_ song: Song) {
        var r = records[song.id]
        if r == nil { r = ListenRecord(playCount: 0, lastPlayed: Date()) }
        r?.playCount += 1
        r?.lastPlayed = Date()
        let hour = Calendar.current.component(.hour, from: Date())
        var hc = r?.hourCounts ?? [:]
        hc[hour] = (hc[hour] ?? 0) + 1
        r?.hourCounts = hc
        records[song.id] = r
        save()
    }

    /// Play counts by hour of day for one song (0…23).
    func hours(for songID: UUID) -> [Int: Int] {
        records[songID]?.hourCounts ?? [:]
    }

    /// The hour the user tends to reach for this song, 0…1 fit for `hour`.
    /// 0 when we have no idea — recipes then treat the track as hour-neutral.
    func hourFit(for song: Song, at hour: Int) -> Double {
        guard let r = records[song.id], r.playCount > 0, let hc = r.hourCounts else { return 0 }
        let hits = Double(hc[hour] ?? 0)
        // 3 plays in this hour band ≈ fully "belongs" to it.
        return min(1.0, hits / 3.0)
    }

    /// Adjacent hours count half, so 6 am and 7 am don't look unrelated.
    func hourFitSmoothed(for song: Song, at hour: Int) -> Double {
        let near = [(hour + 24) % 24, (hour + 1) % 24, (hour + 23) % 24]
        let w = [1.0, 0.5, 0.5]
        var best = 0.0
        for (i, h) in near.enumerated() {
            best = max(best, hourFit(for: song, at: h) * w[i])
        }
        return best
    }

    func remove(songID: UUID) {
        guard records[songID] != nil else { return }
        records[songID] = nil
        save()
    }

    /// Folds a restored backup into the live history. Never loses plays: the
    /// higher count wins and the hour buckets are summed, so restoring an old
    /// backup can only ever make the taste model better informed.
    /// Returns how many songs were touched.
    @discardableResult
    func mergeImported(_ incoming: [UUID: ListenRecord]) -> Int {
        guard !incoming.isEmpty else { return 0 }
        var touched = 0
        for (id, inc) in incoming {
            guard var cur = records[id] else {
                records[id] = inc
                touched += 1
                continue
            }
            var changed = false
            if inc.playCount > cur.playCount { cur.playCount = inc.playCount; changed = true }
            if inc.lastPlayed > cur.lastPlayed { cur.lastPlayed = inc.lastPlayed; changed = true }
            if let hc = inc.hourCounts {
                var merged = cur.hourCounts ?? [:]
                for (h, n) in hc { merged[h] = max(merged[h] ?? 0, n) }
                if merged != cur.hourCounts { cur.hourCounts = merged; changed = true }
            }
            if changed { records[id] = cur; touched += 1 }
        }
        if touched > 0 { save() }
        return touched
    }

    private func save() {
        let snapshot = records
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONEncoder().encode(snapshot) {
                try? d.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    /// Up to `limit` most-recently played songs that still exist in the Library.
    func recentSongs(limit: Int) -> [Song] {
        let mm = MusicManager.shared
        let songs = mm.songs
        var out = [Song]()
        for (id, rec) in records.sorted(by: { $0.value.lastPlayed > $1.value.lastPlayed }) {
            if let s = songs.first(where: { $0.id == id }) {
                out.append(s)
                if out.count >= limit { break }
            }
            _ = rec
        }
        return out
    }

    func playCount(for song: Song) -> Int {
        records[song.id]?.playCount ?? 0
    }

    func stats() -> ListeningStats {
        let mm = MusicManager.shared
        let songs = mm.songs
        var total = 0
        let weekStart = Date().addingTimeInterval(-7 * 86400)
        var week = 0
        var topSong = (title: "", count: 0)
        var byArtist: [String: Int] = [:]

        for s in songs {
            guard let r = records[s.id] else { continue }
            total += r.playCount
            if r.lastPlayed >= weekStart { week += r.playCount }
            if r.playCount > topSong.count {
                topSong = (s.title, r.playCount)
            }
            let a = s.artist.trimmingCharacters(in: .whitespaces)
            if !a.isEmpty && a != "AS Music" {
                byArtist[a, default: 0] += r.playCount
            }
        }
        let topArtist = byArtist.sorted { $0.value > $1.value }.first?.key ?? ""
        return ListeningStats(totalPlays: total, weekPlays: week,
                              topSongTitle: topSong.title, topArtistName: topArtist)
    }

    /// Taste weight used by the recommendation engine:
    /// liked songs are worth 3, plus up to 15 extra points for heavy plays.
    func tasteWeight(for song: Song, isLiked: Bool) -> Int {
        (isLiked ? 3 : 1) + min(playCount(for: song), 15)
    }
}

// MARK: - iTunes enrichment (free, key-free metadata + artwork)

/// Apple's iTunes Search API — free, no API key. We use it to auto-complete
/// missing cover art, real artist names and genres for library songs.
final class ITunesEnricher {
    static let shared = ITunesEnricher()

    private let queue = DispatchQueue(label: "asMusic.itunesEnrich", qos: .utility)
    private let lock = NSLock()
    private var inFlight = Set<String>()
    private var enrichedThisSession = 0
    private let sessionCap = 60   // be a good citizen of the free API

    private init() {}

    /// Enriches songs that are missing artwork, one by one on a serial queue
    /// (naturally rate-limited). Safe to call repeatedly.
    func enrichLibrary() {
        let mm = MusicManager.shared
        let candidates = mm.songs
            .filter { $0.artworkURL == nil }
            .prefix(40)
            .map { $0 }
        queue.async {
            for s in candidates {
                self.enrichOne(s)
                // small gap between calls — free API courtesy
                if self.enrichedThisSession >= self.sessionCap { return }
            }
        }
    }

    /// Enrich a single freshly-downloaded song immediately.
    func enrich(song: Song) {
        queue.async { self.enrichOne(song) }
    }

    private func enrichOne(_ song: Song) {
        lock.lock()
        let already = inFlight.contains(song.id.uuidString)
        if !already { inFlight.insert(song.id.uuidString) }
        lock.unlock()
        if already || enrichedThisSession >= sessionCap { return }

        let term: String
        if song.artist.isEmpty || song.artist == "AS Music" {
            term = song.title
        } else {
            term = "\(song.artist) \(song.title)"
        }
        guard let enc = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?entity=song&limit=3&term=\(enc)") else {
            forget(song); return
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("ASMusic/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json,*/*", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            var best: (score: Int, artwork: String, artist: String, genre: String)? = nil
            if let data = data,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let results = j["results"] as? [[String: Any]] {
                let wantTitle = TasteEngine.normKey(artist: song.artist, title: song.title)
                for r in results {
                    guard let title = r["trackName"] as? String,
                          let artist = r["artistName"] as? String,
                          let art100 = r["artworkUrl100"] as? String else { continue }
                    var score = 0
                    let key = TasteEngine.normKey(artist: artist, title: title)
                    if key == wantTitle { score += 10 }
                    else {
                        let tWant = song.title.lowercased()
                            .folding(options: .diacriticInsensitive, locale: .current)
                        let tGot = title.lowercased()
                            .folding(options: .diacriticInsensitive, locale: .current)
                        if tGot == tWant { score += 8 }
                        else if tGot.hasPrefix(tWant) || tWant.hasPrefix(tGot) { score += 5 }
                    }
                    let aWant = song.artist.lowercased().folding(options: .diacriticInsensitive, locale: .current)
                    let aGot = artist.lowercased().folding(options: .diacriticInsensitive, locale: .current)
                    if !aWant.isEmpty && aWant != "as music" && (aGot == aWant || aGot.contains(aWant)) { score += 4 }
                    let genre = (r["primaryGenreName"] as? String) ?? ""
                    if score > (best?.score ?? 0) {
                        let art600 = art100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                            .replacingOccurrences(of: "100x100", with: "600x600")
                        best = (score, art600, artist, genre)
                    }
                }
            }
            // Only trust the match if the title really lines up.
            guard let best = best, best.score >= 8 else { self.forget(song); return }
            self.enrichedThisSession += 1
            let artwork = best.artwork
            let artist = best.artist
            let genre = best.genre
            let wantArtist = song.artist
            DispatchQueue.main.async {
                let mm = MusicManager.shared
                guard let idx = mm.songs.firstIndex(where: { $0.id == song.id }) else { return }
                var changed = false
                // Fill artwork only if it is still missing (never clobber a
                // user-provided or already-downloaded cover).
                if mm.songs[idx].artworkURL == nil {
                    mm.songs[idx].artworkURL = artwork
                    changed = true
                }
                // Upgrade a placeholder artist to the real one.
                if (wantArtist.isEmpty || wantArtist == "AS Music") && !artist.isEmpty {
                    mm.songs[idx].artist = artist
                    changed = true
                }
                // Remember genre (new optional field, cosmetic + future use).
                if mm.songs[idx].genre == nil && !genre.isEmpty {
                    mm.songs[idx].genre = genre
                    changed = true
                }
                if changed { mm.saveSongMeta() }
            }
            self.forget(song)
        }.resume()
    }

    private func forget(_ song: Song) {
        lock.lock(); inFlight.remove(song.id.uuidString); lock.unlock()
    }
}

// MARK: - Wikipedia artist bios (free, key-free)

// A class so it can live in NSCache (which requires reference types).
final class ArtistBio {
    let name: String
    let extract: String
    let thumbnail: String?
    let pageURL: String

    init(name: String, extract: String, thumbnail: String?, pageURL: String) {
        self.name = name
        self.extract = extract
        self.thumbnail = thumbnail
        self.pageURL = pageURL
    }
}

enum WikipediaAPI {
    private static let cache = NSCache<NSString, ArtistBio>()

    static func hasArabicScript(_ s: String) -> Bool {
        for sc in s.unicodeScalars {
            if (0x0600...0x06FF).contains(sc.value)
                || (0x0750...0x077F).contains(sc.value)
                || (0xFB50...0xFDFF).contains(sc.value)
                || (0xFE70...0xFEFF).contains(sc.value) { return true }
        }
        return false
    }

    /// Fetches a short artist bio + photo. Arabic-script names try the Arabic
    /// Wikipedia first, everything else tries English first.
    static func fetch(_ artist: String, completion: @escaping (ArtistBio?) -> Void) {
        let clean = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "AS Music" else { completion(nil); return }
        let key = clean.lowercased() as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached); return
        }
        let hosts: [String] = hasArabicScript(clean) ? ["ar", "en"] : ["en", "ar"]
        var remaining = hosts
        func tryNext() {
            guard let host = remaining.first else { completion(nil); return }
            remaining.removeFirst()
            guard let enc = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://\(host).wikipedia.org/api/rest_v1/page/summary/\(enc)") else {
                tryNext(); return
            }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("ASMusic/1.0 (personal music app)", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let data = data, err == nil,
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let extract = j["extract"] as? String, !extract.isEmpty,
                   !extract.hasPrefix("Wikipedia does not have an article") {
                    let thumb = (j["thumbnail"] as? [String: Any])?["source"] as? String
                    let page = (((j["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String)
                        ?? "https://\(host).wikipedia.org/wiki/\(enc)"
                    let bio = ArtistBio(name: (j["title"] as? String) ?? clean,
                                        extract: extract, thumbnail: thumb, pageURL: page)
                    cache.setObject(bio, forKey: key)
                    DispatchQueue.main.async { completion(bio) }
                    return
                }
                tryNext()
            }.resume()
        }
        tryNext()
    }
}

// MARK: - Optional AI assistant (multi-provider: APInex / Gemini / on-device)

/// The AI Music Assistant — ONE engine, MANY providers.
///
/// The active provider is chosen in Settings → AI Intelligence:
///   • .apinex   — apinex.bond: one key (sk-apx…) → 20+ models incl. FREE
///                 tiers (GLM, GPT, Gemini, DeepSeek, Qwen…)
///   • .gemini   — the user's own free Google AI Studio key (as before)
///   • .onDevice — no key: nothing is ever sent anywhere
///
/// "Never stop" failover (on by default): a request walks the chain
/// [chosen model → next models of the same provider → the OTHER provider
/// if it has a key]. A retired model id, a rate limit, an empty reply or
/// a dead endpoint only ever costs one silent retry — and when everything
/// is unavailable, callers fall back to their on-device engine, so no
/// feature ever shows the user a dead end.
final class GeminiAI: ObservableObject {
    static let shared = GeminiAI()

    // -- provider selection ---------------------------------------------------
    @Published var provider: AIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerDefaultsKey)
            if provider == .apinex { refreshApinexCatalog() }
        }
    }
    /// Master switch for model rotation + crossing to the other provider.
    @Published var autoFailover: Bool {
        didSet { UserDefaults.standard.set(autoFailover, forKey: Self.failoverDefaultsKey) }
    }

    // -- APInex (apinex.bond — many models, one key) ----------------------------
    @Published var apinexKey: String {
        didSet {
            UserDefaults.standard.set(apinexKey, forKey: Self.apinexKeyDefaultsKey)
            // Pasting a key while "On-device only" is selected obviously means
            // the user wants this provider — switch for them.
            if !apinexKey.trimmingCharacters(in: .whitespaces).isEmpty && provider == .onDevice {
                provider = .apinex
            }
        }
    }
    @Published var apinexModel: String {
        didSet { UserDefaults.standard.set(apinexModel, forKey: Self.apinexModelDefaultsKey) }
    }
    /// Live model list for the picker (bundled snapshot until refreshed).
    @Published private(set) var apinexCatalog: [AIModelInfo] = APInexCatalog.bundled

    // -- Google Gemini (direct, user's own key — unchanged semantics) -----------
    @Published var key: String {
        didSet {
            UserDefaults.standard.set(key, forKey: Self.keyDefaultsKey)
            if !key.trimmingCharacters(in: .whitespaces).isEmpty && provider == .onDevice {
                provider = .gemini
            }
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelDefaultsKey) }
    }
    /// Auto model (self-healing) for the Gemini provider: silently switches
    /// to a verified newer model id when Google retires the stored one.
    @Published var autoModel: Bool {
        didSet { UserDefaults.standard.set(autoModel, forKey: Self.autoDefaultsKey) }
    }

    // -- shared UI state ---------------------------------------------------------
    @Published var isThinking: Bool = false
    @Published var lastError: String? = nil
    @Published var suggestions: [DiscoTrack] = []

    private static let keyDefaultsKey = "asmusic_gemini_key"
    private static let modelDefaultsKey = "asmusic_gemini_model"
    private static let autoDefaultsKey = "asmusic_gemini_auto"
    private static let providerDefaultsKey = "asmusic_ai_provider"
    private static let failoverDefaultsKey = "asmusic_ai_failover"
    private static let apinexKeyDefaultsKey = "asmusic_apinex_key"
    private static let apinexModelDefaultsKey = "asmusic_apinex_model"

    private init() {
        let d = UserDefaults.standard
        key = d.string(forKey: Self.keyDefaultsKey) ?? ""
        autoModel = d.object(forKey: Self.autoDefaultsKey) as? Bool ?? true
        model = d.string(forKey: Self.modelDefaultsKey) ?? "gemini-3.5-flash"
        apinexKey = d.string(forKey: Self.apinexKeyDefaultsKey) ?? ""
        apinexModel = d.string(forKey: Self.apinexModelDefaultsKey) ?? "free/glm-5.3-flash"
        autoFailover = d.object(forKey: Self.failoverDefaultsKey) as? Bool ?? true
        // Migration: anyone who already pasted a Gemini key keeps it working;
        // everyone else starts on-device until they pick a provider.
        if let raw = d.string(forKey: Self.providerDefaultsKey), let p = AIProvider(rawValue: raw) {
            provider = p
        } else if !key.trimmingCharacters(in: .whitespaces).isEmpty {
            provider = .gemini
        } else {
            provider = .onDevice
        }
        if let saved = d.stringArray(forKey: "asmusic_apinex_catalog"), !saved.isEmpty {
            apinexCatalog = APInexCatalog.ordered(saved.map { AIModelInfo(id: $0) })
        }
        if provider == .apinex { refreshApinexCatalog() }
    }

    var isConfigured: Bool {
        switch provider {
        case .onDevice: return false
        case .apinex:   return !apinexKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .gemini:   return !key.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Human name of whatever would answer right now (used in footers).
    var activeLabel: String { provider.shortName }

    // ------------------------------------------------------------------
    // The never-stop chain
    // ------------------------------------------------------------------

    private struct AIAttempt { let provider: AIProvider; let model: String; let key: String }

    /// Ordered attempts for one logical question:
    ///   1. the chosen model of the chosen provider,
    ///   2. its fallback models (Gemini: only when Auto model is on;
    ///      APInex: free models first — only when Auto-failover is on),
    ///   3. the OTHER provider's chain, if it has a key (Auto-failover only).
    /// Capped at 8 attempts, so the worst case is a few quiet retries.
    private func buildChain() -> [AIAttempt] {
        var out: [AIAttempt] = []
        func push(_ p: AIProvider) {
            guard out.count < 8 else { return }
            switch p {
            case .onDevice:
                break
            case .gemini:
                let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty else { return }
                var models = [model]
                if autoModel { models.append(contentsOf: GeminiDiscovery.candidates()) }
                for m in models where !m.isEmpty {
                    guard !out.contains(where: { $0.provider == .gemini && $0.model == m }) else { continue }
                    out.append(AIAttempt(provider: .gemini, model: m, key: k))
                    if out.count >= 8 { break }
                }
            case .apinex:
                let k = apinexKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty else { return }
                var models = [apinexModel]
                if autoFailover { models.append(contentsOf: APInexCatalog.fallbackModels()) }
                for m in models where !m.isEmpty {
                    guard !out.contains(where: { $0.provider == .apinex && $0.model == m }) else { continue }
                    out.append(AIAttempt(provider: .apinex, model: m, key: k))
                    if out.count >= 8 { break }
                }
            }
        }
        push(provider)
        if autoFailover { push(provider == .gemini ? .apinex : .gemini) }
        return out
    }

    /// Walks the chain. Model-level failures rotate to the next model; a
    /// rejected key skips the rest of THAT provider and crosses to the other
    /// one; when everything failed the last error is reported so callers can
    /// fall back to their on-device path.
    private func runChat(system: String, user: String, temperature: Double, maxTokens: Int,
                         chain: [AIAttempt]? = nil, index: Int = 0, lastFailure: String? = nil,
                         completion: @escaping (String?, String?) -> Void) {
        let attempts = chain ?? buildChain()
        guard index < attempts.count else {
            completion(nil, lastFailure ?? "No AI provider answered.")
            return
        }
        let a = attempts[index]
        AITransport.chat(provider: a.provider, key: a.key, model: a.model,
                         system: system, user: user,
                         temperature: temperature, maxTokens: maxTokens) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self else { completion(nil, lastFailure); return }
                if let text = outcome.text {
                    // Self-heal: remember whichever model actually answered.
                    if a.provider == .gemini && a.model != self.model { self.model = a.model }
                    if a.provider == .apinex && a.model != self.apinexModel { self.apinexModel = a.model }
                    completion(text, nil)
                    return
                }
                var next = index + 1
                if outcome.keyRejected {
                    // Wrong key: no point trying more models of this provider.
                    while next < attempts.count && attempts[next].provider == a.provider { next += 1 }
                }
                if next < attempts.count {
                    let who = a.provider == .apinex ? "APInex" : "Gemini"
                    let note = "\(who): \(outcome.error ?? "no answer")"
                    self.runChat(system: system, user: user, temperature: temperature,
                                 maxTokens: maxTokens, chain: attempts, index: next,
                                 lastFailure: note) { t, e in
                        // Pass through untouched: `e` is nil exactly when a
                        // deeper attempt succeeded, and the deepest failure
                        // already carries the accumulated `note`.
                        completion(t, e)
                    }
                } else {
                    completion(nil, outcome.error ?? lastFailure)
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Public API (unchanged signatures — every existing caller keeps working)
    // ------------------------------------------------------------------

    /// Asks the active provider for song suggestions matching the request.
    func ask(_ prompt: String, completion: (([DiscoTrack]) -> Void)? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConfigured else {
            lastError = "Add a free AI key in Settings → AI Intelligence first."
            completion?([])
            return
        }
        guard !trimmed.isEmpty else { completion?([]); return }
        // Proactive heal (Gemini only, fire-and-forget): if the stored model
        // already vanished from Google's list, silently adopt a verified one.
        if provider == .gemini && autoModel {
            GeminiDiscovery.preSwitchIfGone(key: key, current: model) { [weak self] m in
                if let m = m { DispatchQueue.main.async { self?.model = m } }
            }
        }
        isThinking = true
        lastError = nil
        suggestions = []

        let system = """
        You are a music discovery engine inside a personal music player app popular with Arabic/Egyptian pop and global hits.
        The user asks for songs in free text. Respond with ONLY a valid JSON array of exactly 5 objects, no markdown fences, no commentary:
        [{"artist":"Exact real artist name","title":"Exact real song title"}]
        Rules: only real, existing songs; prefer current/popular releases; honor the requested language, mood, genre or year exactly; artist and title must match how the songs are actually credited.
        """
        runChat(system: system, user: trimmed, temperature: 0.7, maxTokens: 1024) { [weak self] text, failure in
            guard let self = self else { completion?([]); return }
            var tracks: [DiscoTrack] = []
            var problem: String? = failure
            if let text = text {
                tracks = self.parseTracks(from: text)
                if tracks.isEmpty { problem = "The AI returned nothing usable. Try again." }
            }
            self.isThinking = false
            if let p = problem, tracks.isEmpty {
                self.lastError = p
            } else {
                self.suggestions = tracks
            }
            completion?(tracks)
        }
    }

    /// General JSON completion: sends `system` + `user`, expects the model to
    /// answer with ONE JSON object, and hands back the parsed dictionary (nil
    /// on any failure — callers then use their on-device fallback). Now goes
    /// through the same never-stop chain as `ask` (this was the hidden gap
    /// before: it used to fail permanently on the first retired model id).
    func completeJSON(system: String, user: String,
                      temperature: Double = 0.4,
                      completion: @escaping ([String: Any]?) -> Void) {
        guard isConfigured else { completion(nil); return }
        var reqText = user
        if reqText.count > 24000 { reqText = String(reqText.prefix(24000)) }
        runChat(system: system, user: reqText, temperature: temperature, maxTokens: 2048) { [weak self] text, _ in
            guard let self = self, let text = text else { completion(nil); return }
            completion(self.parseJSONObject(text))
        }
    }

    // ------------------------------------------------------------------
    // APInex catalog refresh (Settings UI calls this)
    // ------------------------------------------------------------------

    /// Loads the live model list from the platform. Keeps the bundled
    /// snapshot on any failure, so the picker is never empty.
    func refreshApinexCatalog(completion: (() -> Void)? = nil) {
        AITransport.fetchApinexModels(key: apinexKey) { [weak self] models, _ in
            DispatchQueue.main.async {
                defer { completion?() }
                guard let self = self, models != self.apinexCatalog else { return }
                self.apinexCatalog = models
                UserDefaults.standard.set(models.map { $0.id }, forKey: "asmusic_apinex_catalog")
                // If the chosen model vanished from the LIVE list, move to the
                // best free one — but never touch a custom id the user typed
                // (rotation already covers a dead custom id at request time).
                if !models.isEmpty, self.provider == .apinex,
                   !models.contains(where: { $0.id == self.apinexModel }),
                   APInexCatalog.knownModels[self.apinexModel] != nil {
                    self.apinexModel = models[0].id
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Tolerant parsing (unchanged behaviour)
    // ------------------------------------------------------------------

    /// Tolerant object extraction: strips accidental markdown fences and any
    /// prose around the first {...} block.
    private func parseJSONObject(_ text: String) -> [String: Any]? {
        var t = text
        if let l = t.firstIndex(of: "{"), let r = t.lastIndex(of: "}") {
            t = String(t[l...r])
        }
        guard let d = t.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Parses the JSON array (tolerating accidental markdown fences).
    private func parseTracks(from text: String) -> [DiscoTrack] {
        var t = text
        if let l = t.firstIndex(of: "["), let r = t.lastIndex(of: "]") {
            t = String(t[l...r])
        }
        guard let data = t.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var out = [DiscoTrack]()
        var seen = Set<String>()
        for o in arr.prefix(8) {
            guard let artist = o["artist"] as? String, let title = o["title"] as? String,
                  !artist.isEmpty, !title.isEmpty else { continue }
            let id = TasteEngine.normKey(artist: artist, title: title)
            guard seen.insert(id).inserted else { continue }
            out.append(DiscoTrack(id: id, title: title, artist: artist, artistId: nil,
                                  albumCover: nil, previewURL: nil, reason: "AI pick for you"))
        }
        return out
    }
}


// ---------------------------------------------------------------------------
// MARK: - Gemini model self-healing (Auto model)
// ---------------------------------------------------------------------------

/// Verifies model ids against Google's ListModels API and the remote
/// registry, so retired ids (2.0 → 2.5 → 3.x …) are replaced silently
/// without an app update. Read-only: it never touches the classic AI flow
/// beyond supplying a working model id.
enum GeminiDiscovery {
    /// Ordered model candidates: remote registry first, hardcoded backup.
    static func candidates() -> [String] {
        let reg = RegistryStore.shared.current
        if let list = reg.geminiFallbacks, !list.isEmpty { return list }
        if let pref = reg.preferredGeminiModel, !pref.isEmpty { return [pref] }
        return ["gemini-3.5-flash", "gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash"]
    }

    /// Next candidate after `current` (nil when current is last/unknown-end).
    static func nextModel(after current: String) -> String? {
        let list = candidates()
        guard let i = list.firstIndex(of: current) else { return list.first }
        return (i + 1 < list.count) ? list[i + 1] : nil
    }

    /// Fire-and-forget pre-check: if `current` already vanished from Google's
    /// model list, complete with a verified replacement (else nil = keep).
    static func preSwitchIfGone(key: String, current: String, completion: @escaping (String?) -> Void) {
        guard let ke = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(ke)&pageSize=100") else {
            completion(nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let arr = j["models"] as? [[String: Any]] else {
                completion(nil); return
            }
            let names = arr.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
            if names.contains(current) { completion(nil); return }
            for c in candidates() where names.contains(c) { completion(c); return }
            completion(names.filter { $0.contains("flash") }.sorted().last)
        }.resume()
    }
}

// MARK: - Free chart regions (Deezer — no key)

enum ChartRegion: String, CaseIterable, Identifiable {
    case eg = "eg"
    case sa = "sa"
    case ma = "ma"
    case us = "us"
    case gb = "gb"
    case fr = "fr"
    case global = "0"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .eg: return "Egypt"
        case .sa: return "Saudi Arabia"
        case .ma: return "Morocco"
        case .us: return "USA"
        case .gb: return "UK"
        case .fr: return "France"
        case .global: return "Worldwide"
        }
    }
}
