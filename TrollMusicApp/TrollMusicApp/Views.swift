import SwiftUI
import UIKit
import AVKit
import MediaPlayer
import UniformTypeIdentifiers

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// App-wide accent: driven by MusicManager (user pickable)
struct AppTheme {
    static var accent: Color {
        let a = MusicManager.shared.accent
        return Color(red: a.r, green: a.g, blue: a.b)
    }
}

func generateColor(for title: String) -> Color {
    let h = Double(abs(title.hashValue) % 360) / 360.0
    return Color(hue: h, saturation: 0.75, brightness: 0.78)
}

struct VisualizerView: View {
    @ObservedObject private var mm = MusicManager.shared
    @State private var bars: [CGFloat] = [3,3,3,3]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(Color.white)
                    .frame(width: 3, height: bars[i])
            }
        }
        .onReceive(Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()) { _ in
            guard mm.isPlaying else { bars = bars.map { _ in 3 }; return }
            let l = CGFloat(mm.levels.0)
            withAnimation(.easeInOut(duration: 0.08)) {
                bars = (0..<4).map { i in
                    let jitter = CGFloat.random(in: 0...0.25)
                    return max(4, (l * 22) + CGFloat(i)*1.5 - jitter*5)
                }
            }
        }
    }
}

// Real audio-reactive spectrum: 24 log-spaced bands from a live FFT in the
// audio engine (SpectrumMeter), not fake jitter.
struct SpectrumView: View {
    @ObservedObject private var mm = MusicManager.shared
    @State private var bars: [CGFloat] = Array(repeating: 3, count: SpectrumMeter.bands)
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<SpectrumMeter.bands, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(colors: [AppTheme.accent.opacity(0.55), AppTheme.accent],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(width: 3, height: max(3, bars[i]))
            }
        }
        .frame(height: 36, alignment: .bottom)
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            guard mm.isPlaying else {
                withAnimation(.easeOut(duration: 0.35)) { bars = bars.map { _ in 3 } }
                return
            }
            let vals = mm.spectrum.read()
            let target: [CGFloat] = vals.map { db in
                // -55 dB … -10 dB maps to the full bar height.
                let n = max(0.0, min(1.0, (Double(db) + 55.0) / 45.0))
                return 3 + CGFloat(n) * 31
            }
            withAnimation(.easeOut(duration: 0.05)) { bars = target }
        }
    }
}

// "About the artist" — short bio + photo from the free Wikipedia API.
struct ArtistInfoView: View {
    let artist: String
    var genre: String? = nil
    @State private var bio: ArtistBio? = nil
    @State private var failed = false
    @Environment(\.presentationMode) var pm

    var body: some View {
        ZStack {
            if bio == nil && !failed {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding \(artist)…").font(.caption).foregroundColor(.secondary)
                }
            } else if let bio = bio {
                ScrollView {
                    VStack(spacing: 16) {
                        ZStack {
                            if let t = bio.thumbnail, let u = URL(string: t) {
                                AsyncImage(url: u) { phase in
                                    if let im = phase.image { im.resizable().scaledToFill() }
                                    else { generateColor(for: bio.name) }
                                }
                            } else {
                                generateColor(for: bio.name)
                                Text(String(bio.name.prefix(1))).font(.system(size: 64, weight: .black))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 12, y: 6)
                        .padding(.top, 20)

                        Text(bio.name).font(.title2.bold())
                        if let g = genre, !g.isEmpty {
                            Text(g)
                                .font(.caption.bold())
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(AppTheme.accent.opacity(0.15))
                                .foregroundColor(AppTheme.accent)
                                .cornerRadius(12)
                        }
                        Text(bio.extract)
                            .font(.subheadline)
                            .foregroundColor(.primary.opacity(0.85))
                            .lineSpacing(5)
                            .padding(.horizontal)
                        Link(destination: URL(string: bio.pageURL) ?? URL(string: "https://en.wikipedia.org")!) {
                            Label("Open full article", systemImage: "arrow.up.forward.square")
                                .font(.subheadline.bold())
                        }
                        .padding(.bottom, 24)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 44)).foregroundColor(.secondary)
                    Text("No info found for \(artist)").font(.subheadline).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(artist)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { pm.wrappedValue.dismiss() }
            }
        }
        .onAppear {
            WikipediaAPI.fetch(artist) { b in
                bio = b
                if b == nil { failed = true }
            }
        }
    }
}

