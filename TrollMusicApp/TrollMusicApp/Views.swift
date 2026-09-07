import SwiftUI
import UIKit
import AVKit
import MediaPlayer

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

enum TabID: Hashable { case library, discover, playlists, magic, browser }

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
    @StateObject private var lyrics = LyricsStore.shared
    @State private var showTimerOptions = false
    @State private var showLyrics = false
    @State private var showEQ = false
    @State private var showTheme = false
    @State private var showArtistInfo = false

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
                        Button { showTheme = true } label: { Label("Theme color", systemImage: "paintpalette") }
                        if let song = musicManager.currentSong {
                            Divider()
                            Button { musicManager.shareSong(song) } label: { Label("Share / Export", systemImage: "square.and.arrow.up") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).foregroundColor(.white)
                    }
                }.padding()

                if showLyrics {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: lyricsAreRTL ? .trailing : .leading, spacing: 12) {
                            if lyrics.loading {
                                ProgressView().tint(.white)
                            } else {
                                Text(lyrics.lyrics)
                                    .font(.system(size: isRTL(lyrics.lyrics) ? 20 : 18, weight: .medium))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(lyricsAreRTL ? .trailing : .leading)
                                    .lineSpacing(6)
                                    .environment(\.layoutDirection, lyricsAreRTL ? .rightToLeft : .leftToRight)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: lyricsAreRTL ? .trailing : .leading)
                    }
                    .frame(maxHeight: 340)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(16)
                    .padding(.horizontal)
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
        .onAppear {
            if let t = musicManager.currentSong?.title {
                lyrics.fetch(for: t, artist: musicManager.currentSong?.artist ?? "")
            }
        }
        .onChange(of: musicManager.currentSong?.title) { _ in
            if let t = musicManager.currentSong?.title {
                lyrics.fetch(for: t, artist: musicManager.currentSong?.artist ?? "")
            }
        }
        .sheet(isPresented: $showEQ) {
            NavigationView { EQView() }.environmentObject(musicManager)
        }
        .sheet(isPresented: $showTheme) {
            NavigationView { ThemePickerView() }.environmentObject(musicManager)
        }
        .sheet(isPresented: $showArtistInfo) {
            if let song = musicManager.currentSong {
                NavigationView { ArtistInfoView(artist: song.artist, genre: song.genre) }
            }
        }
    }

    private var lyricsAreRTL: Bool { isRTL(lyrics.lyrics) }
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
                    footer: Text("Paste your FREE Google AI Studio key (aistudio.google.com) to ask for songs in plain language — e.g. \"5 new Egyptian pop songs about summer\". With no key the feature is off and nothing is sent anywhere.")) {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Gemini API key", text: $ai.key)
                        .font(.subheadline)
                    TextField("Model (default: gemini-2.5-flash)", text: $ai.model)
                        .font(.subheadline)
                }
                .autocorrectionDisabled()
            }
            Section(footer: Text("Tip: Arabic/Maqaam preset boosts oud/qanun highs while keeping warm lows, great for Amr Diab, Sherine, Nancy Ajram.")) {
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
struct LibraryView: View {
    @EnvironmentObject var musicManager: MusicManager
    @State private var showingOptionsFor: Song?
    @State private var showingRenameFor: Song?
    @State private var newNameInput = ""
    @State private var searchText = ""

    var filteredSongs: [Song] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty { return musicManager.songs }
        return musicManager.songs.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
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
                if !recentlyPlayed.isEmpty {
                    Section {
                        ForEach(recentlyPlayed) { song in
                            songRow(song, isQueued: false)
                        }
                    } header: {
                        Label("Recently Played", systemImage: "clock.arrow.circlepath")
                    }
                }
                Section {
                    if !musicManager.upNextQueue.isEmpty {
                        ForEach(musicManager.upNextQueue) { song in
                            songRow(song, isQueued: true)
                        }
                    }
                } header: {
                    if !musicManager.upNextQueue.isEmpty { Text("Up Next") }
                }
                Section {
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
                                Button { showingRenameFor = song; newNameInput = song.title } label: { Label("Rename", systemImage: "pencil") }
                                Divider()
                                Button(role: .destructive) { musicManager.deleteSong(song) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                } header: {
                    if !musicManager.songs.isEmpty {
                        Text("\(musicManager.songs.count) songs")
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your library")
            .navigationTitle("Your Library").onAppear {
                musicManager.loadSongs()
                ITunesEnricher.shared.enrichLibrary()
            }
            .refreshable { musicManager.loadSongs(); ITunesEnricher.shared.enrichLibrary() }
            .toolbar {
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
                        Button("Rename Song") { showingRenameFor = song; newNameInput = song.title }
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
    var songsInPlaylist: [Song] { musicManager.songs.filter { playlist.songIDs.contains($0.id) } }
    var body: some View {
        List {
            if songsInPlaylist.isEmpty {
                Text("No songs yet. Add from Library.").foregroundColor(.secondary).padding()
            }
            ForEach(songsInPlaylist) { song in
                Button { musicManager.playSong(song) } label: {
                    HStack {
                        ArtworkView(song: song, size: 40, cornerRadius: 5, fallbackSystemName: "music.note")
                        VStack(alignment: .leading) {
                            Text(song.title).foregroundColor(.primary).lineLimit(1)
                            Text(song.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
            .onDelete { indexSet in
                if let pIndex = musicManager.playlists.firstIndex(where: { $0.id == playlist.id }) {
                    indexSet.forEach { musicManager.playlists[pIndex].songIDs.remove(at: $0) }
                    musicManager.savePlaylists()
                }
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            if !songsInPlaylist.isEmpty {
                Button {
                    // Play all shuffled
                    if let first = songsInPlaylist.first { musicManager.playSong(first) }
                    musicManager.isShuffle = true
                } label: { Image(systemName: "shuffle") }
            }
        }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject var musicManager: MusicManager
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink(destination: LikedSongsView()) {
                        HStack {
                            Image(systemName: "heart.fill").foregroundColor(.pink).font(.title2).frame(width:36)
                            VStack(alignment:.leading) {
                                Text("Liked Songs").font(.headline)
                                let liked = musicManager.playlists.first?.songIDs.count ?? 0
                                Text("\(liked) songs").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section(header: Text("My Playlists")) {
                    ForEach(musicManager.playlists.dropFirst()) { playlist in
                        NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                            Text(playlist.name).font(.headline).padding(.vertical, 5)
                        }
                    }
                }
            }
            .navigationTitle("Playlists")
            .toolbar { Button { showingNewPlaylist = true } label: { Image(systemName: "plus") } }
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
}

struct LikedSongsView: View {
    @EnvironmentObject var musicManager: MusicManager
    var likedSongs: [Song] {
        guard !musicManager.playlists.isEmpty else { return [] }
        let ids = musicManager.playlists[0].songIDs
        return musicManager.songs.filter { ids.contains($0.id) }
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

