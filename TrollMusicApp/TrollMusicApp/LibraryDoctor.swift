import Foundation
import SwiftUI
import UIKit

// ===========================================================================
// MARK: - Library Doctor (AI duplicate finder)
//
// The "check my library for duplicate songs" brain, one button in the Library
// tab. It works in two layers and never deletes anything on its own:
//
//   1. DETECT (always on-device, no key, no network)
//      Songs are grouped by a normalized artist+title key, so
//      "Amr Diab - Tamally Maak (Official)" and "tamally maak 1" land in the
//      same group. Each group is then split by measured duration (±8 s) using
//      the AudioLab cache, so a duplicated rip is separated from a genuinely
//      different live/remix version of the same song.
//
//   2. DECIDE (local recommendation + optional AI)
//      Every copy gets a keeper score: liked > most played > best measured
//      sound quality > higher bitrate > has artwork. The best copy is
//      pre-selected to KEEP. With an AI key configured (APInex or Gemini),
//      the model reviews
//      the same facts and may override the pick (with a short reason) — it
//      only ever chooses between files you already own.
//
// The user reviews each group and presses Delete explicitly; a full-library
// "delete all redundant copies" is always confirmed first.
// ===========================================================================

// MARK: - Models

/// One copy of a duplicated song, with the facts the UI (and the AI) decide on.
struct DuplicateSong: Identifiable, Equatable {
    let song: Song
    let fileSize: Int64          // bytes on disk
    let bitrateKbps: Int         // fileSize / duration estimate
    let duration: Double         // seconds (0 = not measured yet)
    let quality: Int             // 0…100, from the on-device audio analysis
    let lowQualityRip: Bool
    let plays: Int
    let isLiked: Bool

    var id: UUID { song.id }

    static func == (l: DuplicateSong, r: DuplicateSong) -> Bool { l.id == r.id }
}

/// A set of files the app believes are the same song.
struct DuplicateGroup: Identifiable, Equatable {
    let id: String               // stable key of the group
    let title: String
    let artist: String
    var songs: [DuplicateSong]   // sorted best-copy first
    /// True when durations were measured and match (±8 s): a duplicated rip.
    /// False = same song, different version/length — check before deleting.
    var sameRecording: Bool
    /// True when the files were matched by how they SOUND, not by their names
    /// (same length, tempo, loudness and tone balance) — this is how a
    /// re-download saved under a different title still gets caught.
    var matchedByAudio: Bool = false
    var recommendedKeepID: UUID
    var aiNote: String? = nil
    var aiReviewed: Bool = false

    var keep: DuplicateSong? { songs.first { $0.id == recommendedKeepID } }
    var redundant: [DuplicateSong] { songs.filter { $0.id != recommendedKeepID } }
    var reclaimableBytes: Int64 { redundant.reduce(0) { $0 + $1.fileSize } }

    static func == (l: DuplicateGroup, r: DuplicateGroup) -> Bool {
        l.id == r.id && l.songs == r.songs && l.recommendedKeepID == r.recommendedKeepID
            && l.aiNote == r.aiNote && l.aiReviewed == r.aiReviewed
            && l.matchedByAudio == r.matchedByAudio
    }
}

// MARK: - The doctor

final class LibraryDoctor: ObservableObject {
    static let shared = LibraryDoctor()

    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date? = nil
    @Published private(set) var aiBusy = false
    @Published var lastError: String? = nil
    @Published var lastNote: String? = nil

    private var lastAutoScan = Date.distantPast
    private init() {}

    /// Bytes that would be freed by deleting every non-kept copy.
    var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    /// How many files are redundant across all groups.
    var redundantCount: Int { groups.reduce(0) { $0 + $1.redundant.count } }

    // MARK: Scanning

