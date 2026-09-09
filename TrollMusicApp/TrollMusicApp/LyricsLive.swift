import Foundation
import SwiftUI
import UIKit

// ===========================================================================
// MARK: - Live (synced) lyrics — karaoke in the full player
//
// The old lyrics sheet fetched a wall of text and stripped the timestamps out.
// This one keeps them, so the current line lights up while the song plays and
// tapping any line jumps the player to that moment.
//
// Where the words come from, in order (first hit wins):
//   1. a `.lrc` file sitting next to the audio in Documents  → 100% offline,
//      AirDrop your own timings and they are used verbatim
//   2. the on-device cache in `Documents/.lyrics/`           → offline after
//      the first successful fetch, even in airplane mode
//   3. lrclib.net — free, open, no account, no API key       → cached at once
//
// Per-song timing offset (±) is remembered, because rips are not all trimmed
// the same way. Nothing is uploaded: the request is a song title and artist.
// ===========================================================================

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double     // seconds
    let text: String
}

enum LyricsKind: Equatable {
    case none
    case plain
    case synced
}

final class LiveLyrics: ObservableObject {
    static let shared = LiveLyrics()

    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plain: String = ""
    @Published private(set) var kind: LyricsKind = .none
    @Published private(set) var loading = false
    @Published private(set) var sourceNote: String = ""
    @Published var offset: Double = 0 {
        didSet {
            guard let id = currentSongID else { return }
            UserDefaults.standard.set(offset, forKey: "asmusic_lrc_off_" + id.uuidString)
        }
    }

    private var currentSongID: UUID?
    private let fm = FileManager.default

    private var cacheDir: URL {
        let d = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".lyrics")
        if !fm.fileExists(atPath: d.path) {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    private init() {}

    // MARK: Loading

    /// Loads lyrics for `song`. Cheap and idempotent: calling it again for the
    /// song already shown does nothing.
    func load(for song: Song, duration: Double = 0, force: Bool = false) {
        if !force, currentSongID == song.id, kind != .none || loading { return }
        currentSongID = song.id
        offset = UserDefaults.standard.double(forKey: "asmusic_lrc_off_" + song.id.uuidString)
        lines = []
        plain = ""
        kind = .none
        sourceNote = ""

        // 1) A .lrc the user placed next to the file wins over everything.
        let sidecar = song.url.deletingPathExtension().appendingPathExtension("lrc")
        if let text = try? String(contentsOf: sidecar, encoding: .utf8), !text.isEmpty {
            apply(text, note: "from the .lrc next to your file", for: song.id)
            return
        }
        // 2) Cache from a previous fetch (works offline).
        if !force {
            let cached = cacheDir.appendingPathComponent(song.id.uuidString + ".lrc")
            if let text = try? String(contentsOf: cached, encoding: .utf8), !text.isEmpty {
                apply(text, note: "saved on your device", for: song.id)
                return
            }
        }
        // 3) lrclib.net (free, key-free).
        fetch(song: song, duration: duration)
    }

    private func apply(_ text: String, note: String, for songID: UUID) {
        let parsed = Self.parseLRC(text)
        DispatchQueue.main.async {
            guard self.currentSongID == songID else { return }
            if parsed.isEmpty {
                self.lines = []
                self.plain = Self.stripTimestamps(text)
                self.kind = self.plain.isEmpty ? .none : .plain
            } else {
                self.lines = parsed
                self.plain = parsed.map { $0.text }.joined(separator: "\n")
                self.kind = .synced
            }
            self.sourceNote = note
            self.loading = false
        }
    }

    private func fetch(song: Song, duration: Double) {
        loading = true
        let title = Self.searchable(song.title)
        let artist = (song.artist == "AS Music" || song.artist.isEmpty) ? "" : Self.searchable(song.artist)
        let songID = song.id

        // Exact match first (title + artist + length) — this is the endpoint
        // that returns properly synced timings.
        var getComps = URLComponents(string: "https://lrclib.net/api/get")
        var q: [URLQueryItem] = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { q.append(URLQueryItem(name: "artist_name", value: artist)) }
        if duration > 1 { q.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        getComps?.queryItems = q

        let searchURL: URL? = {
            var c = URLComponents(string: "https://lrclib.net/api/search")
            if artist.isEmpty {
                c?.queryItems = [URLQueryItem(name: "q", value: title)]
            } else {
                c?.queryItems = [URLQueryItem(name: "track_name", value: title),
                                 URLQueryItem(name: "artist_name", value: artist)]
            }
            return c?.url
        }()

        let finishEmpty: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.currentSongID == songID else { return }
                self.loading = false
                self.kind = .none
                self.sourceNote = "No lyrics found for this track."
            }
        }

        let handleSearch: () -> Void = { [weak self] in
            guard let self = self, let url = searchURL else { finishEmpty(); return }
            self.request(url) { data in
                guard let data = data,
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    finishEmpty(); return
                }
                // Prefer a result that actually has timings, and whose length
                // is close to the file we are playing.
                let best = arr.sorted { a, b in
                    let sa = (a["syncedLyrics"] as? String)?.isEmpty == false ? 1 : 0
                    let sb = (b["syncedLyrics"] as? String)?.isEmpty == false ? 1 : 0
                    if sa != sb { return sa > sb }
                    guard duration > 1 else { return false }
                    let da = abs(((a["duration"] as? Double) ?? 0) - duration)
                    let db = abs(((b["duration"] as? Double) ?? 0) - duration)
                    return da < db
                }.first
                guard let hit = best else { finishEmpty(); return }
                self.consume(hit, songID: songID, note: "lrclib.net", finishEmpty: finishEmpty)
            }
        }

