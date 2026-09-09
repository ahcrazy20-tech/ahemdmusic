import WidgetKit
import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - AS Music widget
// ---------------------------------------------------------------------------
//
// Two widgets:
//   * Now Playing — what's playing, with transport controls.
//   * Moments     — one tap to start a smart mix (gym, focus, chill, …).
//
// Deployment target is iOS 16, so `Button(intent:)` (iOS 17+) is not
// available: every control is a `Link` to an asmusic:// URL that the app
// parses with WidgetLink. That means a tap opens the app — the honest
// behaviour on iOS 16 rather than a button that looks interactive and isn't.
//
// This target compiles SharedNowPlaying.swift and nothing else from the app.

// ---------------------------------------------------------------------------
// MARK: - Timeline
// ---------------------------------------------------------------------------

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    /// nil when the App Group is unreachable — the widget says so instead of
    /// rendering a permanently empty player.
    let groupAvailable: Bool
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .preview, groupAvailable: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let snap = context.isPreview ? .preview : NowPlayingBridge.read()
        completion(NowPlayingEntry(date: Date(), snapshot: snap,
                                   groupAvailable: SharedStore.isAvailable))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let snap = NowPlayingBridge.read()
        let now = Date()
        let available = SharedStore.isAvailable

        // While a track is playing, step the progress bar forward a few times
        // so it doesn't look frozen between the app's own reload calls. When
        // paused there is nothing to animate, so ask for one distant refresh
        // and stop burning the widget's refresh budget.
        var entries: [NowPlayingEntry] = []
        if snap.isPlaying && !snap.isEmpty {
            for step in stride(from: 0, through: 240, by: 30) {
                let date = now.addingTimeInterval(Double(step))
                entries.append(NowPlayingEntry(date: date, snapshot: snap,
                                               groupAvailable: available))
            }
        } else {
            entries = [NowPlayingEntry(date: now, snapshot: snap, groupAvailable: available)]
        }

        let next = now.addingTimeInterval(snap.isPlaying ? 300 : 1800)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

extension NowPlayingSnapshot {
    static let preview = NowPlayingSnapshot(
        title: "Ya Msafer Wahdak", artist: "Abdel Halim Hafez",
        isPlaying: true, position: 72, duration: 245,
        asOf: Date(), hasArtwork: false)
}

// ---------------------------------------------------------------------------
// MARK: - Shared pieces
// ---------------------------------------------------------------------------

private let brand = Color(red: 0.98, green: 0.36, blue: 0.24)

/// Cover art, or a tinted note when there is none.
struct ArtworkView: View {
    let snapshot: NowPlayingSnapshot
    var side: CGFloat

    var body: some View {
        ZStack {
            if snapshot.hasArtwork, let image = NowPlayingBridge.readArtwork() {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [brand.opacity(0.85), brand.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.4, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
    }
}

/// A thin progress bar that extrapolates from the snapshot's timestamp.
struct ProgressBar: View {
    let snapshot: NowPlayingSnapshot
    let date: Date

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(brand)
                    .frame(width: max(2, geo.size.width * snapshot.progress(at: date)))
            }
        }
        .frame(height: 3)
    }
}

struct TransportLink: View {
    let action: WidgetLink.Action
    let symbol: String
    var size: CGFloat = 17

    var body: some View {
        Link(destination: action.url) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: size * 2, height: size * 2)
                .contentShape(Rectangle())
        }
    }
}

/// Shown when the App Group isn't reachable, or nothing has played yet.
struct EmptyStateView: View {
    let groupAvailable: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: groupAvailable ? "music.note" : "exclamationmark.triangle")
                .font(.title2)
                .foregroundColor(brand)
            Text(groupAvailable ? "Nothing playing" : "Open AS Music")
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(.primary)
            Text(groupAvailable
                 ? "Tap to open your library"
                 : "The widget can't reach the app's data yet")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Now Playing widget
// ---------------------------------------------------------------------------

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        Group {
            if entry.snapshot.isEmpty {
                Link(destination: WidgetLink.Action.openNowPlaying.url) {
                    EmptyStateView(groupAvailable: entry.groupAvailable)
                }
            } else {
                switch family {
                case .systemSmall: small
                default:           medium
                }
            }
        }
        .widgetContainerBackground()
    }

    private var small: some View {
        Link(destination: WidgetLink.Action.openNowPlaying.url) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(snapshot: entry.snapshot, side: 54)
                Spacer(minLength: 0)
                Text(entry.snapshot.title)
                    .font(.caption).fontWeight(.semibold)
                    .lineLimit(2)
                Text(entry.snapshot.artist)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                ProgressBar(snapshot: entry.snapshot, date: entry.date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            Link(destination: WidgetLink.Action.openNowPlaying.url) {
                ArtworkView(snapshot: entry.snapshot, side: 68)
            }
            VStack(alignment: .leading, spacing: 5) {
                Link(destination: WidgetLink.Action.openNowPlaying.url) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.snapshot.title)
                            .font(.subheadline).fontWeight(.semibold)
                            .lineLimit(1)
                        Text(entry.snapshot.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ProgressBar(snapshot: entry.snapshot, date: entry.date)
                HStack(spacing: 2) {
                    TransportLink(action: .previous, symbol: "backward.fill")
                    TransportLink(action: .playPause,
                                  symbol: entry.snapshot.isPlaying ? "pause.fill" : "play.fill",
                                  size: 20)
                    TransportLink(action: .next, symbol: "forward.fill")
                    Spacer()
                }
            }
        }
        .padding(12)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ASMusicNowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing, with controls.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// ---------------------------------------------------------------------------
// MARK: - Moments widget
// ---------------------------------------------------------------------------

struct MomentsEntry: TimelineEntry { let date: Date }

struct MomentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> MomentsEntry { MomentsEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (MomentsEntry) -> Void) {
        completion(MomentsEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MomentsEntry>) -> Void) {
        // Static content: never needs refreshing.
        completion(Timeline(entries: [MomentsEntry(date: Date())], policy: .never))
    }
}

struct MomentsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MomentsEntry

    private var moments: [WidgetMoment] {
        family == .systemSmall ? Array(WidgetMoment.all.prefix(4)) : WidgetMoment.all
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8),
              count: family == .systemSmall ? 2 : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start a mix")
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(moments) { moment in
                    Link(destination: WidgetLink.Action.moment(moment.id).url) {
                        VStack(spacing: 3) {
                            Image(systemName: moment.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(brand)
                            Text(moment.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    }
                }
            }
        }
        .padding(12)
        .widgetContainerBackground()
    }
}

struct MomentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ASMusicMoments", provider: MomentsProvider()) { entry in
            MomentsWidgetView(entry: entry)
        }
        .configurationDisplayName("Moments")
        .description("One tap to start a smart mix.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// ---------------------------------------------------------------------------
// MARK: - Bundle
// ---------------------------------------------------------------------------

@main
struct ASMusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        MomentsWidget()
    }
}

// ---------------------------------------------------------------------------
// MARK: - iOS 17 compatibility
// ---------------------------------------------------------------------------

private extension View {
    /// iOS 17 requires `containerBackground` or the widget is letterboxed with
    /// an ugly default margin; the modifier doesn't exist on iOS 16, which is
    /// the deployment target. Apply it only where it exists.
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self
        }
    }
}
