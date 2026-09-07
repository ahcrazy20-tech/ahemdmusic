import Foundation
import SwiftUI
import UIKit

// ===========================================================================
// MARK: - ExtractorKit
//
// NEW alternative download engines + self-healing config (Sept 2026).
//
// HARD RULE: nothing in here modifies the classic engines (y2jar / Mp3Juice
// worker / cnvmp3 / Theta / SoundCloud-direct / search). New engines only:
//   (a) JOIN the existing fast race as extra contenders (fastest valid link
//       wins — old contenders run exactly as before), or
//   (b) run AFTER a classic path has already failed (pure fallback).
// If every new engine fails, behavior is byte-for-byte what it was before.
//
// Every new engine must PROVE its URL serves real audio (probeForAudio)
// before it is allowed to win a race — a dead engine just loses quietly.
// ===========================================================================

// ---------------------------------------------------------------------------
// MARK: - Backend registry (remote config; updates without an app release)
// ---------------------------------------------------------------------------

/// Shape of backend-registry.json. Every field is optional so an old app
/// keeps working even if the file grows new fields later.
struct BackendRegistry: Codable {
    var version: Int? = nil
    var updated: String? = nil
    var preferredGeminiModel: String? = nil
    var geminiFallbacks: [String]? = nil
    var pipedMirrors: [String]? = nil
    var invidiousInstances: [String]? = nil
    var cobaltInstances: [String]? = nil
    var pipedEnabled: Bool? = nil
    var invidiousEnabled: Bool? = nil
    var cobaltEnabled: Bool? = nil
    var notes: String? = nil
}

final class RegistryStore {
    static let shared = RegistryStore()
    static let registryURL = URL(string: "https://raw.githubusercontent.com/ahcrazy20-tech/ahemdmusic/main/backend-registry.json")!

    /// Bundled snapshot — used until the remote file arrives, and forever
    /// while offline. Mirrors the v1 registry file shipped with the app.
    static let bundled = BackendRegistry(
        version: 1,
        updated: "2026-09-07",
        preferredGeminiModel: "gemini-3.5-flash",
        geminiFallbacks: ["gemini-3.5-flash", "gemini-3.6-flash", "gemini-3.7-flash",
                          "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-2.5-flash"],
        pipedMirrors: [
            "https://pipedapi.kavin.rocks",
            "https://pipedapi-libre.kavin.rocks",
            "https://pipedapi.leptons.xyz",
            "https://pipedapi.adminforge.de",
            "https://api.piped.private.coffee",
            "https://pipedapi.nosebs.ru",
            "https://piped-api.privacy.com.de",
            "https://api.piped.yt",
            "https://pipedapi.drgns.space",
            "https://pipedapi.owo.si",
            "https://pipedapi.ducks.party",
            "https://piped-api.codespace.cz",
            "https://pipedapi.reallyaweso.me",
            "https://pipedapi.darkness.services",
            "https://pipedapi.orangenet.cc"
        ],
        invidiousInstances: [
            "https://inv.nadeko.net",
            "https://yewtu.be",
            "https://vid.puffyan.us",
            "https://invidious.snopyta.org",
            "https://inv.in.projectsegfau.lt"
        ],
        cobaltInstances: [],
        pipedEnabled: true,
        invidiousEnabled: true,
        cobaltEnabled: false,
        notes: nil
    )

    private let lock = NSLock()
    private var cached: BackendRegistry? = nil
    private var lastFetch: Date? = nil
    private var fetching = false

    private init() {
        if let d = UserDefaults.standard.data(forKey: "asmusic_registry"),
           let r = try? JSONDecoder().decode(BackendRegistry.self, from: d) {
            cached = r
        }
        lastFetch = UserDefaults.standard.object(forKey: "asmusic_registry_date") as? Date
    }

