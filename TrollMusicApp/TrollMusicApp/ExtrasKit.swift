import Foundation
import SwiftUI
import UIKit

// ===========================================================================
// MARK: - ExtrasKit
//
// Four things a music app feels unfinished without, all built on top of the
// analysis and history the app already keeps on device:
//
//   1. AcousticRadio  — "More like this": a playlist of the songs that SOUND
//                       closest to the one you are playing.
//   2. Artists        — the library grouped by artist (the app had no way to
//                       browse them at all).
//   3. LibraryFilter  — one-tap lenses over the library (new, unplayed, …).
//   4. NameTidy       — messy YouTube file names, cleaned in bulk, with the AI
//                       doing the naming when a key is configured.
//
// Nothing here deletes a file, and every rename keeps the song's id, so
// playlists, likes and play counts survive (see MusicManager.setSongInfo).
// ===========================================================================

// MARK: - 1. Acoustic radio

enum AcousticRadio {

    /// Builds (or refreshes) a playlist of the songs that sound most like
    /// `song`, using the same 0…1 feature space the smart playlists use.
    /// Returns the playlist name, or nil when the library is too small.
    @discardableResult
    static func makePlaylist(similarTo song: Song, count: Int = 15) -> String? {
        let engine = SmartPlaylistEngine.shared
        let vs = engine.vectors()
        guard let anchor = vs.first(where: { $0.song.id == song.id }) else { return nil }
        let others = vs.filter { $0.song.id != song.id }
        guard others.count >= 4 else { return nil }

        let anchorDims = anchor.dims
        let anchorArtist = anchor.song.artist.trimmingCharacters(in: .whitespaces).lowercased()

        let scored: [(v: SongVector, score: Double)] = others.map { v -> (v: SongVector, score: Double) in
            var score = -FeatureMath.distance(anchorDims, v.dims)
            if !anchor.genre.isEmpty, anchor.genre == v.genre { score -= 0.10 }
            // Keep an Arabic request in Arabic and a Latin one in Latin.
            if abs(anchor.arabic - v.arabic) > 0.5 { score += 0.30 }
            // A little variety: don't let one artist eat the whole list.
            if v.song.artist.trimmingCharacters(in: .whitespaces).lowercased() == anchorArtist {
                score += 0.06
            }
            if v.liked > 0 { score -= 0.03 }
            return (v, score)
        }

        let take = max(6, min(count, others.count))
        let nearest = scored.sorted { $0.score > $1.score }.prefix(take).map { $0.v }
        let ordered = [anchor] + PlaylistFlow.order(nearest)

        let shortTitle = String(song.title.prefix(26))
        let suggestion = SmartPlaylistSuggestion(
            kind: "more-" + StableKey.make(song.id.uuidString),
            title: "More like \(shortTitle)",
            blurb: "The \(ordered.count) songs nearest to “\(song.title)” by sound — tempo, tone and energy.",
            icon: "waveform.path.ecg",
            songIDs: ordered.map { $0.song.id },
            usesAI: false)
        guard engine.apply(suggestion, userInitiated: true) else { return nil }
        return suggestion.title
    }

    /// Plays the "More like this" list for a song, building it first if needed.
    @discardableResult
    static func play(similarTo song: Song) -> Bool {
        let mm = MusicManager.shared
        let name = makePlaylist(similarTo: song) ?? "More like \(String(song.title.prefix(26)))"
        guard let pl = mm.playlists.first(where: { $0.name == name }) else { return false }
        _ = mm.playPlaylist(pl)
        return true
    }
}

// MARK: - 2. Artists

struct ArtistSummary: Identifiable {
    let id: String            // normalized artist key
    var name: String          // the spelling used most often in the library
    var songs: [Song]
    var minutes: Double
    var plays: Int

