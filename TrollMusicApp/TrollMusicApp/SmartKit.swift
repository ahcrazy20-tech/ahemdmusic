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
//   • GeminiAI       — optional Google Gemini (free tier). User pastes their
//                      own free API key in settings; the AI suggests real
//                      songs that download into the Library with one tap.
//                      With no key set, NOTHING is sent anywhere.
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

// MARK: - Optional AI assistant (Google Gemini free tier, user's own key)

/// The AI Music Assistant. It does nothing until the user pastes their OWN
/// free API key (Google AI Studio). With no key, no network calls are made.
final class GeminiAI: ObservableObject {
    static let shared = GeminiAI()

    @Published var key: String {
        didSet { UserDefaults.standard.set(key, forKey: "asmusic_gemini_key") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "asmusic_gemini_model") }
    }
    /// NEW: Auto model (self-healing). On: the app silently switches to a
    /// verified newer model id when Google retires the stored one. Off:
    /// always use `model` exactly as before.
    @Published var autoModel: Bool {
        didSet { UserDefaults.standard.set(autoModel, forKey: "asmusic_gemini_auto") }
    }
    @Published var isThinking: Bool = false
    @Published var lastError: String? = nil
    @Published var suggestions: [DiscoTrack] = []

    private static let keyDefaultsKey = "asmusic_gemini_key"
    private static let modelDefaultsKey = "asmusic_gemini_model"
    private static let autoDefaultsKey = "asmusic_gemini_auto"

    private init() {
        key = UserDefaults.standard.string(forKey: Self.keyDefaultsKey) ?? ""
        autoModel = UserDefaults.standard.object(forKey: Self.autoDefaultsKey) as? Bool ?? true
        model = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? "gemini-3.5-flash"
    }

    var isConfigured: Bool { !key.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Asks the model for song suggestions matching the user's request.
    /// `attempt` is 0 for user asks; the self-heal retry uses 1 (one rotation
    /// max per ask, so we can never loop).
    func ask(_ prompt: String, completion: (([DiscoTrack]) -> Void)? = nil, attempt: Int = 0) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConfigured else {
            lastError = "Add your free Gemini key in player settings first."
            completion?([])
            return
        }
        guard !trimmed.isEmpty else { completion?([]); return }
        // Proactive heal (fire-and-forget): if our stored model already
        // vanished from Google's list, silently adopt a verified newer one.
        if autoModel && attempt == 0 {
            GeminiDiscovery.preSwitchIfGone(key: key, current: model) { [weak self] m in
                if let m = m {
                    DispatchQueue.main.async { self?.model = m }
                }
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
        let keyEnc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let modelEnc = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelEnc):generateContent?key=\(keyEnc)") else {
            isThinking = false
            lastError = "Bad URL"
            completion?([])
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 40)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": trimmed]]]],
            "generationConfig": ["temperature": 0.7, "maxOutputTokens": 1024]
        ]
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            var tracks: [DiscoTrack] = []
            var failure: String? = nil
            if let err = err {
                failure = err.localizedDescription
            } else if let data = data {
                if let status = (resp as? HTTPURLResponse)?.statusCode, status >= 400 {
                    // Surface a short human reason (bad key, rate limit, model…).
                    var msg: String? = nil
                    if let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let errObj = j["error"] as? [String: Any],
                       let m = errObj["message"] as? String {
                        msg = String(m.prefix(140))
                    }
                    // NEW self-heal: retired-model error + Auto on + first
                    // attempt → adopt the next verified model and retry once.
                    if attempt == 0 && self.autoModel
                        && self.modelGone(status: status, message: msg ?? ""),
                       let next = GeminiDiscovery.nextModel(after: self.model) {
                        let again = trimmed
                        let cont = completion
                        DispatchQueue.main.async {
                            self.model = next
                            self.ask(again, completion: cont, attempt: 1)
                        }
                        return
                    }
                    failure = msg ?? "Server error \(status)"
                } else if let text = self.extractText(from: data) {
                    tracks = self.parseTracks(from: text)
                    if tracks.isEmpty { failure = "The AI returned nothing usable. Try again." }
                } else {
                    failure = "Unexpected reply from the AI."
                }
            }
            DispatchQueue.main.async {
                self.isThinking = false
                if let f = failure {
                    self.lastError = f
                } else {
                    self.suggestions = tracks
                }
                completion?(tracks)
            }
        }.resume()
    }

    /// General JSON completion: sends `system` + `user`, expects the model to
    /// answer with ONE JSON object, and hands back the parsed dictionary (nil on
    /// any failure). Reuses the same key/model/self-heal path as `ask`, and is
    /// the only way the AI is allowed to touch your library: the prompt always
    /// contains only titles/artists you already own, so it can pick and name —
    /// it can never invent songs that then get downloaded.
    func completeJSON(system: String, user: String,
                      temperature: Double = 0.4,
                      completion: @escaping ([String: Any]?) -> Void) {
        guard isConfigured else { completion(nil); return }
        var reqText = user
        if reqText.count > 24000 { reqText = String(reqText.prefix(24000)) }

        let keyEnc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let modelEnc = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelEnc):generateContent?key=\(keyEnc)") else {
            completion(nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": reqText]]]],
            "generationConfig": ["temperature": temperature, "maxOutputTokens": 2048]
        ]
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { completion(nil); return }
            var out: [String: Any]? = nil
            if err == nil, let data = data,
               (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400,
               let text = self.extractText(from: data) {
                out = self.parseJSONObject(text)
            }
            DispatchQueue.main.async { completion(out) }
        }.resume()
    }

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

    /// True when an error plausibly means "this model id is retired".
    private func modelGone(status: Int, message: String) -> Bool {
        if status == 404 { return true }
        let m = message.lowercased()
        guard m.contains("model") else { return false }
        return m.contains("not found") || m.contains("retired") || m.contains("deprecated")
            || m.contains("unsupported") || m.contains("not supported")
            || m.contains("expired") || m.contains("removed")
    }

    /// Pulls the text out of a generateContent reply.
    private func extractText(from data: Data) -> String? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let candidates = j["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
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
