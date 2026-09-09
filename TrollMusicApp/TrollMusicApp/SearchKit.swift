import Foundation

// ---------------------------------------------------------------------------
// MARK: - Arabic-aware text matching
// ---------------------------------------------------------------------------
//
// The library search used `title.lowercased().contains(query)`. For a Latin
// library that is fine. For an Arabic one it fails constantly, because the
// same word is spelled several legitimate ways and nobody types the one that
// happens to be in the file name:
//
//   أنت عمري   vs  انت عمري      (hamza on the alef, or not)
//   الأطلال    vs  الاطلال       (same)
//   مصطفى      vs  مصطفي         (alef maksura vs yeh)
//   يا حبيبي   vs  ياحبيبي        (spacing)
//   محمّد       vs  محمد          (shadda)
//   كريم       vs  کریم          (Farsi kaf/yeh from a mis-tagged rip)
//   ٢٠٢٤       vs  2024          (Arabic-Indic digits)
//
// Six of those seven miss with a naive `contains`. `LibraryDoctor` already
// folds diacritics for its duplicate check, so the app knew this mattered —
// search just never got the same treatment.
//
// `ArabicFold.key` maps every one of those variants to a single canonical
// form. It is deliberately lossy: it is a SEARCH key, never displayed, and
// never written back to a file.

enum ArabicFold {

    // Harakat, tanwin, shadda, sukun, superscript alef and the Quranic marks.
    // Purely pronunciation aids — invisible to how a title is "spelled" when
    // someone types it into a search box.
    private static let diacritics: Set<Unicode.Scalar> = {
        var s = Set<Unicode.Scalar>()
        for v in 0x064B...0x0652 { if let u = Unicode.Scalar(v) { s.insert(u) } }
        for v in [0x0653, 0x0654, 0x0655, 0x0656, 0x0657, 0x0658, 0x0670] {
            if let u = Unicode.Scalar(v) { s.insert(u) }
        }
        return s
    }()

    /// ARABIC TATWEEL — the decorative stretching character (مـــحـــمـــد).
    private static let tatweel: Unicode.Scalar = Unicode.Scalar(0x0640)!

    /// Every alef shape collapses to the bare alef.
    private static let alefs: Set<Character> = ["آ", "أ", "إ", "ٱ", "ٲ", "ٳ", "ٵ"]
    /// Yeh, alef maksura and the Farsi/Urdu yehs collapse together.
    private static let yehs: Set<Character> = ["ى", "ي", "ی", "ے"]
    /// Teh marbuta reads as heh at the end of a word; treat them as one.
    private static let hehs: Set<Character> = ["ه", "ة", "ۀ"]
    private static let waws: Set<Character> = ["ؤ", "و"]
    /// Farsi kaf turns up constantly in rips tagged on non-Arabic systems.
    private static let kafs: Set<Character> = ["ک", "ك"]
    /// Standalone hamza carriers are dropped entirely.
    private static let hamzas: Set<Character> = ["ء", "ئ"]

    /// Arabic-Indic (٠-٩) and Eastern Arabic-Indic (۰-۹) digits to ASCII.
    private static func asciiDigit(_ c: Character) -> Character? {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return nil }
        if (0x0660...0x0669).contains(v) { return Character(String(v - 0x0660)) }
        if (0x06F0...0x06F9).contains(v) { return Character(String(v - 0x06F0)) }
        return nil
    }

    /// The canonical search key: lowercased, diacritic-free, letter-variants
    /// unified, whitespace collapsed. Latin text passes through essentially
    /// untouched (accents folded, so "Café" matches "cafe").
    static func key(_ input: String) -> String {
        guard !input.isEmpty else { return "" }

        var out = String.UnicodeScalarView()
        out.reserveCapacity(input.unicodeScalars.count)

        for ch in input {
            if let d = asciiDigit(ch) { out.append(contentsOf: String(d).unicodeScalars); continue }
            if alefs.contains(ch)   { out.append("ا"); continue }
            if yehs.contains(ch)    { out.append("ي"); continue }
            if hehs.contains(ch)    { out.append("ه"); continue }
            if waws.contains(ch)    { out.append("و"); continue }
            if kafs.contains(ch)    { out.append("ك"); continue }
            if hamzas.contains(ch)  { continue }

            for u in ch.unicodeScalars {
                if diacritics.contains(u) { continue }
                if u == tatweel { continue }
                out.append(u)
            }
        }

        // Latin accents and compatibility forms; `.diacriticInsensitive` also
        // finishes off any combining marks the pass above didn't cover.
        let folded = String(out)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()

        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The key with spaces removed, so "ياحبيبي" finds "يا حبيبي".
    /// Arabic is frequently typed without the spaces a tagger used.
    static func squeezed(_ input: String) -> String {
        key(input).replacingOccurrences(of: " ", with: "")
    }

    /// True when `needle` appears in `haystack` under Arabic-aware folding.
    ///
    /// The space-insensitive comparison runs in BOTH directions. Arabic is
    /// written with inconsistent spacing -- عبد الحليم and عبدالحليم are the
    /// same name -- so the match has to survive spaces the user typed that the
    /// tagger didn't, and vice versa. Removing spaces from both sides keeps
    /// the query's letter ORDER intact, so this still behaves like a phrase
    /// search: "cafe del mar" does not match "mar del cafe".
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        let n = key(needle)
        guard !n.isEmpty else { return true }
        if key(haystack).contains(n) { return true }
        return squeezed(haystack).contains(squeezed(needle))
    }

    static func hasPrefix(_ haystack: String, _ needle: String) -> Bool {
        let n = key(needle)
        guard !n.isEmpty else { return true }
        return key(haystack).hasPrefix(n) || squeezed(haystack).hasPrefix(squeezed(needle))
    }
}