    /// Effective config = bundled defaults overlaid with the remote file.
    var current: BackendRegistry {
        lock.lock(); let c = cached; lock.unlock()
        var e = Self.bundled
        if let r = c {
            if let v = r.preferredGeminiModel, !v.isEmpty { e.preferredGeminiModel = v }
            if let v = r.geminiFallbacks, !v.isEmpty { e.geminiFallbacks = v }
            if let v = r.pipedMirrors, !v.isEmpty { e.pipedMirrors = v }
            if let v = r.invidiousInstances, !v.isEmpty { e.invidiousInstances = v }
            if let v = r.cobaltInstances { e.cobaltInstances = v }
            if let v = r.pipedEnabled { e.pipedEnabled = v }
            if let v = r.invidiousEnabled { e.invidiousEnabled = v }
            if let v = r.cobaltEnabled { e.cobaltEnabled = v }
        }
        return e
    }

    /// Refresh in the background if older than 24h (or forced). Never blocks.
    func refreshIfStale(force: Bool = false) {
        lock.lock()
        let stale = force || lastFetch == nil
            || Date().timeIntervalSince(lastFetch ?? .distantPast) > 86400
        if fetching || !stale { lock.unlock(); return }
        fetching = true
        lock.unlock()
        var req = URLRequest(url: Self.registryURL, timeoutInterval: 12)
        req.setValue("ASMusic/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self else { return }
            var fresh: BackendRegistry? = nil
            var freshData: Data? = nil
            if let data = data,
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let r = try? JSONDecoder().decode(BackendRegistry.self, from: data) {
                fresh = r
                freshData = data
            }
            self.lock.lock()
            if fresh != nil {
                self.cached = fresh
                self.lastFetch = Date()
            }
            self.fetching = false
            self.lock.unlock()
            if let fd = freshData {
                UserDefaults.standard.set(fd, forKey: "asmusic_registry")
                UserDefaults.standard.set(Date(), forKey: "asmusic_registry_date")
            }
        }.resume()
    }
}

// ---------------------------------------------------------------------------
// MARK: - Backend health (new engines only — classic engines always run)
// ---------------------------------------------------------------------------

/// Tracks recent failures per NEW backend id ("piped", "invidious", "cobalt",
/// "custom", "scapi"). A backend that keeps failing is skipped for a while
/// (backoff) instead of wasting race slots. Classic engines are never
/// skipped — this class doesn't even know their names.
final class BackendHealth {
    static let shared = BackendHealth()

    private let lock = NSLock()
    private var fails: [String: [Double]] = [:]

    private init() {
        if let d = UserDefaults.standard.dictionary(forKey: "asmusic_health") as? [String: [Double]] {
            fails = d
        }
    }

    func shouldTry(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let recent = (fails[id] ?? []).filter { now - $0 < 7200 }
        guard let last = recent.max() else { return true }
        if recent.count >= 5 { return now - last > 1800 }  // 5+ fails → rest 30 min
        if recent.count >= 3 { return now - last > 600 }   // 3+ fails → rest 10 min
        return true
    }

    func recordSuccess(_ id: String) {
        lock.lock(); fails[id] = nil; let snap = fails; lock.unlock()
        UserDefaults.standard.set(snap, forKey: "asmusic_health")
    }

    func recordFail(_ id: String) {
        lock.lock()
        var a = fails[id] ?? []
        a.append(Date().timeIntervalSince1970)
        a = Array(a.suffix(8))
        fails[id] = a
        let snap = fails
        lock.unlock()
        UserDefaults.standard.set(snap, forKey: "asmusic_health")
    }

    /// Recent failure count (for the Engines settings screen).
    func failCount(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        return (fails[id] ?? []).filter { now - $0 < 7200 }.count
    }
}

// ---------------------------------------------------------------------------
// MARK: - Piped audio (direct streams, no conversion)
// ---------------------------------------------------------------------------