// Reusable artwork view with async image + blur support
struct ArtworkView: View {
    let song: Song
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8
    var fallbackSystemName: String = "music.note"
    @State private var img: UIImage? = nil
    var body: some View {
        ZStack {
            if let img = img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                generateColor(for: song.title)
                Image(systemName: fallbackSystemName).foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(cornerRadius)
        .clipped()
        .onAppear {
            MusicManager.shared.artworkImage(for: song, size: size * UIScreen.main.scale) { i in
                DispatchQueue.main.async { self.img = i }
            }
        }
        .onChange(of: song.id) { _ in
            self.img = nil
            MusicManager.shared.artworkImage(for: song, size: size * UIScreen.main.scale) { i in
                DispatchQueue.main.async { self.img = i }
            }
        }
    }
}

// A view that produces a blurred, dimmed version of the current song's artwork
// (Apple-Music style player background)
struct BlurredArtworkBackground: View {
    let song: Song
    @State private var img: UIImage? = nil
    var body: some View {
        ZStack {
            if let img = img {
                GeometryReader { geo in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width + 80, height: geo.size.height + 80)
                        .blur(radius: 60)
                        .overlay(Color.black.opacity(0.55))
                        .clipped()
                }
            } else {
                LinearGradient(gradient: Gradient(colors: [generateColor(for: song.title), Color.black] as [Color]),
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .onAppear { load() }
        .onChange(of: song.id) { _ in img = nil; load() }
    }
    private func load() {
        MusicManager.shared.artworkImage(for: song, size: 800) { i in
            DispatchQueue.main.async { self.img = i }
        }
    }
}

enum TabID: Hashable { case library, discover, playlists, magic, browser, settings }

struct MainTabView: View {
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var dc = DownloadCenter.shared
    @State private var showFullPlayer = false
    @State private var showDownloads = false
    @State private var selected: TabID = .library

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selected {
                case .library:   LibraryView()
                case .discover:  DiscoverView()
                case .playlists: PlaylistsView()
                case .magic:     SmartDownloaderView()
                case .browser:   BrowserMainView()
                case .settings:  SettingsTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, bottomBarHeight)

            VStack(spacing: 0) {
                if dc.showBanner, let first = dc.tasks.first {
                    DownloadBannerView(task: first, total: dc.tasks.count)
                        .onTapGesture { showDownloads = true }
                }
                if musicManager.currentSong != nil {
                    MiniPlayerView(showFullPlayer: $showFullPlayer)
                }
                Divider()
                HStack(spacing: 0) {
                    TabButton(label: "Library", icon: "music.note.list", id: .library, selection: $selected)
                    TabButton(label: "For You", icon: "wand.and.stars", id: .discover, selection: $selected)
                    TabButton(label: "Playlists", icon: "music.mic", id: .playlists, selection: $selected)
                    TabButton(label: "Magic DL", icon: "sparkles", id: .magic, selection: $selected)
                    TabButton(label: "Web Hub", icon: "safari", id: .browser, selection: $selected)
                    TabButton(label: "Settings", icon: "gearshape", id: .settings, selection: $selected)
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
                .background(.bar)
            }
            .background(.bar)
        }
        .edgesIgnoringSafeArea(.bottom)
        .tint(AppTheme.accent)
        .sheet(isPresented: $showFullPlayer) { FullPlayerView() }
        .sheet(isPresented: $showDownloads) { DownloadsQueueView() }
        .onReceive(NotificationCenter.default.publisher(for: .openAISettings)) { _ in
            // Anywhere in the app can send the user straight to the AI
            // settings ("tap to add a free key" hints, EQ screen, Discover).
            selected = .settings
        }
        .onReceive(dc.$tasks) { newTasks in
            // `dc.$tasks` fires *willSet*, so `dc.tasks` is still the old value
            // here — use the incoming value, and defer the write so we don't
            // mutate observed state while SwiftUI is building this view.
            let shouldShow = !newTasks.isEmpty
            DispatchQueue.main.async {
                if dc.showBanner != shouldShow { dc.showBanner = shouldShow }
                NotificationCenter.default.post(name: .downloadCenterChanged, object: nil)
            }
        }
    }

    private var bottomBarHeight: CGFloat {
        var h: CGFloat = 54
        if dc.showBanner, dc.tasks.first != nil { h += 60 }
        if musicManager.currentSong != nil { h += 62 }
        return h
    }
}

struct TabButton: View {
    let label: String
    let icon: String
    let id: TabID
    @Binding var selection: TabID
    var body: some View {
        Button {
            selection = id
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 22))
                Text(label).font(.caption2)
            }
            .foregroundColor(selection == id ? AppTheme.accent : .secondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Download Banner & Queue
// ---------------------------------------------------------------------------
struct DownloadBannerView: View {
    @ObservedObject var task: DownloadTask
    let total: Int
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.white).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.fileName.isEmpty ? task.proposedName : task.fileName)
                    .font(.footnote).bold().lineLimit(1).foregroundColor(.white)
                Group {
                    switch task.status {
                    case .queued:
                        HStack { ProgressView().progressViewStyle(.linear).tint(.white); Text("Queued").font(.caption2).foregroundColor(.white.opacity(0.85)) }
                    case .racing:
                        HStack { ProgressView().progressViewStyle(.linear).tint(.white); Text("Finding fastest server…").font(.caption2).foregroundColor(.white.opacity(0.85)) }
                    case .contacting:
                        HStack { ProgressView().progressViewStyle(.linear).tint(.white); Text("Connecting…").font(.caption2).foregroundColor(.white.opacity(0.85)) }
                    case .converting(let p):
                        HStack(spacing:6) { ProgressView(value: max(0.1, p)).progressViewStyle(.linear).tint(.white);
                            Text(task.backendLabel.isEmpty ? "Converting…" : "\(task.backendLabel) • Converting…").font(.caption2).foregroundColor(.white.opacity(0.85)).lineLimit(1) }
                    case .downloading(let p):
                        HStack(spacing:6) { ProgressView(value: p).progressViewStyle(.linear).tint(.white);
                            Text(task.backendLabel.isEmpty ? String(format:"%.0f%%", p*100) : "\(task.backendLabel) • \(String(format:"%.0f%%", p*100))").font(.caption2).foregroundColor(.white.opacity(0.85)).lineLimit(1) }
                    case .done:
                        Label("Saved to Library", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.white)
                    case .cancelled:
                        Label("Cancelled", systemImage: "xmark.circle").font(.caption).foregroundColor(.white.opacity(0.9))
                    case .failed(let msg):
                        Text(msg).font(.caption2).foregroundColor(.yellow).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if case .done = task.status {
                Image(systemName: "checkmark").foregroundColor(.white).font(.caption.bold())
            } else if case .cancelled = task.status {
                Image(systemName: "xmark").foregroundColor(.white.opacity(0.8)).font(.caption.bold())
            } else {
                // Cancel button
                Button {
                    DownloadCenter.shared.cancel(task)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.9)).font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            }
            if total > 1 {
                Text("\(total)").font(.caption.bold()).foregroundColor(.white)
                    .padding(6).background(Color.white.opacity(0.25)).clipShape(Circle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(AppTheme.accent)
        .contentShape(Rectangle())
    }
}

struct DownloadsQueueView: View {
    @ObservedObject private var dc = DownloadCenter.shared
    @Environment(\.presentationMode) var presentationMode
    var body: some View {
        NavigationView {
            List {
                if dc.tasks.isEmpty {
                    Text("No downloads").foregroundColor(.secondary)
                } else {
                    ForEach(dc.tasks) { task in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.fileName.isEmpty ? task.proposedName : task.fileName)
                                    .font(.subheadline).bold().lineLimit(1)
                                HStack(spacing: 6) {
                                    backendBadge(for: task)
                                    statusLabel(for: task.status).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            switch task.status {
                            case .downloading(let p), .converting(let p), .contacting(let p), .racing(let p):
                                HStack(spacing: 8) {
                                    ProgressView(value: max(0.05, p)).frame(width: 60)
                                    Button(role: .destructive) { dc.cancel(task) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                                    }.buttonStyle(.plain)
                                }
                            case .queued:
                                HStack(spacing: 8) {
                                    ProgressView().frame(width: 60)
                                    Button(role: .destructive) { dc.cancel(task) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                                    }.buttonStyle(.plain)
                                }
                            case .done:
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    Button(role: .destructive) { dc.remove(task) } label: {
                                        Image(systemName: "trash").foregroundColor(.secondary).font(.caption)
                                    }.buttonStyle(.plain)
                                }
                            case .cancelled:
                                HStack(spacing: 8) {
                                    Image(systemName: "xmark.circle").foregroundColor(.secondary)
                                    Button("Retry") { dc.retry(task) }
                                        .font(.caption).padding(5).background(AppTheme.accent).foregroundColor(.white).cornerRadius(6)
                                    Button(role: .destructive) { dc.remove(task) } label: {
                                        Image(systemName: "trash").foregroundColor(.secondary).font(.caption)
                                    }.buttonStyle(.plain)
                                }
                            case .failed:
                                HStack(spacing: 8) {
                                    Button("Retry") { dc.retry(task) }
                                        .font(.caption).padding(6).background(AppTheme.accent).foregroundColor(.white).cornerRadius(6)
                                    Button(role: .destructive) { dc.remove(task) } label: {
                                        Image(systemName: "trash").foregroundColor(.red)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear Finished") { dc.clearCompleted() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
    @ViewBuilder
    private func backendBadge(for task: DownloadTask) -> some View {
        if !task.backendLabel.isEmpty {
            Text(task.backendLabel.uppercased())
                .font(.system(size: 8, weight: .black))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(AppTheme.accent.opacity(0.2))
                .foregroundColor(AppTheme.accent)
                .cornerRadius(3)
        }
    }
    @ViewBuilder
    private func statusLabel(for s: DownloadTaskStatus) -> some View {
        switch s {
        case .queued: Text("Queued")
        case .racing: Text("Racing servers for fastest link…")
        case .contacting: Text("Connecting to server…")
        case .converting(let p): Text(String(format: "Converting… %.0f%%", p*100))
        case .downloading(let p): Text(String(format: "Downloading… %.0f%%", p*100))
        case .done: Text("Saved").foregroundColor(.green)
        case .cancelled: Text("Cancelled").foregroundColor(.secondary)
        case .failed(let m): Text(m).foregroundColor(.red).lineLimit(1)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Browser (Web Hub)
// ---------------------------------------------------------------------------
struct BrowserMainView: View {
    @EnvironmentObject var musicManager: MusicManager
    @StateObject var webViewModel = WebViewModel()
    @State private var urlString = "https://youtube.com"

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search Google or enter website", text: $urlString)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.webSearch).textInputAutocapitalization(.never)
                        .onSubmit { webViewModel.loadUrl(urlString) }
                    Button("Go") { webViewModel.loadUrl(urlString) }
                }.padding(8).background(Color(uiColor: UIColor.secondarySystemBackground))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("Google")     { webViewModel.loadUrl("https://google.com") }      .buttonStyle(.borderedProminent).tint(.blue)
                        Button("YouTube")    { webViewModel.loadUrl("https://youtube.com") }     .buttonStyle(.borderedProminent).tint(.red)
                        Button("SoundCloud") { webViewModel.loadUrl("https://soundcloud.com") }  .buttonStyle(.borderedProminent).tint(.orange)
                        Button("Audiomack")  { webViewModel.loadUrl("https://audiomack.com") }   .buttonStyle(.borderedProminent).tint(.yellow)
                        Button("SpotifyDown"){ webViewModel.loadUrl("https://spotifydown.com") } .buttonStyle(.borderedProminent).tint(.green)
                        Button("Anghami")    { webViewModel.loadUrl("https://play.anghami.com") }.buttonStyle(.borderedProminent).tint(.purple)
                        Button("YTMP3")      { webViewModel.loadUrl("http://nbike.pl/") }        .buttonStyle(.borderedProminent).tint(.pink)
                        Button("CNVMP3")     { webViewModel.loadUrl("https://cnvmp3.com/v55") }  .buttonStyle(.borderedProminent).tint(.teal)
                    }.padding(.horizontal).padding(.bottom, 8)
                }.background(Color(uiColor: UIColor.secondarySystemBackground))

                WebViewUI(viewModel: webViewModel, urlString: $urlString)
                    .id(webViewModel.currentTabIndex)

                HStack {
                    Button { webViewModel.goBack() } label: { Image(systemName: "chevron.backward").font(.title2) }.disabled(!webViewModel.canGoBack)
                    Spacer()
                    Button { webViewModel.goForward() } label: { Image(systemName: "chevron.forward").font(.title2) }.disabled(!webViewModel.canGoForward)
                    Spacer()
                    Button { webViewModel.grabAudio() } label: {
                        Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundColor(AppTheme.accent)
                    }
                    Spacer()
                    Button { webViewModel.injectFloatingDL() } label: {
                        Image(systemName: "wand.and.stars").font(.title2).foregroundColor(AppTheme.accent)
                    }
                    Spacer()
                    Button { webViewModel.showTabs = true } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).stroke(Color.primary, lineWidth: 2).frame(width: 24, height: 24)
                            Text(String(webViewModel.tabs.count)).font(.caption).bold()
                        }
                    }
                    Spacer()
                    Button { webViewModel.refresh() } label: { Image(systemName: "arrow.clockwise").font(.title2) }
                }.padding().background(Color(uiColor: UIColor.secondarySystemBackground))
            }

            if webViewModel.showTabs {
                Color.black.opacity(0.8).edgesIgnoringSafeArea(.all)
                VStack {
                    HStack {
                        Text("Tabs").font(.title).bold().foregroundColor(.white)
                        Spacer()
                        Button("Done") { webViewModel.showTabs = false }.foregroundColor(.blue)
                    }.padding()
                    ScrollView {
                        VStack(spacing: 15) {
                            ForEach(0..<webViewModel.tabs.count, id: \.self) { index in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("Tab \(index+1)").font(.headline).foregroundColor(.white)
                                        Text(webViewModel.tabs[index].urlString).font(.caption).foregroundColor(.gray).lineLimit(1)
                                    }
                                    Spacer()
                                    Button { webViewModel.closeTab(at: index) } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.title)
                                    }
                                }
                                .padding()
                                .background(webViewModel.currentTabIndex == index ? AppTheme.accent.opacity(0.7) : Color.gray.opacity(0.3))
                                .cornerRadius(10)
                                .onTapGesture {
                                    webViewModel.currentTabIndex = index
                                    urlString = webViewModel.tabs[index].urlString
                                    webViewModel.showTabs = false
                                }
                            }
                            Button {
                                webViewModel.addNewTab()
                                webViewModel.showTabs = false
                            } label: {
                                HStack { Image(systemName: "plus"); Text("New Tab") }
                                    .font(.headline).foregroundColor(.white)
                                    .padding().frame(maxWidth: .infinity).background(AppTheme.accent).cornerRadius(10)
                            }.padding(.top, 10)
                        }.padding(.horizontal)
                    }
                }
            }
        }
        .alert("Save As", isPresented: $webViewModel.showNamePrompt) {
            TextField("Song Name", text: $webViewModel.customSongName)
            Button("Download") { webViewModel.confirmDownload() }
            Button("Cancel", role: .cancel) { webViewModel.cancelPendingDownload() }
        } message: {
            Text("Edit the name before saving to your Library.")
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Player
// ---------------------------------------------------------------------------
struct MiniPlayerView: View {
    @EnvironmentObject var musicManager: MusicManager
    @Binding var showFullPlayer: Bool
    @Namespace private var ns
    var body: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.1))
            HStack(spacing: 15) {
                if let song = musicManager.currentSong {
                    ArtworkView(song: song, size: 45, cornerRadius: 8, fallbackSystemName: "music.note")
                        .matchedGeometryEffect(id: "art", in: ns)
                } else {
                    ZStack {
                        Color.gray.opacity(0.3).frame(width:45,height:45).cornerRadius(8)
                        Image(systemName: "music.note").foregroundColor(.white)
                    }
                }
                VStack(alignment: .leading) {
                    Text(musicManager.currentSong?.title ?? "").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    HStack(spacing:4) {
                        Text(musicManager.currentSong?.artist.isEmpty == false ? musicManager.currentSong!.artist : "AS Music").font(.caption).foregroundColor(.gray).lineLimit(1)
                        if musicManager.isPlaying { VisualizerView() }
                    }
                }
                Spacer()
                Button { musicManager.togglePlayPause() } label: {
                    Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).foregroundColor(.primary)
                }.padding(.trailing)
            }.padding(.horizontal).padding(.vertical, 8).background(.ultraThinMaterial)
                .onTapGesture { withAnimation(.spring(response:0.45,dampingFraction:0.85)) { showFullPlayer = true } }
        }
    }
}

struct FullPlayerView: View {
    @EnvironmentObject var musicManager: MusicManager
    @Environment(\.presentationMode) var presentationMode
    @State private var showTimerOptions = false
    @State private var showLyrics = false
    @State private var showEQ = false
    @State private var showTheme = false
    @State private var showArtistInfo = false
    @State private var showStudio = false

