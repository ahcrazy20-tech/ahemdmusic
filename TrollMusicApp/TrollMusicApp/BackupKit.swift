import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// ===========================================================================
// MARK: - Backup & Restore
//
// A sideloaded app is one bad re-install away from losing everything that is
// NOT the audio files: playlists, likes, play counts, the AI's idea of your
// taste, your theme. This writes all of that into a single small JSON file you
// can AirDrop, put in iCloud Drive, or mail to yourself — and reads it back.
//
// Design decisions that matter:
//   • Songs are matched by FILE NAME, never by UUID, so a backup restores
//     correctly even on a fresh install where ids were re-derived.
//   • Restore MERGES by default (nothing you have today is thrown away);
//     "replace" is opt-in and only touches playlists/likes, never audio.
//   • Audio files are never inside the backup (they can be gigabytes) — the
//     file stays a few hundred KB and re-downloading a song puts it straight
//     back into the playlists that referenced it.
// ===========================================================================

struct BackupSongMeta: Codable {
    var file: String
    var title: String
    var artist: String
    var genre: String?
    var artworkURL: String?
    var sourceVid: String?
}

struct BackupPlaylist: Codable {
    var name: String
    var files: [String]
}

struct BackupHistoryEntry: Codable {
    var file: String
    var playCount: Int
    var lastPlayed: Date
    var hourCounts: [Int: Int]?
}

struct BackupPayload: Codable {
    var app: String = "AS Music"
    var format: Int = 1
    var exportedAt: Date = Date()
    var deviceName: String = UIDevice.current.name
    var songCount: Int = 0
    var songs: [BackupSongMeta] = []
    var playlists: [BackupPlaylist] = []
    var liked: [String] = []
    var history: [BackupHistoryEntry] = []
    var settings: [String: String] = [:]
}

struct RestoreReport {
    var playlistsAdded = 0
    var playlistsMerged = 0
    var songsMatched = 0
    var songsMissing = 0
    var likesAdded = 0
    var historyMerged = 0
    var settingsApplied = 0

    var summary: String {
        var parts: [String] = []
        if playlistsAdded > 0 { parts.append("\(playlistsAdded) playlist\(playlistsAdded == 1 ? "" : "s") added") }
        if playlistsMerged > 0 { parts.append("\(playlistsMerged) merged") }
        if likesAdded > 0 { parts.append("\(likesAdded) like\(likesAdded == 1 ? "" : "s") restored") }
        if historyMerged > 0 { parts.append("\(historyMerged) play counts") }
        if settingsApplied > 0 { parts.append("settings") }
        if songsMissing > 0 { parts.append("\(songsMissing) song\(songsMissing == 1 ? "" : "s") not on this device yet") }
        return parts.isEmpty ? "Nothing to restore — this backup matches what you already have." : parts.joined(separator: " · ")
    }
}

final class BackupKit: ObservableObject {
    static let shared = BackupKit()

    @Published var busy = false
    @Published var lastNote: String? = nil
    @Published var lastError: String? = nil
    @Published var lastBackupAt: Date? = nil

    /// Settings worth carrying between installs (all cheap UserDefaults keys).
    private static let settingKeys = [
        "asmusic_accent", "asmusic_eq", "asmusic_preamp", "asmusic_spatial",
        "asmusic_stopend", "asmusic_lib_sort", "asmusic_trash_on",
        "asmusic_trash_days", "asmusic_smart_auto", "asmusic_smart_flow",
        "asmusic_smart_clusters"
    ]

    private let fm = FileManager.default
    private var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private init() {
        if let d = UserDefaults.standard.object(forKey: "asmusic_last_backup") as? Date {
            lastBackupAt = d
        }
    }

    // MARK: Build

    func makePayload() -> BackupPayload {
        let mm = MusicManager.shared
        var p = BackupPayload()
        p.songCount = mm.songs.count
        p.songs = mm.songs.map {
            BackupSongMeta(file: $0.url.lastPathComponent,
                           title: $0.title,
                           artist: $0.artist,
                           genre: $0.genre,
                           artworkURL: $0.artworkURL,
                           sourceVid: $0.sourceVid)
        }
        let fileByID: [UUID: String] = Dictionary(
            mm.songs.map { ($0.id, $0.url.lastPathComponent) },
            uniquingKeysWith: { a, _ in a })

        for pl in mm.playlists where pl.name != "Liked Songs" {
            p.playlists.append(BackupPlaylist(name: pl.name,
                                              files: pl.songIDs.compactMap { fileByID[$0] }))
        }
        if let liked = mm.playlists.first(where: { $0.name == "Liked Songs" }) {
            p.liked = liked.songIDs.compactMap { fileByID[$0] }
        }
        for (id, rec) in ListenHistory.shared.records {
            guard let file = fileByID[id] else { continue }
            p.history.append(BackupHistoryEntry(file: file,
                                                playCount: rec.playCount,
                                                lastPlayed: rec.lastPlayed,
                                                hourCounts: rec.hourCounts))
        }
        let ud = UserDefaults.standard
        for k in Self.settingKeys {
            if let v = ud.object(forKey: k) {
                p.settings[k] = String(describing: v)
            }
        }
        return p
    }