    var subtitle: String {
        var parts = ["\(songs.count) song\(songs.count == 1 ? "" : "s")"]
        if minutes >= 1 { parts.append("\(Int((minutes / 60).rounded())) min") }
        if plays > 0 { parts.append("\(plays) play\(plays == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

enum LibraryGrouping {

    static func artists(from songs: [Song]) -> [ArtistSummary] {
        var buckets: [String: [Song]] = [:]
        for s in songs {
            let key = key(for: s.artist)
            buckets[key, default: []].append(s)
        }

        let history = ListenHistory.shared
        let lab = AudioLab.shared
        var out: [ArtistSummary] = []
        out.reserveCapacity(buckets.count)

        for (key, list) in buckets {
            let minutes = list.reduce(0.0) { (total: Double, s: Song) -> Double in
                total + (lab.features(for: s)?.duration ?? 0)
            }
            let plays = list.reduce(0) { (total: Int, s: Song) -> Int in
                total + history.playCount(for: s)
            }
            let sorted = list.sorted { (l: Song, r: Song) -> Bool in
                l.title.localizedCaseInsensitiveCompare(r.title) == .orderedAscending
            }
            out.append(ArtistSummary(id: key, name: displayName(for: list),
                                     songs: sorted, minutes: minutes, plays: plays))
        }

        return out.sorted { l, r in
            if l.songs.count != r.songs.count { return l.songs.count > r.songs.count }
            return l.name.localizedCaseInsensitiveCompare(r.name) == .orderedAscending
        }
    }

    static func key(for artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "as music" : trimmed
    }

    /// Files ripped from different sources spell the same artist differently —
    /// show the spelling the library actually uses most.
    private static func displayName(for songs: [Song]) -> String {
        var counts: [String: Int] = [:]
        for s in songs {
            let n = s.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { counts[n, default: 0] += 1 }
        }
        guard let best = counts.max(by: { l, r in
            if l.value != r.value { return l.value < r.value }
            return l.key.count < r.key.count
        }) else { return "AS Music" }
        return best.key
    }
}

struct ArtistsBrowserView: View {
    @EnvironmentObject var musicManager: MusicManager
    @State private var query = ""
    @State private var artists: [ArtistSummary] = []

    var body: some View {
        NavigationView {
            Group {
                if artists.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("No artists yet").font(.headline)
                        Text("Songs get an artist from their file name or from the free iTunes lookup.")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(shown) { artist in
                                NavigationLink(destination: ArtistDetailView(summary: artist)) {
                                    HStack(spacing: 10) {
                                        ArtworkView(song: artist.songs[0], size: 44, cornerRadius: 22,
                                                    fallbackSystemName: "person.fill")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(artist.name).font(.headline).lineLimit(1)
                                            Text(artist.subtitle)
                                                .font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("\(shown.count) artist\(shown.count == 1 ? "" : "s")")
                        }
                    }
                }
            }
            .navigationTitle("Artists")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search artists")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { artists = LibraryGrouping.artists(from: musicManager.songs) }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var shown: [ArtistSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return artists }
        return artists.filter { $0.name.lowercased().contains(q) }
    }

    @Environment(\.presentationMode) private var presentationMode
    private func dismiss() { presentationMode.wrappedValue.dismiss() }
}

struct ArtistDetailView: View {
    @EnvironmentObject var musicManager: MusicManager
    var summary: ArtistSummary
    @State private var note: String? = nil

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    ArtworkView(song: summary.songs[0], size: 64, cornerRadius: 32,
                                fallbackSystemName: "person.fill")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.name).font(.title3.bold())
                        Text(summary.subtitle).font(.caption).foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button { PlayQueues.play(summary.songs, shuffled: false) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button { PlayQueues.play(summary.songs, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    Spacer()
                }
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.accent)
                .buttonStyle(.borderless)

                Button { makePlaylist() } label: {
                    Label("Make a playlist of \(summary.name)", systemImage: "plus.circle")
                }
            }

            Section(header: Text("Songs")) {
                ForEach(summary.songs) { song in
                    Button { musicManager.playSong(song) } label: {
                        HStack(spacing: 10) {
                            ArtworkView(song: song, size: 40, cornerRadius: 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(song.title).foregroundColor(.primary).lineLimit(1)
                                if let g = song.genre, !g.isEmpty {
                                    Text(g).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            let plays = ListenHistory.shared.playCount(for: song)
                            if plays > 0 {
                                Text("\(plays)×").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let note = note {
                Section { Text(note).font(.caption).foregroundColor(.green) }
            }
        }
        .navigationTitle(summary.name)
    }

    private func makePlaylist() {
        let name = summary.name
        let ids = summary.songs.map { $0.id }
        if let idx = musicManager.playlists.firstIndex(where: { $0.name == name }) {
            musicManager.playlists[idx].songIDs = ids
        } else {
            musicManager.createPlaylist(name: name)
            if let idx = musicManager.playlists.indices.last {
                musicManager.playlists[idx].songIDs = ids
            }
        }
        musicManager.savePlaylists()
        note = "“\(name)” — \(ids.count) songs, saved in Playlists."
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Small helper: play a list in order or shuffled, queueing the rest behind the
/// first track so "Up Next" stays meaningful.
enum PlayQueues {
    static func play(_ songs: [Song], shuffled: Bool) {
        let mm = MusicManager.shared
        let list = shuffled ? songs.shuffled() : songs
        guard let first = list.first else { return }
        mm.playSong(first)
        for s in list.dropFirst() { mm.playLater(s) }
    }
}

// MARK: - 3. Library lenses

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case recent = "New"
    case unplayed = "Unplayed"
    case favourites = "Liked"
    case long = "Long"
    case noArt = "No art"
    case messy = "Messy names"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all:        return "music.note.list"
        case .recent:     return "sparkles"
        case .unplayed:   return "circle"
        case .favourites: return "heart.fill"
        case .long:       return "clock"
        case .noArt:      return "photo"
        case .messy:      return "textformat.abc"
        }
    }

    var explanation: String {
        switch self {
        case .all:        return "Every song in the library."
        case .recent:     return "Added in the last two weeks."
        case .unplayed:   return "Never played since it was downloaded."
        case .favourites: return "Everything you liked."
        case .long:       return "Ten minutes or longer — mixes, live sets, Quran recitations."
        case .noArt:      return "No cover art yet."
        case .messy:      return "File names that still look like downloads."
        }
    }
}

/// Applies one of the lenses to the library. Pure, cheap, all on-device.
func applyLibraryFilter(_ filter: LibraryFilter, to songs: [Song]) -> [Song] {
    switch filter {
    case .all:
        return songs
    case .recent:
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        return songs.filter { addedDate($0) >= cutoff }
    case .unplayed:
        let history = ListenHistory.shared
        return songs.filter { history.playCount(for: $0) == 0 }
    case .favourites:
        let liked = Set(MusicManager.shared.playlists
            .first(where: { $0.name == "Liked Songs" })?.songIDs ?? [])
        return songs.filter { liked.contains($0.id) }
    case .long:
        let lab = AudioLab.shared
        return songs.filter { (lab.features(for: $0)?.duration ?? 0) >= 600 }
    case .noArt:
        return songs.filter { ($0.artworkURL ?? "").isEmpty }
    case .messy:
        return songs.filter { NameHeuristics.looksMessy($0) }
    }
}

private func addedDate(_ song: Song) -> Date {
    (try? song.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? .distantPast
}

struct FilterChipRow: View {
    @Binding var selection: LibraryFilter
    var countFor: (LibraryFilter) -> Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { filter in
                    chip(filter)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ filter: LibraryFilter) -> some View {
        let selected = selection == filter
        let n = countFor(filter)
        return Button {
            selection = filter
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.icon).font(.caption2)
                Text(filter.rawValue).font(.caption.bold())
                if n > 0 {
                    Text("\(n)").font(.caption2.bold())
                        .foregroundColor(selected ? .white : .secondary)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(selected ? AppTheme.accent : AppTheme.accent.opacity(0.12))
            .foregroundColor(selected ? .white : AppTheme.accent)
            .cornerRadius(14)
        }
        .opacity(n == 0 && filter != .all ? 0.45 : 1)
    }
}

// MARK: - 4. Tidy up names

enum NameHeuristics {

    /// Words that mean "this came off a video site", not "this is the title".
    private static let junk = [
        "official music video", "official lyric video", "official lyrics video",
        "official video", "official audio", "lyric video", "lyrics video",
        "official", "lyrics", "lyric", "explicit",
        "4k", "1080p", "720p", "480p", "hd", "hq",
        "320kbps", "256kbps", "192kbps", "128kbps", "320 kbps", "128 kbps",
        "youtube", "youtu.be", "www.", "http", "-topic", "topic",
        "full album", "full song", "audio only", "video only",
        "mp3", "download", "new song", "status",
    ]

    /// True when the file name still looks like a download rather than a song.
    static func looksMessy(_ song: Song) -> Bool {
        let raw = song.url.deletingPathExtension().lastPathComponent
        let lower = raw.lowercased()

        if lower.range(of: #"(^|[^a-z0-9])(audio|track|video|song|file|download|untitled|unknown|clip|rec)[^a-z0-9]{0,3}\d{1,6}"#,
                       options: .regularExpression) != nil { return true }
        if lower.contains("_") { return true }
        if lower.contains("|") || lower.contains("[") || lower.contains("(") { return true }
        if lower.range(of: #"\d{3,4}\s?kbps"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^\d{1,3}[\s.\-_]"#, options: .regularExpression) != nil { return true }
        for j in junk where lower.contains(j) { return true }
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if artist.isEmpty || artist == "AS Music" { return true }
        return raw.count > 70
    }

    /// Local, offline clean-up: split "Artist - Title", drop the junk, tidy
    /// spacing. Never invents an artist it cannot see.
    static func clean(_ song: Song) -> (title: String, artist: String) {
        let raw = song.url.deletingPathExtension().lastPathComponent
        var artist = ""
        var title = raw

        if let dash = raw.range(of: " - ") {
            let left = String(raw[raw.startIndex..<dash.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let right = String(raw[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty && left.count <= 50 && !right.isEmpty {
                artist = left
                title = right
            }
        }

        title = title.replacingOccurrences(of: "_", with: " ")
        title = title.replacingOccurrences(of: #"\s*[\[\(][^\]\)]{0,32}[\]\)]\s*"#,
                                           with: " ", options: .regularExpression)
        for j in junk {
            title = title.replacingOccurrences(of: j, with: " ", options: .caseInsensitive)
        }
        title = title.replacingOccurrences(of: #"\b\d{3,4}\s?kbps\b"#, with: " ",
                                           options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let trimSet = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-–—_|"))
        title = title.trimmingCharacters(in: trimSet)
        artist = artist.trimmingCharacters(in: trimSet)

        if title.isEmpty { title = raw }
        if artist.isEmpty, song.artist != "AS Music" { artist = song.artist }
        return (title, artist)
    }
}

final class NameTidy: ObservableObject {
    static let shared = NameTidy()

    struct Item: Identifiable {
        var song: Song
        var title: String
        var artist: String
        var selected: Bool
        var source: String          // "local" or "ai"

        var id: UUID { song.id }
    }

    @Published var items: [Item] = []
    @Published var busy = false
    @Published var note: String? = nil
    @Published var error: String? = nil

    private init() {}

    func scan(songs: [Song]) {
        let messy = songs.filter { NameHeuristics.looksMessy($0) }
        items = messy.map { s -> Item in
            let c = NameHeuristics.clean(s)
            return Item(song: s, title: c.title, artist: c.artist, selected: true, source: "local")
        }
        note = nil
        error = nil
    }

    /// Asks the model to do the same job as `NameHeuristics`, but with
    /// knowledge of who actually performs the song. Only indexes and raw file
    /// names ever leave the device — no audio, no library contents.
    func suggestWithAI() {
        guard !busy else { return }
        let ai = GeminiAI.shared
        guard ai.isConfigured else {
            error = "Add a free AI key in the Settings tab (APInex or Gemini) and the AI will name these. The local suggestions work without one."
            return
        }
        guard !items.isEmpty else { return }
        busy = true
        error = nil

        let lines = items.enumerated().map { i, item -> String in
            "\(i)|\(item.song.url.deletingPathExtension().lastPathComponent)"
        }.joined(separator: "\n")

        let system = """
        You clean up music file names for an offline music player.
        Each input line is: index|raw file name.
        Reply with ONLY valid JSON, no markdown:
        {"items":[{"i":0,"title":"Song Title","artist":"Artist Name"}]}
        Rules: keep the real song title and the real performing artist; delete "official video", "lyrics", "hd", "4k", "1080p", "320kbps", "youtube", "-topic", track numbers and underscores; never translate a title; keep Arabic in Arabic; if you truly do not know the artist use ""; do not invent a title that is not in the file name.
        """

        ai.completeJSON(system: system, user: lines) { [weak self] obj in
            guard let self = self else { return }
            self.busy = false
            guard let arr = obj?["items"] as? [Any], !arr.isEmpty else {
                self.error = "The AI could not read those names — the local suggestions are still there."
                return
            }
            var proposed: [Int: (String, String)] = [:]
            for any in arr {
                guard let d = any as? [String: Any],
                      let i = Self.int(from: d["i"]),
                      let t = d["title"] as? String,
                      !t.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let a = (d["artist"] as? String) ?? ""
                proposed[i] = (t, a)
            }
            var changed = 0
            for i in self.items.indices {
                if let pair = proposed[i] {
                    self.items[i].title = pair.0
                    self.items[i].artist = pair.1
                    self.items[i].source = "ai"
                    changed += 1
                }
            }
            self.note = changed > 0
                ? "AI suggested \(changed) of \(self.items.count) names — check them, then apply."
                : nil
        }
    }

    @discardableResult
    func applySelected(using mm: MusicManager) -> Int {
        let chosen = items.filter { $0.selected }
        guard !chosen.isEmpty else { return 0 }
        var done = 0
        for item in chosen {
            let title = item.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            mm.setSongInfo(song: item.song, title: title, artist: item.artist)
            done += 1
        }
        if done > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            note = "Renamed \(done) file\(done == 1 ? "" : "s"). Playlists, likes and play counts travelled with them."
        }
        let appliedIDs = Set(chosen.map { $0.song.id })
        items.removeAll { appliedIDs.contains($0.song.id) }
        return done
    }

    func selectAll(_ on: Bool) {
        for i in items.indices { items[i].selected = on }
    }

    var selectedCount: Int { items.filter { $0.selected }.count }

    private static func int(from any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

struct NameTidyView: View {
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var tidy = NameTidy.shared
    @Environment(\.presentationMode) private var presentationMode
    @State private var confirmApply = false

    var body: some View {
        NavigationView {
            Group {
                if tidy.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal").font(.system(size: 42))
                            .foregroundColor(.green)
                        Text("Every file name looks clean").font(.headline)
                        Text("Names like “Amr Diab - Tamally Maak (Official Video)” are what the duplicate finder and the AI playlists read. Nothing to tidy right now.")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        Section {
                            Text("These file names still look like downloads. Pick the ones to rename — the file is renamed, never the audio, and the song keeps its playlists, likes and play counts.")
                                .font(.caption2).foregroundColor(.secondary)
                        }

                        Section(header: Text("\(tidy.items.count) file\(tidy.items.count == 1 ? "" : "s")")) {
                            ForEach($tidy.items) { item in
                                row(item)
                            }
                        }

                        if let note = tidy.note {
                            Section { Text(note).font(.caption).foregroundColor(.green) }
                        }
                        if let err = tidy.error {
                            Section { Text(err).font(.caption).foregroundColor(.orange) }
                        }
                    }
                }
            }
            .navigationTitle("Tidy up names")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if tidy.busy {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Button("Ask AI") { tidy.suggestWithAI() }
                        }
                        Button("Apply") { confirmApply = true }
                            .fontWeight(.bold)
                            .disabled(tidy.selectedCount == 0)
                    }
                }
            }
            .onAppear { if tidy.items.isEmpty { tidy.scan(songs: musicManager.songs) } }
            .alert("Rename \(tidy.selectedCount) file\(tidy.selectedCount == 1 ? "" : "s")?",
                   isPresented: $confirmApply) {
                Button("Rename", role: .destructive) { _ = tidy.applySelected(using: musicManager) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Only the file names change. The songs stay where they are, in the same playlists.")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func row(_ item: Binding<NameTidy.Item>) -> some View {
        Button {
            item.selected.wrappedValue.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.selected.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(item.selected.wrappedValue ? AppTheme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.song.wrappedValue.url.deletingPathExtension().lastPathComponent)
                        .font(.caption2).foregroundColor(.secondary)
                        .strikethrough().lineLimit(1)
                    HStack(spacing: 5) {
                        Text(item.title.wrappedValue).font(.subheadline).lineLimit(2)
                        if item.source.wrappedValue == "ai" {
                            Text("AI").font(.system(size: 9, weight: .black))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(AppTheme.accent.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                    if !item.artist.wrappedValue.isEmpty {
                        Text(item.artist.wrappedValue)
                            .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 5. Fix a song's information

struct SongInfoEditorView: View {
    @EnvironmentObject var musicManager: MusicManager
    var song: Song
    @Environment(\.presentationMode) private var presentationMode
    @State private var title = ""
    @State private var artist = ""
    @State private var note: String? = nil

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Shown everywhere"),
                        footer: Text("The file is renamed to match, so the new name sticks after a restart. Playlists, likes and play counts stay with the song.")) {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                }

                Section(header: Text("Current file")) {
                    Text(song.url.lastPathComponent)
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Re-read the name from the file") {
                        let raw = song.url.deletingPathExtension().lastPathComponent
                        let c = TitleCleaner.clean(raw)
                        title = c.title
                        artist = c.artist == "AS Music" ? "" : c.artist
                    }
                    .font(.subheadline)
                }

                if let note = note {
                    Section { Text(note).font(.caption).foregroundColor(.green) }
                }
            }
            .navigationTitle("Song info")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.bold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                title = song.title
                artist = song.artist == "AS Music" ? "" : song.artist
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        musicManager.setSongInfo(song: song, title: t, artist: a)
        note = "Saved."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            presentationMode.wrappedValue.dismiss()
        }
    }
}
