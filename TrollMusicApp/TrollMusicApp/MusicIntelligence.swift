import Foundation
import SwiftUI
import UIKit
import Combine

// ===========================================================================
// MARK: - Music Intelligence
//
// A lightweight, key-free "music brain" built on Deezer's public catalog API
// (https://api.deezer.com — no auth needed for search / artist / chart).
//
// It does three things the user asked for:
//   1. Detects the artists & songs you actually listen to (taste profile).
//   2. Recommends NEW songs to download, based on what you love.
//   3. Suggests ready-made playlists grouped by artist so you can create
//      them with one tap.
//
// Recommendations are resolved to downloadable YouTube tracks through the
// existing DownloadCenter search pipeline, so a single tap on a suggestion
// drops it straight into your Library.
// ===========================================================================

// MARK: - Models

struct DiscoTrack: Identifiable, Equatable, Codable {
    var id: String            // "\(artist)|\(title)" normalized – stable across launches
    var title: String
    var artist: String
    var artistId: Int?
    var albumCover: String?   // artwork URL from Deezer
    var previewURL: String?   // 30s preview mp3 from Deezer (optional taste preview)
    var reason: String        // why we recommended it (e.g. "Because you like Wegz")

    static func == (l: DiscoTrack, r: DiscoTrack) -> Bool { l.id == r.id }
}

struct DiscoArtist: Identifiable, Equatable {
    let id: Int
    let name: String
    let picture: String?
    var playCountInLibrary: Int = 0
}

// MARK: - Deezer API (key-free public catalog)

