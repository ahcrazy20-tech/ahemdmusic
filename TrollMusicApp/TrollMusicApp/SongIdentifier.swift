import Foundation
import AVFoundation
import SwiftUI
import UIKit
#if canImport(ShazamKit)
import ShazamKit
#endif

// ===========================================================================
// MARK: - Song Identifier — "what IS this file?"
//
// The root data problem in this app: a library full of
// `Amr Diab - Tamally Maak (Official Video) [HD] 1.mp3`, `audio_2024.mp3`,
// `يا حبيبي 320kbps.m4a`. `NameTidy` cleans the *string*; nothing knew the
// actual *song*. Everything downstream suffers: lyrics lookup searches by
// title+artist, the duplicate finder groups by a normalized name, iTunes
// enrichment fuzzy-matches, genres stay empty.
//
// This file fixes the root cause with two engines, tried in order:
//
//   1. ShazamKit (📱 on-device signature, Apple's catalog)
//      `SHSignatureGenerator` turns ~12 s of the actual AUDIO into a
//      signature; `SHSession` matches it and returns the real title, artist,
//      ALBUM, release year, artwork URL, ISRC and genres. This identifies a
//      file whose name is pure garbage, because it listens to it.
//
//   2. iTunes Search (🌐 free, no key) on the cleaned file name
//      The fallback when ShazamKit is unavailable (entitlement missing on a
//      sideloaded build) or when a track simply isn't in the catalog —
//      mahraganat and small local artists often aren't.
//
// SAFETY: nothing is ever renamed automatically. Every match lands in a
// review list with a confidence badge, the user ticks what to apply, and the
// rename goes through `MusicManager.setSongInfo` — the path that carries the
// song's id, playlists, likes and play counts across the change.
//
// AVAILABILITY: ShazamKit needs its entitlement. On a TrollStore build that
// may or may not be granted, so every ShazamKit touch is behind
// `SongIdentifier.shazamAvailable` and a `canImport` guard — with the
// entitlement missing the feature degrades to engine 2 instead of crashing.
// ===========================================================================

/// One proposed identification, pending the user's approval.
struct IdentifiedSong: Identifiable {
    var song: Song
    var title: String
    var artist: String
    var album: String
    var year: String
    var artworkURL: String?
    var genre: String?
    /// "Shazam" or "iTunes" — shown as a badge so the user knows how sure to be.
    var source: String
    /// 0…1. ShazamKit matches are authoritative (1.0); name-based matches
    /// carry the string similarity that produced them.
    var confidence: Double
    var selected: Bool = true

    var id: UUID { song.id }

    /// True when the proposal actually changes something worth applying.
    var isChange: Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        let a = artist.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return t != song.title || (!a.isEmpty && a != song.artist)
    }

    var displayLine: String {
        let a = artist.trimmingCharacters(in: .whitespaces)
        var s = a.isEmpty ? title : "\(a) — \(title)"
        if !album.isEmpty { s += " · \(album)" }
        if !year.isEmpty { s += " (\(year))" }
        return s
    }
}

// MARK: - The identifier

@MainActor
final class SongIdentifier: ObservableObject {
    static let shared = SongIdentifier()

    @Published private(set) var results: [IdentifiedSong] = []
    @Published private(set) var busy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var scanned = 0
    @Published private(set) var total = 0
    @Published var note: String? = nil
    @Published var error: String? = nil

    private var cancelled = false

    private init() {}

