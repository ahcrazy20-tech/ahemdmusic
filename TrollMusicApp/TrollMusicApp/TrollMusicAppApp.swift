import SwiftUI
import AVFoundation

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } catch { print("Background Audio Setup Failed") }
        return true
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        MusicManager.shared.appWillBackground()
    }
    func applicationWillTerminate(_ application: UIApplication) {
        MusicManager.shared.appWillBackground()
    }
}

@main
struct TrollMusicAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate: AppDelegate
    @State private var didResume = false
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(MusicManager.shared)
                .onAppear {
                    guard !didResume else { return }
                    didResume = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if UserDefaults.standard.bool(forKey: "asmusic_autoresume") {
                            MusicManager.shared.resumeLastSongIfAvailable()
                        }
                    }
                }
        }
    }
}

