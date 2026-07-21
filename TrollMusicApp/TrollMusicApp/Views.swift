import SwiftUI
import WebKit

struct MainTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }
            
            PlaylistsView()
                .tabItem {
                    Label("Playlists", systemImage: "music.mic")
                }
            
            BrowserView()
                .tabItem {
                    Label("Browser", systemImage: "safari")
                }
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayerView()
        }
    }
}

// MARK: - Mini Player
struct MiniPlayerView: View {
    @EnvironmentObject var musicManager: MusicManager
    
    var body: some View {
        if let currentSong = musicManager.currentSong {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Image(systemName: "music.note")
                        .resizable()
                        .frame(width: 30, height: 30)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                    
                    Text(currentSong.title)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button(action: {
                        musicManager.togglePlayPause()
                    }) {
                        Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundColor(.primary)
                    }
                    .padding(.trailing)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))
            }
        }
    }
}

// MARK: - Library View
struct LibraryView: View {
    @EnvironmentObject var musicManager: MusicManager
    @State private var showingOptionsFor: Song?
    
    var body: some View {
        NavigationView {
            List {
                ForEach(musicManager.songs) { song in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(song.title).font(.headline)
                        }
                        Spacer()
                        Button(action: {
                            showingOptionsFor = song
                        }) {
                            Image(systemName: "ellipsis")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        musicManager.playSong(song)
                    }
                }
                .onDelete { indexSet in
                    indexSet.forEach { index in
                        musicManager.deleteSong(musicManager.songs[index])
                    }
                }
            }
            .navigationTitle("Ahmed's Music")
            .onAppear {
                musicManager.loadSongs()
            }
            .actionSheet(item: Binding<Song?>(
                get: { showingOptionsFor },
                set: { showingOptionsFor = $0 }
            )) { song in
                var buttons: [ActionSheet.Button] = musicManager.playlists.map { playlist in
                    .default(Text("Add to \(playlist.name)")) {
                        musicManager.addSongToPlaylist(song: song, playlist: playlist)
                    }
                }
                buttons.append(.cancel())
                return ActionSheet(title: Text("Add to Playlist"), buttons: buttons)
            }
        }
    }
}

// MARK: - Playlists View
struct PlaylistsView: View {
    @EnvironmentObject var musicManager: MusicManager
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    
    var body: some View {
        NavigationView {
            List {
                ForEach(musicManager.playlists) { playlist in
                    NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                        Text(playlist.name)
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                Button(action: { showingNewPlaylist = true }) {
                    Image(systemName: "plus")
                }
            }
            .alert("New Playlist", isPresented: $showingNewPlaylist) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Create") {
                    if !newPlaylistName.isEmpty {
                        musicManager.createPlaylist(name: newPlaylistName)
                        newPlaylistName = ""
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject var musicManager: MusicManager
    var playlist: Playlist
    
    var songsInPlaylist: [Song] {
        musicManager.songs.filter { playlist.songIDs.contains($0.id) }
    }
    
    var body: some View {
        List {
            ForEach(songsInPlaylist) { song in
                Text(song.title)
                    .onTapGesture {
                        musicManager.playSong(song)
                    }
            }
        }
        .navigationTitle(playlist.name)
    }
}

// MARK: - Browser View
struct BrowserView: View {
    @EnvironmentObject var musicManager: MusicManager
    @State private var urlString = "https://google.com/search?q=mp3+download"
    @State private var showDownloadAlert = false
    @State private var downloadFileName = ""
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Enter URL or search", text: $urlString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                
                Button("Go") {
                    NotificationCenter.default.post(name: NSNotification.Name("LoadURL"), object: urlString)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            
            // Quick Bookmarks
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    BookmarkButton(title: "Google Search", url: "https://google.com/search?q=mp3+download")
                    BookmarkButton(title: "Sm3na", url: "https://sm3na.com")
                    BookmarkButton(title: "Nogomi", url: "https://nogomistars.com")
                    BookmarkButton(title: "YtMP3", url: "https://ytmp3.cc")
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .background(Color(UIColor.secondarySystemBackground))
            
            WebViewUI(urlString: $urlString, didDetectDownload: { fileUrl in
                downloadFileName = fileUrl.lastPathComponent
                showDownloadAlert = true
            })
        }
        .alert(isPresented: $showDownloadAlert) {
            Alert(
                title: Text("Download Complete"),
                message: Text("Successfully saved \(downloadFileName) to your Library!"),
                dismissButton: .default(Text("OK")) {
                    musicManager.loadSongs()
                }
            )
        }
    }
}

struct BookmarkButton: View {
    var title: String
    var url: String
    var body: some View {
        Button(action: {
            NotificationCenter.default.post(name: NSNotification.Name("LoadURL"), object: url)
        }) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
    }
}

// MARK: - WebView Wrapper
struct WebViewUI: UIViewRepresentable {
    @Binding var urlString: String
    var didDetectDownload: (URL) -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LoadURL"), object: nil, queue: .main) { notification in
            if let urlStr = notification.object as? String {
                load(urlStr: urlStr, in: webView)
            }
        }
        
        load(urlStr: urlString, in: webView)
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func load(urlStr: String, in webView: WKWebView) {
        var finalUrlStr = urlStr
        if !finalUrlStr.hasPrefix("http") {
            finalUrlStr = "https://" + finalUrlStr
        }
        if let url = URL(string: finalUrlStr) {
            webView.load(URLRequest(url: url))
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebViewUI
        
        init(_ parent: WebViewUI) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                parent.urlString = url.absoluteString
                
                // Very basic interceptor for mp3/m4a file extensions
                if url.pathExtension.lowercased() == "mp3" || url.pathExtension.lowercased() == "m4a" {
                    downloadFile(from: url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
        
        func downloadFile(from url: URL) {
            let task = URLSession.shared.downloadTask(with: url) { localUrl, response, error in
                guard let localUrl = localUrl, error == nil else { return }
                
                let fileManager = FileManager.default
                let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                
                // Fallback name if none found
                let fileName = response?.suggestedFilename ?? url.lastPathComponent
                let destinationUrl = documentsPath.appendingPathComponent(fileName)
                
                do {
                    if fileManager.fileExists(atPath: destinationUrl.path) {
                        try fileManager.removeItem(at: destinationUrl)
                    }
                    try fileManager.moveItem(at: localUrl, to: destinationUrl)
                    DispatchQueue.main.async {
                        self.parent.didDetectDownload(destinationUrl)
                    }
                } catch {
                    print("Error saving file: \(error)")
                }
            }
            task.resume()
        }
    }
}