enum PipedAudio {
    /// Resolve a YouTube id to a direct iOS-playable audio URL via Piped's
    /// /streams endpoint. Tries mirrors in order; nil if none works.
    static func resolve(vid: String, completion: @escaping (URL?) -> Void) {
        RegistryStore.shared.refreshIfStale()
        let cfg = RegistryStore.shared.current
        var mirrors = (cfg.pipedMirrors?.isEmpty == false) ? cfg.pipedMirrors! : (bundledMirrors())
        mirrors = normalize(mirrors)
        tryNext(mirrors: mirrors, vid: vid, completion: completion)
    }

    private static func bundledMirrors() -> [String] {
        RegistryStore.bundled.pipedMirrors ?? []
    }

    private static func normalize(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for m in list {
            let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !t.isEmpty && t.hasPrefix("https://") && seen.insert(t).inserted {
                out.append(t)
            }
        }
        return out
    }

    private static func tryNext(mirrors: [String], vid: String, completion: @escaping (URL?) -> Void) {
        var rest = mirrors
        guard let base = rest.first else { completion(nil); return }
        rest.removeFirst()
        guard let url = URL(string: "\(base)/streams/\(vid)") else {
            tryNext(mirrors: rest, vid: vid, completion: completion); return
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(DownloadCenter.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data = data,
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let u = pickAudio(from: j) {
                completion(u); return
            }
            tryNext(mirrors: rest, vid: vid, completion: completion)
        }.resume()
    }

    /// Pick the best iOS-playable audio stream. iOS cannot play Opus-in-WebM,
    /// so M4A/AAC containers win even at a lower bitrate.
    private static func pickAudio(from j: [String: Any]) -> URL? {
        guard let arr = j["audioStreams"] as? [[String: Any]], !arr.isEmpty else { return nil }
        func bitrate(_ o: [String: Any]) -> Int { (o["bitrate"] as? NSNumber)?.intValue ?? 0 }
        func playable(_ o: [String: Any]) -> Bool {
            let c = ((o["container"] as? String) ?? "").lowercased()
            let co = ((o["codec"] as? String) ?? "").lowercased()
            return c.contains("m4a") || c.contains("mp4") || c.contains("m4v")
                || co.contains("aac") || co.contains("mp4a")
        }
        let sorted = arr.sorted { bitrate($0) > bitrate($1) }
        for o in sorted where playable(o) {
            if let s = o["url"] as? String, let u = URL(string: s) { return u }
        }
        return nil
    }
}

// ---------------------------------------------------------------------------
// MARK: - Invidious audio (direct itag 140, proxied fallback)
// ---------------------------------------------------------------------------

enum InvidiousAudio {
    /// Resolve via {instance}/latest_version (itag 140 = M4A/AAC, iOS-safe).
    /// Each candidate is probe-validated, so dead instances just lose.
    static func resolve(vid: String, completion: @escaping (URL?) -> Void) {
        RegistryStore.shared.refreshIfStale()
        let cfg = RegistryStore.shared.current
        var insts = (cfg.invidiousInstances?.isEmpty == false)
            ? cfg.invidiousInstances! : (RegistryStore.bundled.invidiousInstances ?? [])
        var seen = Set<String>()
        insts = insts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }.filter { !$0.isEmpty && $0.hasPrefix("https://") && seen.insert($0).inserted }
        tryNext(insts: insts, vid: vid, completion: completion)
    }

    private static func tryNext(insts: [String], vid: String, completion: @escaping (URL?) -> Void) {
        var rest = insts
        guard let base = rest.first else { completion(nil); return }
        rest.removeFirst()
        // Direct file first, then the instance-proxied variant (local=true),
        // which survives IP-locked media URLs.
        let candidates = [
            "\(base)/latest_version?id=\(vid)&itag=140",
            "\(base)/latest_version?id=\(vid)&itag=140&local=true"
        ]
        tryCandidates(candidates: candidates, fallback: rest, vid: vid, completion: completion)
    }