    var body: some View {
        ZStack {
            if let song = musicManager.currentSong {
                BlurredArtworkBackground(song: song).edgesIgnoringSafeArea(.all)
            } else {
                LinearGradient(gradient: Gradient(colors: [AppTheme.accent, Color.black] as [Color]),
                               startPoint: .top, endPoint: .bottom).edgesIgnoringSafeArea(.all)
            }
            VStack(spacing: 20) {
                HStack {
                    Button {
                        withAnimation(.spring(response:0.45,dampingFraction:0.85)) { presentationMode.wrappedValue.dismiss() }
                    } label: {
                        Image(systemName: "chevron.down").font(.title2).foregroundColor(.white)
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        if musicManager.smartRadioMode {
                            Text("SMART RADIO").font(.caption).bold().foregroundColor(AppTheme.accent)
                        } else if let song = musicManager.currentSong, musicManager.isFavorite(song: song) {
                            Text("FROM LIKED SONGS").font(.caption).bold().foregroundColor(.white.opacity(0.6))
                        } else {
                            Text("NOW PLAYING").font(.caption).bold().foregroundColor(.white.opacity(0.6))
                        }
                        Text(musicManager.currentSong?.artist.isEmpty == false ? musicManager.currentSong!.artist : "AS Music")
                            .font(.subheadline).bold().foregroundColor(.white).lineLimit(1)
                    }
                    Spacer()
                    if musicManager.currentSong != nil {
                        Button { showArtistInfo = true } label: {
                            Image(systemName: "info.circle").font(.title3).foregroundColor(.white)
                        }
                        .accessibilityLabel("About the artist")
                    }
                    Menu {
                        Button { musicManager.setSleepTimer(minutes: 15) } label: { Label("15 min sleep", systemImage: "moon.zzz") }
                        Button { musicManager.setSleepTimer(minutes: 30) } label: { Label("30 min sleep", systemImage: "moon.zzz") }
                        Button { musicManager.setSleepTimer(minutes: 60) } label: { Label("60 min sleep", systemImage: "moon.zzz") }
                        Toggle("Stop at song end", isOn: Binding(
                            get: { musicManager.stopAtSongEnd },
                            set: { musicManager.stopAtSongEnd = $0 }
                        ))
                        if musicManager.sleepTimerMinutes > 0 {
                            Button(role: .destructive) { musicManager.setSleepTimer(minutes: 0) } label: { Label("Cancel sleep", systemImage: "moon.zzz.slash") }
                        }
                        Divider()
                        Button { showEQ = true } label: { Label("Equalizer", systemImage: "slider.horizontal.3") }
                        Button { showStudio = true } label: { Label("Vocal & Sound Studio", systemImage: "waveform.with.arrow.down.circle") }
                        Button { showTheme = true } label: { Label("Theme color", systemImage: "paintpalette") }
                        if let song = musicManager.currentSong {
                            Divider()
                            Button { musicManager.shareSong(song) } label: { Label("Share / Export", systemImage: "square.and.arrow.up") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).foregroundColor(.white)
                    }
                }.padding()

                if showLyrics, let song = musicManager.currentSong {
                    // Synced (karaoke) lyrics: the current line lights up and
                    // tapping any line seeks the player there. Falls back to
                    // plain text when the source has no timings.
                    LiveLyricsView(song: song)
                        .environmentObject(musicManager)
                } else if showLyrics {
                    Text("Play a song to see its lyrics.")
                        .font(.subheadline).foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    if let song = musicManager.currentSong {
                        ArtworkView(song: song, size: 290, cornerRadius: 16, fallbackSystemName: "music.note.list")
                            .shadow(color: Color.black.opacity(0.5), radius: 25, x: 0, y: 18)
                            .padding(.top, 10)
                            .rotation3DEffect(
                                .degrees(musicManager.isPlaying ? 3 : 0),
                                axis: (x: 0, y: 1, z: 0)
                            )
                            .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true),
                                       value: musicManager.isPlaying)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(musicManager.currentSong?.title ?? "Unknown")
                            .font(.system(size: 22, weight: .bold)).foregroundColor(.white).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(musicManager.currentSong?.artist.isEmpty == false ? musicManager.currentSong!.artist : "AS Music")
                                .font(.subheadline).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                            if let g = musicManager.currentSong?.genre, !g.isEmpty {
                                Text(g)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(AppTheme.accent.opacity(0.9))
                                    .lineLimit(1)
                            }
                            if musicManager.isPlaying && !showLyrics { VisualizerView().padding(.leading, 4) }
                        }
                    }
                    Spacer()
                    HStack(spacing: 16) {
                        Button { showLyrics.toggle() } label: {
                            Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                                .font(.title3).foregroundColor(showLyrics ? AppTheme.accent : .white)
                        }
                        if let song = musicManager.currentSong {
                            Button { musicManager.toggleFavorite(song: song) } label: {
                                Image(systemName: musicManager.isFavorite(song: song) ? "heart.fill" : "heart")
                                    .font(.title3).foregroundColor(musicManager.isFavorite(song: song) ? .pink : .white)
                            }
                        }
                        AirPlayButton().frame(width:28,height:26).tint(.white)
                    }
                }.padding(.horizontal, 30)

                VStack(spacing: 5) {
                    Slider(value: Binding(
                        get: { musicManager.isSeeking ? musicManager.seekPreviewTime : musicManager.currentTime },
                        set: { v in
                            if musicManager.isSeeking { musicManager.seekPreviewTime = v }
                            else { musicManager.currentTime = v }
                        }),
                           in: 0...(musicManager.duration > 0 && !musicManager.duration.isNaN ? musicManager.duration : 1),
                           onEditingChanged: { editing in
                               if editing {
                                   musicManager.beginSeek(to: musicManager.currentTime)
                               } else {
                                   musicManager.endSeek(to: musicManager.seekPreviewTime)
                               }
                           }).accentColor(.white)
                    HStack {
                        Text(musicManager.formatTime(musicManager.currentTime)).font(.caption).foregroundColor(.gray)
                        Spacer()
                        Text(musicManager.formatTime(musicManager.duration)).font(.caption).foregroundColor(.gray)
                    }
                }.padding(.horizontal, 30)

                if !showLyrics {
                    SpectrumView()
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 32) {
                    Button { musicManager.isShuffle.toggle() } label: {
                        Image(systemName: "shuffle").font(.title2)
                            .foregroundColor(musicManager.isShuffle ? .green : .white.opacity(0.5))
                    }
                    Button { musicManager.playPrevious() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 32)).foregroundColor(.white)
                    }
                    Button { musicManager.togglePlayPause() } label: {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 76, height: 76)
                            Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                                .resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28).foregroundColor(.black)
                        }
                    }
                    Button { musicManager.playNext() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 32)).foregroundColor(.white)
                    }
                    Button { musicManager.toggleRepeat() } label: {
                        Image(systemName: musicManager.repeatMode == .one ? "repeat.1" : "repeat").font(.title2)
                            .foregroundColor(musicManager.repeatMode == .off ? .white.opacity(0.5) : .green)
                    }
                }.padding(.top, 4)
                HStack(spacing: 10) {
                    Button { musicManager.toggleSmartRadio() } label: {
                        Label("Smart Radio", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption).foregroundColor(musicManager.smartRadioMode ? .black : .white.opacity(0.9))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(musicManager.smartRadioMode ? AppTheme.accent.opacity(1) : Color.white.opacity(0.15))
                            .cornerRadius(20)
                    }
                    Button { musicManager.cyclePlaybackRate() } label: {
                        Text(String(format: "%.2gx", musicManager.playbackRate))
                            .font(.caption).foregroundColor(abs(musicManager.playbackRate - 1.0) < 0.01 ? .white.opacity(0.8) : AppTheme.accent)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(abs(musicManager.playbackRate - 1.0) < 0.01 ? Color.white.opacity(0.15) : AppTheme.accent.opacity(0.3))
                            .cornerRadius(20)
                    }
                    Button { musicManager.spatialEnhance.toggle() } label: {
                        Image(systemName: musicManager.spatialEnhance ? "speaker.wave.3.fill" : "speaker.wave.2")
                            .font(.caption).foregroundColor(musicManager.spatialEnhance ? AppTheme.accent : .white.opacity(0.8))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(musicManager.spatialEnhance ? AppTheme.accent.opacity(0.3) : Color.white.opacity(0.15))
                            .cornerRadius(20)
                    }
                    if musicManager.sleepTimerMinutes > 0 {
                        Text("\(musicManager.sleepTimerMinutes)m").font(.caption).foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 12).padding(.vertical, 6).background(AppTheme.accent).cornerRadius(20)
                    }
                    Text(musicManager.eqPreset.rawValue).font(.caption).foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Color.white.opacity(0.15)).cornerRadius(20)
                }
                Spacer()
            }
        }
        // Lyrics are loaded by LiveLyricsView itself (offline cache first,
        // then lrclib) — no need to prefetch a second copy here.
        .sheet(isPresented: $showEQ) {
            NavigationView { EQView() }.environmentObject(musicManager)
        }
        .sheet(isPresented: $showTheme) {
            NavigationView { ThemePickerView() }.environmentObject(musicManager)
        }
        .sheet(isPresented: $showStudio) {
            NavigationView { VocalStudioView() }.environmentObject(musicManager)
        }
        .sheet(isPresented: $showArtistInfo) {
            if let song = musicManager.currentSong {
                NavigationView { ArtistInfoView(artist: song.artist, genre: song.genre) }
            }
        }
    }

    private func isRTL(_ text: String) -> Bool {
        var rtl = 0; var total = 0
        for c in text.prefix(400) {
            guard let sv = c.unicodeScalars.first?.value else { continue }
            if (0x0600...0x06FF).contains(sv) || (0x0750...0x077F).contains(sv)
                || (0x08A0...0x08FF).contains(sv) || (0xFB50...0xFDFF).contains(sv)
                || (0xFE70...0xFEFF).contains(sv) || (0x0590...0x05FF).contains(sv) {
                rtl += 1; total += 1
            } else if c.isLetter { total += 1 }
        }
        return total > 5 && Double(rtl) / Double(total) > 0.25
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.activeTintColor = UIColor(AppTheme.accent)
        v.tintColor = .white
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = UIColor(AppTheme.accent)
    }
}

struct EQView: View {
    @EnvironmentObject var mm: MusicManager
    @Environment(\.presentationMode) var pm
    @ObservedObject private var ai = GeminiAI.shared
    @AppStorage("asmusic_autoresume") private var autoResume: Bool = false
    var body: some View {
        List {
            Section(header: Text("Equalizer Preset")) {
                ForEach(EQPreset.allCases) { p in
                    Button {
                        mm.eqPreset = p
                    } label: {
                        HStack {
                            Text(p.rawValue).foregroundColor(.primary)
                            Spacer()
                            if mm.eqPreset == p { Image(systemName: "checkmark").foregroundColor(AppTheme.accent) }
                        }
                    }
                }
            }
            Section(header: Text("Loudness Boost"),
                    footer: Text("Adds clean gain (0 = no boost, +3 to +6 dB for quieter Arabic masters, -dB for noisy sources).")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Preamp").foregroundColor(.primary)
                        Spacer()
                        Text(String(format: "%+.1f dB", mm.preampDB))
                            .foregroundColor(.secondary).font(.subheadline.monospacedDigit())
                    }
                    Slider(value: Binding(
                        get: { mm.preampDB },
                        set: { mm.preampDB = $0 }
                    ), in: -12...9, step: 0.5)
                    .tint(AppTheme.accent)
                }
            }
            Section(header: Text("Between songs"),
                    footer: Text(mm.transitionMode.subtitle)) {
                Picker("Transition", selection: Binding(
                    get: { mm.transitionMode },
                    set: { mm.transitionMode = $0 }
                )) {
                    ForEach(TransitionMode.allCases) { m in
                        Label(m.title, systemImage: m.icon).tag(m)
                    }
                }
                .pickerStyle(.menu)

                if mm.transitionMode.blends {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(mm.transitionMode == .autoDJ
                                 ? LocalizedStringKey("Maximum blend")
                                 : LocalizedStringKey("Blend length"))
                                .foregroundColor(.primary)
                            Spacer()
                            Text(String(format: "%.1f s", mm.crossfadeSeconds))
                                .foregroundColor(.secondary).font(.subheadline.monospacedDigit())
                        }
                        Slider(value: Binding(
                            get: { mm.crossfadeSeconds },
                            set: { mm.crossfadeSeconds = $0 }
                        ), in: 1.5...12, step: 0.5)
                        .tint(AppTheme.accent)
                    }
                }
            }
            Section(header: Text("Audio Enhancements"),
                    footer: Text("Spatial adds a subtle hall reverb that widens the stereo image on headphones and car speakers.")) {
                Toggle(isOn: Binding(
                    get: { mm.spatialEnhance },
                    set: { mm.spatialEnhance = $0 }
                )) {
                    Label("Spatial / 3D sound", systemImage: "speaker.wave.3.fill")
                }
                Toggle(isOn: $autoResume) {
                    Label("Resume last song on launch", systemImage: "arrow.counterclockwise")
                }
            }
            Section(header: Text("AI Music Assistant (optional)"),
                    footer: Text(ai.isConfigured
                                 ? "AI is on (\(ai.activeLabel) · \(ai.provider == .apinex ? ai.apinexModel : ai.model)). Providers, keys and models now live in the Settings tab."
                                 : "Off — add a free key in the Settings tab. APInex gives you 20+ models (GPT, Gemini, DeepSeek, GLM…) incl. free tiers with ONE key.")) {
                Button {
                    pm.wrappedValue.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NotificationCenter.default.post(name: .openAISettings, object: nil)
                    }
                } label: {
                    Label("Open AI Intelligence settings", systemImage: "brain.head.profile")
                }
            }
            VoiceSettingsSection()
            Section(footer: Text("Tip: the Vocal & Sound Studio sheet adds per-song corrections on top of these presets. Arabic/Maqaam boosts oud/qanun highs while keeping warm lows — great for Amr Diab, Sherine, Nancy Ajram.")) {
                EmptyView()
            }
        }
        .navigationTitle("Audio Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { pm.wrappedValue.dismiss() }
            }
        }
    }
}

