import Foundation
import SwiftUI
import UIKit

// ===========================================================================
// MARK: - Recently Deleted (the undo button for your library)
//
// Deleting a song used to be final: `FileManager.removeItem` and the file was
// gone. That is a scary thing to pair with a one-tap duplicate cleaner, so
// every delete now goes through here first:
//
//   Documents/<song>.mp3  ──move──▶  Documents/.trash/<uuid>-<song>.mp3
//
// The `.trash` folder starts with a dot, so `MusicManager.loadSongs()` (which
// only scans the top level of Documents and skips dot-files) never sees it —
// the song disappears from the library exactly like before, but the bytes are
// still there until the user says otherwise.
//
// What is remembered per item: title, artist, genre, artwork, how big it was,
// whether it was liked, and which playlists it belonged to. Restoring puts the
// file back under its original name AND puts the song back into those
// playlists with its original id, so a mistaken "delete all duplicates" costs
// one tap to undo instead of a re-download.
//
// Auto-clean: items older than the retention window (default 30 days) are
// purged on launch, and the trash is capped so it can never quietly eat the
// device (default 2 GB, oldest first).
// ===========================================================================

struct TrashedItem: Identifiable, Codable, Equatable {
    var id: UUID                 // the song's stable id at delete time
    var fileName: String         // original name in Documents ("Song.mp3")
    var trashName: String        // name inside .trash (unique)
    var title: String
    var artist: String
    var genre: String?
    var artworkURL: String?
    var sourceVid: String?
    var deletedAt: Date
    var bytes: Int64
    var wasLiked: Bool
    var playlistNames: [String]
    /// Set when the file was deleted by the duplicate cleaner, so the UI can
    /// say *why* something is in here.
    var reason: String?

    static func == (l: TrashedItem, r: TrashedItem) -> Bool {
        l.id == r.id && l.trashName == r.trashName
    }
}

final class LibraryTrash: ObservableObject {
    static let shared = LibraryTrash()

    @Published private(set) var items: [TrashedItem] = []
    @Published var lastNote: String? = nil