    /// Writes the backup into Documents (so it is visible in the Files app) and
    /// returns its URL.
    func writeBackup() -> URL? {
        let payload = makePayload()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(payload) else {
            lastError = "Could not build the backup file."
            return nil
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        let url = documents.appendingPathComponent("ASMusic-Backup-\(df.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = "Could not save the backup: \(error.localizedDescription)"
            return nil
        }
        lastBackupAt = Date()
        UserDefaults.standard.set(lastBackupAt, forKey: "asmusic_last_backup")
        lastError = nil
        lastNote = "Backup saved · \(payload.playlists.count) playlists, \(payload.liked.count) likes, \(payload.songs.count) songs described."
        return url
    }

    /// Saves + opens the iOS share sheet (AirDrop / Files / Mail).
    func exportAndShare() {
        guard let url = writeBackup() else { return }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = ac.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(ac, animated: true)
    }

    /// Backups already sitting in Documents, newest first.
    func existingBackups() -> [URL] {
        let all = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("ASMusic-Backup-") && $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    // MARK: Restore

    func readPayload(at url: URL) -> BackupPayload? {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            lastError = "Could not read that file."
            return nil
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let p = try? dec.decode(BackupPayload.self, from: data) { return p }
        dec.dateDecodingStrategy = .deferredToDate
        if let p = try? dec.decode(BackupPayload.self, from: data) { return p }
        lastError = "That doesn't look like an AS Music backup."
        return nil
    }

    /// Merges a backup into the live library. `replacePlaylists` wipes the
    /// current user playlists first (Liked Songs is always merged, never lost).
    @discardableResult
    func restore(_ p: BackupPayload, replacePlaylists: Bool = false) -> RestoreReport {
        let mm = MusicManager.shared
        var report = RestoreReport()

        let idByFile: [String: UUID] = Dictionary(
            mm.songs.map { ($0.url.lastPathComponent, $0.id) },
            uniquingKeysWith: { a, _ in a })

        // 1) Song metadata (titles/artists/genres/artwork) for files we have.
        var metaChanged = false
        for meta in p.songs {
            guard let idx = mm.songs.firstIndex(where: { $0.url.lastPathComponent == meta.file }) else { continue }
            if mm.songs[idx].genre == nil, let g = meta.genre { mm.songs[idx].genre = g; metaChanged = true }
            if mm.songs[idx].artworkURL == nil, let a = meta.artworkURL { mm.songs[idx].artworkURL = a; metaChanged = true }
            if mm.songs[idx].artist == "AS Music", !meta.artist.isEmpty, meta.artist != "AS Music" {
                mm.songs[idx].artist = meta.artist; metaChanged = true
            }
        }
        if metaChanged { mm.saveSongMeta() }

        // 2) Playlists.
        if replacePlaylists {
            mm.playlists.removeAll { $0.name != "Liked Songs" }
        }
        for bp in p.playlists {
            let ids = bp.files.compactMap { idByFile[$0] }
            report.songsMatched += ids.count
            report.songsMissing += bp.files.count - ids.count
            if let idx = mm.playlists.firstIndex(where: { $0.name == bp.name }) {
                var merged = mm.playlists[idx].songIDs
                for id in ids where !merged.contains(id) { merged.append(id) }
                if merged.count != mm.playlists[idx].songIDs.count {
                    mm.playlists[idx].songIDs = merged
                    report.playlistsMerged += 1
                }
            } else {
                mm.playlists.append(Playlist(id: UUID(), name: bp.name, songIDs: ids))
                report.playlistsAdded += 1
            }
        }

        // 3) Likes.
        if !p.liked.isEmpty {
            if !mm.playlists.contains(where: { $0.name == "Liked Songs" }) {
                mm.playlists.insert(Playlist(id: UUID(), name: "Liked Songs", songIDs: []), at: 0)
            }
            if let li = mm.playlists.firstIndex(where: { $0.name == "Liked Songs" }) {
                for f in p.liked {
                    guard let id = idByFile[f] else { report.songsMissing += 1; continue }
                    if !mm.playlists[li].songIDs.contains(id) {
                        mm.playlists[li].songIDs.append(id)
                        report.likesAdded += 1
                    }
                }
            }
        }
        mm.savePlaylists()

        // 4) Listening history (keeps the higher play count of the two).
        var incoming: [UUID: ListenRecord] = [:]
        for h in p.history {
            guard let id = idByFile[h.file] else { continue }
            incoming[id] = ListenRecord(playCount: h.playCount, lastPlayed: h.lastPlayed, hourCounts: h.hourCounts)
        }
        report.historyMerged = ListenHistory.shared.mergeImported(incoming)

        // 5) Settings.
        let ud = UserDefaults.standard
        for (k, raw) in p.settings where Self.settingKeys.contains(k) {
            if raw == "true" || raw == "false" {
                ud.set(raw == "true", forKey: k)
            } else if k == "asmusic_preamp", let f = Float(raw) {
                // Stored as Float by the audio chain — keep the exact type so
                // `object(forKey:) as? Float` still finds it after a restore.
                ud.set(f, forKey: k)
            } else if let i = Int(raw) {
                ud.set(i, forKey: k)
            } else if let d = Double(raw) {
                ud.set(d, forKey: k)
            } else {
                ud.set(raw, forKey: k)
            }
            report.settingsApplied += 1
        }
        mm.loadPrefs()
        mm.objectWillChange.send()

        lastNote = report.summary
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return report
    }
}

// MARK: - Document picker (import)

struct BackupDocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [UTType.json, UTType.plainText, UTType.data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}

// MARK: - UI

/// Library ▸ ⋯ ▸ Backup & Restore.
struct BackupView: View {
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var kit = BackupKit.shared
    @Environment(\.presentationMode) private var pm

    @State private var showPicker = false
    @State private var pending: BackupPayload? = nil
    @State private var pendingName = ""
    @State private var replaceMode = false
    @State private var report: RestoreReport? = nil

    private var playlistCount: Int {
        musicManager.playlists.filter { $0.name != "Liked Songs" }.count
    }
    private var likeCount: Int {
        musicManager.playlists.first(where: { $0.name == "Liked Songs" })?.songIDs.count ?? 0
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.badge.timemachine")
                            .font(.title2).foregroundColor(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(playlistCount) playlists · \(likeCount) likes · \(musicManager.songs.count) songs")
                                .font(.subheadline.bold())
                            Text(kit.lastBackupAt == nil
                                 ? "No backup taken yet"
                                 : "Last backup \(TrashFormat.when(kit.lastBackupAt!))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("The backup holds your playlists, likes, play counts, song titles/artists and app settings — not the audio files, so it stays tiny.")
                }

                Section("Save") {
                    Button {
                        kit.exportAndShare()
                    } label: {
                        Label("Export backup & share…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        _ = kit.writeBackup()
                    } label: {
                        Label("Save a copy in the app's Documents", systemImage: "folder.badge.plus")
                    }
                }

                Section("Restore") {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Choose a backup file…", systemImage: "square.and.arrow.down")
                    }
                    ForEach(kit.existingBackups(), id: \.self) { url in
                        Button {
                            if let p = kit.readPayload(at: url) {
                                pending = p
                                pendingName = url.lastPathComponent
                            }
                        } label: {
                            HStack {
                                Image(systemName: "doc.text").foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent).font(.caption).lineLimit(1)
                                    Text("on this device").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    Toggle("Replace my playlists instead of merging", isOn: $replaceMode)
                        .font(.subheadline)
                }

                if let r = report {
                    Section {
                        Text(r.summary).font(.caption).foregroundColor(.green)
                        if r.songsMissing > 0 {
                            Text("Songs that aren't on this device stay reserved: download them again and they drop back into the same playlists automatically.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                if let note = kit.lastNote, report == nil {
                    Section { Text(note).font(.caption).foregroundColor(.green) }
                }
                if let err = kit.lastError {
                    Section { Text(err).font(.caption).foregroundColor(.orange) }
                }
            }
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { pm.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                BackupDocumentPicker { url in
                    showPicker = false
                    if let p = kit.readPayload(at: url) {
                        pending = p
                        pendingName = url.lastPathComponent
                    }
                }
            }
            .alert("Restore this backup?",
                   isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button(replaceMode ? "Replace playlists" : "Merge into my library") {
                    if let p = pending { report = kit.restore(p, replacePlaylists: replaceMode) }
                    pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                if let p = pending {
                    Text("\(pendingName)\n\(p.playlists.count) playlists · \(p.liked.count) likes · taken \(TrashFormat.when(p.exportedAt)).\nYour audio files are never touched.")
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