    /// Passive scan used when the Library tab appears: throttled to once per
    /// 10 minutes so it never costs anything the user can feel.
    func autoScan() {
        guard Date().timeIntervalSince(lastAutoScan) > 600 else { return }
        scan()
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        lastNote = nil
        lastAutoScan = Date()
        // Snapshot everything on the main thread; the heavy lifting then runs
        // in the background without touching @Published arrays.
        let mm = MusicManager.shared
        let songs = mm.songs
        let likedIDs = Set(mm.playlists.first(where: { $0.name == "Liked Songs" })?.songIDs ?? [])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = self?.buildGroups(from: songs, likedIDs: likedIDs) ?? []
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.groups = found
                self.lastScan = Date()
                self.isScanning = false
            }
        }
    }

    /// Normalized identity: lowercase, diacritics off, parenthetical junk
    /// ("(Official Video)", "[HD]") removed, trailing copy markers (" 2",
    /// " copy") stripped — so the same song lands in one group no matter how
    /// the file was named.
    static func identityKey(artist: String, title: String) -> String {
        func clean(_ raw: String, stripTrailingMarkers: Bool) -> String {
            var x = raw.lowercased()
            x = x.folding(options: .diacriticInsensitive, locale: .current)
            x = x.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            x = x.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            x = x.replacingOccurrences(of: #"[^a-z0-9\u0600-\u06FF ]"#, with: " ", options: .regularExpression)
            var tokens = x.split(separator: " ").map(String.init)
            if stripTrailingMarkers {
                while let last = tokens.last,
                      last == "copy" || last.allSatisfy({ $0.isNumber }) {
                    tokens.removeLast()
                    if tokens.isEmpty { break }
                }
            }
            return tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        var t = clean(title, stripTrailingMarkers: true)
        if t.isEmpty { t = clean(title, stripTrailingMarkers: false) }   // titles that ARE numbers
        var a = clean(artist, stripTrailingMarkers: false)
        // Placeholder artists carry no identity — group those by title only.
        let placeholders = ["", "as music", "youtube", "soundcloud", "unknown", "unknown artist"]
        if placeholders.contains(a) { a = "~" }
        return a + "|" + t
    }

    private func buildGroups(from songs: [Song], likedIDs: Set<UUID>) -> [DuplicateGroup] {
        var byKey: [String: [Song]] = [:]
        for s in songs {
            let key = Self.identityKey(artist: s.artist, title: s.title)
            byKey[key, default: []].append(s)
        }

        let lab = AudioLab.shared
        let history = ListenHistory.shared
        let fm = FileManager.default
        var out: [DuplicateGroup] = []

        for (key, list) in byKey where list.count > 1 {
            // Split the group by measured duration so "same rip twice" and
            // "same song, different (live/short) version" don't mix.
            var buckets: [[Song]] = []
            var unmeasured: [Song] = []
            for s in list {
                guard let d = lab.features(for: s)?.duration, d > 0 else {
                    unmeasured.append(s)
                    continue
                }
                let matched = buckets.firstIndex(where: { bucket in
                    guard let ref = lab.features(for: bucket[0])?.duration else { return false }
                    return abs(ref - d) <= 8
                })
                if let i = matched { buckets[i].append(s) } else { buckets.append([s]) }
            }
            // Never measured → still flag by name, marked for extra caution.
            if unmeasured.count > 1 { buckets.append(unmeasured) }

            for bucket in buckets where bucket.count > 1 {
                var facts: [DuplicateSong] = bucket.map { s in
                    let f = lab.features(for: s)
                    let size = ((try? fm.attributesOfItem(atPath: s.url.path)[.size]) as? Int64) ?? 0
                    let dur = f?.duration ?? 0
                    let kbps = dur > 1 ? Int(Double(size) * 8.0 / (dur * 1000.0)) : 0
                    return DuplicateSong(song: s,
                                         fileSize: size,
                                         bitrateKbps: kbps,
                                         duration: dur,
                                         quality: Int((Self.qualityNorm(f) * 100).rounded()),
                                         lowQualityRip: f?.isLowQualityRip ?? false,
                                         plays: history.playCount(for: s),
                                         isLiked: likedIDs.contains(s.id))
                }
                facts.sort { keeperScore($0) > keeperScore($1) }
                let measured = bucket.compactMap { lab.features(for: $0)?.duration }
                let sameRecording = measured.count == bucket.count
                    && ((measured.max() ?? 0) - (measured.min() ?? 0)) <= 8
                guard let best = facts.first else { continue }
                let displayArtist = list.first(where: { !$0.artist.isEmpty && $0.artist != "AS Music" })?.artist
                    ?? bucket[0].artist
                out.append(DuplicateGroup(id: key + "#" + String(bucket.count) + "-" + best.id.uuidString,
                                          title: bucket[0].title,
                                          artist: displayArtist,
                                          songs: facts,
                                          sameRecording: sameRecording,
                                          recommendedKeepID: best.id))
            }
        }
        // ---------------------------------------------------------------
        // Second pass: same AUDIO, different NAME.
        // Anything the name matcher didn't catch is compared on measured
        // sound: length, tempo, loudness, tone balance, stereo width and
        // dynamics. Two files that agree on all of those are the same
        // recording even when one is called "audio_2831" — the case the old
        // matcher was blind to.
        // ---------------------------------------------------------------
        let alreadyGrouped = Set(out.flatMap { $0.songs.map { $0.id } })
        let leftovers = songs.filter { !alreadyGrouped.contains($0.id) }
        let twins = acousticGroups(from: leftovers, likedIDs: likedIDs)
        out.append(contentsOf: twins)

        // Biggest space savings first.
        return out.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Are these two measurements the same recording? Deliberately strict:
    /// a false positive here would offer to delete a song the user still
    /// wants, so every axis has to agree.
    static func soundsIdentical(_ a: TrackFeatures, _ b: TrackFeatures) -> Bool {
        guard a.duration > 20, b.duration > 20 else { return false }   // ignore clips/jingles
        guard abs(a.duration - b.duration) <= 1.5 else { return false }
        guard abs(a.loudness - b.loudness) <= 1.5 else { return false }
        guard abs(a.dynRange - b.dynRange) <= 1.5 else { return false }
        guard abs(a.stereoWidth - b.stereoWidth) <= 0.06 else { return false }
        if a.tempo > 0, b.tempo > 0, abs(a.tempo - b.tempo) > 2.5 { return false }
        let profileA = [a.subBass, a.warmth, a.body, a.presence, a.air, a.vocalCenter]
        let profileB = [b.subBass, b.warmth, b.body, b.presence, b.air, b.vocalCenter]
        return FeatureMath.distance(profileA, profileB) <= 0.025
    }

    /// Groups un-matched songs by their measured sound.
    private func acousticGroups(from songs: [Song], likedIDs: Set<UUID>) -> [DuplicateGroup] {
        let lab = AudioLab.shared
        let measured: [(Song, TrackFeatures)] = songs.compactMap { s -> (Song, TrackFeatures)? in
            guard let f = lab.features(for: s), f.duration > 20 else { return nil }
            return (s, f)
        }
        guard measured.count > 1 else { return [] }
        // Sorting by length keeps the comparison local: a song can only pair
        // with neighbours inside the ±1.5 s window, so this stays ~O(n).
        let ordered = measured.sorted { $0.1.duration < $1.1.duration }
        var used = Set<UUID>()
        var clusters: [[(Song, TrackFeatures)]] = []
        for i in 0..<ordered.count {
            let (song, f) = ordered[i]
            if used.contains(song.id) { continue }
            var cluster: [(Song, TrackFeatures)] = [(song, f)]
            var j = i + 1
            while j < ordered.count, ordered[j].1.duration - f.duration <= 1.5 {
                let (other, of) = ordered[j]
                if !used.contains(other.id), Self.soundsIdentical(f, of) {
                    cluster.append((other, of))
                    used.insert(other.id)
                }
                j += 1
            }
            if cluster.count > 1 {
                used.insert(song.id)
                clusters.append(cluster)
            }
        }

        let history = ListenHistory.shared
        let fm = FileManager.default
        return clusters.compactMap { cluster -> DuplicateGroup? in
            var facts: [DuplicateSong] = cluster.map { pair -> DuplicateSong in
                let (s, f) = pair
                let size = ((try? fm.attributesOfItem(atPath: s.url.path)[.size]) as? Int64) ?? 0
                let kbps = f.duration > 1 ? Int(Double(size) * 8.0 / (f.duration * 1000.0)) : 0
                return DuplicateSong(song: s,
                                     fileSize: size,
                                     bitrateKbps: kbps,
                                     duration: f.duration,
                                     quality: Int((Self.qualityNorm(f) * 100).rounded()),
                                     lowQualityRip: f.isLowQualityRip,
                                     plays: history.playCount(for: s),
                                     isLiked: likedIDs.contains(s.id))
            }
            facts.sort { keeperScore($0) > keeperScore($1) }
            guard let best = facts.first else { return nil }
            return DuplicateGroup(id: "audio#" + best.id.uuidString,
                                  title: best.song.title,
                                  artist: best.song.artist,
                                  songs: facts,
                                  sameRecording: true,
                                  matchedByAudio: true,
                                  recommendedKeepID: best.id)
        }
    }

    /// 0…1 estimate of how clean a master sounds — same formula the smart
    /// playlists use, so "keep the best sounding copy" means the same thing
    /// everywhere in the app.
    static func qualityNorm(_ f: TrackFeatures?) -> Double {
        guard let f = f else { return 0.5 }
        let clipPenalty = min(0.5, f.clipRatio * 60)
        let tooQuiet = f.loudness < -24 ? min(0.4, (-24 - f.loudness) / 22) : 0
        let crushed = f.dynRange < 3.5 ? 0.25 : (f.dynRange < 6 ? 0.1 : 0)
        let bonus = f.dynRange > 8 ? 0.1 : 0
        return FeatureMath.clamp01(0.75 + bonus - clipPenalty - tooQuiet - crushed)
    }

    /// Which copy deserves to survive. Liked beats plays, plays beat quality,
    /// quality beats size; a known-bad rip is pushed to the bottom.
    private func keeperScore(_ d: DuplicateSong) -> Double {
        var s = 0.0
        if d.isLiked { s += 2.2 }
        s += min(1.6, Double(d.plays) * 0.15)
        s += (Double(d.quality) / 100.0) * 1.5
        s += min(1.0, Double(d.bitrateKbps) / 250.0)
        if d.song.artworkURL != nil { s += 0.3 }
        if d.lowQualityRip { s -= 0.9 }
        return s
    }

    // MARK: AI review (optional — only with the user's own Gemini key)

    /// Sends each group's FACTS (never the audio) to the model and lets it
    /// pick the copy to keep, with a short reason. On any failure the local
    /// recommendation simply stays.
    func aiReview(completion: (() -> Void)? = nil) {
        guard GeminiAI.shared.isConfigured else {
            lastError = "Add a free AI key in the Settings tab (AI Intelligence — APInex or Gemini) to let AI pick the best copies — without a key the app still recommends locally."
            completion?()
            return
        }
        guard !groups.isEmpty else { completion?(); return }
        aiBusy = true
        lastError = nil
        lastNote = nil

        let reviewed = Array(groups.prefix(12))
        var lines: [String] = []
        for (gi, g) in reviewed.enumerated() {
            lines.append("Group \(gi + 1):")
            for (si, d) in g.songs.prefix(6).enumerated() {
                let dur = d.duration > 0 ? "\(Int(d.duration))s" : "?s"
                let mb = String(format: "%.1fMB", Double(d.fileSize) / 1_048_576)
                lines.append("\(si)|\(d.song.title)|\(d.song.artist)|\(dur)|\(mb)|\(d.bitrateKbps)kbps|plays \(d.plays)|liked \(d.isLiked ? "yes" : "no")|quality \(d.quality)/100|sameRecording \(g.sameRecording ? "yes" : "no")|matchedBy \(g.matchedByAudio ? "audio-fingerprint" : "name")")
            }
        }
        let system = """
        You are the library-cleaner inside a personal offline music player.
        The user has groups of duplicate audio files. For EACH group choose the ONE copy to KEEP.
        Prefer, in this order: a copy the user liked, the most played copy, the best sounding copy (higher quality score, higher bitrate), then the complete take.
        When matchedBy is audio-fingerprint the files are byte-different but sound identical, so the better-named, better-tagged copy should win ties.
        Reply with ONLY valid JSON, no markdown:
        {"decisions":[{"keep":<index>,"note":"max 8 words why"}]}
        One decision per group, in the order the groups were given.
        """
        GeminiAI.shared.completeJSON(system: system, user: lines.joined(separator: "\n")) { [weak self] obj in
            guard let self = self else { return }
            self.aiBusy = false
            guard let decisions = obj?["decisions"] as? [[String: Any]] else {
                self.lastError = "The AI didn't answer with a usable list — the app's own recommendation is still shown."
                completion?()
                return
            }
            var changed = 0
            for (gi, decision) in decisions.enumerated() where gi < reviewed.count {
                let anyIdx = decision["keep"]
                let idx: Int?
                if let n = anyIdx as? Int { idx = n }
                else if let s = anyIdx as? String, let n = Int(s) { idx = n }
                else { idx = nil }
                guard let i = idx, i >= 0, i < reviewed[gi].songs.count else { continue }
                let pick = reviewed[gi].songs[i].id
                guard let giFull = self.groups.firstIndex(where: { $0.id == reviewed[gi].id }) else { continue }
                if self.groups[giFull].recommendedKeepID != pick { changed += 1 }
                self.groups[giFull].recommendedKeepID = pick
                self.groups[giFull].aiReviewed = true
                if let note = decision["note"] as? String, !note.isEmpty {
                    self.groups[giFull].aiNote = String(note.prefix(80))
                }
            }
            self.lastNote = changed == 0
                ? "AI agrees with the app's picks."
                : "AI re-picked \(changed) group\(changed == 1 ? "" : "s") — check the AI PICK badges."
            completion?()
        }
    }

    // MARK: Deleting (always user-confirmed, done through MusicManager)

    /// Deletes every copy in `group` except `keepID`. Returns files removed.
    @discardableResult
    func deleteRedundant(in group: DuplicateGroup, keeping keepID: UUID) -> Int {
        let mm = MusicManager.shared
        var removed = 0
        for d in group.songs where d.id != keepID {
            if let live = mm.songs.first(where: { $0.id == d.id }) {
                // Goes to Recently Deleted (unless the user turned the safety
                // net off), so an over-eager clean is always reversible.
                mm.deleteSong(live, reason: "duplicate of “\(group.title)”")
                removed += 1
            }
        }
        if removed > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        return removed
    }
}

// MARK: - Formatting helpers

enum DoctorFormat {
    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
    static func time(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Review UI

/// The sheet opened from the duplicate button in the Library tab.
struct DuplicateReviewView: View {
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var doctor = LibraryDoctor.shared
    @ObservedObject private var ai = GeminiAI.shared
    @Environment(\.presentationMode) var pm

    /// group id → the copy the user chose to keep (falls back to the
    /// recommendation).
    @State private var keepSelection: [String: UUID] = [:]
    @State private var confirmDeleteAll = false
    @State private var groupToClean: DuplicateGroup? = nil
    @State private var freedNote: String? = nil
    @State private var showTrash = false

    var body: some View {
        NavigationView {
            Group {
                if doctor.isScanning && doctor.groups.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Comparing your songs…").font(.subheadline).foregroundColor(.secondary)
                    }
                } else if doctor.groups.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
            }
            .navigationTitle("Duplicate Finder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Rescan") { doctor.scan() }
                        .disabled(doctor.isScanning)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { pm.wrappedValue.dismiss() }
                }
            }
            .alert("Delete all redundant copies?", isPresented: $confirmDeleteAll) {
                Button("Delete \(doctor.redundantCount) file(s)", role: .destructive) {
                    deleteAllRedundant()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(LibraryTrash.shared.safeDelete
                     ? "The app keeps the best copy of every group (your likes, plays and sound quality decide). The extras move to Recently Deleted, so you can bring any of them back."
                     : "The app keeps the best copy of every group and erases the rest immediately — the safety net is switched off in Recently Deleted.")
            }
            .alert("Clean this group?",
                   isPresented: Binding(get: { groupToClean != nil },
                                        set: { if !$0 { groupToClean = nil } })) {
                Button("Delete extra copies", role: .destructive) {
                    if let g = groupToClean { cleanGroup(g) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if let g = groupToClean {
                    let keepTitle = g.songs.first(where: { $0.id == selectedKeep(in: g) })?.song.title ?? "the best copy"
                    Text(LibraryTrash.shared.safeDelete
                         ? "Keeps “\(keepTitle)” and moves \(g.songs.count - 1) other file(s) of this song to Recently Deleted."
                         : "Keeps “\(keepTitle)” and erases \(g.songs.count - 1) other file(s) of this song.")
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showTrash) {
            RecentlyDeletedView()
        }
        .onAppear {
            if doctor.groups.isEmpty && !doctor.isScanning { doctor.scan() }
        }
    }

    // MARK: Empty / clean state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52)).foregroundColor(.green)
            Text("No duplicates found").font(.title3).bold()
            Text("Your library looks clean. Songs are matched by name and artist, by how long they play, and finally by how they actually sound — so even a re-download saved under a different name gets caught.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Button { doctor.scan() } label: {
                Label("Scan again", systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(AppTheme.accent.opacity(0.15))
                    .foregroundColor(AppTheme.accent)
                    .cornerRadius(18)
            }
            if let last = doctor.lastScan {
                Text("Last scan \(timeAgo(last))").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Results

    private var resultsList: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.doc")
                        .font(.title3).foregroundColor(AppTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(doctor.groups.count) duplicate group\(doctor.groups.count == 1 ? "" : "s") · \(doctor.redundantCount) extra file(s)")
                            .font(.subheadline).bold()
                        Text("Delete the extras to free \(DoctorFormat.mb(doctor.totalReclaimable))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if doctor.isScanning { ProgressView() }
                }
                if let note = freedNote ?? doctor.lastNote {
                    Text(note).font(.caption).foregroundColor(.green)
                }
                if LibraryTrash.shared.count > 0 {
                    Button {
                        showTrash = true
                    } label: {
                        Label("Recently Deleted (\(LibraryTrash.shared.count)) — restore anything",
                              systemImage: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundColor(AppTheme.accent)
                    }
                }
                if let err = doctor.lastError {
                    Text(err).font(.caption).foregroundColor(.orange)
                }
            }

            ForEach(doctor.groups) { g in
                groupSection(g)
            }

            Section(footer: Text("Nothing is deleted automatically — you pick the copy to keep (the app pre-selects the best one) and press Delete yourself. Deleted files wait in Recently Deleted until you empty it.")) {
                if ai.isConfigured {
                    Button {
                        hideKeyboard()
                        doctor.aiReview()
                    } label: {
                        Label(doctor.aiBusy ? "AI is comparing your copies…" : "Ask AI which copy to keep",
                              systemImage: "wand.and.stars")
                            .foregroundColor(AppTheme.accent)
                    }
                    .disabled(doctor.aiBusy || doctor.groups.isEmpty)
                }
                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Label("Delete \(doctor.redundantCount) redundant file(s) · free \(DoctorFormat.mb(doctor.totalReclaimable))",
                          systemImage: "trash")
                }
                .disabled(doctor.redundantCount == 0)
            }
        }
    }

    private func groupSection(_ g: DuplicateGroup) -> some View {
        Section {
            ForEach(g.songs) { d in
                dupRow(g, d)
            }
            Button(role: .destructive) {
                groupToClean = g
            } label: {
                Label("Keep only the selected copy (delete \(g.songs.count - 1))",
                      systemImage: "trash")
                    .font(.caption)
            }
        } header: {
            HStack(spacing: 6) {
                Text("\(g.title) — \(g.artist)").lineLimit(1)
                Spacer()
                if g.matchedByAudio {
                    Text("SAME AUDIO")
                        .font(.system(size: 8, weight: .black))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(AppTheme.accent.opacity(0.18))
                        .foregroundColor(AppTheme.accent)
                        .cornerRadius(4)
                }
                if !g.sameRecording {
                    Text("DIFFERENT VERSIONS")
                        .font(.system(size: 8, weight: .black))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }
                Text("+\(DoctorFormat.mb(g.reclaimableBytes))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
            }
        } footer: {
            if let note = g.aiNote {
                Text("AI: \(note)").font(.caption2).foregroundColor(AppTheme.accent)
            } else if g.matchedByAudio {
                Text("Different file names, identical sound (same length, tempo, loudness and tone) — this is the same recording saved twice.")
            } else if !g.sameRecording {
                Text("Lengths differ — could be a live/remix version. Double-check before deleting.")
            }
        }
    }

    private func dupRow(_ g: DuplicateGroup, _ d: DuplicateSong) -> some View {
        let selected = selectedKeep(in: g) == d.id
        return Button {
            keepSelection[g.id] = d.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selected ? AppTheme.accent : .secondary.opacity(0.6))
                ArtworkView(song: d.song, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(d.song.title).font(.subheadline).foregroundColor(.primary).lineLimit(1)
                        if d.id == g.recommendedKeepID {
                            Text(g.aiReviewed ? "AI PICK" : "BEST")
                                .font(.system(size: 8, weight: .black))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(AppTheme.accent.opacity(0.18))
                                .foregroundColor(AppTheme.accent)
                                .cornerRadius(4)
                        }
                    }
                    Text(detailLine(d)).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                if d.isLiked {
                    Image(systemName: "heart.fill").font(.caption).foregroundColor(.pink)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detailLine(_ d: DuplicateSong) -> String {
        var parts: [String] = [DoctorFormat.time(d.duration)]
        parts.append(DoctorFormat.mb(d.fileSize))
        if d.bitrateKbps > 0 { parts.append("\(d.bitrateKbps) kbps") }
        if d.plays > 0 { parts.append("\(d.plays) plays") }
        parts.append("quality \(d.quality)/100")
        if d.lowQualityRip { parts.append("rough rip") }
        return parts.joined(separator: " · ")
    }

    private func selectedKeep(in g: DuplicateGroup) -> UUID {
        keepSelection[g.id] ?? g.recommendedKeepID
    }

    // MARK: Actions

    private func cleanGroup(_ g: DuplicateGroup) {
        let freed = doctor.deleteRedundant(in: g, keeping: selectedKeep(in: g))
        freedNote = "Removed \(freed) file\(freed == 1 ? "" : "s")."
        groupToClean = nil
        rescanSoon()
    }

    private func deleteAllRedundant() {
        let before = doctor.totalReclaimable
        var removed = 0
        for g in doctor.groups {
            removed += doctor.deleteRedundant(in: g, keeping: selectedKeep(in: g))
        }
        freedNote = removed == 0
            ? "Nothing to delete — every group already keeps its best copy."
            : "Removed \(removed) duplicate file\(removed == 1 ? "" : "s") · freed about \(DoctorFormat.mb(before))."
        rescanSoon()
    }

    /// Gives MusicManager's file re-scan a beat to land before re-grouping.
    private func rescanSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            doctor.scan()
        }
    }

    private func timeAgo(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60) min ago" }
        return "\(secs / 3600) h ago"
    }
}