struct ThemePickerView: View {
    @EnvironmentObject var mm: MusicManager
    @Environment(\.presentationMode) var pm
    var body: some View {
        List {
            Section(header: Text("App Accent Color")) {
                ForEach(AppAccent.list) { a in
                    Button {
                        mm.accent = a
                    } label: {
                        HStack {
                            Circle().fill(Color(red:a.r, green:a.g, blue:a.b)).frame(width:28,height:28)
                            Text(a.name).foregroundColor(.primary).padding(.leading,6)
                            Spacer()
                            if mm.accent.id == a.id { Image(systemName: "checkmark").foregroundColor(AppTheme.accent) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { pm.wrappedValue.dismiss() }
            }
        }
    }
}



// ---------------------------------------------------------------------------
// MARK: - Library
// ---------------------------------------------------------------------------

/// How the All-Songs section is ordered. Persisted, applied live.
enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "Title"
    case artist = "Artist"
    case recent = "Recently added"
    case mostPlayed = "Most played"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .title: return "textformat"
        case .artist: return "person"
        case .recent: return "clock"
        case .mostPlayed: return "flame"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var musicManager: MusicManager
    @Environment(\.layoutDirection) private var layoutDirection
    @ObservedObject private var doctor = LibraryDoctor.shared
    @ObservedObject private var trash = LibraryTrash.shared
    @State private var showingOptionsFor: Song?
    @State private var showingRenameFor: Song?
    @State private var newNameInput = ""
    @State private var searchText = ""
    @State private var showDuplicateDoctor = false
    @State private var showRecentlyDeleted = false
    @State private var showHealth = false
    @State private var showBackup = false
    @State private var showArtists = false
    @State private var showNameTidy = false
    @State private var songToEdit: Song? = nil
    @State private var showImporter = false
    @State private var showIdentify = false
    @State private var importNote: String? = nil
    @AppStorage("asmusic_lib_sort") private var sortRaw: String = LibrarySort.title.rawValue
    @AppStorage("asmusic_lib_filter") private var filterRaw: String = LibraryFilter.all.rawValue

    private var currentFilter: LibraryFilter { LibraryFilter(rawValue: filterRaw) ?? .all }

    private var filterBinding: Binding<LibraryFilter> {
        Binding(get: { LibraryFilter(rawValue: filterRaw) ?? .all },
                set: { filterRaw = $0.rawValue })
    }

    private var filterCounts: [LibraryFilter: Int] {
        var out: [LibraryFilter: Int] = [:]
        for f in LibraryFilter.allCases {
            out[f] = applyLibraryFilter(f, to: musicManager.songs).count
        }
        return out
    }

    /// Songs with a messy name, no artist or no genre — the ones the
    /// identifier can actually improve.
    private var unknownCount: Int {
        SongIdentifier.candidates(from: musicManager.songs).count
    }

    /// Searches title AND artist AND genre, ranked by where the match is —
    /// a title hit beats an artist hit beats a genre hit. The lens (All / New /
    /// Unplayed / …) is applied first, so search works inside it.
    var filteredSongs: [Song] {
        let base = applyLibraryFilter(currentFilter, to: musicManager.songs)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sorted(base) }
        func score(_ s: Song) -> Int {
            let t = s.title.lowercased()
            let a = s.artist.lowercased()
            let g = (s.genre ?? "").lowercased()
            if t.hasPrefix(q) { return 4 }
            if t.contains(q) { return 3 }
            if a.contains(q) { return 2 }
            if g.contains(q) { return 1 }
            return 0
        }
        return base
            .compactMap { s -> (song: Song, rank: Int)? in
                let r = score(s)
                return r > 0 ? (s, r) : nil
            }
            .sorted { l, r in
                if l.rank != r.rank { return l.rank > r.rank }
                return l.song.title.localizedCaseInsensitiveCompare(r.song.title) == .orderedAscending
            }
            .map { $0.song }
    }

    private var emptyReason: String {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return currentFilter == .all
                ? "No matches for “\(q)”"
                : "No “\(q)” in \(currentFilter.rawValue)"
        }
        return "Nothing in \(currentFilter.rawValue) yet"
    }

    private var emptyHint: String {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return currentFilter.explanation + " Tap All to see the whole library."
        }
        return "Search looks at titles, artists and genres."
    }

