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

    /// iOS relaunched us (or woke us) because background downloads finished.
    /// Holding onto the handler until the session drains its events is what
    /// makes a download that completed in the user's pocket land properly.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadCenter.backgroundSessionID else {
            completionHandler(); return
        }
        DownloadCenter.shared.backgroundCompletionHandler = completionHandler
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
                    // Start mirroring now-playing state out to the widget.
                    // No-ops harmlessly when the App Group isn't available.
                    WidgetPublisher.shared.start()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if UserDefaults.standard.bool(forKey: "asmusic_autoresume") {
                            MusicManager.shared.resumeLastSongIfAvailable()
                        }
                    }
                    // Touch the trash once per launch so expired items are
                    // swept up (and the folder never grows without bound).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        LibraryTrash.shared.purgeExpired()
                    }
                }
                // Two very different things arrive here: a widget/Shortcuts
                // deep link (asmusic://…) and a file handed over by Files,
                // AirDrop or another app. Check for our own scheme FIRST —
                // otherwise a widget tap would be passed to the importer,
                // which would just fail to read it as audio.
                .onOpenURL { url in
                    if let action = WidgetLink.action(from: url) {
                        WidgetLinkRouter.handle(action)
                        return
                    }
                    let result = MusicManager.shared.importAudioFiles(from: [url])
                    if result.imported > 0 {
                        NotificationCenter.default.post(name: .libraryDidImport, object: nil,
                                                        userInfo: ["count": result.imported])
                    }
                }
        }
    }
}

