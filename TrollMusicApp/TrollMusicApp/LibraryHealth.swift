import Foundation
import SwiftUI
import UIKit

// ===========================================================================
// MARK: - Library Health
//
// One screen that answers "is my library in good shape?" using engines the app
// already has, and puts a fix next to every problem instead of just reporting
// it:
//
//   storage        → what the songs cost, what the trash is holding
//   duplicates     → LibraryDoctor's count, opens the review sheet
//   sound analysis → AudioLab coverage + a real "measure everything" sweep
//   metadata       → songs with no artist/artwork, fixed by the free iTunes
//                    lookup (no key, no account)
//   broken files   → 0-byte / truncated downloads, deleted safely (they go to
//                    Recently Deleted like everything else)
//   rough rips     → the clipped / very quiet files the analysis flagged, so
//                    you know which songs deserve a better download
//
// Everything here reads cached numbers; the only work it starts is work the
// user asked for by tapping.
// ===========================================================================

struct LibraryHealthStats {
    var songCount = 0
    var libraryBytes: Int64 = 0
    var brokenFiles: [Song] = []
    var missingArtist: Int = 0
    var missingArtwork: Int = 0
    var roughRips: [Song] = []
    var analyzed = 0
    var pending = 0

    var coverage: Double {
        songCount == 0 ? 1 : Double(analyzed) / Double(songCount)
    }

    /// 0…100 — a single number so the user sees progress after cleaning up.
    var score: Int {
        guard songCount > 0 else { return 100 }
        var s = 100.0
        s -= min(25.0, Double(LibraryDoctor.shared.redundantCount) / Double(songCount) * 120.0)
        s -= min(20.0, Double(brokenFiles.count) * 6.0)
        s -= min(15.0, Double(missingArtist) / Double(songCount) * 45.0)
        s -= min(10.0, Double(missingArtwork) / Double(songCount) * 25.0)
        s -= min(15.0, Double(roughRips.count) / Double(songCount) * 45.0)
        s -= min(15.0, (1.0 - coverage) * 20.0)
        return max(0, min(100, Int(s.rounded())))
    }
}

final class LibraryHealth: ObservableObject {
    static let shared = LibraryHealth()

    @Published private(set) var stats = LibraryHealthStats()
    @Published private(set) var scanning = false
    @Published var note: String? = nil

    private init() {}

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let songs = MusicManager.shared.songs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let lab = AudioLab.shared
            var s = LibraryHealthStats()
            s.songCount = songs.count
            for song in songs {
                let size = ((try? fm.attributesOfItem(atPath: song.url.path)[.size]) as? Int64) ?? 0
                s.libraryBytes += size
                // Under 32 KB of audio is never a real song: it's a failed or
                // interrupted download.
                if size < 32_768 { s.brokenFiles.append(song) }
                if song.artist.isEmpty || song.artist == "AS Music" { s.missingArtist += 1 }
                if song.artworkURL == nil { s.missingArtwork += 1 }
                if let f = lab.features(for: song) {
                    s.analyzed += 1
                    if f.isLowQualityRip { s.roughRips.append(song) }
                } else {
                    s.pending += 1
                }
            }
            s.roughRips = Array(s.roughRips.prefix(12))
            s.brokenFiles = Array(s.brokenFiles.prefix(20))
            DispatchQueue.main.async {
                self?.stats = s
                self?.scanning = false
            }
        }
    }
}

struct LibraryHealthView: View {
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var health = LibraryHealth.shared
    @ObservedObject private var doctor = LibraryDoctor.shared
    @ObservedObject private var lab = AudioLab.shared
    @ObservedObject private var trash = LibraryTrash.shared
    @Environment(\.presentationMode) private var pm

    @State private var showDuplicates = false
    @State private var showTrash = false
    @State private var confirmBroken = false

    private var s: LibraryHealthStats { health.stats }