        guard let getURL = getComps?.url else { handleSearch(); return }
        request(getURL) { [weak self] data in
            guard let self = self else { return }
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["syncedLyrics"] is String || obj["plainLyrics"] is String) {
                self.consume(obj, songID: songID, note: "lrclib.net", finishEmpty: handleSearch)
            } else {
                handleSearch()
            }
        }
    }

    private func consume(_ obj: [String: Any], songID: UUID, note: String, finishEmpty: @escaping () -> Void) {
        let synced = (obj["syncedLyrics"] as? String) ?? ""
        let plainText = (obj["plainLyrics"] as? String) ?? ""
        let text = !synced.isEmpty ? synced : plainText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finishEmpty(); return
        }
        // Cache so the next play works with no network at all.
        try? text.write(to: cacheDir.appendingPathComponent(songID.uuidString + ".lrc"),
                        atomically: true, encoding: .utf8)
        // New words on disk — let the library search pick them up.
        LyricsIndex.shared.invalidate()
        apply(text, note: synced.isEmpty ? "\(note) · no timings for this one" : note, for: songID)
    }

    private func request(_ url: URL, completion: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("ASMusic v2 (offline music player)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            completion((200...299).contains(code) ? data : nil)
        }.resume()
    }

    // MARK: Live position

    /// Index of the line that should be highlighted at `time`, or nil.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        let t = time - offset
        var lo = 0, hi = lines.count - 1, found: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// Saves what is on screen as a `.lrc` next to the audio file, so it stays
    /// even if the caches are cleared (and travels with the exported song).
    @discardableResult
    func pinToFile(for song: Song) -> Bool {
        let text: String
        if kind == .synced {
            text = lines.map { l -> String in
                let m = Int(l.time) / 60
                let sec = Int(l.time) % 60
                let cs = Int((l.time - floor(l.time)) * 100)
                let stamp = String(format: "[%02d:%02d.%02d]", m, sec, cs)
                return stamp + l.text
            }.joined(separator: "\n")
        } else {
            text = plain
        }
        guard !text.isEmpty else { return false }
        let dest = song.url.deletingPathExtension().appendingPathExtension("lrc")
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
            sourceNote = "saved beside your song file"
            return true
        } catch { return false }
    }

    // MARK: Parsing

    /// Parses standard LRC (`[01:23.45] line`), including repeated timestamps
    /// on one line. Metadata tags (`[ar:...]`) are ignored.
    static func parseLRC(_ raw: String) -> [LyricLine] {
        var out: [(Double, String)] = []
        let stampPattern = "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]"
        guard let rx = try? NSRegularExpression(pattern: stampPattern) else { return [] }
        for rawLine in raw.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            let ns = line as NSString
            let matches = rx.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let lastEnd = matches.map { $0.range.location + $0.range.length }.max() ?? 0
            let text = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                out.append((mm * 60 + ss + frac, text))
            }
        }
        // Empty lines are kept (they are the instrumental breaks) but a run of
        // them collapses to one so the view doesn't scroll through nothing.
        let sorted = out.sorted { $0.0 < $1.0 }
        var cleaned: [(Double, String)] = []
        for entry in sorted {
            if entry.1.isEmpty, cleaned.last?.1.isEmpty == true { continue }
            cleaned.append(entry)
        }
        guard cleaned.contains(where: { !$0.1.isEmpty }) else { return [] }
        return cleaned.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    static func stripTimestamps(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\[[0-9:.\\s\\-]+\\]", with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes the junk downloaders leave in titles so the lookup matches.
    static func searchable(_ s: String) -> String {
        var x = s
        for pattern in ["\\([^)]*\\)", "\\[[^\\]]*\\]", "(?i)official", "(?i)video",
                        "(?i)lyrics?", "(?i)audio", "(?i)hd", "(?i)4k", "(?i)remaster(ed)?"] {
            x = x.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        x = x.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return x.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - The karaoke view

struct LiveLyricsView: View {
    let song: Song
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var store = LiveLyrics.shared
    @State private var pinned = false

    private var rtl: Bool {
        let sample = store.kind == .synced ? store.lines.prefix(6).map { $0.text }.joined() : String(store.plain.prefix(120))
        return sample.unicodeScalars.contains { (0x0600...0x06FF).contains(Int($0.value)) }
    }

    private var activeIndex: Int? {
        store.activeIndex(at: musicManager.currentTime)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            Group {
                if store.loading {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Looking for the words…")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.kind == .synced {
                    syncedList
                } else if store.kind == .plain {
                    ScrollView(showsIndicators: false) {
                        Text(store.plain)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(rtl ? .trailing : .leading)
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                            .padding(20)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 34)).foregroundColor(.white.opacity(0.5))
                        Text(store.sourceNote.isEmpty ? "No lyrics yet" : store.sourceNote)
                            .font(.subheadline).foregroundColor(.white.opacity(0.75))
                        Text("Tip: drop a “\(song.url.deletingPathExtension().lastPathComponent).lrc” file in the app's Documents folder and it will be used offline.")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                        Button {
                            store.load(for: song, duration: musicManager.duration, force: true)
                        } label: {
                            Label("Search again", systemImage: "arrow.clockwise")
                                .font(.caption.bold())
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Color.white.opacity(0.15))
                                .foregroundColor(.white)
                                .cornerRadius(16)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxHeight: 340)
        .background(Color.white.opacity(0.08))
        .cornerRadius(16)
        .padding(.horizontal)
        .onAppear { store.load(for: song, duration: musicManager.duration) }
        .onChange(of: song.id) { _ in
            pinned = false
            store.load(for: song, duration: musicManager.duration)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: store.kind == .synced ? "waveform.and.mic" : "text.quote")
                .font(.caption).foregroundColor(AppTheme.accent)
            Text(store.kind == .synced ? "Synced · tap a line to jump" : (store.sourceNote.isEmpty ? "Lyrics" : store.sourceNote))
                .font(.caption2).foregroundColor(.white.opacity(0.65)).lineLimit(1)
            Spacer()
            if store.kind == .synced {
                Button { store.offset -= 0.3 } label: {
                    Image(systemName: "minus.circle").font(.caption)
                }
                Text(String(format: "%+.1fs", store.offset))
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.7))
                Button { store.offset += 0.3 } label: {
                    Image(systemName: "plus.circle").font(.caption)
                }
            }
            Menu {
                Button {
                    store.load(for: song, duration: musicManager.duration, force: true)
                } label: { Label("Re-download lyrics", systemImage: "arrow.clockwise") }
                Button {
                    pinned = store.pinToFile(for: song)
                } label: { Label(pinned ? "Saved beside the song" : "Keep offline with this song",
                                 systemImage: pinned ? "checkmark.circle" : "square.and.arrow.down") }
                    .disabled(store.kind == .none)
                Button { store.offset = 0 } label: { Label("Reset timing", systemImage: "gobackward") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.caption)
            }
        }
        .foregroundColor(.white.opacity(0.8))
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var syncedList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: rtl ? .trailing : .leading, spacing: 14) {
                    ForEach(store.lines) { line in
                        let isActive = activeIndex == line.id
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: isActive ? 22 : 17,
                                          weight: isActive ? .bold : .medium))
                            .foregroundColor(isActive ? .white : .white.opacity(0.42))
                            .multilineTextAlignment(rtl ? .trailing : .leading)
                            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                            .id(line.id)
                            .onTapGesture {
                                musicManager.seek(to: max(0, line.time + store.offset))
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            .animation(.easeInOut(duration: 0.2), value: isActive)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .onChange(of: activeIndex ?? -1) { idx in
                guard idx >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }
}