    /// Master switch. Off = classic behaviour (files are erased immediately).
    @Published var safeDelete: Bool {
        didSet { UserDefaults.standard.set(safeDelete, forKey: "asmusic_trash_on") }
    }
    /// 0 = keep until the user empties it.
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "asmusic_trash_days"); purgeExpired() }
    }

    static let retentionChoices: [Int] = [7, 30, 90, 0]
    private let maxBytes: Int64 = 2 * 1024 * 1024 * 1024   // 2 GB ceiling

    private let fm = FileManager.default

    private var documents: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var trashDir: URL {
        let d = documents.appendingPathComponent(".trash")
        if !fm.fileExists(atPath: d.path) {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }
    private var indexURL: URL { trashDir.appendingPathComponent("index.json") }

    private init() {
        let ud = UserDefaults.standard
        safeDelete = (ud.object(forKey: "asmusic_trash_on") as? Bool) ?? true
        retentionDays = (ud.object(forKey: "asmusic_trash_days") as? Int) ?? 30
        load()
        purgeExpired()
    }

    // MARK: Stats

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var count: Int { items.count }

    func daysLeft(for item: TrashedItem) -> Int? {
        guard retentionDays > 0 else { return nil }
        let age = Date().timeIntervalSince(item.deletedAt) / 86_400
        return max(0, retentionDays - Int(age))
    }

    // MARK: Persistence

    private func load() {
        guard let d = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([TrashedItem].self, from: d) else { return }
        // Drop entries whose file vanished (user cleaned via the Files app).
        items = decoded.filter { fm.fileExists(atPath: trashDir.appendingPathComponent($0.trashName).path) }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    private func save() {
        let snapshot = items
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            if let d = try? JSONEncoder().encode(snapshot) {
                try? d.write(to: self.indexURL, options: .atomic)
            }
        }
    }

    // MARK: Accepting a delete

    /// Moves `song` (and its artwork sidecar) into the trash.
    /// Returns true when the file now lives in `.trash` — the caller must then
    /// NOT delete it from disk. Returns false when safe-delete is off or the
    /// move failed, in which case the caller does its normal hard delete.
    @discardableResult
    func accept(song: Song, liked: Bool, playlistNames: [String], reason: String? = nil) -> Bool {
        guard safeDelete else { return false }
        guard fm.fileExists(atPath: song.url.path) else { return false }

        let original = song.url.lastPathComponent
        let stamp = UUID().uuidString.prefix(8)
        let trashName = "\(stamp)-\(original)"
        let dest = trashDir.appendingPathComponent(trashName)
        do {
            try fm.moveItem(at: song.url, to: dest)
        } catch {
            return false
        }
        // Artwork sidecar travels with the audio so restore looks identical.
        let sideOld = song.url.deletingPathExtension().appendingPathExtension("jpg")
        if fm.fileExists(atPath: sideOld.path) {
            let sideNew = dest.deletingPathExtension().appendingPathExtension("jpg")
            try? fm.moveItem(at: sideOld, to: sideNew)
        }
        let size = ((try? fm.attributesOfItem(atPath: dest.path)[.size]) as? Int64) ?? 0
        let item = TrashedItem(id: song.id,
                               fileName: original,
                               trashName: trashName,
                               title: song.title,
                               artist: song.artist,
                               genre: song.genre,
                               artworkURL: song.artworkURL,
                               sourceVid: song.sourceVid,
                               deletedAt: Date(),
                               bytes: size,
                               wasLiked: liked,
                               playlistNames: playlistNames,
                               reason: reason)
        items.insert(item, at: 0)
        save()
        enforceCeiling()
        return true
    }

    // MARK: Restoring

    /// Puts the file back in Documents and re-attaches likes + playlists.
    @discardableResult
    func restore(_ item: TrashedItem) -> Bool {
        let src = trashDir.appendingPathComponent(item.trashName)
        guard fm.fileExists(atPath: src.path) else {
            drop(item)
            return false
        }
        // Never clobber a file that came back by other means.
        var dest = documents.appendingPathComponent(item.fileName)
        if fm.fileExists(atPath: dest.path) {
            let base = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            var i = 2
            repeat {
                dest = documents.appendingPathComponent("\(base) \(i).\(ext)")
                i += 1
            } while fm.fileExists(atPath: dest.path) && i < 50
        }
        do {
            try fm.moveItem(at: src, to: dest)
        } catch {
            lastNote = "Could not restore “\(item.title)”."
            return false
        }
        let sideOld = src.deletingPathExtension().appendingPathExtension("jpg")
        if fm.fileExists(atPath: sideOld.path) {
            try? fm.moveItem(at: sideOld, to: dest.deletingPathExtension().appendingPathExtension("jpg"))
        }
        try? fm.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: dest.path)

        // Re-register with the ORIGINAL id so playlists, likes, listening
        // history and the audio-analysis cache all still point at this song.
        let mm = MusicManager.shared
        let restored = Song(id: item.id,
                            title: item.title,
                            url: dest,
                            artist: item.artist.isEmpty ? "AS Music" : item.artist,
                            artworkURL: item.artworkURL,
                            sourceVid: item.sourceVid,
                            genre: item.genre)
        mm.songs.removeAll { $0.id == item.id || $0.url.lastPathComponent == dest.lastPathComponent }
        mm.songs.append(restored)
        mm.songs.sort { $0.title.lowercased() < $1.title.lowercased() }
        mm.saveSongMeta()

        // Memberships (playlists are matched by name; missing ones are recreated).
        for name in item.playlistNames {
            if let idx = mm.playlists.firstIndex(where: { $0.name == name }) {
                if !mm.playlists[idx].songIDs.contains(item.id) {
                    mm.playlists[idx].songIDs.append(item.id)
                }
            } else {
                mm.playlists.append(Playlist(id: UUID(), name: name, songIDs: [item.id]))
            }
        }
        if item.wasLiked, let li = mm.playlists.firstIndex(where: { $0.name == "Liked Songs" }),
           !mm.playlists[li].songIDs.contains(item.id) {
            mm.playlists[li].songIDs.append(item.id)
        }
        mm.savePlaylists()
        mm.loadSongs()

        drop(item)
        lastNote = "“\(item.title)” is back in your library."
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }

    @discardableResult
    func restoreAll() -> Int {
        var n = 0
        for item in items { if restore(item) { n += 1 } }
        lastNote = n == 0 ? "Nothing to restore." : "Restored \(n) song\(n == 1 ? "" : "s")."
        return n
    }

    // MARK: Purging

    /// Erases one item for good.
    func purge(_ item: TrashedItem) {
        let f = trashDir.appendingPathComponent(item.trashName)
        try? fm.removeItem(at: f)
        try? fm.removeItem(at: f.deletingPathExtension().appendingPathExtension("jpg"))
        drop(item)
    }

    func emptyAll() {
        let freed = totalBytes
        for item in items { purge(item) }
        items = []
        save()
        lastNote = "Trash emptied · \(TrashFormat.size(freed)) freed."
    }

    /// Called on launch and whenever the retention setting changes.
    func purgeExpired() {
        guard retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let expired = items.filter { $0.deletedAt < cutoff }
        guard !expired.isEmpty else { return }
        for item in expired { purge(item) }
    }

    /// Keeps the folder under the ceiling, oldest first.
    private func enforceCeiling() {
        var total = totalBytes
        guard total > maxBytes else { return }
        for item in items.sorted(by: { $0.deletedAt < $1.deletedAt }) {
            guard total > maxBytes else { break }
            total -= item.bytes
            purge(item)
        }
    }

    private func drop(_ item: TrashedItem) {
        items.removeAll { $0.trashName == item.trashName }
        save()
    }
}