    private static func tryCandidates(candidates: [String], fallback: [String],
                                      vid: String, completion: @escaping (URL?) -> Void) {
        var c = candidates
        guard let s = c.first else {
            tryNext(insts: fallback, vid: vid, completion: completion); return
        }
        c.removeFirst()
        guard let u = URL(string: s) else {
            tryCandidates(candidates: c, fallback: fallback, vid: vid, completion: completion); return
        }
        DownloadCenter.shared.probeForAudio(url: u, referer: "https://piped.video/") { ready in
            if ready { completion(u); return }
            tryCandidates(candidates: c, fallback: fallback, vid: vid, completion: completion)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Cobalt (dormant until a keyless instance is enabled via registry)
// ---------------------------------------------------------------------------

enum CobaltAudio {
    /// Cobalt API: POST {instance}/ {"url","downloadMode":"audio"}. Ships
    /// DORMANT (no instances whitelisted) — enable via backend-registry.json
    /// once a working keyless instance is confirmed.
    static func resolve(watchURL: String, completion: @escaping (URL?) -> Void) {
        let cfg = RegistryStore.shared.current
        guard cfg.cobaltEnabled == true,
              let insts = cfg.cobaltInstances, !insts.isEmpty else {
            completion(nil); return
        }
        tryNext(insts: insts, watchURL: watchURL, completion: completion)
    }

    private static func tryNext(insts: [String], watchURL: String, completion: @escaping (URL?) -> Void) {
        var rest = insts
        guard let baseRaw = rest.first else { completion(nil); return }
        rest.removeFirst()
        let base = baseRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.hasPrefix("https://"), let url = URL(string: "\(base)/") else {
            tryNext(insts: rest, watchURL: watchURL, completion: completion); return
        }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["url": watchURL, "downloadMode": "audio", "audioFormat": "mp3"]
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data = data,
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let status = j["status"] as? String,
               (status == "tunnel" || status == "redirect"),
               let s = j["url"] as? String, let u = URL(string: s) {
                completion(u); return
            }
            tryNext(insts: rest, watchURL: watchURL, completion: completion)
        }.resume()
    }
}

// ---------------------------------------------------------------------------
// MARK: - Your own extractor server (BYO yt-dlp — nearly unbreakable path)
// ---------------------------------------------------------------------------

enum CustomExtractor {
    private static let key = "asmusic_customx"

    static var baseURLString: String {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static var isConfigured: Bool { !baseURLString.isEmpty }

    /// GET {base}/extract?v={vid} -> {"url": "...", "ext": "m4a"}.
    /// The server proxies the bytes itself, so the URL always works.
    static func resolve(vid: String, completion: @escaping (URL?, String?) -> Void) {
        guard isConfigured, let url = URL(string: "\(baseURLString)/extract?v=\(vid)") else {
            completion(nil, nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("ASMusic/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let s = j["url"] as? String, let u = URL(string: s) else {
                completion(nil, nil); return
            }
            let ext = (j["ext"] as? String) ?? "m4a"
            DownloadCenter.shared.probeForAudio(url: u, referer: "https://youtube.com/") { ready in
                completion(ready ? u : nil, ready ? ext : nil)
            }
        }.resume()
    }

    /// GET {base}/ -> {"ok": true} (settings "Test connection" button).
    static func ping(completion: @escaping (Bool) -> Void) {
        guard isConfigured, let url = URL(string: "\(baseURLString)/") else {
            completion(false); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("ASMusic/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (j["ok"] as? Bool) == true else { completion(false); return }
            completion(true)
        }.resume()
    }
}

// ---------------------------------------------------------------------------
// MARK: - SoundCloud API resolver (yt-dlp technique; fallback only)
// ---------------------------------------------------------------------------

enum SoundCloudResolver {
    private static let cidKey = "asmusic_sc_client_id"

    /// Resolve a SoundCloud track PAGE url — or, if nil, search by title —
    /// to a progressive MP3 via SoundCloud's own API. Only called after the
    /// classic direct-URL path has already failed.
    static func resolve(pageURL: URL?, titleQuery: String, completion: @escaping (URL?) -> Void) {
        withClientID { cid in
            guard let cid = cid else { completion(nil); return }
            if let page = pageURL {
                resolveURL(page, cid: cid, completion: completion)
            } else {
                search(query: titleQuery, cid: cid, completion: completion)
            }
        }
    }

    // ---- client_id (cached; scraped yt-dlp-style when missing) ------------

    private static func withClientID(completion: @escaping (String?) -> Void) {
        if let cached = UserDefaults.standard.string(forKey: cidKey), cached.count >= 20 {
            completion(cached); return
        }
        guard let home = URL(string: "https://soundcloud.com/") else { completion(nil); return }
        var req = URLRequest(url: home, timeoutInterval: 15)
        req.setValue(DownloadCenter.mobileUA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let html = data.flatMap({ String(data: $0, encoding: .utf8) }) else {
                completion(nil); return
            }
            if let inline = firstMatch(#"client_id\s*[:=]\s*"([a-zA-Z0-9]{20,60})"#, in: html) {
                saveCID(inline); completion(inline); return
            }
            let scripts = allMatches(#"<script[^>]+src="([^"]+\.js[^"]*)"#, in: html)
            fetchScripts(Array(scripts.prefix(8)), completion: completion)
        }.resume()
    }

    private static func fetchScripts(_ list: [String], completion: @escaping (String?) -> Void) {
        var rest = list
        guard let src = rest.first else { completion(nil); return }
        rest.removeFirst()
        let abs: String
        if src.hasPrefix("http") { abs = src }
        else if src.hasPrefix("//") { abs = "https:" + src }
        else if src.hasPrefix("/") { abs = "https://soundcloud.com" + src }
        else { abs = "https://soundcloud.com/" + src }
        guard let u = URL(string: abs) else {
            fetchScripts(rest, completion: completion); return
        }
        var req = URLRequest(url: u, timeoutInterval: 12)
        req.setValue(DownloadCenter.mobileUA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let js = data.flatMap({ String(data: $0, encoding: .utf8) }),
               let cid = firstMatch(#"client_id\s*[:=]\s*"([a-zA-Z0-9]{20,60})"#, in: js) {
                saveCID(cid); completion(cid); return
            }
            fetchScripts(rest, completion: completion)
        }.resume()
    }

    private static func saveCID(_ cid: String) {
        UserDefaults.standard.set(cid, forKey: cidKey)
    }

    // ---- resolve / search --------------------------------------------------

    private static func resolveURL(_ page: URL, cid: String, completion: @escaping (URL?) -> Void) {
        guard let enc = page.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "https://api-v2.soundcloud.com/resolve?url=\(enc)&client_id=\(cid)") else {
            completion(nil); return
        }
        getJSON(u) { j in
            guard let j = j else { completion(nil); return }
            followTranscoding(j, cid: cid, done: completion)
        }
    }

    private static func search(query: String, cid: String, completion: @escaping (URL?) -> Void) {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.lowercased().hasSuffix(".mp3") { q = String(q.dropLast(4)) }
        guard !q.isEmpty,
              let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "https://api-v2.soundcloud.com/search/tracks?q=\(enc)&client_id=\(cid)&limit=5") else {
            completion(nil); return
        }
        getJSON(u) { j in
            guard let items = j?["collection"] as? [[String: Any]],
                  let first = items.first else { completion(nil); return }
            followTranscoding(first, cid: cid, done: completion)
        }
    }

    /// Pick the progressive (plain MP3) transcoding and follow it to the
    /// signed media URL. Always completes exactly once via `done`.
    private static func followTranscoding(_ track: [String: Any], cid: String,
                                          done: @escaping (URL?) -> Void) {
        guard let media = track["media"] as? [String: Any],
              let trans = media["transcodings"] as? [[String: Any]] else {
            done(nil); return
        }
        var pick: String? = nil
        for t in trans {
            let proto = ((t["format"] as? [String: Any])?["protocol"] as? String) ?? ""
            if proto == "progressive", let u = t["url"] as? String { pick = u; break }
        }
        guard let base = pick,
              let u = URL(string: "\(base)?client_id=\(cid)") else {
            done(nil); return
        }
        getJSON(u) { j in
            if let s = j?["url"] as? String, let mediaURL = URL(string: s) {
                done(mediaURL)
            } else {
                done(nil)
            }
        }
    }

    private static func getJSON(_ url: URL, completion: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(DownloadCenter.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(nil); return
            }
            completion(j)
        }.resume()
    }

    // ---- tiny regex helpers (no exotic syntax — oldest-safe APIs) ---------

    private static func regex(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                guard m.numberOfRanges >= 2 else { return nil }
                return ns.substring(with: m.range(at: 1))
            }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        regex(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        regex(pattern, in: text)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Race plugs (called from DownloadCenter.startFastRace — additive)
// ---------------------------------------------------------------------------

/// One extra race contender: a UI label, a Referer, and the racer function.
typealias RaceContender = (label: String, referer: String,
                           run: (DownloadTask, @escaping (URL, String) -> Void, @escaping () -> Void) -> Void)

enum NewExtractors {
    /// Extra contenders for the fast race. The classic 3 contenders are
    /// untouched and always run; these simply join them (fastest valid URL
    /// wins). Disabled/unhealthy/configured-out engines are omitted, and the
    /// race's fail-counter only counts launched contenders.
    static func racers() -> [RaceContender] {
        var out: [RaceContender] = []
        let cfg = RegistryStore.shared.current
        if cfg.pipedEnabled != false {
            out.append((label: "Piped⚡", referer: "https://piped.video/", run: pipedRace))
        }
        if cfg.invidiousEnabled != false {
            out.append((label: "Invidious", referer: "https://invidious.io/", run: invidiousRace))
        }
        if cfg.cobaltEnabled == true {
            out.append((label: "Cobalt", referer: "https://cobalt.tools/", run: cobaltRace))
        }
        if CustomExtractor.isConfigured {
            out.append((label: "MyServer", referer: "https://youtube.com/", run: customRace))
        }
        return out
    }
}

/// Piped contender: direct M4A, probe-validated before it may win.
func pipedRace(task: DownloadTask,
               win: @escaping (URL, String) -> Void,
               lose: @escaping () -> Void) {
    guard BackendHealth.shared.shouldTry("piped") else { lose(); return }
    PipedAudio.resolve(vid: task.vid) { url in
        if task.raceCancelled || task.isCancelled { return }
        guard let u = url else { BackendHealth.shared.recordFail("piped"); lose(); return }
        DownloadCenter.shared.probeForAudio(url: u, referer: "https://piped.video/") { ready in
            if task.raceCancelled || task.isCancelled { return }
            if ready {
                BackendHealth.shared.recordSuccess("piped")
                win(u, DownloadCenter.y2jarName(task.proposedName))
            } else {
                BackendHealth.shared.recordFail("piped"); lose()
            }
        }
    }
}

/// Invidious contender: itag-140 M4A (already probe-validated by resolve).
func invidiousRace(task: DownloadTask,
                   win: @escaping (URL, String) -> Void,
                   lose: @escaping () -> Void) {
    guard BackendHealth.shared.shouldTry("invidious") else { lose(); return }
    InvidiousAudio.resolve(vid: task.vid) { url in
        if task.raceCancelled || task.isCancelled { return }
        if let u = url {
            BackendHealth.shared.recordSuccess("invidious")
            win(u, DownloadCenter.y2jarName(task.proposedName))
        } else {
            BackendHealth.shared.recordFail("invidious"); lose()
        }
    }
}

/// Cobalt contender (dormant until registry enables an instance).
func cobaltRace(task: DownloadTask,
                win: @escaping (URL, String) -> Void,
                lose: @escaping () -> Void) {
    guard BackendHealth.shared.shouldTry("cobalt") else { lose(); return }
    let watch = "https://www.youtube.com/watch?v=\(task.vid)"
    CobaltAudio.resolve(watchURL: watch) { url in
        if task.raceCancelled || task.isCancelled { return }
        guard let u = url else { BackendHealth.shared.recordFail("cobalt"); lose(); return }
        DownloadCenter.shared.probeForAudio(url: u, referer: "https://cobalt.tools/") { ready in
            if task.raceCancelled || task.isCancelled { return }
            if ready {
                BackendHealth.shared.recordSuccess("cobalt")
                win(u, DownloadCenter.ensureExt(task.proposedName, ext: "mp3"))
            } else {
                BackendHealth.shared.recordFail("cobalt"); lose()
            }
        }
    }
}

/// Your-own-server contender (only exists when configured in Engines).
func customRace(task: DownloadTask,
                win: @escaping (URL, String) -> Void,
                lose: @escaping () -> Void) {
    guard BackendHealth.shared.shouldTry("custom") else { lose(); return }
    CustomExtractor.resolve(vid: task.vid) { url, ext in
        if task.raceCancelled || task.isCancelled { return }
        if let u = url {
            BackendHealth.shared.recordSuccess("custom")
            let name: String
            if (ext ?? "m4a") == "mp3" {
                name = DownloadCenter.ensureExt(task.proposedName, ext: "mp3")
            } else {
                name = DownloadCenter.y2jarName(task.proposedName)
            }
            win(u, name)
        } else {
            BackendHealth.shared.recordFail("custom"); lose()
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Engines settings screen
// ---------------------------------------------------------------------------

struct EngineSettingsView: View {
    @AppStorage("asmusic_customx") private var customX: String = ""
    @State private var testing = false
    @State private var testResult: String? = nil

    var body: some View {
        List {
            Section(header: Text("Classic engines"),
                    footer: Text("y2jar • Mp3Juice • cnvmp3 • Theta — always on, never modified.")) {
                Label("Classic engines always on", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.primary)
            }
            Section(header: Text("Alternative engines"),
                    footer: Text("Each joins the download race. Only links proven to serve real audio can win, so a dead engine just loses quietly and the classic engines carry on.")) {
                engineRow(name: "Piped audio", id: "piped", desc: "Direct audio stream, no conversion")
                engineRow(name: "Invidious audio", id: "invidious", desc: "Direct M4A stream")
                engineRow(name: "Cobalt", id: "cobalt", desc: cobaltDesc)
                engineRow(name: "My own server", id: "custom",
                          desc: CustomExtractor.isConfigured ? "Configured" : "Not set up")
            }
            Section(header: Text("Your own extractor (optional)"),
                    footer: Text("Deploy the free extractor server (see extractor-server/README.md in the repo), paste its address here, and it joins every race. Example: https://my-extractor.onrender.com")) {
                TextField("https://…", text: $customX)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .font(.subheadline)
                Button(testing ? "Testing…" : "Test connection") { testCustom() }
                    .disabled(testing || customX.trimmingCharacters(in: .whitespaces).isEmpty)
                if let r = testResult {
                    Text(r).font(.caption).foregroundColor(.secondary)
                }
            }
            Section(header: Text("Backend list"),
                    footer: Text("Mirror lists refresh automatically once a day.")) {
                Button("Refresh now") { RegistryStore.shared.refreshIfStale(force: true) }
            }
        }
        .navigationTitle("Download Engines")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var cobaltDesc: String {
        let cfg = RegistryStore.shared.current
        if cfg.cobaltEnabled == true { return "Enabled" }
        return "Standby — enables automatically when available"
    }

    private func engineRow(name: String, id: String, desc: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(BackendHealth.shared.failCount(id) == 0 ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.bold()).foregroundColor(.primary)
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            let n = BackendHealth.shared.failCount(id)
            if n > 0 {
                Text("\(n) recent fails").font(.caption2).foregroundColor(.orange)
            }
        }
    }

    private func testCustom() {
        testing = true
        testResult = nil
        CustomExtractor.ping { ok in
            DispatchQueue.main.async {
                testing = false
                testResult = ok ? "Connected — your server will join every race."
                    : "No answer. Check the address and that the server is running."
            }
        }
    }
}
