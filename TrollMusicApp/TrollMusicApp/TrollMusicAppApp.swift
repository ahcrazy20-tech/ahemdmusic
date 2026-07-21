import SwiftUI
import AVFoundation

@main
struct TrollMusicAppApp: App {
    
    // We initialize the AudioSession on app launch so it can play in the background
    init() {
        setupAudioSession()
    }
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(MusicManager.shared)
        }
    }
    
    func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category. Error: \(error)")
        }
    }
}