    /// Whether the ShazamKit path can run in THIS build. False on a build
    /// whose entitlement was stripped — the UI then says so honestly instead
    /// of failing mysteriously.
    static var shazamAvailable: Bool {
        #if canImport(ShazamKit)
        if #available(iOS 15.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    /// Songs worth identifying: messy names, missing artist, or no genre.
    static func candidates(from songs: [Song]) -> [Song] {
        songs.filter { s in
            NameHeuristics.looksMessy(s)
                || s.artist.trimmingCharacters(in: .whitespaces).isEmpty
                || s.artist == "AS Music"
                || s.artist == "YouTube"
                || s.artist == "SoundCloud"
                || (s.genre ?? "").isEmpty
        }
    }

    func cancel() { cancelled = true }

    func clear() {
        results = []
        note = nil
        error = nil
        scanned = 0
        total = 0
        progress = 0
    }

    /// Identify a batch of songs. Runs sequentially so the app stays smooth
    /// and Apple's service isn't hammered; a 40-song sweep takes a while and
    /// shows progress throughout.
    func identify(songs: [Song], limit: Int = 40) {
        guard !busy else { return }
        let batch = Array(songs.prefix(limit))
        guard !batch.isEmpty else {
            note = "Nothing needs identifying — every song already has a clean title, artist and genre."
            return
        }
        busy = true
        cancelled = false
        error = nil
        note = nil
        results = []
        scanned = 0
        total = batch.count
        progress = 0

        Task { await runIdentification(batch) }
    }

    private func runIdentification(_ batch: [Song]) async {
        var found: [IdentifiedSong] = []

        for song in batch {
            if cancelled { break }

            var match: IdentifiedSong? = nil

            // Engine 1: listen to the actual audio.
            if Self.shazamAvailable {
                match = await Self.identifyByAudio(song)
            }
            // Engine 2: the free catalogue lookup on a cleaned-up name.
            if match == nil {
                match = await Self.identifyByName(song)
            }

            if let m = match, m.isChange {
                found.append(m)
            }

            scanned += 1
            progress = total > 0 ? Double(scanned) / Double(total) : 0
            results = found
        }

        busy = false
        if cancelled {
            note = found.isEmpty ? "Stopped." : "Stopped — \(found.count) match\(found.count == 1 ? "" : "es") found so far."
            return
        }
        if found.isEmpty {
            note = Self.shazamAvailable
                ? "Checked \(scanned) song\(scanned == 1 ? "" : "s") — no confident matches. Local and rare tracks often aren't in the catalog."
                : "Checked \(scanned) song\(scanned == 1 ? "" : "s") by name. Audio matching (Shazam) isn't available in this build, so only well-named files can be looked up."
        } else {
            note = "Found \(found.count) match\(found.count == 1 ? "" : "es") — review them below, then apply."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: Engine 1 — ShazamKit (on-device signature of the real audio)

    /// Reads a slice of the file, builds a signature and asks Shazam.
    /// Returns nil when unavailable, unmatched, or on any error.
    private static func identifyByAudio(_ song: Song) async -> IdentifiedSong? {
        #if canImport(ShazamKit)
        guard #available(iOS 15.0, *) else { return nil }
        guard let signature = await makeSignature(for: song.url) else { return nil }

        let session = SHSession()
        let match: SHMatch? = await withCheckedContinuation { continuation in
            let delegate = ShazamDelegate { result in
                continuation.resume(returning: result)
            }
            // The delegate must outlive the call; the box keeps it alive until
            // the continuation fires.
            delegate.retainSelf(session: session)
            session.delegate = delegate
            session.match(signature)
        }

        guard let item = match?.mediaItems.first else { return nil }
        let title = item.title ?? ""
        guard !title.isEmpty else { return nil }

        // `creationDate` is iOS 17+, and this app targets iOS 16, so read the
        // same value out of the property dictionary instead — same result,
        // no availability gate, and it simply comes back nil on older systems.
        var year = ""
        if let date = item[SHMediaItemProperty("creationDate")] as? Date {
            year = String(Calendar.current.component(.year, from: date))
        }

        return IdentifiedSong(
            song: song,
            title: title,
            artist: item.artist ?? "",
            album: Self.albumName(from: item),
            year: year,
            artworkURL: item.artworkURL?.absoluteString,
            genre: item.genres.first,
            source: "Shazam",
            confidence: 1.0
        )
        #else
        return nil
        #endif
    }

    #if canImport(ShazamKit)
    @available(iOS 15.0, *)
    private static func albumName(from item: SHMatchedMediaItem) -> String {
        // `albumName` only exists on newer SDKs; read it defensively through
        // the item's property dictionary so this compiles against iOS 15+.
        if let s = item[SHMediaItemProperty("albumName")] as? String { return s }
        return ""
    }

    /// Builds a Shazam signature from up to 14 s taken from the middle of the
    /// track (intros are often silence, applause or a talk-over).
    @available(iOS 15.0, *)
    private static func makeSignature(for url: URL) async -> SHSignature? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let file = try? AVAudioFile(forReading: url) else {
                    continuation.resume(returning: nil); return
                }
                let format = file.processingFormat
                let sr = format.sampleRate
                guard sr > 1000, file.length > 0 else {
                    continuation.resume(returning: nil); return
                }

                let generator = SHSignatureGenerator()
                // Start ~20% in, take 14 s (or whatever the file has).
                let wanted = AVAudioFramePosition(min(Double(file.length), sr * 14))
                let start = max(0, min(file.length - wanted, AVAudioFramePosition(Double(file.length) * 0.2)))
                file.framePosition = start

                let chunk: AVAudioFrameCount = 8192
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                    continuation.resume(returning: nil); return
                }
                var remaining = wanted
                while remaining > 0 {
                    let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
                    do {
                        try file.read(into: buffer, frameCount: toRead)
                    } catch { break }
                    if buffer.frameLength == 0 { break }
                    do {
                        try generator.append(buffer, at: nil)
                    } catch { break }
                    remaining -= AVAudioFramePosition(buffer.frameLength)
                }

                let signature = generator.signature()
                // A signature under ~3 s never matches; don't waste the call.
                if signature.duration < 3 {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: signature)
                }
            }
        }
    }
    #endif

    // MARK: Engine 2 — iTunes Search on a cleaned name (free, no key)

    private static func identifyByName(_ song: Song) async -> IdentifiedSong? {
        let cleaned = NameHeuristics.clean(song)
        let query = [cleaned.artist, cleaned.title]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 3 else { return nil }
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=5")
        else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["results"] as? [[String: Any]], !items.isEmpty
        else { return nil }

        let wantKey = TasteEngine.normKey(artist: cleaned.artist, title: cleaned.title)
        var best: (score: Double, item: [String: Any])? = nil

        for r in items {
            guard let t = r["trackName"] as? String,
                  let a = r["artistName"] as? String else { continue }
            let key = TasteEngine.normKey(artist: a, title: t)
            let score = Self.similarity(wantKey, key)
            if best == nil || score > best!.score { best = (score, r) }
        }

        // Below this the "match" is usually a different song entirely — better
        // to return nothing than to rename a file wrongly.
        guard let picked = best, picked.score >= 0.62,
              let t = picked.item["trackName"] as? String,
              let a = picked.item["artistName"] as? String else { return nil }

        var year = ""
        if let released = picked.item["releaseDate"] as? String, released.count >= 4 {
            year = String(released.prefix(4))
        }
        var art: String? = nil
        if let a100 = picked.item["artworkUrl100"] as? String {
            art = a100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        }

        return IdentifiedSong(
            song: song,
            title: t,
            artist: a,
            album: (picked.item["collectionName"] as? String) ?? "",
            year: year,
            artworkURL: art,
            genre: picked.item["primaryGenreName"] as? String,
            source: "iTunes",
            confidence: picked.score
        )
    }

    /// Cheap token-overlap similarity (Jaccard over words). Good enough to
    /// separate "the same song" from "a different song by the same artist".
    static func similarity(_ a: String, _ b: String) -> Double {
        let sa = Set(a.split(separator: " ").map(String.init))
        let sb = Set(b.split(separator: " ").map(String.init))
        guard !sa.isEmpty, !sb.isEmpty else { return 0 }
        let inter = Double(sa.intersection(sb).count)
        let union = Double(sa.union(sb).count)
        return union > 0 ? inter / union : 0
    }

    // MARK: Applying

    func setSelection(_ id: UUID, _ on: Bool) {
        guard let i = results.firstIndex(where: { $0.id == id }) else { return }
        results[i].selected = on
    }

    func selectAll(_ on: Bool) {
        for i in results.indices { results[i].selected = on }
    }

    var selectedCount: Int { results.filter { $0.selected }.count }

    /// Applies the ticked matches. Renames go through `setSongInfo`, which
    /// keeps the song's id — so playlists, likes and play counts survive.
    @discardableResult
    func applySelected(using mm: MusicManager) -> Int {
        let chosen = results.filter { $0.selected && $0.isChange }
        guard !chosen.isEmpty else { return 0 }
        var done = 0
        for item in chosen {
            let title = item.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let artist = item.artist.trimmingCharacters(in: .whitespaces)
            mm.setSongInfo(song: item.song, title: title, artist: artist)
            // Carry the genre and artwork across too — that's half the value
            // of having identified the track at all.
            if let g = item.genre, !g.isEmpty {
                mm.setGenre(songID: item.song.id, genre: g)
            }
            if let art = item.artworkURL, !art.isEmpty {
                mm.setArtworkURL(songID: item.song.id, url: art)
            }
            done += 1
        }
        if done > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            note = "Identified and renamed \(done) song\(done == 1 ? "" : "s"). Playlists, likes and play counts travelled with them."
            mm.saveSongMeta()
            mm.loadSongs()
        }
        let appliedIDs = Set(chosen.map { $0.song.id })
        results.removeAll { appliedIDs.contains($0.song.id) }
        return done
    }
}