// MARK: - Formatting

enum TrashFormat {
    static func size(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
    static func when(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60) min ago" }
        if secs < 86_400 { return "\(secs / 3600) h ago" }
        return "\(secs / 86_400) day\(secs / 86_400 == 1 ? "" : "s") ago"
    }
}

// MARK: - UI

/// Library ▸ ⋯ ▸ Recently Deleted. Restore, erase, or change how long the
/// safety net keeps things.
struct RecentlyDeletedView: View {
    @ObservedObject private var trash = LibraryTrash.shared
    @Environment(\.presentationMode) private var pm
    @State private var confirmEmpty = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle(isOn: $trash.safeDelete) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Safety net").font(.subheadline.bold())
                            Text("Deleted songs wait here instead of vanishing.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Picker("Keep for", selection: $trash.retentionDays) {
                        ForEach(LibraryTrash.retentionChoices, id: \.self) { d in
                            Text(d == 0 ? "Until I empty it" : "\(d) days").tag(d)
                        }
                    }
                } footer: {
                    Text("Songs in here don't show in your Library and don't play — they only take up storage. Restoring puts a song back with its likes and playlists intact.")
                }

                if trash.items.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "trash.slash")
                                .font(.system(size: 42)).foregroundColor(.secondary)
                            Text("Nothing deleted recently").font(.headline)
                            Text("When you delete a song — or clean duplicates — it lands here first.")
                                .font(.caption).foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                    }
                } else {
                    Section {
                        ForEach(trash.items) { item in
                            row(item)
                        }
                    } header: {
                        Text("\(trash.count) song\(trash.count == 1 ? "" : "s") · \(TrashFormat.size(trash.totalBytes))")
                    }

                    Section {
                        Button {
                            _ = trash.restoreAll()
                        } label: {
                            Label("Restore everything", systemImage: "arrow.uturn.backward")
                        }
                        Button(role: .destructive) {
                            confirmEmpty = true
                        } label: {
                            Label("Empty trash · free \(TrashFormat.size(trash.totalBytes))", systemImage: "trash")
                        }
                    }
                }

                if let note = trash.lastNote {
                    Section { Text(note).font(.caption).foregroundColor(.green) }
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { pm.wrappedValue.dismiss() }
                }
            }
            .alert("Erase \(trash.count) song\(trash.count == 1 ? "" : "s") for good?",
                   isPresented: $confirmEmpty) {
                Button("Erase", role: .destructive) { trash.emptyAll() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This frees \(TrashFormat.size(trash.totalBytes)) and cannot be undone.")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func row(_ item: TrashedItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.body)
                .frame(width: 34, height: 34)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(6)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).lineLimit(1)
                Text(subtitle(item)).font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer()
            Button {
                _ = trash.restore(item)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title3).foregroundColor(AppTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { trash.purge(item) } label: {
                Label("Erase", systemImage: "trash")
            }
            Button { _ = trash.restore(item) } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }.tint(AppTheme.accent)
        }
    }

    private func subtitle(_ item: TrashedItem) -> String {
        var parts: [String] = [item.artist, TrashFormat.size(item.bytes), TrashFormat.when(item.deletedAt)]
        if let d = trash.daysLeft(for: item) {
            parts.append(d == 0 ? "erased soon" : "\(d) day\(d == 1 ? "" : "s") left")
        }
        if let r = item.reason { parts.append(r) }
        if item.wasLiked { parts.append("was liked") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