enum DeezerAPI {
    private static let base = "https://api.deezer.com"
    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static func get(_ path: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: base + path) else { completion(nil); return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json,*/*", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(nil); return
            }
            completion(j)
        }.resume()
    }

    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }

    /// Resolve an artist name to a Deezer artist object (best match).
    static func findArtist(_ name: String, completion: @escaping (DiscoArtist?) -> Void) {
        get("/search/artist?limit=1&q=\(q(name))") { j in
            guard let arr = j?["data"] as? [[String: Any]], let first = arr.first,
                  let id = (first["id"] as? NSNumber)?.intValue,
                  let nm = first["name"] as? String else { completion(nil); return }
            completion(DiscoArtist(id: id, name: nm, picture: first["picture_medium"] as? String))
        }
    }

    /// Top tracks for an artist id.
    static func topTracks(artistId: Int, limit: Int = 15, completion: @escaping ([DiscoTrack]) -> Void) {
        get("/artist/\(artistId)/top?limit=\(limit)") { j in
            completion(parseTracks(j?["data"] as? [[String: Any]], reasonFallback: ""))
        }
    }

    /// Related / similar artists to an artist id.
    static func relatedArtists(artistId: Int, limit: Int = 8, completion: @escaping ([DiscoArtist]) -> Void) {
        get("/artist/\(artistId)/related?limit=\(limit)") { j in
            guard let arr = j?["data"] as? [[String: Any]] else { completion([]); return }
            let out: [DiscoArtist] = arr.compactMap {
                guard let id = ($0["id"] as? NSNumber)?.intValue,
                      let nm = $0["name"] as? String else { return nil }
                return DiscoArtist(id: id, name: nm, picture: $0["picture_medium"] as? String)
            }
            completion(out)
        }
    }

    /// Free-text track search (used for "detect this song").
    static func searchTracks(_ query: String, limit: Int = 20, completion: @escaping ([DiscoTrack]) -> Void) {
        get("/search/track?limit=\(limit)&q=\(q(query))") { j in
            completion(parseTracks(j?["data"] as? [[String: Any]], reasonFallback: ""))
        }
    }

    /// Global / regional chart tracks.
    static func chartTracks(limit: Int = 25, completion: @escaping ([DiscoTrack]) -> Void) {
        get("/chart/0/tracks?limit=\(limit)") { j in
            completion(parseTracks(j?["data"] as? [[String: Any]], reasonFallback: "Trending now"))
        }
    }

    private static func parseTracks(_ arr: [[String: Any]]?, reasonFallback: String) -> [DiscoTrack] {
        guard let arr = arr else { return [] }
        var out = [DiscoTrack]()
        for t in arr {
            guard let title = t["title"] as? String else { continue }
            let artistDict = t["artist"] as? [String: Any]
            let artistName = (artistDict?["name"] as? String) ?? ""
            let artistId = (artistDict?["id"] as? NSNumber)?.intValue
            let albumDict = t["album"] as? [String: Any]
            let cover = (albumDict?["cover_medium"] as? String) ?? (t["cover_medium"] as? String)
            let preview = t["preview"] as? String
            out.append(DiscoTrack(
                id: TasteEngine.normKey(artist: artistName, title: title),
                title: title, artist: artistName, artistId: artistId,
                albumCover: cover, previewURL: preview, reason: reasonFallback))
        }
        return out
    }
}

// MARK: - Taste engine helpers

enum TasteEngine {
    /// Normalized dedupe key so "Amr Diab - Tamally Maak" and
    /// "amr diab  tamally maak (official)" collapse to the same identity.
    static func normKey(artist: String, title: String) -> String {
        func norm(_ s: String) -> String {
            var x = s.lowercased()
            x = x.folding(options: .diacriticInsensitive, locale: .current)
            x = x.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            x = x.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            x = x.replacingOccurrences(of: #"[^a-z0-9\u0600-\u06FF ]"#, with: "", options: .regularExpression)
            x = x.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return x.trimmingCharacters(in: .whitespaces)
        }
        return "\(norm(artist))|\(norm(title))"
    }
}

// MARK: - Discovery Manager

class DiscoveryManager: ObservableObject {
    static let shared = DiscoveryManager()

    @Published var topArtists: [DiscoArtist] = []
    @Published var recommendations: [DiscoTrack] = []
    @Published var trending: [DiscoTrack] = []
    @Published var isLoading = false
    @Published var lastError: String? = nil

    private var lastRefresh: Date = .distantPast

    private init() {}

    // ---- Taste profile ---------------------------------------------------

    /// Count how often each artist appears in the Library, weighting Liked
    /// songs more heavily. Returns the artists sorted by that weight.
    private func libraryArtistWeights() -> [(artist: String, weight: Int)] {
        let mm = MusicManager.shared
        let likedIDs = Set(mm.playlists.first(where: { $0.name == "Liked Songs" })?.songIDs ?? [])
        var weights: [String: Int] = [:]
        for song in mm.songs {
            let a = song.artist.trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, a != "AS Music", a != "YouTube", a != "SoundCloud" else { continue }
            weights[a, default: 0] += likedIDs.contains(song.id) ? 3 : 1
        }
        return weights.sorted { $0.value > $1.value }.map { (artist: $0.key, weight: $0.value) }
    }

    /// A quick set of everything already in the Library (normalized) so we
    /// never recommend a song the user already has.
    private func librarySignatures() -> Set<String> {
        Set(MusicManager.shared.songs.map { TasteEngine.normKey(artist: $0.artist, title: $0.title) })
    }

    // ---- Recommendations -------------------------------------------------

    func refresh(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastRefresh) < 60, !recommendations.isEmpty { return }
        lastRefresh = Date()

        let weighted = libraryArtistWeights()
        DispatchQueue.main.async {
            self.isLoading = true
            self.lastError = nil
        }

        // Always load a trending row as a fallback / discovery source.
        DeezerAPI.chartTracks(limit: 25) { [weak self] tracks in
            guard let self = self else { return }
            let have = self.librarySignatures()
            let filtered = tracks.filter { !have.contains($0.id) }
            DispatchQueue.main.async { self.trending = filtered }
        }

        guard !weighted.isEmpty else {
            // Empty library — recommend from the chart so there's still value.
            DeezerAPI.chartTracks(limit: 30) { [weak self] tracks in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.recommendations = Array(tracks.prefix(30))
                    self.topArtists = []
                    self.isLoading = false
                }
            }
            return
        }

        let seedArtists = Array(weighted.prefix(5))
        let have = librarySignatures()
        let group = DispatchGroup()
        let lock = NSLock()
        var detected: [DiscoArtist] = []
        var candidates: [DiscoTrack] = []
        var seenTrack = Set<String>()

        func add(_ tracks: [DiscoTrack], reason: String) {
            lock.lock()
            for t in tracks {
                guard !have.contains(t.id), seenTrack.insert(t.id).inserted else { continue }
                var copy = t
                if copy.reason.isEmpty { copy.reason = reason }
                candidates.append(copy)
            }
            lock.unlock()
        }

        for seed in seedArtists {
            group.enter()
            DeezerAPI.findArtist(seed.artist) { artist in
                guard let artist = artist else { group.leave(); return }
                lock.lock()
                var a = artist; a.playCountInLibrary = seed.weight
                detected.append(a)
                lock.unlock()

                let inner = DispatchGroup()

                // 1) More of the artist you already love.
                inner.enter()
                DeezerAPI.topTracks(artistId: artist.id, limit: 12) { tracks in
                    add(tracks, reason: "More from \(artist.name)")
                    inner.leave()
                }

                // 2) Similar artists' top tracks (the discovery magic).
                inner.enter()
                DeezerAPI.relatedArtists(artistId: artist.id, limit: 5) { related in
                    let relGroup = DispatchGroup()
                    for r in related.prefix(4) {
                        relGroup.enter()
                        DeezerAPI.topTracks(artistId: r.id, limit: 5) { tracks in
                            add(tracks, reason: "Because you like \(artist.name)")
                            relGroup.leave()
                        }
                    }
                    relGroup.notify(queue: .global()) { inner.leave() }
                }

                inner.notify(queue: .global()) { group.leave() }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.topArtists = detected.sorted { $0.playCountInLibrary > $1.playCountInLibrary }
            // Interleave "more from" and "because you like" so the list feels varied.
            var shuffled = candidates
            shuffled.shuffle()
            self.recommendations = Array(shuffled.prefix(40))
            self.isLoading = false
            if self.recommendations.isEmpty {
                self.lastError = "Couldn't build recommendations right now. Pull to refresh."
            }
        }
    }

    // ---- Auto playlists --------------------------------------------------

    struct PlaylistSuggestion: Identifiable {
        var id: String { name }
        let name: String
        let songIDs: [UUID]
        let count: Int
    }

    /// Group the Library by detected artist so the user can create an
    /// "artist playlist" with one tap. Only artists with 2+ songs qualify.
    func playlistSuggestions() -> [PlaylistSuggestion] {
        let mm = MusicManager.shared
        var byArtist: [String: [UUID]] = [:]
        for s in mm.songs {
            let a = s.artist.trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, a != "AS Music", a != "YouTube", a != "SoundCloud" else { continue }
            byArtist[a, default: []].append(s.id)
        }
        let existing = Set(mm.playlists.map { $0.name.lowercased() })
        return byArtist
            .filter { $0.value.count >= 2 && !existing.contains($0.key.lowercased()) }
            .sorted { $0.value.count > $1.value.count }
            .map { PlaylistSuggestion(name: $0.key, songIDs: $0.value, count: $0.value.count) }
    }

    func createPlaylist(from suggestion: PlaylistSuggestion) {
        let mm = MusicManager.shared
        mm.createPlaylist(name: suggestion.name)
        guard let pl = mm.playlists.last else { return }
        for id in suggestion.songIDs {
            if let song = mm.songs.first(where: { $0.id == id }) {
                mm.addSongToPlaylist(song: song, playlist: pl)
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
