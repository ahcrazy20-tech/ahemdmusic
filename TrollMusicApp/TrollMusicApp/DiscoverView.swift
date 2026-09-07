import SwiftUI
import UIKit
import Combine

// ===========================================================================
// MARK: - Discover ("For You")
//
// The music-intelligence surface: it reads your taste from the Library, then
//   • suggests one-tap artist playlists,
//   • recommends new songs to download ("Because you like …"),
//   • shows what's trending.
// Every recommendation downloads straight into your Library on tap.
// ===========================================================================

struct DiscoverView: View {
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var disco = DiscoveryManager.shared
    @StateObject private var downloader = SmartDownloaderManager()
    @ObservedObject private var dc = DownloadCenter.shared
    @ObservedObject private var ai = GeminiAI.shared

    @State private var queuedIDs: Set<String> = []
    @State private var aiPrompt = ""
    @State private var showAIKey = false

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [.black, Color(red: 0.10, green: 0.04, blue: 0.18)],
                               startPoint: .top, endPoint: .bottom)
                    .edgesIgnoringSafeArea(.all)

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header

                        if disco.isLoading && disco.recommendations.isEmpty {
                            loadingCard
                        }

                        if let err = disco.lastError, disco.recommendations.isEmpty {
                            errorCard(err)
                        }

                        statsSection
                        SmartPlaylistsSection()
                            .environmentObject(musicManager)
                        aiSection
                        playlistSuggestionsSection
                        tasteSection
                        recommendationsSection
                        trendingSection

                        Spacer().frame(height: 20)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .refreshable { disco.refresh(force: true) }

                if let msg = dc.toastMessage {
                    VStack {
                        Spacer().frame(height: 70)
                        Text(msg)
                            .font(.footnote.bold()).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.ultraThinMaterial).cornerRadius(20)
                        Spacer()
                    }
                    .transition(.opacity).animation(.easeInOut, value: dc.toastMessage)
                }
            }
            .navigationTitle("For You")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                disco.refresh()
                // The suggestion list is computed from the library + the audio
                // analysis cache, so show it even before any auto-run fired.
                if SmartPlaylistEngine.shared.suggestions.isEmpty {
                    SmartPlaylistEngine.shared.rebuild()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .smartPlaylistsChanged)) { _ in
                SmartPlaylistEngine.shared.rebuild()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showAIKey) {
            NavigationView { AIKeySetupView() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "wand.and.stars.inverse")
                    .font(.title2)
                    .foregroundStyle(LinearGradient(colors: [AppTheme.accent, .pink],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Made for You")
                    .font(.title.bold()).foregroundColor(.white)
                Spacer()
                Button {
                    disco.refresh(force: true)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.body.bold()).foregroundColor(AppTheme.accent)
                }
            }
            Text("Recommendations based on the music you love")
                .font(.subheadline).foregroundColor(.gray)
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Analyzing your taste…").foregroundColor(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity).padding()
        .background(Color.white.opacity(0.06)).cornerRadius(16)
    }

    private func errorCard(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark").font(.title).foregroundColor(.orange)
            Text(msg).font(.subheadline).foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button("Try Again") { disco.refresh(force: true) }
                .font(.subheadline.bold()).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(AppTheme.accent).cornerRadius(20)
        }
        .frame(maxWidth: .infinity).padding()
        .background(Color.white.opacity(0.06)).cornerRadius(16)
    }

    // MARK: One-tap playlist suggestions

    private var playlistSuggestionsSection: some View {
        let suggestions = disco.playlistSuggestions()
        return Group {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Auto Playlists", icon: "rectangle.stack.badge.plus", tint: .cyan)
                    Text("We grouped your Library by artist — tap to create.")
                        .font(.caption).foregroundColor(.gray)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(suggestions.prefix(10)) { s in
                                Button {
                                    disco.createPlaylist(from: s)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ZStack {
                                            LinearGradient(colors: [generateColor(for: s.name), .black],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                                            Image(systemName: "music.note.list")
                                                .font(.title).foregroundColor(.white.opacity(0.9))
                                        }
                                        .frame(width: 140, height: 90).cornerRadius(12)
                                        Text(s.name).font(.caption.bold()).foregroundColor(.white)
                                            .lineLimit(1).frame(width: 140, alignment: .leading)
                                        Text("\(s.count) songs • Tap to add")
                                            .font(.caption2).foregroundColor(.gray)
                                            .frame(width: 140, alignment: .leading)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Your top artists (detected)

    private var tasteSection: some View {
        Group {
            if !disco.topArtists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Your Top Artists", icon: "person.2.fill", tint: .pink)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(disco.topArtists) { a in
                                VStack(spacing: 6) {
                                    artistAvatar(a)
                                    Text(a.name).font(.caption.bold()).foregroundColor(.white)
                                        .lineLimit(1).frame(width: 74)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func artistAvatar(_ a: DiscoArtist) -> some View {
        ZStack {
            if let p = a.picture, let u = URL(string: p) {
                AsyncImage(url: u) { phase in
                    if let im = phase.image { im.resizable().scaledToFill() }
                    else { generateColor(for: a.name) }
                }
            } else {
                generateColor(for: a.name)
                Text(String(a.name.prefix(1))).font(.title.bold()).foregroundColor(.white)
            }
        }
        .frame(width: 74, height: 74).clipShape(Circle())
        .overlay(Circle().stroke(AppTheme.accent.opacity(0.6), lineWidth: 2))
    }

    // MARK: Recommendations

    private var recommendationsSection: some View {
        Group {
            if !disco.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        sectionTitle("Recommended for You", icon: "sparkles", tint: AppTheme.accent)
                        Spacer()
                        Button {
                            downloadAll(disco.recommendations.prefix(15))
                        } label: {
                            Label("Get 15", systemImage: "arrow.down.circle.fill")
                                .font(.caption.bold()).foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(AppTheme.accent).cornerRadius(14)
                        }
                    }
                    ForEach(disco.recommendations) { track in
                        recRow(track)
                    }
                }
            }
        }
    }

    private func recRow(_ track: DiscoTrack) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if let c = track.albumCover, let u = URL(string: c) {
                    AsyncImage(url: u) { phase in
                        if let im = phase.image { im.resizable().scaledToFill() }
                        else { generateColor(for: track.title) }
                    }
                } else {
                    generateColor(for: track.title)
                    Image(systemName: "music.note").foregroundColor(.white)
                }
            }
            .frame(width: 54, height: 54).cornerRadius(8).clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                Text(track.artist).font(.caption).foregroundColor(.gray).lineLimit(1)
                if !track.reason.isEmpty {
                    Text(track.reason)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppTheme.accent).lineLimit(1)
                }
            }
            Spacer()
            downloadButton(for: track)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color.white.opacity(0.05)).cornerRadius(10)
    }

    @ViewBuilder
    private func downloadButton(for track: DiscoTrack) -> some View {
        if queuedIDs.contains(track.id) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundColor(.green)
        } else {
            Button {
                queuedIDs.insert(track.id)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                downloader.downloadDiscoTrack(artist: track.artist, title: track.title,
                                              thumbnail: track.albumCover) { ok in
                    if !ok { queuedIDs.remove(track.id) }
                }
            } label: {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundColor(AppTheme.accent)
            }.buttonStyle(.plain)
        }
    }

    private func downloadAll<S: Sequence>(_ tracks: S) where S.Element == DiscoTrack {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        for t in tracks {
            guard !queuedIDs.contains(t.id) else { continue }
            queuedIDs.insert(t.id)
            downloader.downloadDiscoTrack(artist: t.artist, title: t.title, thumbnail: t.albumCover) { ok in
                if !ok { queuedIDs.remove(t.id) }
            }
        }
    }

    // MARK: Trending

    private var trendingSection: some View {
        Group {
            if !disco.trending.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        sectionTitle("Trending Now", icon: "chart.line.uptrend.xyaxis", tint: .green)
                        Spacer()
                        Menu {
                            ForEach(ChartRegion.allCases) { r in
                                Button {
                                    disco.setChart(r.rawValue)
                                } label: {
                                    if disco.chartCode == r.rawValue {
                                        Label(r.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(r.displayName)
                                    }
                                }
                            }
                        } label: {
                            Text(ChartRegion(rawValue: disco.chartCode)?.displayName ?? "Egypt")
                                .font(.caption.bold()).foregroundColor(AppTheme.accent)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.white.opacity(0.1)).cornerRadius(12)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(disco.trending) { track in
                                Button {
                                    guard !queuedIDs.contains(track.id) else { return }
                                    queuedIDs.insert(track.id)
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    downloader.downloadDiscoTrack(artist: track.artist, title: track.title,
                                                                  thumbnail: track.albumCover) { ok in
                                        if !ok { queuedIDs.remove(track.id) }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ZStack(alignment: .bottomTrailing) {
                                            ZStack {
                                                if let c = track.albumCover, let u = URL(string: c) {
                                                    AsyncImage(url: u) { phase in
                                                        if let im = phase.image { im.resizable().scaledToFill() }
                                                        else { generateColor(for: track.title) }
                                                    }
                                                } else { generateColor(for: track.title) }
                                            }
                                            .frame(width: 130, height: 130).clipped().cornerRadius(12)
                                            Image(systemName: queuedIDs.contains(track.id) ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                                .font(.title2)
                                                .foregroundColor(queuedIDs.contains(track.id) ? .green : .white)
                                                .padding(6).shadow(radius: 3)
                                        }
                                        Text(track.title).font(.caption2.bold()).foregroundColor(.white)
                                            .lineLimit(1).frame(width: 130, alignment: .leading)
                                        Text(track.artist).font(.caption2).foregroundColor(.gray)
                                            .lineLimit(1).frame(width: 130, alignment: .leading)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Your Listening stats

    private var statsSection: some View {
        let stats = ListenHistory.shared.stats()
        return Group {
            if stats.totalPlays > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Your Listening", icon: "chart.bar.fill", tint: .orange)
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            statCell(value: String(stats.totalPlays), label: "Total plays", icon: "play.circle.fill")
                            statCell(value: String(stats.weekPlays), label: "This week", icon: "calendar")
                        }
                        HStack(spacing: 10) {
                            if !stats.topSongTitle.isEmpty {
                                statCell(value: stats.topSongTitle, label: "Most played", icon: "crown.fill", isText: true)
                            }
                            if !stats.topArtistName.isEmpty {
                                statCell(value: stats.topArtistName, label: "Top artist", icon: "person.fill", isText: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statCell(value: String, label: String, icon: String, isText: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundColor(AppTheme.accent)
                Text(value)
                    .font(isText ? .caption2.bold() : .title3.bold())
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            Text(label).font(.system(size: 10)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
    }

    // MARK: AI assistant (optional — user's own free Gemini key)

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("AI Music Assistant", icon: "sparkles.tv", tint: AppTheme.accent)
            if !ai.isConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ask for songs in plain language — for example “5 new Egyptian pop songs about summer” — and download the results in one tap. Free, powered by your own Google Gemini key.")
                        .font(.caption).foregroundColor(.gray)
                    Button {
                        showAIKey = true
                    } label: {
                        Label("Set up (free key)", systemImage: "key.fill")
                            .font(.subheadline.bold()).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(AppTheme.accent).cornerRadius(16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(14)
            } else {
                HStack(spacing: 8) {
                    TextField("Ask… e.g. 5 new Wegz songs", text: $aiPrompt)
                        .font(.subheadline)
                        .submitLabel(.send)
                        .onSubmit { sendAIPrompt() }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.white.opacity(0.08)).cornerRadius(12)
                    Button { sendAIPrompt() } label: {
                        Image(systemName: "paperplane.fill").foregroundColor(.white)
                            .padding(10)
                            .background(AppTheme.accent).clipShape(Circle())
                    }
                    .disabled(ai.isThinking || aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if ai.isThinking {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Thinking…").font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                }
                if let err = ai.lastError {
                    Text(err).font(.caption).foregroundColor(.orange)
                }
                ForEach(ai.suggestions) { track in
                    aiRow(track)
                }
            }
        }
    }

    private func sendAIPrompt() {
        let p = aiPrompt.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !ai.isThinking else { return }
        hideKeyboard()
        ai.ask(p)
    }

    private func aiRow(_ track: DiscoTrack) -> some View {
        HStack(spacing: 12) {
            ZStack {
                generateColor(for: track.title)
                Image(systemName: "music.note").foregroundColor(.white)
            }
            .frame(width: 46, height: 46).cornerRadius(8)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
                Text(track.artist).font(.caption).foregroundColor(.gray).lineLimit(1)
                Text(track.reason).font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppTheme.accent).lineLimit(1)
            }
            Spacer()
            if queuedIDs.contains(track.id) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundColor(.green)
            } else {
                Button {
                    queuedIDs.insert(track.id)
                    downloader.downloadDiscoTrack(artist: track.artist, title: track.title,
                                                  thumbnail: track.albumCover) { ok in
                        if !ok { queuedIDs.remove(track.id) }
                    }
                } label: {
                    Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundColor(AppTheme.accent)
                }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color.white.opacity(0.05)).cornerRadius(10)
    }

    // MARK: Helpers

    private func sectionTitle(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(tint)
            Text(text).font(.headline).foregroundColor(.white)
        }
    }
}

// MARK: - AI key setup sheet

struct AIKeySetupView: View {
    @ObservedObject private var ai = GeminiAI.shared
    @State private var keyInput = ""
    @Environment(\.presentationMode) var pm

    var body: some View {
        Form {
            Section(header: Text("Get your free key"),
                    footer: Text("1. Open aistudio.google.com and sign in with Google\n2. Tap “Get API key” → “Create API key”\n3. Paste it below — it is stored only on this device. Free tier: generous daily limit.")) {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Paste your Gemini API key", text: $keyInput)
                    TextField("Model (default: gemini-3.5-flash)", text: $ai.model)
                    Toggle("Auto model (self-healing)", isOn: $ai.autoModel)
                        .font(.subheadline)
                    Text(ai.autoModel ? "On: the app switches models automatically when Google retires one." : "Off: always use the model above.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .autocorrectionDisabled()
            }
            Button {
                ai.key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                keyInput = ""
                pm.wrappedValue.dismiss()
            } label: {
                Text("Save key").frame(maxWidth: .infinity).bold()
            }
            .disabled(keyInput.trimmingCharacters(in: .whitespaces).count < 10)
        }
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { pm.wrappedValue.dismiss() }
            }
        }
        .onAppear { keyInput = ai.key }
    }
}
