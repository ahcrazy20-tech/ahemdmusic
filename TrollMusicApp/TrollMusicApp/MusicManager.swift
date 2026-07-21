import Foundation
import AVFoundation
import MediaPlayer
import Combine

class MusicManager: ObservableObject {
    static let shared = MusicManager()
    
    @Published var songs: [Song] = []
    @Published var playlists: [Playlist] = []
    @Published var currentSong: Song?
    @Published var isPlaying: Bool = false
    
    var audioPlayer: AVAudioPlayer?
    
    let fileManager = FileManager.default
    var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    init() {
        loadSongs()
        loadPlaylists()
        setupRemoteCommandCenter()
    }
    
    // MARK: - File Management
    func loadSongs() {
        do {
            let files = try fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            let audioFiles = files.filter { $0.pathExtension == "mp3" || $0.pathExtension == "m4a" || $0.pathExtension == "wav" }
            
            songs = audioFiles.map { url in
                Song(id: UUID(), title: url.deletingPathExtension().lastPathComponent, url: url)
            }.sorted { $0.title < $1.title }
        } catch {
            print("Error loading songs: \(error)")
        }
    }
    
    func deleteSong(_ song: Song) {
        do {
            try fileManager.removeItem(at: song.url)
            loadSongs()
            // Also remove from playlists
            for i in 0..<playlists.count {
                playlists[i].songIDs.removeAll { $0 == song.id }
            }
            savePlaylists()
        } catch {
            print("Error deleting song: \(error)")
        }
    }
    
    // MARK: - Playlists
    func createPlaylist(name: String) {
        let newPlaylist = Playlist(id: UUID(), name: name, songIDs: [])
        playlists.append(newPlaylist)
        savePlaylists()
    }
    
    func addSongToPlaylist(song: Song, playlist: Playlist) {
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            if !playlists[index].songIDs.contains(song.id) {
                playlists[index].songIDs.append(song.id)
                savePlaylists()
            }
        }
    }
    
    func savePlaylists() {
        if let encoded = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(encoded, forKey: "savedPlaylists")
        }
    }
    
    func loadPlaylists() {
        if let data = UserDefaults.standard.data(forKey: "savedPlaylists"),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
    }
    
    // MARK: - Audio Playback
    func playSong(_ song: Song) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: song.url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            currentSong = song
            isPlaying = true
            updateNowPlayingInfo()
        } catch {
            print("Playback error: \(error)")
        }
    }
    
    func togglePlayPause() {
        if isPlaying {
            audioPlayer?.pause()
        } else {
            audioPlayer?.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }
    
    // MARK: - Lock Screen Controls
    func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [unowned self] event in
            if !self.isPlaying {
                self.togglePlayPause()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.pauseCommand.addTarget { [unowned self] event in
            if self.isPlaying {
                self.togglePlayPause()
                return .success
            }
            return .commandFailed
        }
    }
    
    func updateNowPlayingInfo() {
        guard let currentSong = currentSong else { return }
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentSong.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = "TrollMusic"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}

struct Song: Identifiable, Codable {
    var id: UUID
    var title: String
    var url: URL
}

struct Playlist: Identifiable, Codable {
    var id: UUID
    var name: String
    var songIDs: [UUID]
}