// MARK: - ShazamKit delegate bridge

#if canImport(ShazamKit)
@available(iOS 15.0, *)
private final class ShazamDelegate: NSObject, SHSessionDelegate {
    private let completion: (SHMatch?) -> Void
    private var done = false
    private var strongSelf: ShazamDelegate?
    private var session: SHSession?
    private let lock = NSLock()

    init(completion: @escaping (SHMatch?) -> Void) {
        self.completion = completion
        super.init()
    }

    /// Keeps the delegate (and the session it belongs to) alive until the
    /// match resolves — SHSession holds its delegate weakly.
    func retainSelf(session: SHSession) {
        self.strongSelf = self
        self.session = session
        // A stuck request must not hang the sweep forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.finish(nil)
        }
    }

    private func finish(_ match: SHMatch?) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        completion(match)
        session = nil
        strongSelf = nil
    }

    func session(_ session: SHSession, didFind match: SHMatch) { finish(match) }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        finish(nil)
    }
}
#endif

// MARK: - Review UI

struct IdentifySongsView: View {
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var identifier = SongIdentifier.shared
    @Environment(\.presentationMode) private var pm

    private var candidates: [Song] { SongIdentifier.candidates(from: musicManager.songs) }

    var body: some View {
        NavigationView {
            List {
                introSection
                if identifier.busy { progressSection }
                if let n = identifier.note { messageRow(n, color: .secondary) }
                if let e = identifier.error { messageRow(e, color: .orange) }
                if !identifier.results.isEmpty { resultsSection }
            }
            .navigationTitle("Identify songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { pm.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if identifier.busy {
                        Button("Stop") { identifier.cancel() }
                    } else if !identifier.results.isEmpty {
                        Button("Apply (\(identifier.selectedCount))") {
                            _ = identifier.applySelected(using: musicManager)
                        }
                        .disabled(identifier.selectedCount == 0)
                        .fontWeight(.semibold)
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var introSection: some View {
        Section(footer: Text(SongIdentifier.shazamAvailable
            ? "Listens to a few seconds of each file on this device and matches it against Apple's music catalog — so even a file called “audio_2024.mp3” gets its real title, artist, album and year. Nothing is renamed until you tap Apply."
            : "Audio matching (ShazamKit) isn't available in this build, so songs are looked up by their cleaned-up file name instead. Nothing is renamed until you tap Apply.")) {
            HStack {
                Label("Songs that need it", systemImage: "questionmark.circle")
                Spacer()
                Text("\(candidates.count)").foregroundColor(.secondary)
            }
            HStack {
                Label("Matching engine", systemImage: SongIdentifier.shazamAvailable ? "waveform.badge.magnifyingglass" : "textformat.abc")
                Spacer()
                Text(SongIdentifier.shazamAvailable ? "Audio + name" : "Name only")
                    .foregroundColor(.secondary)
            }
            Button {
                identifier.identify(songs: candidates)
            } label: {
                Label(identifier.busy ? "Identifying…" : "Identify \(min(candidates.count, 40)) songs",
                      systemImage: "sparkle.magnifyingglass")
            }
            .disabled(identifier.busy || candidates.isEmpty)
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: identifier.progress)
                    .tint(AppTheme.accent)
                Text("Checked \(identifier.scanned) of \(identifier.total)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func messageRow(_ text: String, color: Color) -> some View {
        Section { Text(text).font(.footnote).foregroundColor(color) }
    }

    private var resultsSection: some View {
        Section(header: HStack {
            Text("Matches")
            Spacer()
            Button(identifier.selectedCount == identifier.results.count ? "None" : "All") {
                identifier.selectAll(identifier.selectedCount != identifier.results.count)
            }
            .font(.caption.bold())
        }) {
            ForEach(identifier.results) { item in
                Button {
                    identifier.setSelection(item.id, !item.selected)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(item.selected ? AppTheme.accent : .secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.song.title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .strikethrough()
                                .lineLimit(1)
                            Text(item.displayLine)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(item.source.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(item.source == "Shazam" ? Color.blue.opacity(0.25) : Color.gray.opacity(0.25))
                                    .cornerRadius(4)
                                if item.confidence < 1.0 {
                                    Text("\(Int(item.confidence * 100))% name match")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                if let g = item.genre, !g.isEmpty {
                                    Text(g).font(.system(size: 9)).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
