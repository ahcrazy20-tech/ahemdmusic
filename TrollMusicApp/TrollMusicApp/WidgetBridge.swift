import Foundation
import SwiftUI
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif

// ---------------------------------------------------------------------------
// MARK: - App side of the widget bridge
// ---------------------------------------------------------------------------
//
// `SharedNowPlaying.swift` holds the parts both processes compile. This file is
// APP-ONLY: it reads MusicManager and pushes snapshots out to the App Group,
// and it handles the deep links the widget sends back.

/// Runs the action behind a widget tap.
enum WidgetLinkRouter {
    static func handle(_ action: WidgetLink.Action) {
        // Always hop to main: this is called from onOpenURL and every call
        // below touches published state or the audio engine.
        DispatchQueue.main.async {
            let mm = MusicManager.shared
            switch action {
            case .openNowPlaying:
                NotificationCenter.default.post(name: .widgetDidRequestNowPlaying, object: nil)

            case .playPause:
                // Nothing loaded yet (cold launch from the widget): start
                // where the user left off rather than doing nothing.
                if mm.currentSong == nil {
                    mm.resumeLastSongIfAvailable()
                } else {
                    mm.togglePlayPause()
                }

            case .next:
                mm.playNext()

            case .previous:
                mm.playPrevious()

            case .moment(let kind):
                // Returns the playlist title for Siri to speak; nothing to say
                // here, the user is looking at the screen.
                _ = SmartPlaylistEngine.shared.playMoment(kind)
                NotificationCenter.default.post(name: .widgetDidRequestNowPlaying, object: nil)
            }
        }
    }
}

extension Notification.Name {
    /// Posted when a widget tap should bring the Now Playing screen forward.
    static let widgetDidRequestNowPlaying = Notification.Name("asmusic_widget_nowplaying")
}

// ---------------------------------------------------------------------------
// MARK: - Publishing state to the widget
// ---------------------------------------------------------------------------

/// Keeps the App Group snapshot in step with what's actually playing.
///
/// Widgets are refreshed by the system on its own schedule, and the budget is
/// limited, so this deliberately does NOT push on every tick. It writes when
/// something a person would notice changes: the song, play/pause, or a seek
/// large enough to move the progress bar.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private var cancellables = Set<AnyCancellable>()
    private var lastSongID: UUID?
    private var lastIsPlaying: Bool?
    private var lastPosition: Double = 0
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        guard SharedStore.isAvailable else {
            // No App Group (entitlement refused, or a signing setup that
            // doesn't grant it). The app is fully functional without it; the
            // widget will show its "open the app" state.
            return
        }

        let mm = MusicManager.shared

        mm.$currentSong
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] _ in self?.pushNow(forceArtwork: true) }
            .store(in: &cancellables)

        mm.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in self?.pushNow() }
            .store(in: &cancellables)

        // A low-frequency safety net so the progress bar can't drift far from
        // reality if the app sits in the foreground for a long time.
        Timer.publish(every: 20, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pushIfMoved() }
            .store(in: &cancellables)

        pushNow(forceArtwork: true)
    }

    /// Writes a snapshot only when the position has actually moved on.
    private func pushIfMoved() {
        let mm = MusicManager.shared
        guard mm.isPlaying else { return }
        if abs(mm.currentTime - lastPosition) < 5 { return }
        pushNow()
    }

    func pushNow(forceArtwork: Bool = false) {
        guard SharedStore.isAvailable else { return }
        let mm = MusicManager.shared
        let song = mm.currentSong

        let songChanged = song?.id != lastSongID
        lastSongID = song?.id
        lastIsPlaying = mm.isPlaying
        lastPosition = mm.currentTime

        var hasArt = false
        if let song = song, songChanged || forceArtwork {
            // Artwork is copied out to the group container at a small size;
            // the widget process has a tight memory limit.
            mm.artworkImage(for: song, size: 240) { image in
                let ok = NowPlayingBridge.writeArtwork(image)
                // Rewrite the snapshot so `hasArtwork` matches what's on disk,
                // then ask the system to redraw.
                var snap = NowPlayingBridge.read()
                snap.hasArtwork = ok
                NowPlayingBridge.write(snap)
                Self.reloadWidgets()
            }
        } else {
            hasArt = NowPlayingBridge.read().hasArtwork
        }

        let snapshot = NowPlayingSnapshot(
            title: song?.title ?? "",
            artist: song?.artist ?? "",
            isPlaying: mm.isPlaying,
            position: mm.currentTime,
            duration: mm.duration,
            asOf: Date(),
            hasArtwork: hasArt
        )
        NowPlayingBridge.write(snapshot)
        Self.reloadWidgets()
    }

    static func reloadWidgets() {
        #if canImport(WidgetKit)
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}