// ---------------------------------------------------------------------------
// MARK: - Lyrics index
// ---------------------------------------------------------------------------
//
// The app already caches LRC/plain lyrics next to the library, but nothing
// ever reads them back for search. "The song that goes ya habibi" is how
// people actually look for Arabic music, so index what is already on disk.
//
// Everything here is lazy and cheap: the index is built once from the cache
// directory, kept in memory, and refreshed when a new lyric file appears.

final class LyricsIndex {
    static let shared = LyricsIndex()

    private let fm = FileManager.default
    private let lock = NSLock()
    /// song id -> folded lyric text (timestamps and blank lines stripped).
    private var index: [UUID: String] = [:]
    private var built = false

    private init() {}

    private var cacheDir: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".lyrics")
    }

    /// Strips LRC timing tags so a search never matches "[00:12.34]".
    private func plainText(from lrc: String) -> String {
        var out: [String] = []
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(raw)
            // Remove every leading [mm:ss.xx] / [ar: …] style tag.
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                line = String(line[line.index(after: close)...])
            }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
        }
        return out.joined(separator: " ")
    }

    /// Reads the lyric cache into memory. Safe to call repeatedly.
    func build(force: Bool = false) {
        lock.lock()
        if built && !force { lock.unlock(); return }
        lock.unlock()

        var fresh: [UUID: String] = [:]
        if let files = try? fm.contentsOfDirectory(at: cacheDir,
                                                   includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension.lowercased() == "lrc" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                fresh[id] = ArabicFold.key(plainText(from: text))
            }
        }

        lock.lock()
        index = fresh
        built = true
        lock.unlock()
    }

    /// Call when a new lyric file is written so the next search sees it.
    func invalidate() {
        lock.lock(); built = false; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return index.count
    }

    /// True when this song's cached lyrics contain the query.
    func matches(songID: UUID, query: String) -> Bool {
        build()
        let q = ArabicFold.key(query)
        guard q.count >= 2 else { return false }
        lock.lock(); let text = index[songID]; lock.unlock()
        guard let text = text else { return false }
        return text.contains(q)
    }

    /// The matching line, for showing *why* a song matched.
    func snippet(songID: UUID, query: String, maxLength: Int = 60) -> String? {
        build()
        let q = ArabicFold.key(query)
        guard q.count >= 2 else { return nil }
        lock.lock(); let text = index[songID]; lock.unlock()
        guard let text = text, let r = text.range(of: q) else { return nil }

        // Widen to a readable window around the hit.
        let lower = text.index(r.lowerBound,
                               offsetBy: -min(20, text.distance(from: text.startIndex, to: r.lowerBound)))
        let upper = text.index(r.upperBound,
                               offsetBy: min(maxLength, text.distance(from: r.upperBound, to: text.endIndex)))
        var s = String(text[lower..<upper]).trimmingCharacters(in: .whitespaces)
        if lower != text.startIndex { s = "…" + s }
        if upper != text.endIndex { s += "…" }
        return s
    }
}

// ---------------------------------------------------------------------------
// MARK: - Ranked library search
// ---------------------------------------------------------------------------

enum LibrarySearch {

    /// Why a song matched, so the UI can explain itself.
    enum Reason: Equatable {
        case title, artist, genre, lyrics
    }

    struct Hit: Identifiable, Equatable {
        let song: Song
        let rank: Int
        let reason: Reason
        var id: UUID { song.id }
    }

    /// Ranks `songs` against `query`. Title beats artist beats genre beats
    /// lyrics, and an exact prefix beats a match in the middle.
    ///
    /// Lyrics are only consulted when the query is 3+ characters and nothing
    /// stronger matched, because scanning them is the expensive part and a
    /// two-letter lyric hit is noise.
    static func run(_ query: String, in songs: [Song],
                    includeLyrics: Bool = true) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        var hits: [Hit] = []
        var matched = Set<UUID>()

        for s in songs {
            let reason: Reason
            let rank: Int
            if ArabicFold.hasPrefix(s.title, q)      { reason = .title;  rank = 5 }
            else if ArabicFold.contains(s.title, q)  { reason = .title;  rank = 4 }
            else if ArabicFold.hasPrefix(s.artist, q){ reason = .artist; rank = 3 }
            else if ArabicFold.contains(s.artist, q) { reason = .artist; rank = 2 }
            else if ArabicFold.contains(s.genre ?? "", q) { reason = .genre; rank = 1 }
            else { continue }
            hits.append(Hit(song: s, rank: rank, reason: reason))
            matched.insert(s.id)
        }

        if includeLyrics, q.count >= 3 {
            for s in songs where !matched.contains(s.id) {
                if LyricsIndex.shared.matches(songID: s.id, query: q) {
                    hits.append(Hit(song: s, rank: 0, reason: .lyrics))
                }
            }
        }

        return hits.sorted { l, r in
            if l.rank != r.rank { return l.rank > r.rank }
            return l.song.title.localizedCaseInsensitiveCompare(r.song.title) == .orderedAscending
        }
    }
}