    private func sorted(_ list: [Song]) -> [Song] {
        switch LibrarySort(rawValue: sortRaw) ?? .title {
        case .title:
            return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return list.sorted {
                let cmp = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if cmp == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return cmp == .orderedAscending
            }
        case .recent:
            return list.sorted { modDate($0.url) > modDate($1.url) }
        case .mostPlayed:
            return list.sorted {
                let lp = ListenHistory.shared.playCount(for: $0)
                let rp = ListenHistory.shared.playCount(for: $1)
                if lp != rp { return lp > rp }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    private var recentlyPlayed: [Song] {
        ListenHistory.shared.recentSongs(limit: 5)
    }

    var body: some View {
        NavigationView {
            List {
                if musicManager.songs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.system(size: 48)).foregroundColor(AppTheme.accent)
                        Text("Your Library is Empty").font(.title2).bold()
                        Text("Use Magic DL or Web Hub to download songs")
                            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }.padding(.vertical, 60).frame(maxWidth: .infinity)
                }
                // One-tap undo right after a delete — the file is still in
                // Recently Deleted, this just saves a trip to the menu.
                if let justDeleted = trash.items.first,
                   Date().timeIntervalSince(justDeleted.deletedAt) < 30 {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "trash.slash").foregroundColor(AppTheme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Deleted “\(justDeleted.title)”")
                                    .font(.caption.bold()).lineLimit(1)
                                Text("It's in Recently Deleted — nothing is gone yet.")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Undo") { _ = trash.restore(justDeleted) }
                                .font(.caption.bold())
                                .foregroundColor(AppTheme.accent)
                        }
                    }
                }
                if !recentlyPlayed.isEmpty {
                    Section {
                        ForEach(recentlyPlayed) { song in
                            songRow(song, isQueued: false)
                        }
                    } header: {
                        Label("Recently Played", systemImage: "clock.arrow.circlepath")
                    }
                }

                // The duplicate check used to live only as a small icon in the
                // nav bar, which is exactly why it kept being reported as
                // "missing". It is now a labelled row in the library itself.
                if !musicManager.songs.isEmpty {
                    Section {
                        Button { showDuplicateDoctor = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.on.doc")
                                    .font(.body)
                                    .foregroundColor(doctor.redundantCount > 0 ? .red : AppTheme.accent)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doctor.redundantCount > 0
                                         ? "Duplicates found — \(doctor.redundantCount) extra copies"
                                         : "Check for duplicate songs")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.primary)
                                    Text(doctor.redundantCount > 0
                                         ? "\(doctor.groups.count) group\(doctor.groups.count == 1 ? "" : "s") · \(DoctorFormat.mb(doctor.totalReclaimable)) to reclaim · you decide what goes"
                                         : "Compares names, then how the files actually sound.")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                if doctor.isScanning {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    // .forward instead of .right so it points
                                    // the correct way in Arabic (RTL).
                                    Image(systemName: "chevron.forward")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Button { musicManager.shuffleAll() } label: {
                                Label("Shuffle all", systemImage: "shuffle")
                            }
                            Spacer()
                            Button { PlayQueues.play(filteredSongs, shuffled: false) } label: {
                                Label("Play \(filteredSongs.count)", systemImage: "play.fill")
                            }
                            .disabled(filteredSongs.isEmpty)
                            Spacer()
                            Button { showArtists = true } label: {
                                Label("Artists", systemImage: "person.2")
                            }
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(AppTheme.accent)
                        .buttonStyle(.borderless)
                    } header: {
                        Label("Library tools", systemImage: "wrench.and.screwdriver")
                    }
                }

                if !musicManager.songs.isEmpty {
                    Section {
                        FilterChipRow(selection: filterBinding) { f in filterCounts[f] ?? 0 }
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                        if currentFilter != .all {
                            Text(currentFilter.explanation)
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Section {
                    if !musicManager.upNextQueue.isEmpty {
                        ForEach(musicManager.upNextQueue) { song in
                            songRow(song, isQueued: true)
                        }
                    }
                } header: {
                    if !musicManager.upNextQueue.isEmpty {
                        HStack {
                            Text("Up Next")
                            Spacer()
                            Button("Clear") { musicManager.clearUpNext() }
                                .font(.caption.bold())
                                .foregroundColor(AppTheme.accent)
                        }
                    }
                }
                Section {
                    if filteredSongs.isEmpty && !musicManager.songs.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: currentFilter == .all ? "magnifyingglass" : currentFilter.icon)
                                .font(.title2).foregroundColor(.secondary)
                            Text(emptyReason)
                                .font(.subheadline).foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Text(emptyHint)
                                .font(.caption2).foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                    ForEach(filteredSongs) { song in
                        songRow(song, isQueued: false)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { musicManager.deleteSong(song) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { musicManager.toggleFavorite(song: song) } label: {
                                    Label(musicManager.isFavorite(song: song) ? "Unfav" : "Like",
                                          systemImage: musicManager.isFavorite(song: song) ? "heart.slash" : "heart")
                                }.tint(AppTheme.accent)
                                Button { musicManager.playNext(song) } label: {
                                    Label("Play Next", systemImage: "text.insert")
                                }.tint(.blue)
                            }
                            .contextMenu {
                                Button { musicManager.playSong(song) } label: { Label("Play Now", systemImage: "play.fill") }
                                Button { musicManager.playNext(song) } label: { Label("Play Next", systemImage: "text.insert") }
                                Button { musicManager.playLater(song) } label: { Label("Play Later", systemImage: "text.append") }
                                Button { musicManager.toggleFavorite(song: song) } label: {
                                    Label(musicManager.isFavorite(song: song) ? "Remove from Liked" : "Add to Liked",
                                          systemImage: musicManager.isFavorite(song: song) ? "heart.slash" : "heart")
                                }
                                Menu("Add to Playlist") {
                                    ForEach(musicManager.playlists) { pl in
                                        Button(pl.name) { musicManager.addSongToPlaylist(song: song, playlist: pl) }
                                    }
                                }
                                Button { musicManager.shareSong(song) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                Button { _ = AcousticRadio.play(similarTo: song) } label: {
                                    Label("More like this", systemImage: "waveform.path.ecg")
                                }
                                Button { showingRenameFor = song; newNameInput = song.title } label: { Label("Rename", systemImage: "pencil") }
                                Button { songToEdit = song } label: { Label("Song info…", systemImage: "info.circle") }
                                Divider()
                                Button(role: .destructive) { musicManager.deleteSong(song) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                } header: {
                    if !musicManager.songs.isEmpty {
                        let q = searchText.trimmingCharacters(in: .whitespaces)
                        if q.isEmpty {
                            Text("\(musicManager.songs.count) songs · by \(LibrarySort(rawValue: sortRaw)?.rawValue ?? "Title")")
                        } else {
                            Text("\(filteredSongs.count) of \(musicManager.songs.count) songs")
                        }
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles, artists, genres")
            .navigationTitle("Your Library").onAppear {
                musicManager.loadSongs()
                ITunesEnricher.shared.enrichLibrary()
                // Cheap background pass: badge the duplicate button when the
                // library visibly contains double downloads.
                LibraryDoctor.shared.autoScan()
            }
            .refreshable {
                musicManager.loadSongs()
                ITunesEnricher.shared.enrichLibrary()
                LibraryDoctor.shared.scan()
            }
            .sheet(isPresented: $showDuplicateDoctor) {
                DuplicateReviewView().environmentObject(musicManager)
            }
            .sheet(isPresented: $showRecentlyDeleted) {
                RecentlyDeletedView()
            }
            .sheet(isPresented: $showHealth) {
                LibraryHealthView().environmentObject(musicManager)
            }
            .sheet(isPresented: $showBackup) {
                BackupView().environmentObject(musicManager)
            }
            .sheet(isPresented: $showArtists) {
                ArtistsBrowserView().environmentObject(musicManager)
            }
            .sheet(isPresented: $showNameTidy) {
                NameTidyView().environmentObject(musicManager)
            }
            .sheet(isPresented: $showIdentify) {
                IdentifySongsView().environmentObject(musicManager)
            }
            .sheet(item: $songToEdit) { song in
                SongInfoEditorView(song: song).environmentObject(musicManager)
            }
            // Bring your own music in: multi-select from the Files app.
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let r = musicManager.importAudioFiles(from: urls)
                    if r.imported > 0 {
                        importNote = "Imported \(r.imported) song\(r.imported == 1 ? "" : "s")"
                            + (r.skipped > 0 ? " · \(r.skipped) skipped (already here or unsupported)" : "")
                    } else if r.skipped > 0 {
                        importNote = "Nothing imported — \(r.skipped) file\(r.skipped == 1 ? " was" : "s were") already in your Library or not audio."
                    }
                case .failure(let err):
                    importNote = "Import failed: \(err.localizedDescription)"
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { note in
                let n = (note.userInfo?["count"] as? Int) ?? 0
                if n > 0 { importNote = "Imported \(n) song\(n == 1 ? "" : "s") from another app" }
            }
            .alert("Import", isPresented: Binding(get: { importNote != nil },
                                                  set: { if !$0 { importNote = nil } })) {
                Button("OK", role: .cancel) { importNote = nil }
            } message: {
                Text(importNote ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showDuplicateDoctor = true } label: {
                        Image(systemName: "doc.on.doc")
                            .overlay(alignment: .topTrailing) {
                                if doctor.redundantCount > 0 {
                                    Text("\(min(doctor.redundantCount, 99))")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Color.red)
                                        .clipShape(Circle())
                                        // Nudge the badge outward on whichever
                                        // side "trailing" is — +x would push it
                                        // back over the icon in Arabic (RTL).
                                        .offset(x: layoutDirection == .rightToLeft ? -9 : 9, y: -9)
                                }
                            }
                    }
                    .accessibilityLabel(doctor.redundantCount > 0
                                        ? "Find duplicate songs (\(doctor.redundantCount) found)"
                                        : "Find duplicate songs")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    VoiceSearchButton(placeholderHint: "a song in your library") { heard in
                        searchText = heard
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { musicManager.isShuffle.toggle() } label: {
                            Label(musicManager.isShuffle ? "Shuffle On" : "Shuffle Off",
                                  systemImage: "shuffle")
                        }
                        Button { musicManager.toggleSmartRadio() } label: {
                            Label(musicManager.smartRadioMode ? "Smart Radio ON" : "Smart Radio (recommended)",
                                  systemImage: "dot.radiowaves.left.and.right")
                        }
                        Divider()
                        Text("Sort by")
                        ForEach(LibrarySort.allCases) { mode in
                            Button {
                                sortRaw = mode.rawValue
                            } label: {
                                if sortRaw == mode.rawValue {
                                    Label(mode.rawValue, systemImage: "checkmark")
                                } else {
                                    Label(mode.rawValue, systemImage: mode.icon)
                                }
                            }
                        }
                        Divider()
                        Button { showImporter = true } label: {
                            Label("Import from Files", systemImage: "square.and.arrow.down")
                        }
                        Button { showIdentify = true } label: {
                            Label(unknownCount > 0
                                  ? "Identify songs (\(unknownCount))"
                                  : "Identify songs",
                                  systemImage: "waveform.badge.magnifyingglass")
                        }
                        Divider()
                        Button { showDuplicateDoctor = true } label: {
                            Label(doctor.redundantCount > 0
                                  ? "Find Duplicates (\(doctor.redundantCount) found)"
                                  : "Find Duplicates",
                                  systemImage: "doc.on.doc")
                        }
                        Button { showArtists = true } label: {
                            Label("Artists", systemImage: "person.2")
                        }
                        let messy = filterCounts[.messy] ?? 0
                        Button { showNameTidy = true } label: {
                            Label(messy > 0 ? "Tidy up names (\(messy))" : "Tidy up names",
                                  systemImage: "textformat.abc")
                        }
                        Button { showHealth = true } label: {
                            Label("Library Health", systemImage: "heart.text.square")
                        }
                        Button { showRecentlyDeleted = true } label: {
                            Label(trash.count > 0
                                  ? "Recently Deleted (\(trash.count))"
                                  : "Recently Deleted",
                                  systemImage: "trash.slash")
                        }
                        Button { showBackup = true } label: {
                            Label("Backup & Restore", systemImage: "externaldrive.badge.timemachine")
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .confirmationDialog("Options",
                isPresented: Binding(get: { showingOptionsFor != nil }, set: { if !$0 { showingOptionsFor = nil } }),
                titleVisibility: .visible) {
                    if let song = showingOptionsFor {
                        Button("Play Now") { musicManager.playSong(song) }
                        Button("Play Next") { musicManager.playNext(song) }
                        Button("Play Later") { musicManager.playLater(song) }
                        ForEach(musicManager.playlists) { pl in
                            Button("Add to \(pl.name)") { musicManager.addSongToPlaylist(song: song, playlist: pl) }
                        }
                        Button("More Like This") { _ = AcousticRadio.play(similarTo: song) }
                        Button("Rename Song") { showingRenameFor = song; newNameInput = song.title }
                        Button("Song Info…") { songToEdit = song }
                        Button("Share") { musicManager.shareSong(song) }
                        Button("Delete", role: .destructive) { musicManager.deleteSong(song) }
                    }
                    Button("Cancel", role: .cancel) {}
            }
            .alert("Rename Song",
                   isPresented: Binding(get: { showingRenameFor != nil }, set: { if !$0 { showingRenameFor = nil } })) {
                TextField("New Name", text: $newNameInput)
                Button("Save") {
                    if let song = showingRenameFor, !newNameInput.isEmpty {
                        musicManager.renameSong(song: song, newName: newNameInput)
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @ViewBuilder
    private func songRow(_ song: Song, isQueued: Bool) -> some View {
        Button { musicManager.playSong(song) } label: {
            HStack {
                ZStack(alignment: .center) {
                    ArtworkView(song: song, size: 42, cornerRadius: 6, fallbackSystemName: isQueued ? "text.insert" : "music.note")
                }
                VStack(alignment: .leading) {
                    Text(song.title).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(song.artist.isEmpty ? "AS Music" : song.artist).font(.caption).foregroundColor(.gray).lineLimit(1)
                        if musicManager.isFavorite(song: song) {
                            Image(systemName: "heart.fill").font(.caption2).foregroundColor(.pink)
                        }
                    }
                }
                Spacer()
            }.contentShape(Rectangle())
        }.buttonStyle(BorderlessButtonStyle())
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject var musicManager: MusicManager
    var playlist: Playlist
    @Environment(\.presentationMode) var pm
    @State private var confirmDelete = false
    @State private var showRename = false
    @State private var renameText = ""

    /// Live copy from the manager, so renames/deletes reflect immediately.
    private var live: Playlist {
        musicManager.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }
    /// Ordered by the playlist itself — smart playlists are DJ-ordered, so
    /// re-sorting them by title would throw the flow away.
    var songsInPlaylist: [Song] {
        live.songIDs.compactMap { id in musicManager.songs.first(where: { $0.id == id }) }
    }
    private var isProtected: Bool { live.name == "Liked Songs" }

    private var totalMinutes: Int? {
        var total = 0.0
        var known = 0
        for s in songsInPlaylist {
            if let d = AudioLab.shared.features(for: s)?.duration, d > 0 {
                total += d
                known += 1
            }
        }
        guard known > 0 else { return nil }
        return Int((total / 60).rounded())
    }

    var body: some View {
        List {
            if songsInPlaylist.isEmpty {
                Text("No songs yet. Add from Library.").foregroundColor(.secondary).padding()
            }
            ForEach(Array(songsInPlaylist.enumerated()), id: \.element.id) { index, song in
                Button { musicManager.playSong(song) } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption2).foregroundColor(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        ArtworkView(song: song, size: 40, cornerRadius: 5, fallbackSystemName: "music.note")
                        VStack(alignment: .leading) {
                            Text(song.title).foregroundColor(.primary).lineLimit(1)
                            Text(song.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .contextMenu {
                    Button { musicManager.playNext(song) } label: { Label("Play Next", systemImage: "text.insert") }
                    Button { musicManager.playLater(song) } label: { Label("Play Later", systemImage: "text.append") }
                }
            }
            .onDelete { indexSet in
                if let pIndex = musicManager.playlists.firstIndex(where: { $0.id == live.id }) {
                    let ids = indexSet.compactMap { i -> UUID? in
                        i < songsInPlaylist.count ? songsInPlaylist[i].id : nil
                    }
                    musicManager.playlists[pIndex].songIDs.removeAll { ids.contains($0) }
                    musicManager.savePlaylists()
                }
            }
        }
        .navigationTitle(live.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if !songsInPlaylist.isEmpty {
                        Button {
                            musicManager.playPlaylist(live)
                        } label: { Image(systemName: "play.fill") }
                        .accessibilityLabel("Play playlist in order")
                        Button {
                            musicManager.isShuffle = true
                            musicManager.playPlaylist(live)
                        } label: { Image(systemName: "shuffle") }
                        .accessibilityLabel("Shuffle playlist")
                    }
                    if !isProtected {
                        Menu {
                            Button {
                                renameText = live.name
                                showRename = true
                            } label: { Label("Rename Playlist", systemImage: "pencil") }
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: { Label("Delete Playlist", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !songsInPlaylist.isEmpty {
                HStack(spacing: 6) {
                    Text("\(songsInPlaylist.count) songs")
                    if let mins = totalMinutes {
                        Text("· about \(mins) min")
                    }
                    if SmartPlaylistStore.shared.isSmart(live.id) {
                        Label("smart order", systemImage: "sparkles")
                    }
                    Spacer()
                }
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(.bar)
            }
        }
        .alert("Delete Playlist?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                musicManager.deletePlaylist(live)
                pm.wrappedValue.dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("“\(live.name)” (\(songsInPlaylist.count) songs) will be removed. The songs themselves stay in your Library.")
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Playlist Name", text: $renameText)
            Button("Save") {
                if !renameText.isEmpty { musicManager.renamePlaylist(live, to: renameText) }
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var engine = SmartPlaylistEngine.shared
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var showAsk = false
    @State private var askText = ""
    @State private var confirm: PlaylistConfirm? = nil
    @State private var playlistToRename: Playlist? = nil
    @State private var renameText = ""

    // Multi-select ("Select" in the toolbar) — delete ten AI experiments in
    // one go instead of swiping ten times.
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @AppStorage("asmusic_pl_sort") private var sortRaw: String = PlaylistSort.custom.rawValue

    /// Every playlist except the protected "Liked Songs" — looked up by name,
    /// never by position, so deleting lists can't shift the wrong one in.
    private var userPlaylists: [Playlist] {
        let base = musicManager.playlists.filter { $0.name != "Liked Songs" }
        switch PlaylistSort(rawValue: sortRaw) ?? .custom {
        case .custom: return base
        case .name:   return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:   return base.sorted { $0.songIDs.count > $1.songIDs.count }
        case .smart:  return base.sorted { a, b in
            let sa = SmartPlaylistStore.shared.isSmart(a.id) ? 1 : 0
            let sb = SmartPlaylistStore.shared.isSmart(b.id) ? 1 : 0
            if sa != sb { return sa > sb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        }
    }

    private var smartPlaylists: [Playlist] {
        userPlaylists.filter { SmartPlaylistStore.shared.isSmart($0.id) }
    }

    private var songByID: [UUID: Song] {
        Dictionary(musicManager.songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Explains the ✨ badges and gives a manual "rebuild now" escape hatch.
    private var smartFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("✨ Sparkled playlists are built by the app from how your songs actually sound (energy, tempo, brightness, vocal focus). Toggle the sparkle in the bar above to turn auto-creation on or off. Swipe any playlist to delete it, or use Select to remove several at once — deleted smart playlists stay deleted.")
                .font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 10) {
                Button("Rebuild smart playlists now") {
                    SmartPlaylistStore.shared.unretireAll()
                    SmartPlaylistEngine.shared.rebuild(force: true)
                    _ = SmartPlaylistEngine.shared.applyAll()
                }
                .font(.caption.bold())
                Button("Describe a playlist…") { showAsk = true }
                    .font(.caption.bold())
            }
            .foregroundColor(AppTheme.accent)
            if let note = engine.lastNote {
                Text(note).font(.caption2).foregroundColor(.green)
            }
            if let err = engine.lastError {
                Text(err).font(.caption2).foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                List {
                    if !selecting {
                        Section {
                            NavigationLink(destination: LikedSongsView()) {
                                HStack {
                                    Image(systemName: "heart.fill").foregroundColor(.pink).font(.title2).frame(width:36)
                                    VStack(alignment:.leading) {
                                        Text("Liked Songs").font(.headline)
                                        let liked = musicManager.playlists
                                            .first(where: { $0.name == "Liked Songs" })?.songIDs.count ?? 0
                                        Text("\(liked) songs").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        Section(header: Label("AI Playlist Generator", systemImage: "wand.and.stars")) {
                            PlaylistAICard()
                        }
                    }

                    Section(header: listHeader, footer: smartFooter) {
                        if userPlaylists.isEmpty {
                            Text("No playlists yet — let the AI build one above, or tap +.")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        ForEach(userPlaylists) { playlist in
                            if selecting {
                                Button { toggle(playlist) } label: { playlistRow(playlist) }
                                    .buttonStyle(.plain)
                            } else {
                                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                                    playlistRow(playlist)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        confirm = .single(playlist)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        playlistToRename = playlist
                                        renameText = playlist.name
                                    } label: { Label("Rename", systemImage: "pencil") }
                                        .tint(.blue)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        musicManager.playPlaylist(playlist)
                                    } label: { Label("Play", systemImage: "play.fill") }
                                        .tint(AppTheme.accent)
                                    Button {
                                        musicManager.shufflePlaylist(playlist)
                                    } label: { Label("Shuffle", systemImage: "shuffle") }
                                        .tint(.indigo)
                                }
                                .contextMenu {
                                    Button {
                                        musicManager.playPlaylist(playlist)
                                    } label: { Label("Play", systemImage: "play.fill") }
                                    Button {
                                        musicManager.shufflePlaylist(playlist)
                                    } label: { Label("Shuffle Play", systemImage: "shuffle") }
                                    if let request = engine.request(forPlaylist: playlist.id) {
                                        Button {
                                            engine.generate(from: request) { _ in }
                                        } label: { Label("Regenerate with AI", systemImage: "arrow.triangle.2.circlepath") }
                                    }
                                    Button {
                                        playlistToRename = playlist
                                        renameText = playlist.name
                                    } label: { Label("Rename", systemImage: "pencil") }
                                    Button {
                                        selecting = true
                                        selected = [playlist.id]
                                    } label: { Label("Select…", systemImage: "checkmark.circle") }
                                    Divider()
                                    Button(role: .destructive) {
                                        confirm = .single(playlist)
                                    } label: { Label("Delete Playlist", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }

                if !musicManager.recentlyDeletedPlaylists.isEmpty {
                    undoBanner
                }
                if selecting {
                    selectionBar
                }
            }
            .alert("Describe a playlist", isPresented: $showAsk) {
                TextField("“quiet arabic for a drive”, “جيم حماسية”", text: $askText)
                Button("Build it") {
                    let text = askText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        SmartPlaylistEngine.shared.generate(from: text) { _ in }
                    }
                    askText = ""
                }
                Button("Cancel", role: .cancel) { askText = "" }
            } message: {
                Text("Built from the songs already in your Library — offline if you have no AI key set.")
            }
            // One alert drives every destructive confirmation: SwiftUI only
            // reliably presents a single alert per view, and stacking five of
            // them is how "the delete button does nothing" bugs happen.
            .alert(confirmTitle,
                   isPresented: Binding(get: { confirm != nil },
                                        set: { if !$0 { confirm = nil } })) {
                Button("Delete", role: .destructive) { runConfirm() }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: {
                Text(confirmMessage)
            }
            .alert("Rename Playlist",
                   isPresented: Binding(get: { playlistToRename != nil },
                                        set: { if !$0 { playlistToRename = nil } })) {
                TextField("Playlist Name", text: $renameText)
                Button("Save") {
                    if let p = playlistToRename, !renameText.isEmpty {
                        musicManager.renamePlaylist(p, to: renameText)
                    }
                    playlistToRename = nil
                }
                Button("Cancel", role: .cancel) { playlistToRename = nil }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !userPlaylists.isEmpty {
                        Button(selecting ? "Done" : "Select") {
                            withAnimation {
                                selecting.toggle()
                                if !selecting { selected = [] }
                            }
                        }
                        .font(.subheadline.bold())
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingNewPlaylist = true } label: { Image(systemName: "plus") }
                        .disabled(selecting)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Toggle(isOn: Binding(get: { engine.autoCreate },
                                             set: { engine.autoCreate = $0 })) {
                            Label("Auto-create ✨ playlists", systemImage: "sparkles")
                        }
                        Toggle(isOn: Binding(get: { engine.flowOrdering },
                                             set: { engine.flowOrdering = $0 })) {
                            Label("Order tracks like a DJ set", systemImage: "waveform.path.ecg")
                        }
                        Divider()
                        Text("Sort playlists")
                        ForEach(PlaylistSort.allCases) { mode in
                            Button {
                                sortRaw = mode.rawValue
                            } label: {
                                if sortRaw == mode.rawValue {
                                    Label(mode.label, systemImage: "checkmark")
                                } else {
                                    Label(mode.label, systemImage: mode.icon)
                                }
                            }
                        }
                        Divider()
                        Button {
                            SmartPlaylistStore.shared.unretireAll()
                            SmartPlaylistEngine.shared.rebuild(force: true)
                            _ = SmartPlaylistEngine.shared.applyAll()
                        } label: { Label("Rebuild ✨ playlists", systemImage: "arrow.clockwise") }
                        if !smartPlaylists.isEmpty {
                            Button(role: .destructive) {
                                confirm = .allSmart
                            } label: { Label("Delete all ✨ playlists", systemImage: "trash") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("New Playlist", isPresented: $showingNewPlaylist) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Create") {
                    if !newPlaylistName.isEmpty { musicManager.createPlaylist(name: newPlaylistName); newPlaylistName = "" }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: Pieces

    private var listHeader: some View {
        HStack {
            Text(selecting ? "\(selected.count) selected" : "My Playlists")
            Spacer()
            if selecting {
                Button(selected.count == userPlaylists.count ? "None" : "All") {
                    selected = selected.count == userPlaylists.count
                        ? []
                        : Set(userPlaylists.map { $0.id })
                }
                .font(.caption.bold())
                .foregroundColor(AppTheme.accent)
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Button(role: .destructive) {
                confirm = .bulk
            } label: {
                Label("Delete \(selected.count)", systemImage: "trash")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(selected.isEmpty ? Color.gray.opacity(0.3) : Color.red.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(22)
            }
            .disabled(selected.isEmpty)
            Button {
                withAnimation { selecting = false; selected = [] }
            } label: {
                Text("Cancel")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(22)
            }
        }
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom))
    }

    private var undoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.slash").foregroundColor(.white)
            Text(musicManager.recentlyDeletedPlaylists.count == 1
                 ? "“\(musicManager.recentlyDeletedPlaylists[0].name)” deleted"
                 : "\(musicManager.recentlyDeletedPlaylists.count) playlists deleted")
                .font(.caption.bold()).foregroundColor(.white).lineLimit(1)
            Spacer()
            Button("Undo") { _ = musicManager.undoPlaylistDelete() }
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.white.opacity(0.25))
                .cornerRadius(14)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AppTheme.accent.opacity(0.95))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.bottom, selecting ? 74 : 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Destructive confirmations

    private var confirmTitle: String {
        guard let c = confirm else { return "" }
        switch c {
        case .single(let p): return "Delete “\(p.name)”?"
        case .bulk:          return "Delete \(selected.count) playlist\(selected.count == 1 ? "" : "s")?"
        case .allSmart:      return "Delete all \(smartPlaylists.count) ✨ playlists?"
        }
    }

    private var confirmMessage: String {
        guard let c = confirm else { return "" }
        switch c {
        case .single(let p):
            return "\(p.songIDs.count) song\(p.songIDs.count == 1 ? "" : "s") in this list. Your songs stay in the Library — only the list is deleted, and Undo appears right after."
        case .bulk:
            return "Only the lists go away — every song stays in your Library, and Undo appears right after."
        case .allSmart:
            return "Removes every playlist the app built for you. Your own playlists and all your songs are untouched, and the AI won't rebuild these unless you ask it to."
        }
    }

    private func runConfirm() {
        guard let c = confirm else { return }
        switch c {
        case .single(let p):
            musicManager.deletePlaylist(p)
        case .bulk:
            let n = musicManager.deletePlaylists(ids: selected)
            selected = []
            selecting = false
            if n > 0 { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        case .allSmart:
            musicManager.deletePlaylists(ids: Set(smartPlaylists.map { $0.id }))
        }
        confirm = nil
    }

    private func toggle(_ p: Playlist) {
        if selected.contains(p.id) { selected.remove(p.id) } else { selected.insert(p.id) }
    }

    /// "12 songs · 48 min" — the minutes come from the on-device analysis, so
    /// they only appear for songs the lab has already measured.
    private func subtitle(_ playlist: Playlist) -> String {
        let map = songByID
        var seconds = 0.0
        var measured = 0
        for id in playlist.songIDs {
            guard let s = map[id] else { continue }
            if let f = AudioLab.shared.features(for: s), f.duration > 0 {
                seconds += f.duration
                measured += 1
            }
        }
        var out = "\(playlist.songIDs.count) song\(playlist.songIDs.count == 1 ? "" : "s")"
        if measured > 0, seconds > 60 {
            let mins = Int(seconds / 60)
            out += measured == playlist.songIDs.count ? " · \(mins) min" : " · about \(mins) min"
        }
        return out
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 10) {
            if selecting {
                Image(systemName: selected.contains(playlist.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(selected.contains(playlist.id) ? AppTheme.accent : .secondary.opacity(0.6))
            }
            if SmartPlaylistStore.shared.isSmart(playlist.id) {
                Image(systemName: "sparkles")
                    .font(.caption2).foregroundColor(AppTheme.accent)
                    .accessibilityLabel("Smart playlist — refreshed automatically")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.headline).lineLimit(1)
                Text(subtitle(playlist)).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// What the single confirmation alert in the Playlists tab is about.
enum PlaylistConfirm {
    case single(Playlist)
    case bulk
    case allSmart
}

/// How the Playlists tab orders the list.
enum PlaylistSort: String, CaseIterable, Identifiable {
    case custom, name, size, smart
    var id: String { rawValue }
    var label: String {
        switch self {
        case .custom: return "My order"
        case .name:   return "Name"
        case .size:   return "Most songs"
        case .smart:  return "AI playlists first"
        }
    }
    var icon: String {
        switch self {
        case .custom: return "list.bullet"
        case .name:   return "textformat.abc"
        case .size:   return "number"
        case .smart:  return "sparkles"
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - AI Playlist Generator (the card at the top of the Playlists tab)
//
// One field + one button: describe the vibe ("quiet arabic for a drive",
// "جيم حماسية", "90s road trip") and the SmartPlaylistEngine builds it from
// the user's OWN library — with Gemini when a key is set, with the local
// Arabic/English parser when not. Quick mood chips and a time-of-day
// "Surprise me" give zero-typing paths to the same engine.
// ---------------------------------------------------------------------------
struct PlaylistAICard: View {
    @ObservedObject private var engine = SmartPlaylistEngine.shared
    @ObservedObject private var ai = GeminiAI.shared
    @State private var request = ""
    @State private var busy = false

    /// Chip label → the phrase actually sent to the generator.
    private let moods: [(String, String)] = [
        ("Gym", "gym hype workout fast"),
        ("Party", "farah party dance"),
        ("Chill", "chill quiet relaxing"),
        ("Focus", "focus study no vocals"),
        ("Drive", "road trip drive"),
        ("Sleep", "sleep calm slow"),
        ("Arabic", "arabic night classics"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Describe the vibe… “sad arabic for a rainy night”", text: $request)
                    .font(.subheadline)
                    .autocorrectionDisabled(false)
                    .onSubmit { generate(request) }
                Button {
                    generate(request)
                } label: {
                    Image(systemName: busy ? "hourglass" : "wand.and.stars")
                        .font(.body.bold())
                        .foregroundColor(.white)
                        .padding(9)
                        .background(canGenerate(request) ? AppTheme.accent : Color.gray.opacity(0.4))
                        .clipShape(Circle())
                }
                .disabled(!canGenerate(request))
                .accessibilityLabel("Generate AI playlist")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Surprise me", icon: "die.face.5") {
                        surprise()
                    }
                    ForEach(moods, id: \.0) { mood in
                        chip(mood.0, icon: nil) {
                            generate(mood.1)
                        }
                    }
                }
            }

            if busy {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(ai.isConfigured
                         ? "AI is listening to your library…"
                         : "Building from your library (on-device)…")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                Button {
                    NotificationCenter.default.post(name: .openAISettings, object: nil)
                } label: {
                    Text(ai.isConfigured
                         ? "AI (\(ai.activeLabel)) picks & names it · tap to change provider or model"
                         : "On-device AI · tap to add a free key (APInex: 20+ models, one key)")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let note = engine.lastNote {
                Text(note).font(.caption).foregroundColor(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = engine.lastError {
                Text(err).font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func canGenerate(_ text: String) -> Bool {
        !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func generate(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canGenerate(clean) else { return }
        busy = true
        hideKeyboard()
        engine.lastError = nil
        engine.generate(from: clean) { err in
            DispatchQueue.main.async {
                busy = false
                if err == nil { request = "" }
            }
        }
    }

    private func surprise() {
        guard !busy else { return }
        busy = true
        engine.lastError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            engine.surpriseMix()
            busy = false
        }
    }

    private func chip(_ label: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon { Image(systemName: icon).font(.caption2) }
                Text(label).font(.caption.bold())
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(AppTheme.accent.opacity(0.14))
            .foregroundColor(AppTheme.accent)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

struct LikedSongsView: View {
    @EnvironmentObject var musicManager: MusicManager
    var likedSongs: [Song] {
        guard let liked = musicManager.playlists.first(where: { $0.name == "Liked Songs" }) else { return [] }
        let ids = liked.songIDs
        return ids.compactMap { id in musicManager.songs.first(where: { $0.id == id }) }
    }
    var body: some View {
        List {
            ForEach(likedSongs) { song in
                Button { musicManager.playSong(song) } label: {
                    HStack(spacing: 10) {
                        ArtworkView(song: song, size: 40, cornerRadius: 5, fallbackSystemName: "heart.fill")
                        VStack(alignment: .leading) {
                            Text(song.title).foregroundColor(.primary).lineLimit(1)
                            Text(song.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
        }.navigationTitle("Liked Songs")
    }
}

// ---------------------------------------------------------------------------
// MARK: - Magic DL view
// ---------------------------------------------------------------------------
struct SmartDownloaderView: View {
    @StateObject var downloader = SmartDownloaderManager()
    @State private var searchInput = ""
    @State private var linkInput = ""
    @State private var nameInput = ""
    @StateObject private var dc = DownloadCenter.shared

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [.black, Color(red:0.12, green:0.05, blue:0.2)], startPoint: .top, endPoint: .bottom)
                    .edgesIgnoringSafeArea(.all)
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            Image(systemName: "sparkles").resizable().frame(width: 70, height: 70)
                                .foregroundStyle(LinearGradient(colors: [AppTheme.accent, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .padding(.top, 30)
                            Text("Smart Magic DL").font(.largeTitle.bold()).foregroundColor(.white)
                            Text("Search YouTube & SoundCloud • Paste any link").font(.subheadline).foregroundColor(.gray)
                        }

                        // Smart search bar
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                                TextField("Search songs, artists, or paste link…", text: $searchInput)
                                    .foregroundColor(.white)
                                    .autocapitalization(.none)
                                    .submitLabel(.search)
                                    .onSubmit { downloader.performMagicSearch(query: searchInput) }
                                if !searchInput.isEmpty {
                                    Button { searchInput = "" } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                                    }
                                }
                                Button("Paste") {
                                    downloader.handlePaste()
                                    if let s = UIPasteboard.general.string {
                                        searchInput = s
                                    }
                                }.font(.subheadline.bold()).foregroundColor(AppTheme.accent)
                                VoiceSearchButton(placeholderHint: "a song to download") { heard in
                                    searchInput = heard
                                    downloader.performMagicSearch(query: heard)
                                }
                            }
                            .padding()
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(16)
                            Button {
                                hideKeyboard()
                                downloader.performMagicSearch(query: searchInput)
                            } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                    Text("Magic Search").bold()
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding()
                                .background(LinearGradient(colors: [AppTheme.accent, .pink], startPoint: .leading, endPoint: .trailing))
                                .cornerRadius(16)
                            }.disabled(downloader.isSearching || searchInput.isEmpty)
                        }.padding(.horizontal)

                        // Quick Arabic artist chips
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "flame.fill").foregroundColor(.orange)
                                Text("Quick Picks").font(.subheadline.bold()).foregroundColor(.white)
                                Spacer()
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(SmartDownloaderManager.arabicArtistChips, id: \.0) { chip in
                                        Button {
                                            searchInput = chip.0
                                            downloader.performMagicSearch(query: chip.0)
                                        } label: {
                                            VStack(spacing: 2) {
                                                Text(chip.1).font(.caption2.bold()).foregroundColor(.white)
                                                Text(chip.0).font(.caption2).foregroundColor(.white.opacity(0.75))
                                            }
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(Color.white.opacity(0.1))
                                            .cornerRadius(14)
                                        }
                                    }
                                }
                            }
                        }.padding(.horizontal)

                        // Trending (region selectable — free Deezer/Piped charts)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "chart.bar.fill").foregroundColor(.green)
                                Text("Trending in \(ChartRegion(rawValue: downloader.trendRegion)?.displayName ?? "Egypt")")
                                    .font(.subheadline.bold()).foregroundColor(.white)
                                Spacer()
                                Menu {
                                    ForEach(ChartRegion.allCases) { r in
                                        Button {
                                            downloader.trendingResults = []
                                            downloader.loadTrending(region: r.rawValue)
                                        } label: {
                                            if downloader.trendRegion == r.rawValue {
                                                Label(r.displayName, systemImage: "checkmark")
                                            } else {
                                                Text(r.displayName)
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "globe").foregroundColor(AppTheme.accent).font(.caption.bold())
                                }
                                if downloader.isLoadingTrending {
                                    ProgressView().tint(.white)
                                } else {
                                    Button("Refresh") {
                                        downloader.trendingResults = []
                                        downloader.loadTrending()
                                    }.font(.caption).foregroundColor(AppTheme.accent)
                                }
                            }
                            if downloader.trendingResults.isEmpty && !downloader.isLoadingTrending {
                                Button("Load Trending") { downloader.loadTrending() }
                                    .font(.caption).foregroundColor(AppTheme.accent)
                            }
                            if !downloader.trendingResults.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(downloader.trendingResults.prefix(10)) { r in
                                            TrendingCard(result: r, downloader: downloader)
                                        }
                                    }
                                }
                            }
                        }.padding(.horizontal)

                        Text("— OR —").font(.subheadline.bold()).foregroundColor(.gray)

                        // Direct link
                        VStack(spacing: 12) {
                            TextField("Paste YouTube link (youtu.be/…)", text: $linkInput)
                                .padding()
                                .background(Color.white.opacity(0.08)).cornerRadius(12).foregroundColor(.white)
                                .autocapitalization(.none)
                            TextField("Save As (optional)", text: $nameInput)
                                .padding()
                                .background(Color.white.opacity(0.08)).cornerRadius(12).foregroundColor(.white)
                            Button {
                                downloader.requestLinkDownload(link: linkInput, name: nameInput)
                            } label: {
                                Text("Extract MP3").font(.headline).foregroundColor(.white)
                                    .frame(maxWidth: .infinity).padding()
                                    .background(Color.blue).cornerRadius(12)
                            }.disabled(linkInput.isEmpty)
                        }.padding(.horizontal)
                        Spacer().frame(height: 20)
                    }
                }
                .onAppear { downloader.loadTrending() }

                // Toast overlay
                if let msg = dc.toastMessage {
                    VStack {
                        Spacer().frame(height: 80)
                        Text(msg)
                            .font(.footnote.bold()).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.ultraThinMaterial).cornerRadius(20)
                        Spacer()
                    }
                    .transition(.opacity).animation(.easeInOut, value: dc.toastMessage)
                }

                if downloader.isSearching {
                    VStack {
                        ProgressView().tint(.white)
                        Text("Searching multiple sources…").foregroundColor(.white.opacity(0.8)).padding(.top, 8)
                    }
                    .padding(30).background(.ultraThinMaterial).cornerRadius(20)
                }

                if downloader.showSearchResults {
                    ZStack {
                        Color.black.opacity(0.97).edgesIgnoringSafeArea(.all)
                        VStack(spacing:0) {
                            HStack {
                                Text("\(downloader.searchResults.count) Results").font(.title2.bold()).foregroundColor(.white)
                                Spacer()
                                Button { downloader.downloadAllResults() } label: {
                                    Label("Download All", systemImage: "arrow.down.circle.fill")
                                        .font(.subheadline.bold()).foregroundColor(.white)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(AppTheme.accent).cornerRadius(20)
                                }
                                Button { downloader.showSearchResults = false } label: {
                                    Image(systemName: "xmark.circle.fill").font(.title).foregroundColor(.gray)
                                }
                            }.padding()
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(downloader.searchResults) { result in
                                        HStack(spacing: 12) {
                                            ZStack {
                                                if let thumb = result.thumbnail, let u = URL(string: thumb),
                                                   result.platform == "yt" {
                                                    AsyncImage(url: u) { phase in
                                                        if let im = phase.image { im.resizable().scaledToFill() }
                                                        else { generateColor(for: result.title) }
                                                    }
                                                } else {
                                                    generateColor(for: result.title)
                                                }
                                                Image(systemName: result.platform == "sc" ? "waveform" : "play.rectangle.fill")
                                                    .foregroundColor(.white).font(.title2)
                                            }
                                            .frame(width: 56, height: 56).cornerRadius(8).clipped()

                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(result.title).font(.subheadline.bold()).foregroundColor(.white).lineLimit(2)
                                                HStack(spacing: 6) {
                                                    Text(result.platform == "sc" ? "SOUNDCLOUD" : "YOUTUBE")
                                                        .font(.system(size: 9, weight: .black))
                                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                                        .background(result.platform == "sc" ? Color.orange : Color.red)
                                                        .cornerRadius(4)
                                                    Text(result.artist).font(.caption).foregroundColor(.gray).lineLimit(1)
                                                    Text(result.durationFormatted).font(.caption).foregroundColor(.gray)
                                                }
                                            }
                                            Spacer()
                                            Button { downloader.requestDownload(result: result) } label: {
                                                Image(systemName: "arrow.down.circle.fill").font(.title).foregroundColor(AppTheme.accent)
                                            }.buttonStyle(.plain)
                                        }
                                        .padding(.vertical, 8).padding(.horizontal, 12)
                                        .background(Color.white.opacity(0.06)).cornerRadius(10)
                                    }
                                }.padding(.horizontal)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Magic DL").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: EngineSettingsView()) {
                        Image(systemName: "gearshape").font(.body)
                    }
                }
            }
            .alert("Save As", isPresented: $downloader.showNamePrompt) {
                TextField("Song name", text: $downloader.nameInput)
                Button("Download") { downloader.confirmNamedDownload() }
                Button("Cancel", role: .cancel) { downloader.cancelNamePrompt() }
            } message: {
                Text("Edit the name before saving to your Library.")
            }
            .alert("Error", isPresented: $downloader.showError) {
                Button("OK", role: .cancel) { }
            } message: { Text(downloader.errorDetails) }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct TrendingCard: View {
    let result: SearchResult
    @ObservedObject var downloader: SmartDownloaderManager
    var body: some View {
        Button { downloader.requestDownload(result: result) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        if let thumb = result.thumbnail, let u = URL(string: thumb) {
                            AsyncImage(url: u) { phase in
                                if let im = phase.image { im.resizable().scaledToFill() }
                                else { generateColor(for: result.title) }
                            }
                        } else {
                            generateColor(for: result.title)
                        }
                    }
                    .frame(width: 130, height: 100).clipped().cornerRadius(10)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2).foregroundColor(.white)
                        .padding(6).shadow(radius: 3)
                }
                Text(result.title).font(.caption2.bold())
                    .foregroundColor(.white).lineLimit(2)
                    .frame(width: 130, alignment: .leading)
                Text(result.artist).font(.caption2).foregroundColor(.gray)
                    .lineLimit(1).frame(width:130, alignment:.leading)
            }
        }.buttonStyle(.plain)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Settings tab — every setting in one place
// ---------------------------------------------------------------------------

/// The Settings tab: AI Intelligence (provider · key · model · never-stop
/// failover), Audio & Playback, Voice control, Appearance, Download engines,
/// Library tools and About. Every screen that used to hide a setting behind
/// a toolbar icon is reachable from here.
struct SettingsTabView: View {
    @EnvironmentObject var musicManager: MusicManager
    @ObservedObject private var ai = GeminiAI.shared
    @State private var showBackup = false
    @State private var showHealth = false
    @State private var showDuplicates = false
    @State private var showTrash = false
    @State private var showNameTidy = false
    @State private var showArtists = false

    var body: some View {
        NavigationView {
            Form {
                AISettingsSection()
                VoiceSettingsSection()
                Section(header: Label("Audio & Playback", systemImage: "waveform"),
                        footer: Text("Same screen as from the player: EQ preset, loudness boost, spatial sound, resume.")) {
                    NavigationLink(destination: EQView()) {
                        Label("Equalizer, loudness & playback", systemImage: "slider.horizontal.3")
                    }
                }
                Section(header: Label("Appearance", systemImage: "paintpalette")) {
                    NavigationLink(destination: ThemePickerView()) {
                        Label("Accent color & theme", systemImage: "drop.fill")
                    }
                }
                Section(header: Label("Downloads", systemImage: "arrow.down.circle"),
                        footer: Text("Piped / Invidious / Cobalt / your own server, mirror lists and health — the engines that race to fetch your songs.")) {
                    NavigationLink(destination: EngineSettingsView()) {
                        Label("Download engines", systemImage: "bolt.horizontal.circle")
                    }
                }
                Section(header: Label("Library tools", systemImage: "music.note.list")) {
                    toolRow("Backup & restore", icon: "externaldrive.fill", active: $showBackup)
                    toolRow("Library health report", icon: "heart.text.square", active: $showHealth)
                    toolRow("Duplicate finder", icon: "doc.on.doc", active: $showDuplicates)
                    toolRow("Recently deleted", icon: "trash", active: $showTrash)
                    toolRow("Name tidy-up", icon: "textformat.abc", active: $showNameTidy)
                    toolRow("Artists browser", icon: "person.2.fill", active: $showArtists)
                }
                Section(header: Label("About", systemImage: "info.circle")) {
                    HStack {
                        Text("App version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Songs in library")
                        Spacer()
                        Text("\(musicManager.songs.count)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("AI provider")
                        Spacer()
                        Text(ai.isConfigured ? "\(ai.activeLabel) · \(ai.provider == .apinex ? ai.apinexModel : ai.model)" : "On-device (no key)")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showBackup) { BackupView().environmentObject(musicManager) }
            .sheet(isPresented: $showHealth) { LibraryHealthView().environmentObject(musicManager) }
            .sheet(isPresented: $showDuplicates) { DuplicateReviewView().environmentObject(musicManager) }
            .sheet(isPresented: $showTrash) { RecentlyDeletedView() }
            .sheet(isPresented: $showNameTidy) { NameTidyView().environmentObject(musicManager) }
            .sheet(isPresented: $showArtists) { ArtistsBrowserView().environmentObject(musicManager) }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func toolRow(_ title: String, icon: String, active: Binding<Bool>) -> some View {
        Button {
            active.wrappedValue = true
        } label: {
            HStack {
                Label(title, systemImage: icon).foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption).foregroundColor(Color(UIColor.tertiaryLabel))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - AI Intelligence section (provider · key · model · never-stop)
// ---------------------------------------------------------------------------

struct AISettingsSection: View {
    @ObservedObject private var ai = GeminiAI.shared
    @State private var testing = false
    @State private var testResult: String? = nil
    @State private var refreshing = false

    var body: some View {
        Section(header: Label("AI Intelligence", systemImage: "brain.head.profile"),
                footer: Text(aiFooter)) {
            Picker("Provider", selection: $ai.provider) {
                ForEach(AIProvider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            switch ai.provider {
            case .onDevice:
                Text("Everything smart still works — playlists, duplicate checks, mood picks — computed fully on this phone. Add a key below whenever you want cloud models.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .apinex:
                apinexBody
            case .gemini:
                geminiBody
            }
        }
    }

    // -- APInex -------------------------------------------------------------

    @ViewBuilder
    private var apinexBody: some View {
        SecureField("APInex key (sk-apx…)", text: $ai.apinexKey)
            .autocorrectionDisabled()
            .autocapitalization(.none)
            .font(.subheadline)

        Menu {
            ForEach(ai.apinexCatalog) { m in
                Button {
                    ai.apinexModel = m.id
                } label: {
                    Text(m.isFree ? "FREE · \(m.label) · \(m.price)" : "\(m.label) · \(m.price)")
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model").font(.caption).foregroundColor(.secondary)
                    Text(currentApinexLabel)
                        .font(.subheadline).foregroundColor(.primary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption).foregroundColor(.secondary)
            }
        }

        TextField("Custom model id (advanced)", text: $ai.apinexModel)
            .autocorrectionDisabled()
            .autocapitalization(.none)
            .font(.subheadline)

        failoverToggle

        Button {
            refreshModels()
        } label: {
            Label(refreshing ? "Refreshing model list…" : "Refresh model list (live from apinex.bond)",
                  systemImage: "arrow.clockwise")
        }
        .disabled(refreshing || ai.apinexKey.trimmingCharacters(in: .whitespaces).isEmpty)

        Button {
            testKey()
        } label: {
            Label(testing ? "Testing…" : "Test key now", systemImage: "checkmark.seal")
        }
        .disabled(testing || ai.apinexKey.trimmingCharacters(in: .whitespaces).isEmpty)

        if let r = testResult {
            Text(r).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentApinexLabel: String {
        if let m = ai.apinexCatalog.first(where: { $0.id == ai.apinexModel }) {
            return (m.isFree ? "★ FREE · " : "") + m.label + " · " + m.price
        }
        return ai.apinexModel
    }

    // -- Gemini (direct) ------------------------------------------------------

    @ViewBuilder
    private var geminiBody: some View {
        SecureField("Gemini API key (aistudio.google.com)", text: $ai.key)
            .autocorrectionDisabled()
            .autocapitalization(.none)
            .font(.subheadline)
        TextField("Model (default: gemini-3.5-flash)", text: $ai.model)
            .autocorrectionDisabled()
            .autocapitalization(.none)
            .font(.subheadline)
        Toggle(isOn: $ai.autoModel) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto model (self-healing)").font(.subheadline)
                Text("Switches to a verified newer Gemini when Google retires one.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        failoverToggle
        Button {
            testGemini()
        } label: {
            Label(testing ? "Testing…" : "Test key now", systemImage: "checkmark.seal")
        }
        .disabled(testing || ai.key.trimmingCharacters(in: .whitespaces).isEmpty)
        if let r = testResult {
            Text(r).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shared "never stop" toggle (shown for both cloud providers).
    private var failoverToggle: some View {
        Toggle(isOn: $ai.autoFailover) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-failover — never stop").font(.subheadline)
                Text("Dead or retired model → next model → other provider → on-device. One silent retry, no dead ends.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // -- Footer ----------------------------------------------------------------

    private var aiFooter: String {
        switch ai.provider {
        case .onDevice:
            return "No key, no account: nothing ever leaves this phone."
        case .apinex:
            return "Get ONE free key at apinex.bond (register → dashboard → create key, starts with sk-apx…). It unlocks 20+ models — GPT, Gemini, DeepSeek, GLM, Qwen, Kimi, Grok — free tiers included. The key is stored only on this device and only ever sent to api.apinex.bond."
        case .gemini:
            return "Free key from aistudio.google.com. Stored only on this device; only ever sent to Google."
        }
    }

    // -- Actions ----------------------------------------------------------------

    private func refreshModels() {
        refreshing = true
        testResult = nil
        ai.refreshApinexCatalog {
            refreshing = false
            testResult = "Model list refreshed — \(ai.apinexCatalog.count) models available."
        }
    }

    private func testKey() {
        testing = true
        testResult = nil
        AITransport.testApinexKey(key: ai.apinexKey) { r in
            DispatchQueue.main.async {
                testing = false
                testResult = r
            }
        }
    }

    private func testGemini() {
        testing = true
        testResult = nil
        AITransport.testGeminiKey(key: ai.key, model: ai.model) { r in
            DispatchQueue.main.async {
                testing = false
                testResult = r
            }
        }
    }
}
