import Foundation
#if canImport(UIKit)
import UIKit
#endif

// ---------------------------------------------------------------------------
// MARK: - Shared state between the app and its widget
// ---------------------------------------------------------------------------
//
// A widget runs in a SEPARATE PROCESS with its own sandbox. It cannot read the
// app's Documents directory, so anything it needs to draw has to be written
// somewhere both processes can reach — an App Group container.
//
// This file is compiled into BOTH targets. Keep it free of anything that only
// exists in the app (MusicManager, AVFoundation, SwiftUI views): the widget
// extension would fail to link.
//
// Entitlement note: App Groups need the entitlement to be honoured at install
// time, which is the one part of this feature that can fail on a TrollStore
// install rather than at compile time. Everything here therefore degrades to
// nil/empty instead of crashing, and the widget renders an honest "open the
// app" state when the container is unreachable.

public enum SharedStore {
    /// Must match the App Group declared in the XcodeGen spec for both targets.
    public static let appGroupID = "group.com.ahmedsoliman.trollmusicapp"

    /// The shared container, or nil when the App Group is not available.
    public static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// True when the app and widget can actually exchange data.
    public static var isAvailable: Bool { container != nil }

    static var stateURL: URL? { container?.appendingPathComponent("nowplaying.json") }
    static var artworkURL: URL? { container?.appendingPathComponent("nowplaying.jpg") }
}

/// The snapshot the widget draws. Deliberately small and self-contained —
/// everything the widget needs, nothing it has to look up.
public struct NowPlayingSnapshot: Codable, Equatable {
    public var title: String
    public var artist: String
    public var isPlaying: Bool
    /// Seconds into the track at `asOf`.
    public var position: Double
    public var duration: Double
    /// When this snapshot was written, so the widget can extrapolate.
    public var asOf: Date
    /// Set when the artwork file was refreshed, so the widget can tell a
    /// stale image apart from a missing one.
    public var hasArtwork: Bool

    public init(title: String, artist: String, isPlaying: Bool,
                position: Double, duration: Double, asOf: Date, hasArtwork: Bool) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
        self.asOf = asOf
        self.hasArtwork = hasArtwork
    }

    public static let empty = NowPlayingSnapshot(
        title: "", artist: "", isPlaying: false,
        position: 0, duration: 0, asOf: .distantPast, hasArtwork: false)

    public var isEmpty: Bool { title.isEmpty }

    /// Where the track has reached *now*, assuming it kept playing since the
    /// snapshot was taken. A widget timeline is refreshed rarely, so without
    /// this the progress bar would visibly freeze.
    public func position(at date: Date) -> Double {
        guard isPlaying, duration > 0 else { return min(position, duration) }
        let drift = max(0, date.timeIntervalSince(asOf))
        return min(position + drift, duration)
    }

    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, position(at: date) / duration))
    }
}

// ---------------------------------------------------------------------------
// MARK: - Reading / writing the snapshot
// ---------------------------------------------------------------------------

public enum NowPlayingBridge {
    private static let lock = NSLock()

    /// Writes the snapshot for the widget. Silent no-op when the App Group is
    /// unavailable — the app must keep working with or without the widget.
    public static func write(_ snapshot: NowPlayingSnapshot) {
        guard let url = SharedStore.stateURL else { return }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Atomic: the widget may read this file at any moment, and a
        // half-written JSON would decode to nothing and blank the widget.
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> NowPlayingSnapshot {
        guard let url = SharedStore.stateURL,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        else { return .empty }
        return snap
    }

    #if canImport(UIKit)
    /// Copies the current artwork into the shared container, downscaled —
    /// a widget never needs a full-size cover, and the memory limit for a
    /// widget process is small enough that a large image can get it killed.
    public static func writeArtwork(_ image: UIImage?) -> Bool {
        guard let url = SharedStore.artworkURL else { return false }
        guard let image = image else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        let side: CGFloat = 240
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = scaled.jpegData(compressionQuality: 0.8) else { return false }
        try? data.write(to: url, options: .atomic)
        return true
    }

    public static func readArtwork() -> UIImage? {
        guard let url = SharedStore.artworkURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
    #endif
}

// ---------------------------------------------------------------------------
// MARK: - Deep links
// ---------------------------------------------------------------------------
//
// Interactive widget buttons (`Button(intent:)`) are iOS 17+; this app targets
// iOS 16, so every tap is a URL the app opens instead. Parsing lives here so
// the widget that BUILDS the links and the app that CONSUMES them can never
// drift apart.

public enum WidgetLink {
    public static let scheme = "asmusic"

    public enum Action: Equatable {
        case openNowPlaying
        case playPause
        case next
        case previous
        /// One of the smart-playlist moments (gym, focus, calm, …).
        case moment(String)

        public var url: URL {
            switch self {
            case .openNowPlaying: return URL(string: "\(scheme)://nowplaying")!
            case .playPause:      return URL(string: "\(scheme)://playpause")!
            case .next:           return URL(string: "\(scheme)://next")!
            case .previous:       return URL(string: "\(scheme)://previous")!
            case .moment(let k):  return URL(string: "\(scheme)://moment/\(k)")!
            }
        }
    }

    /// Parses a URL the app was opened with. Returns nil for anything that
    /// isn't one of ours — importantly including file URLs, which the app
    /// treats as music to import.
    public static func action(from url: URL) -> Action? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = (url.host ?? "").lowercased()
        switch host {
        case "nowplaying": return .openNowPlaying
        case "playpause":  return .playPause
        case "next":       return .next
        case "previous":   return .previous
        case "moment":
            let kind = url.pathComponents.filter { $0 != "/" }.first ?? ""
            return kind.isEmpty ? nil : .moment(kind.lowercased())
        default:
            return nil
        }
    }
}

/// The moments offered as one-tap widget buttons, mirroring `MusicMoment`.
/// Kept as plain data so the widget target doesn't need AppIntents.
public struct WidgetMoment: Identifiable, Equatable {
    public let id: String        // the smart-playlist recipe kind
    public let label: String
    public let symbol: String

    public init(id: String, label: String, symbol: String) {
        self.id = id; self.label = label; self.symbol = symbol
    }

    public static let all: [WidgetMoment] = [
        WidgetMoment(id: "gym",    label: "Gym",    symbol: "figure.run"),
        WidgetMoment(id: "focus",  label: "Focus",  symbol: "brain.head.profile"),
        WidgetMoment(id: "calm",   label: "Chill",  symbol: "leaf.fill"),
        WidgetMoment(id: "party",  label: "Party",  symbol: "sparkles"),
        WidgetMoment(id: "arabic", label: "Arabic", symbol: "music.note.list"),
        WidgetMoment(id: "drive",  label: "Drive",  symbol: "car.fill"),
    ]
}