    var body: some View {
        NavigationView {
            List {
                scoreSection
                storageSection
                duplicatesSection
                analysisSection
                metadataSection
                if !s.brokenFiles.isEmpty { brokenSection }
                if !s.roughRips.isEmpty { ripsSection }
                if let note = health.note {
                    Section { Text(note).font(.caption).foregroundColor(.green) }
                }
            }
            .navigationTitle("Library Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Recheck") { health.refresh(); doctor.scan() }
                        .disabled(health.scanning)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { pm.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: $showDuplicates) {
                DuplicateReviewView().environmentObject(musicManager)
            }
            .sheet(isPresented: $showTrash) {
                RecentlyDeletedView()
            }
            .alert("Delete \(s.brokenFiles.count) unplayable file(s)?", isPresented: $confirmBroken) {
                Button("Delete", role: .destructive) { deleteBroken() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("These files are too small to contain audio — a download that failed halfway. They go to Recently Deleted, so you can still get them back.")
            }
            .onAppear {
                health.refresh()
                doctor.autoScan()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: Sections

    private var scoreSection: some View {
        Section {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: CGFloat(s.score) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(s.score)").font(.title3.bold())
                }
                .frame(width: 62, height: 62)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.subheadline.bold())
                    Text("\(s.songCount) songs · \(TrashFormat.size(s.libraryBytes))")
                        .font(.caption).foregroundColor(.secondary)
                    if health.scanning {
                        Text("Checking…").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            row(icon: "internaldrive", title: "Songs on this device",
                detail: TrashFormat.size(s.libraryBytes))
            Button {
                showTrash = true
            } label: {
                row(icon: "trash.slash", title: "Recently Deleted",
                    detail: trash.count == 0 ? "empty" : "\(trash.count) · \(TrashFormat.size(trash.totalBytes))",
                    accent: trash.count > 0)
            }
        }
    }

    private var duplicatesSection: some View {
        Section("Duplicates") {
            Button {
                showDuplicates = true
            } label: {
                row(icon: "doc.on.doc",
                    title: doctor.redundantCount == 0 ? "No duplicate files" : "\(doctor.redundantCount) extra copies",
                    detail: doctor.redundantCount == 0
                        ? (doctor.isScanning ? "scanning…" : "clean")
                        : "free \(DoctorFormat.mb(doctor.totalReclaimable))",
                    accent: doctor.redundantCount > 0)
            }
        }
    }

    private var analysisSection: some View {
        Section {
            row(icon: "waveform.path.ecg",
                title: "Sound analysis",
                detail: "\(Int(s.coverage * 100))% measured")
            if s.pending > 0 {
                Button {
                    AudioLab.shared.analyzeAll(musicManager.songs)
                    health.note = "Measuring \(s.pending) song\(s.pending == 1 ? "" : "s") in the background — smart playlists get sharper as it goes."
                } label: {
                    Label(lab.isWorking ? "Measuring… (\(lab.queueDepth) left)" : "Measure the remaining \(s.pending)",
                          systemImage: "gauge")
                        .foregroundColor(AppTheme.accent)
                }
                .disabled(lab.isWorking)
            }
        } header: {
            Text("AI · on-device")
        } footer: {
            Text("Tempo, loudness, tone and vocal balance are measured on the device itself — that's what the auto-playlists, the duplicate 'same audio' check and the smart EQ all read.")
        }
    }

    private var metadataSection: some View {
        Section("Song info") {
            row(icon: "person.crop.square", title: "Missing artist",
                detail: s.missingArtist == 0 ? "all named" : "\(s.missingArtist) songs",
                accent: s.missingArtist > 0)
            row(icon: "photo", title: "Missing artwork",
                detail: s.missingArtwork == 0 ? "all covered" : "\(s.missingArtwork) songs",
                accent: s.missingArtwork > 0)
            if s.missingArtist + s.missingArtwork > 0 {
                Button {
                    ITunesEnricher.shared.enrichLibrary()
                    health.note = "Looking up artists and covers (free iTunes catalogue, no account) — give it a minute, then Recheck."
                } label: {
                    Label("Fetch missing artists & covers", systemImage: "magnifyingglass")
                        .foregroundColor(AppTheme.accent)
                }
            }
        }
    }

    private var brokenSection: some View {
        Section {
            ForEach(s.brokenFiles) { song in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange).font(.caption)
                    Text(song.title).font(.caption).lineLimit(1)
                }
            }
            Button(role: .destructive) {
                confirmBroken = true
            } label: {
                Label("Delete \(s.brokenFiles.count) unplayable file(s)", systemImage: "trash")
            }
        } header: {
            Text("Failed downloads")
        } footer: {
            Text("Files under 32 KB can't hold a song — they're what's left when a download is cut off.")
        }
    }

    private var ripsSection: some View {
        Section {
            ForEach(s.roughRips) { song in
                HStack {
                    Image(systemName: "waveform.path.badge.minus")
                        .foregroundColor(.orange).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.caption).lineLimit(1)
                        Text(ripReason(song)).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        musicManager.playSong(song)
                    } label: {
                        Image(systemName: "play.circle").foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Rough sounding rips")
        } footer: {
            Text("Clipped, very quiet, or starting with dead air. Re-download these from Magic DL for a cleaner copy — the duplicate finder will then keep the better one automatically.")
        }
    }

    // MARK: Bits

    private var headline: String {
        switch s.score {
        case 90...100: return "Your library is in great shape"
        case 70..<90:  return "Good — a couple of things to tidy"
        case 45..<70:  return "Worth a clean-up"
        default:       return "Needs attention"
        }
    }

    private var scoreColor: Color {
        switch s.score {
        case 80...100: return .green
        case 55..<80:  return .yellow
        default:       return .orange
        }
    }

    private func ripReason(_ song: Song) -> String {
        guard let f = AudioLab.shared.features(for: song) else { return "not measured" }
        var parts: [String] = []
        if f.clipRatio > 0.004 { parts.append("clipping") }
        if f.loudness < -26 { parts.append("very quiet") }
        if f.leadSilence > 0.8 { parts.append(String(format: "%.1fs dead air", f.leadSilence)) }
        return parts.isEmpty ? "rough master" : parts.joined(separator: " · ")
    }

    private func row(icon: String, title: String, detail: String, accent: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 26)
                .foregroundColor(accent ? AppTheme.accent : .secondary)
            Text(title).font(.subheadline).foregroundColor(.primary)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundColor(accent ? AppTheme.accent : .secondary)
        }
    }

    private func deleteBroken() {
        var n = 0
        for song in s.brokenFiles {
            if let live = musicManager.songs.first(where: { $0.id == song.id }) {
                musicManager.deleteSong(live, reason: "unplayable file")
                n += 1
            }
        }
        health.note = "Removed \(n) broken file\(n == 1 ? "" : "s") — they're in Recently Deleted."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { health.refresh() }
    }
}
