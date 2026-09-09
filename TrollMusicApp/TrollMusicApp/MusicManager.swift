import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit
import Accelerate
import CryptoKit
import os

/// Tiny wrapper for a value the audio render thread writes and the UI reads.
/// Replaces the old per-buffer `DispatchQueue.main.async` that ran ~43x/sec
/// straight from the render callback (allocation on a real-time thread).
final class AtomicFloat {
    private var value: Float
    private let lock = NSLock()
    init(_ v: Float = 0) { value = v }
    func store(_ v: Float) {
        lock.lock(); value = v; lock.unlock()
    }
    func load() -> Float {
        lock.lock(); let v = value; lock.unlock(); return v
    }
}

struct Song: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var url: URL
    var artist: String = "AS Music"
    var artworkURL: String? = nil
    var sourceVid: String? = nil
    /// Optional genre, filled by the iTunes enrichment (free API, no key).
    var genre: String? = nil
}

struct Playlist: Identifiable, Codable {
    var id: UUID
    var name: String
    var songIDs: [UUID]
}

enum RepeatMode: Int { case off, all, one }

/// How one track is joined to the next.
enum TransitionMode: String, CaseIterable, Identifiable {
    /// Hard cut — exactly how the app behaved before Pack 6.
    case off
    /// No silence between tracks: the next one starts the instant the audio of
    /// the current one ends (measured tail silence is trimmed). Right for
    /// albums, live sets and Quran recitation.
    case gapless
    /// A fixed overlap: the outgoing track fades down while the next fades up.
    case crossfade
    /// Crossfade whose length adapts to the two tracks — a long blend between
    /// two steady beat-driven songs, a short one into a quiet or spoken track.
    case autoDJ

    var id: String { rawValue }

    // NSLocalizedString, not a bare literal: these are read into `String`
    // properties, and Text/Label given a String VARIABLE use the non-localizing
    // overload — the literal would stay English on an Arabic device.
    var title: String {
        switch self {
        case .off:       return NSLocalizedString("Off (hard cut)", comment: "Transition mode")
        case .gapless:   return NSLocalizedString("Gapless", comment: "Transition mode")
        case .crossfade: return NSLocalizedString("Crossfade", comment: "Transition mode")
        case .autoDJ:    return NSLocalizedString("Auto-DJ", comment: "Transition mode")
        }
    }

    var subtitle: String {
        switch self {
        case .off:       return NSLocalizedString("Each song stops, the next begins. The classic behaviour.", comment: "Transition mode explanation")
        case .gapless:   return NSLocalizedString("Removes the silence between tracks without blending them. Best for albums, live sets and long recitations.", comment: "Transition mode explanation")
        case .crossfade: return NSLocalizedString("The next song fades in while this one fades out, over a length you choose.", comment: "Transition mode explanation")
        case .autoDJ:    return NSLocalizedString("Like crossfade, but the length adapts to what the two songs actually sound like — long blends between steady beats, short ones into quiet or spoken tracks.", comment: "Transition mode explanation")
        }
    }

    var icon: String {
        switch self {
        case .off:       return "scissors"
        case .gapless:   return "arrow.right.to.line"
        case .crossfade: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .autoDJ:    return "slider.horizontal.below.rectangle"
        }
    }

    var blends: Bool { self == .crossfade || self == .autoDJ }
}

enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case vocal = "Vocal Boost"
    case arabic = "Arabic/Maqaam"
    case treble = "Treble Boost"
    case rock = "Rock"
    var id: String { rawValue }

    var gains: [Float] {
        switch self {
        case .flat:      return [0,0,0,0,0,0,0,0,0,0]
        case .bassBoost: return [6,7,6,4,2,0,0,0,0,0]
        case .vocal:     return [-2,-2,-1,1,3,4,4,3,1,0]
        case .arabic:    return [3,3,2,1,0,1,2,3,4,3]
        case .treble:    return [0,0,0,0,0,1,3,5,6,6]
        case .rock:      return [5,4,3,1,-1,1,3,4,5,5]
        }
    }
}

struct AppAccent: Identifiable, Equatable {
    let id: String
    let name: String
    let r,g,b: Double
    static let list: [AppAccent] = [
        .init(id:"purple", name:"Purple", r:0.55,g:0.27,b:0.85),
        .init(id:"pink",   name:"Pink",   r:0.92,g:0.29,b:0.60),
        .init(id:"blue",   name:"Blue",   r:0.20,g:0.45,b:0.95),
        .init(id:"teal",   name:"Teal",   r:0.10,g:0.70,b:0.65),
        .init(id:"green",  name:"Green",  r:0.20,g:0.75,b:0.40),
        .init(id:"orange", name:"Orange", r:0.97,g:0.55,b:0.18),
        .init(id:"red",    name:"Red",    r:0.90,g:0.20,b:0.30),
        .init(id:"gold",   name:"Gold",   r:0.87,g:0.72,b:0.25),
    ]
}

/// A serial queue we use for all player-state mutations so play/pause/seek
/// never interleave (the #1 cause of "skip / seek broke playback" bugs).
private let playerQueue = DispatchQueue(label: "asMusic.player")

class MusicManager: NSObject, ObservableObject {
    static let shared = MusicManager()

    @Published var songs: [Song] = []
    @Published var playlists: [Playlist] = []
    @Published var currentSong: Song?
    @Published var isPlaying: Bool = false
    @Published var isSeeking: Bool = false           // true while slider drag is in progress
    @Published var seekPreviewTime: TimeInterval = 0 // shown during drag
    @Published var isShuffle: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var playbackRate: Float = 1.0
    @Published var sleepTimerMinutes: Int = 0
    @Published var currentTime: TimeInterval = 0.0
    @Published var duration: TimeInterval = 1.0
    @Published var upNextQueue: [Song] = []
    /// The last playlist(s) removed — powers the one-tap Undo in the
    /// Playlists tab. Cleared once the user restores or the banner times out.
    @Published var recentlyDeletedPlaylists: [Playlist] = []
    @Published var smartRadioMode: Bool = false
    @Published var eqPreset: EQPreset = .flat {
        didSet { applyEQ(); UserDefaults.standard.set(eqPreset.rawValue, forKey: "asmusic_eq") }
    }
    @Published var accent: AppAccent = .list[0] {
        didSet {
            UserDefaults.standard.set(accent.id, forKey: "asmusic_accent")
            objectWillChange.send()
        }
    }
    @Published var levels: (Float,Float) = (0,0)
    @Published var preampDB: Float = 0.0 {
        didSet { applyGain(); UserDefaults.standard.set(preampDB, forKey: "asmusic_preamp") }
    }
    @Published var spatialEnhance: Bool = false {
        didSet { applySpatial(); UserDefaults.standard.set(spatialEnhance, forKey: "asmusic_spatial") }
    }
    /// Sleep behavior: when on, the sleep timer waits for the song to finish
    /// instead of fading mid-track.
    @Published var stopAtSongEnd: Bool = false {
        didSet { UserDefaults.standard.set(stopAtSongEnd, forKey: "asmusic_stopend") }
    }
    /// Master output attenuation while the app is talking (SpokenFeedback).
    private var duckLevel: Float = 1.0

    // MARK: - Crossfade / gapless (Pack 6)

    /// How tracks are joined. `.off` reproduces the old hard cut exactly.
    @Published var transitionMode: TransitionMode = .off {
        didSet {
            UserDefaults.standard.set(transitionMode.rawValue, forKey: "asmusic_transition")
            if transitionMode == .off { cancelPendingTransition() }
        }
    }
    /// Crossfade length in seconds (1.5…12). Ignored in .off and .gapless.
    @Published var crossfadeSeconds: Double = 4 {
        didSet {
            let c = max(1.5, min(12, crossfadeSeconds))
            if c != crossfadeSeconds { crossfadeSeconds = c; return }
            UserDefaults.standard.set(c, forKey: "asmusic_xfade_secs")
        }
    }
    /// True while a crossfade is actually in progress.
    @Published private(set) var isCrossfading = false

    private var fadeLink: CADisplayLink?
    private var transitionArmed = false
    private var pendingNextSong: Song?
    /// The file opened on the incoming deck, promoted by `completeHandover`.
    private var incomingFile: AVAudioFile?
    private var incomingLead: TimeInterval = 0
    private var pendingScheduledEnd: AVAudioFramePosition = 0

    /// Live FFT spectrum (24 log-spaced bands in dB), written by the audio
    /// render thread, read by the player UI.
    let spectrum = SpectrumMeter()
    private var fft = FFTProcessor()
    private var fftScratch: [Float] = Array(repeating: -100, count: SpectrumMeter.bands)
    private var pendingStopAtEnd = false
    private var fadeTimer: Timer?
    private var preFadeDB: Float = 0
    private let sleepFadeSeconds: TimeInterval = 45

    // Signal chain (Pack 6 adds the two-deck front end for crossfading):
    //   playerNodes[0] ─┐
    //                   ├─> blendMixer -> eqNode -> preampMixer -> reverb -> timePitch -> mainMixerNode
    //   playerNodes[1] ─┘
    //
    // Two decks are what make a crossfade possible at all: the outgoing track
    // keeps rendering on one node while the incoming track starts on the
    // other. With crossfade OFF only deck 0 is ever used and the graph behaves
    // exactly as it did before.
    private var engine: AVAudioEngine!
    private var playerNodes: [AVAudioPlayerNode] = []
    private var blendMixer: AVAudioMixerNode!
    /// Which deck is playing the *current* song.
    private var activeDeck = 0
    /// The deck the next track will start on.
    private var idleDeck: Int { 1 - activeDeck }
    /// Convenience for all the existing code: the deck in charge right now.
    private var playerNode: AVAudioPlayerNode! { playerNodes.indices.contains(activeDeck) ? playerNodes[activeDeck] : nil }
    private var eqNode: AVAudioUnitEQ!
    private var preampMixer: AVAudioMixerNode!
    private var reverb: AVAudioUnitReverb!
    private var timePitch: AVAudioUnitTimePitch!

    private var audioFile: AVAudioFile?
    private var fileLength: AVAudioFramePosition = 0
    private var fileSampleRate: Double = 44100

    /// The frame position the playerNode is scheduled FROM (the start of the
    /// currently-scheduled segment). We compute the live playback position as
    /// seekFrame + playerTime.sampleTime for accuracy even at non-1.0 rates.
    private var seekFrame: AVAudioFramePosition = 0
    private var scheduledSegmentEnd: AVAudioFramePosition = 0
    private var isScheduled = false  // true when playerNode has a buffer/segment queued
    private var scheduleGeneration: Int = 0 // monotonically increasing; stale callbacks are ignored

    private var displayLink: CADisplayLink?
    private let levelL = AtomicFloat(0)
    private let levelR = AtomicFloat(0)
    private var audioSessionConfigured = false
    private var lastSongId: UUID? = nil
    private var lastSongTime: TimeInterval = 0
    private var engineIsStarting = false
    private var shouldResumePlaybackAfterInterruption = false

    var sleepTimer: Timer?
    var progressTimer: Timer?
    var queueObserver: NSObjectProtocol?
    private var didAutoSearchForRadio = false

    /// The track currently being listened to, and how much of it has been
    /// heard. Used to tell a real play from a skip when it is replaced
    /// (see `closeOutCurrentPlay`). Written on the main thread only.
    private var playbackWatch: (song: Song, startedAt: Date, startOffset: TimeInterval)?
    /// History of what was actually played, newest last — powers a Back button
    /// that retraces your steps instead of walking the library array.
    private var playHistory: [UUID] = []
    private var suppressHistoryPush = false

    let fileManager = FileManager.default
    var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var artworkCacheDir: URL {
        let d = documentsDirectory.appendingPathComponent(".artwork_cache")
        try? fileManager.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Private so nobody can accidentally spin up a second AVAudioEngine /
    /// CADisplayLink / observer set via `MusicManager()`.
    override private init() {
        super.init()
        setupEngine()
        registerSessionObservers()
        loadSongs()
        loadPlaylists()
        loadPrefs()
        setupRemoteCommandCenter()
        startLevelMeter()
        // Kick off background artwork enrichment once the first library scan
        // has landed (it is also called from the Library tab on appear).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            ITunesEnricher.shared.enrichLibrary()
        }
        // Measure the library on-device (loudness/tempo/balance) and let the
        // auto-DJ refresh smart playlists once the real song list exists.
        // Deferred so nothing here runs while MusicManager is still initializing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            AudioLab.shared.prime(MusicManager.shared.songs)
            SmartPlaylistEngine.shared.autoSyncIfNeeded()
        }
    }

    deinit {
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Thread helper

    /// Every `@Published` mutation must land on the main thread or SwiftUI will
    /// complain ("Publishing changes from background threads is not allowed")
    /// and, at worst, crash. Engine work stays on `playerQueue`; state
    /// publication goes through here.
    @inline(__always)
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Engine

    /// Registered exactly once from `init`. Previously these lived inside
    /// `setupEngine()`, which is also called from `handleMediaReset(_:)` — so
    /// every media-services reset doubled the number of observers and each
    /// interruption fired the handler 2x, 4x, 8x…
    private func registerSessionObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange(_:)),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleMediaReset(_:)),
                                               name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    func setupEngine() {
        // Tear the previous graph down first so re-entry (media reset) doesn't
        // leak an engine, its nodes and its render tap.
        if let old = engine {
            old.mainMixerNode.removeTap(onBus: 0)
            if old.isRunning { old.stop() }
            old.reset()
        }
        engine = AVAudioEngine()
        playerNodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
        activeDeck = 0
        blendMixer = AVAudioMixerNode()
        eqNode = AVAudioUnitEQ(numberOfBands: 10)
        preampMixer = AVAudioMixerNode()
        preampMixer.outputVolume = 1.0
        reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 0
        timePitch = AVAudioUnitTimePitch()

        let freqs: [Float] = [32,64,125,250,500,1000,2000,4000,8000,16000]
        for (i,b) in eqNode.bands.enumerated() {
            b.frequency = freqs[i]
            b.filterType = .parametric
            b.bandwidth = 1.0
            b.gain = 0
            b.bypass = false
        }
        for node in playerNodes { engine.attach(node) }
        engine.attach(blendMixer)
        engine.attach(eqNode)
        engine.attach(preampMixer)
        engine.attach(reverb)
        engine.attach(timePitch)
        // Connect once with format:nil; engine auto-negotiates per-file format.
        // Both decks sum into blendMixer; deck 1 starts silent.
        for node in playerNodes { engine.connect(node, to: blendMixer, format: nil) }
        playerNodes[0].volume = 1.0
        playerNodes[1].volume = 0.0
        engine.connect(blendMixer, to: eqNode, format: nil)
        engine.connect(eqNode, to: preampMixer, format: nil)
        engine.connect(preampMixer, to: reverb, format: nil)
        engine.connect(reverb, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = duckLevel
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.updatePowerLevel(buffer: buf)
            self?.updateSpectrum(buffer: buf)
        }
        do {
            try engine.start()
        } catch {
            print("Engine start error:", error)
        }
        applyGain()
        applySpatial()
        isScheduled = false
    }

    /// Preamp + the per-song loudness trim from Vocal Studio (loudness match).
    private func applyGain() {
        let trim = VocalStudio.shared.snapshot().trim
        let db = max(-14, min(9, preampDB + trim))
        preampMixer?.outputVolume = pow(10.0, db / 20.0)
    }

    /// Lowers the master only while the app speaks; EQ and the sleep fade are
    /// untouched, so the music is never permanently quieter.
    func setDuckLevel(_ v: Float) {
        let clamped = max(0.05, min(1.0, v))
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            self.duckLevel = clamped
            self.engine?.mainMixerNode.outputVolume = clamped
        }
    }

    /// Vocal Studio pushes new per-song EQ / trim values through here.
    func soundTuningChanged() {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            self.applyEQ()
            self.applyGain()
        }
    }

    /// After KaraokeRecorder swaps the session category back to playback.
    func reassertPlaybackSession() {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            self.audioSessionConfigured = true
            self.ensureEngineRunning()
            if self.isPlaying, self.audioFile != nil, !self.playerNode.isPlaying {
                self.playerNode.play()
            }
        }
    }

    private func applySpatial() {
        reverb?.wetDryMix = spatialEnhance ? 25 : 0
    }

    /// Preset curve + Smart Master's per-song correction (Vocal Studio). The
    /// correction is all zeros when the feature is off, so the old behaviour is
    /// the exact fallback.
    func applyEQ() {
        let gains = eqPreset.gains
        let smart = VocalStudio.shared.snapshot().eq
        for (i,b) in eqNode.bands.enumerated() where i < gains.count {
            let extra = i < smart.count ? smart[i] : 0
            b.gain = max(-12, min(9, gains[i] + extra))
        }
    }

    // MARK: - Interruptions / route changes

    @objc private func handleInterruption(_ n: Notification) {
        guard let type = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        if type == AVAudioSession.InterruptionType.began.rawValue {
            let wasPlaying = isPlaying
            shouldResumePlaybackAfterInterruption = wasPlaying
            playerQueue.async { [weak self] in self?.playerNode.pause() }
            onMain { [weak self] in
                self?.isPlaying = false
                self?.updateNowPlayingInfo()
            }
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            guard let opts = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let shouldResume = (opts & AVAudioSession.InterruptionOptions.shouldResume.rawValue) != 0
                || shouldResumePlaybackAfterInterruption
            guard shouldResume else { return }
            shouldResumePlaybackAfterInterruption = false
            playerQueue.async { [weak self] in
                guard let self = self else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                self.ensureEngineRunning()
                self.playerNode.play()
                self.onMain {
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    @objc private func handleRouteChange(_ n: Notification) {
        guard let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            // Headphones unplugged / Bluetooth disconnected — pause like every
            // other music app does.
            playerQueue.async { [weak self] in self?.playerNode.pause() }
            onMain { [weak self] in
                self?.isPlaying = false
                self?.updateNowPlayingInfo()
            }
        }
        playerQueue.async { [weak self] in self?.ensureEngineRunning() }
    }

    @objc private func handleMediaReset(_ n: Notification) {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            // Rebuild the engine and re-schedule the current file if possible
            self.playerNode.stop()
            self.setupEngine()
            if let f = self.audioFile {
                let frames = AVAudioFrameCount(max(0, self.fileLength - self.seekFrame))
                if frames > 0 {
                    self.scheduleSegmentOnPlayer(file: f, startFrame: self.seekFrame, framesToPlay: frames)
                }
            }
            // `isPlaying` is main-thread state; snapshot it before touching the engine.
            DispatchQueue.main.async {
                let resume = self.isPlaying
                guard resume else { return }
                playerQueue.async {
                    self.ensureEngineRunning()
                    self.playerNode.play()
                }
            }
        }
    }

    private func ensureEngineRunning() {
        if !engine.isRunning { try? engine.start() }
    }

    // MARK: - Display tick (time / levels / end detection)

    private func startLevelMeter() {
        displayLink?.invalidate()
        let dl = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() }, selector: #selector(DisplayLinkProxy.tick))
        // 60–120 Hz was pure waste: a time label and a 4-bar meter don't need
        // more than ~12 updates/sec, and every tick used to hop to the main
        // queue and republish two @Published values.
        dl.preferredFramesPerSecond = 12
        dl.add(to: .main, forMode: .common)
        dl.isPaused = true
        displayLink = dl
    }

    /// Keep the display link asleep whenever nothing is moving.
    private func updateDisplayLinkState() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.displayLink?.isPaused = !(self.isPlaying || self.isSeeking)
        }
    }

    @objc private func tick() {
        // Only update displayed time when the user isn't dragging the slider,
        // otherwise our updates fight with the user's finger.
        guard !isSeeking else { return }
        guard let node = playerNode, let file = audioFile else { return }
        let sr = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : fileSampleRate
        var sec: TimeInterval = Double(seekFrame) / sr
        if node.isPlaying, let lrt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: lrt) {
            // playerTime.sampleTime advances at rate * sampleRate (for timePitch).
            let effectiveRate = playbackRate > 0 ? playbackRate : 1.0
            sec = (Double(seekFrame) + Double(pt.sampleTime) / Double(effectiveRate)) / sr
        }
        let d = fileLength > 0 ? Double(fileLength) / fileSampleRate : 1.0
        let clamped = max(0, min(sec, d))
        // We're already on the main run loop here (CADisplayLink), so publish
        // directly and only when the value actually changed — this stops a
        // pointless SwiftUI invalidation on every single tick.
        if abs(duration - d) > 0.001 { duration = d }
        if abs(currentTime - clamped) > 0.05 { currentTime = clamped }

        // Start the next track early when crossfade/gapless is on.
        maybeArmTransition()

        // Safety net for the rare case scheduleSegment's completion doesn't fire.
        checkEndOfTrack()

        // Drain the lock-free levels written by the audio render thread.
        let l = levelL.load(), r = levelR.load()
        let smoothedL = levels.0 * 0.6 + l * 0.4
        let smoothedR = levels.1 * 0.6 + r * 0.4
        if abs(smoothedL - levels.0) > 0.005 || abs(smoothedR - levels.1) > 0.005 {
            levels = (smoothedL, smoothedR)
        }
    }

    /// Runs on the real-time audio render thread. No allocation, no locks, no
    /// dispatching — just vDSP RMS into two atomics that the display link reads.
    private func updatePowerLevel(buffer: AVAudioPCMBuffer) {
        let chCount = Int(buffer.format.channelCount)
        guard chCount > 0, let data = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0 else { return }
        var msL: Float = 0
        vDSP_measqv(data[0], 1, &msL, frames)
        let rmsL = sqrt(msL)
        var rmsR = rmsL
        if chCount >= 2 {
            var msR: Float = 0
            vDSP_measqv(data[1], 1, &msR, frames)
            rmsR = sqrt(msR)
        }
        let dbL = rmsL > 0 ? 20 * log10(rmsL) : -60
        let dbR = rmsR > 0 ? 20 * log10(rmsR) : -60
        levelL.store(max(0, min(1, (dbL + 50) / 50)))
        levelR.store(max(0, min(1, (dbR + 50) / 50)))
    }

    /// Runs on the real-time audio render thread: Hann window + in-place FFT
    /// + log-band reduction into pre-allocated buffers (no allocations).
    private func updateSpectrum(buffer: AVAudioPCMBuffer) {
        fft.process(buffer: buffer, into: &fftScratch)
        spectrum.store(fftScratch)
    }

    // MARK: - Playback primitives

    /// Schedule a segment of `audioFile` on playerNode. CALL FROM playerQueue.
    /// Clears any previously scheduled buffers first via stop().
    private func scheduleSegmentOnPlayer(file: AVAudioFile, startFrame: AVAudioFramePosition, framesToPlay: AVAudioFrameCount) {
        playerNode.stop()
        scheduleGeneration &+= 1
        let gen = scheduleGeneration
        seekFrame = startFrame
        scheduledSegmentEnd = startFrame + AVAudioFramePosition(framesToPlay)
        playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay, at: nil) { [weak self] in
            guard let self = self else { return }
            playerQueue.async {
                // If a newer schedule (seek/new song/rate change) happened
                // after this callback was enqueued, ignore it — otherwise
                // a stale completion fires songFinished mid-playback.
                if self.scheduleGeneration != gen { return }
                self.isScheduled = false
                if self.isPlaying && self.audioFile != nil
                    && self.seekFrame + AVAudioFramePosition(framesToPlay) >= self.fileLength - 1 {
                    DispatchQueue.main.async { self.songFinished() }
                }
            }
        }
        isScheduled = true
    }

    private func playCurrent(resumeFrom seekTime: TimeInterval? = nil) {
        guard let file = audioFile else { return }
        let sr = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : fileSampleRate
        let targetFrame: AVAudioFramePosition
        if let t = seekTime {
            targetFrame = max(0, min(AVAudioFramePosition(t * sr), fileLength - 1))
        } else {
            targetFrame = 0
        }
        let remaining = AVAudioFrameCount(max(0, fileLength - targetFrame))
        guard remaining > 0 else { return }
        scheduleSegmentOnPlayer(file: file, startFrame: targetFrame, framesToPlay: remaining)
        timePitch.rate = playbackRate
        ensureEngineRunning()
        playerNode.rate = playbackRate
        playerNode.play()
        onMain { [weak self] in
            self?.isPlaying = true
            self?.updateDisplayLinkState()
        }
    }

    // MARK: - Public controls

    func seek(to time: TimeInterval) {
        beginSeek(to: time)
        endSeek(to: time)
    }

    /// Called when the user starts dragging the slider (pauses audio if playing
    /// so preview scrubbing is glitch-free).
    func beginSeek(to time: TimeInterval? = nil) {
        isSeeking = true
        if let t = time { seekPreviewTime = t }
        // Do NOT stop playback while scrubbing on iOS 16+; we only pause live
        // time updates. Pausing/stopping mid-drag causes AVAudioEngine stalls.
    }

    /// Called when the user releases the slider: actually re-schedule from the
    /// requested time.
    func endSeek(to time: TimeInterval) {
        isSeeking = false
        // Scrubbing away from the end cancels a transition that was arming;
        // scrubbing back toward it will simply re-arm on the next tick.
        cancelPendingTransition()
        let t = max(0, min(time, duration))
        seekPreviewTime = t
        // Snapshot main-thread state before hopping onto the player queue.
        let wasPlaying = isPlaying
        playerQueue.async { [weak self] in
            guard let self = self, let file = self.audioFile else { return }
            // Stop current playback and clear scheduled state before rescheduling
            self.playerNode.stop()
            self.isScheduled = false
            let sr = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : self.fileSampleRate
            let frame = max(0, min(AVAudioFramePosition(t * sr), self.fileLength - 1))
            self.seekFrame = frame
            let remaining = AVAudioFrameCount(max(0, self.fileLength - frame))
            guard remaining > 0 else {
                DispatchQueue.main.async {
                    self.currentTime = t
                    if wasPlaying { self.songFinished() }
                }
                return
            }
            self.scheduleSegmentOnPlayer(file: file, startFrame: frame, framesToPlay: remaining)
            self.timePitch.rate = self.playbackRate
            self.ensureEngineRunning()
            self.playerNode.rate = self.playbackRate
            if wasPlaying { self.playerNode.play() }
            DispatchQueue.main.async {
                self.currentTime = t
                if !wasPlaying { self.isPlaying = false }
                self.updateDisplayLinkState()
                self.updateNowPlayingInfo()
            }
        }
    }

    func setPlaybackRate(_ r: Float) {
        let clamped = max(0.5, min(2.0, r))
        playbackRate = clamped
        UserDefaults.standard.set(clamped, forKey: "asmusic_rate")
        // Changing rate on a playing AVAudioPlayerNode requires rescheduling on
        // iOS 26 to avoid distortion/crash; do it cleanly.
        let wasPlaying = isPlaying
        let resumeAt = currentTime
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            self.timePitch.rate = clamped
            if wasPlaying, let file = self.audioFile {
                self.playerNode.stop()
                self.isScheduled = false
                let sr = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : self.fileSampleRate
                let frame = max(0, min(AVAudioFramePosition(resumeAt * sr), self.fileLength - 1))
                self.seekFrame = frame
                let remaining = AVAudioFrameCount(max(0, self.fileLength - frame))
                if remaining > 0 {
                    self.scheduleSegmentOnPlayer(file: file, startFrame: frame, framesToPlay: remaining)
                    self.playerNode.rate = clamped
                    self.ensureEngineRunning()
                    self.playerNode.play()
                }
            } else {
                self.playerNode.rate = clamped
            }
            self.onMain { self.updateNowPlayingInfo() }
        }
    }

    func cyclePlaybackRate() {
        let steps: [Float] = [0.75, 1.0, 1.25, 1.5]
        if let idx = steps.firstIndex(of: playbackRate) {
            setPlaybackRate(steps[(idx + 1) % steps.count])
        } else {
            setPlaybackRate(1.0)
        }
    }

    func formatTime(_ t: TimeInterval) -> String {
        if t.isNaN || t.isInfinite { return "0:00" }
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Library / playlists / metadata

    func loadSongs() {
        let meta = Self.loadSongMeta()
        do {
            let files = try fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            let audioExts = ["mp3","m4a","wav","webm","mp4","aac","ogg","opus"]
            let audio = files.filter { audioExts.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
            for f in audio {
                try? fileManager.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: f.path)
            }
            var discoveredNew = false
            let mapped: [Song] = audio.map { url -> Song in
                let rawName = url.deletingPathExtension().lastPathComponent
                if var s = meta[url.lastPathComponent] {
                    s.url = url
                    if s.artist.isEmpty { s.artist = "AS Music" }
                    let (t,a) = TitleCleaner.clean(rawName, artistHint: s.artist == "AS Music" ? nil : s.artist)
                    s.title = t; s.artist = a
                    if s.title.isEmpty { s.title = rawName }
                    return s
                }
                // No metadata yet (file arrived via AirDrop / Files / iTunes).
                // Derive a DETERMINISTIC id from the file name so playlists and
                // "Liked Songs" survive a relaunch — the old code minted a fresh
                // UUID() on every load, which silently emptied every playlist.
                discoveredNew = true
                let (t,a) = TitleCleaner.clean(rawName)
                return Song(id: Self.stableID(for: url.lastPathComponent),
                            title: t, url: url, artist: a, artworkURL: nil, sourceVid: nil)
            }.sorted { $0.title.lowercased() < $1.title.lowercased() }

            DispatchQueue.main.async {
                self.songs = mapped
                // Persist ids for newly discovered files so they're stable even
                // if the naming scheme ever changes.
                if discoveredNew { self.saveSongMeta() }
            }
        } catch {}
    }

    /// Deterministic UUID derived from the file name (RFC-4122-shaped v5-ish).
    /// Same file name always yields the same id, on every launch and device.
    static func stableID(for fileName: String) -> UUID {
        var digest = Array(SHA256.hash(data: Data(fileName.utf8)))
        digest[6] = (digest[6] & 0x0F) | 0x50   // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80   // RFC 4122 variant
        let b = digest.prefix(16)
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],
                           b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }

    /// Deletes a song. By default the file is **moved to Recently Deleted**
    /// (`LibraryTrash`) instead of being erased, so a wrong tap — or an
    /// over-eager duplicate clean — is one button away from being undone.
    /// Pass `permanently: true` (or turn the safety net off in Recently
    /// Deleted) to erase the bytes immediately.
    func deleteSong(_ s: Song, permanently: Bool = false, reason: String? = nil) {
        // Remember where this song lived so a restore can put it back.
        let memberships = playlists
            .filter { $0.name != "Liked Songs" && $0.songIDs.contains(s.id) }
            .map { $0.name }
        let liked = isFavorite(song: s)
        let archived = permanently
            ? false
            : LibraryTrash.shared.accept(song: s, liked: liked,
                                         playlistNames: memberships, reason: reason)
        if !archived {
            try? fileManager.removeItem(at: s.url)
            try? fileManager.removeItem(at: s.url.deletingPathExtension().appendingPathExtension("jpg"))
        }
        try? fileManager.removeItem(at: artworkCacheDir.appendingPathComponent("\(s.id.uuidString).jpg"))
        upNextQueue.removeAll { $0.id == s.id }
        // Drop dangling references so playlists don't accumulate dead ids.
        for i in playlists.indices { playlists[i].songIDs.removeAll { $0 == s.id } }
        savePlaylists()
        if currentSong?.id == s.id {
            playerQueue.async { [weak self] in
                self?.playerNode.stop()
                self?.isScheduled = false
                self?.audioFile = nil
            }
            currentSong = nil
            isPlaying = false
            updateDisplayLinkState()
            updateNowPlayingInfo()
        }
        songs.removeAll { $0.id == s.id }
        // Play counts are kept while the song sits in Recently Deleted, so a
        // restore brings its history (and its weight in the smart playlists)
        // back with it.
        if !archived { ListenHistory.shared.remove(songID: s.id) }
        saveSongMeta()
        loadSongs()
    }

    func renameSong(song: Song, newName: String) {
        let (t, a) = TitleCleaner.clean(newName)
        setSongInfo(song: song, title: t, artist: a)
    }

    /// Changes the visible title/artist of a song and renames the file to match,
    /// so the change is still there after a relaunch.
    ///
    /// The important half of this method is what it *keeps*: a song's id is a
    /// hash of its file name, so the old implementation silently orphaned
    /// everything attached to it — the song fell out of every playlist, out of
    /// Liked Songs, and lost its play counts. Writing the new name into the
    /// in-memory list and persisting it BEFORE the reload is what carries the
    /// id (and therefore the playlists, the likes and the history) across.
    func setSongInfo(song: Song, title: String, artist: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = song.url.pathExtension
        let base = Self.safeFileName(cleanArtist.isEmpty ? cleanTitle : "\(cleanArtist) - \(cleanTitle)")
        guard !base.isEmpty else { return }

        var newURL = documentsDirectory.appendingPathComponent(base + "." + ext)
        if newURL.lastPathComponent.caseInsensitiveCompare(song.url.lastPathComponent) == .orderedSame {
            // Only the casing / metadata changed — keep the file exactly where
            // it is so we never fight ourselves over the same name.
            newURL = song.url
        } else {
            var i = 2
            while fileManager.fileExists(atPath: newURL.path) {
                newURL = documentsDirectory.appendingPathComponent("\(base) \(i)." + ext)
                i += 1
            }
        }

        do {
            if newURL != song.url {
                try fileManager.moveItem(at: song.url, to: newURL)
                let oldSide = song.url.deletingPathExtension().appendingPathExtension("jpg")
                let newSide = newURL.deletingPathExtension().appendingPathExtension("jpg")
                if fileManager.fileExists(atPath: oldSide.path) {
                    try? fileManager.moveItem(at: oldSide, to: newSide)
                }
            }

            let finalArtist = cleanArtist.isEmpty ? "AS Music" : cleanArtist
            if let idx = songs.firstIndex(where: { $0.id == song.id }) {
                songs[idx].url = newURL
                songs[idx].title = cleanTitle.isEmpty ? songs[idx].title : cleanTitle
                songs[idx].artist = finalArtist
            } else {
                var s = song
                s.url = newURL
                s.title = cleanTitle.isEmpty ? song.title : cleanTitle
                s.artist = finalArtist
                songs.append(s)
            }
            // Persist FIRST: the meta file is keyed by file name and is the only
            // place the id is stored, so this is what keeps the identity alive.
            saveSongMeta()

            if currentSong?.id == song.id {
                currentSong = songs.first(where: { $0.id == song.id }) ?? currentSong
                updateNowPlayingInfo()
            }
            if let qi = upNextQueue.firstIndex(where: { $0.id == song.id }),
               let fresh = songs.first(where: { $0.id == song.id }) {
                upNextQueue[qi] = fresh
            }
            loadSongs()

            // Keep the MP3 tag in step so other players show the new name too.
            if newURL.pathExtension.lowercased() == "mp3" {
                let tagURL = newURL
                let tagTitle = cleanTitle
                DispatchQueue.global(qos: .utility).async {
                    _ = ID3TagWriter.tagIfNeeded(at: tagURL, title: tagTitle,
                                                 artist: finalArtist, album: "",
                                                 artworkJPEG: nil)
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// File names come from user text, so strip the characters that would send
    /// the file into another folder or confuse the importers.
    static func safeFileName(_ s: String) -> String {
        var out = s
        for bad in ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"] {
            out = out.replacingOccurrences(of: bad, with: "-")
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    func shareSong(_ song: Song) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        let ac = UIActivityViewController(activityItems: [song.url], applicationActivities: nil)
        if let pop = ac.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        root.present(ac, animated: true)
    }

    func createPlaylist(name: String) {
        playlists.append(Playlist(id: UUID(), name: name, songIDs: []))
        savePlaylists()
    }

    /// Deletes ANY playlist except "Liked Songs". The songs themselves stay in
    /// the Library — only the list goes away. If the playlist is a smart (✨)
    /// one, its kind is also *retired* in `SmartPlaylistStore`, so the
    /// auto-create pass never silently resurrects a list the user removed.
    func deletePlaylist(_ playlist: Playlist, recordUndo: Bool = true) {
        guard playlist.name != "Liked Songs" else { return }
        if recordUndo {
            recentlyDeletedPlaylists = [playlist]
            scheduleUndoExpiry()
        }
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
        if let kind = SmartPlaylistStore.shared.kind(for: playlist.id) {
            SmartPlaylistStore.shared.remove(kind: kind)
            SmartPlaylistStore.shared.retire(kind: kind)
        }
        objectWillChange.send()
    }

    /// Deletes several playlists at once (the Playlists tab's Select mode) and
    /// keeps a copy so the whole batch can be undone with one tap.
    @discardableResult
    func deletePlaylists(ids: Set<UUID>) -> Int {
        let doomed = playlists.filter { ids.contains($0.id) && $0.name != "Liked Songs" }
        guard !doomed.isEmpty else { return 0 }
        recentlyDeletedPlaylists = doomed
        for p in doomed { deletePlaylist(p, recordUndo: false) }
        scheduleUndoExpiry()
        return doomed.count
    }

    /// The Undo banner is a safety net, not a permanent fixture: it fades ten
    /// seconds after the delete unless the user acts on it.
    private func scheduleUndoExpiry() {
        let snapshot = recentlyDeletedPlaylists.map { $0.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            if self.recentlyDeletedPlaylists.map({ $0.id }) == snapshot {
                withAnimation { self.recentlyDeletedPlaylists = [] }
            }
        }
    }

    /// Puts the last deleted playlist(s) back, exactly as they were — including
    /// un-retiring smart ✨ lists so the auto-DJ keeps refreshing them.
    @discardableResult
    func undoPlaylistDelete() -> Int {
        let back = recentlyDeletedPlaylists
        guard !back.isEmpty else { return 0 }
        for p in back where !playlists.contains(where: { $0.id == p.id }) {
            playlists.append(p)
            if let kind = SmartPlaylistStore.shared.kind(for: p.id) {
                SmartPlaylistStore.shared.unretire(kind: kind)
            }
        }
        savePlaylists()
        recentlyDeletedPlaylists = []
        objectWillChange.send()
        return back.count
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) {        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, playlist.name != "Liked Songs" else { return }
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].name = clean
        savePlaylists()
        if let kind = SmartPlaylistStore.shared.kind(for: playlist.id) {
            SmartPlaylistStore.shared.set(kind: kind, playlistID: playlist.id,
                                          name: clean, count: playlists[idx].songIDs.count)
        }
        objectWillChange.send()
    }

    /// Empties the "Up Next" queue (one tap from the Library header).
    func clearUpNext() {
        upNextQueue.removeAll()
        objectWillChange.send()
    }
    func addSongToPlaylist(song: Song, playlist: Playlist) {
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            if !playlists[idx].songIDs.contains(song.id) {
                playlists[idx].songIDs.append(song.id); savePlaylists()
            }
        }
    }
    /// Index of the "Liked Songs" playlist, looked up by name rather than
    /// assuming index 0 — the old code inserted a brand-new empty playlist
    /// (burying the real one) whenever anything else ended up first.
    private var likedIndex: Int {
        if let i = playlists.firstIndex(where: { $0.name == "Liked Songs" }) { return i }
        playlists.insert(Playlist(id: UUID(), name: "Liked Songs", songIDs: []), at: 0)
        savePlaylists()
        return 0
    }
    func toggleFavorite(song: Song) {
        let i = likedIndex
        if playlists[i].songIDs.contains(song.id) {
            playlists[i].songIDs.removeAll { $0 == song.id }
        } else {
            playlists[i].songIDs.append(song.id)
        }
        savePlaylists(); objectWillChange.send()
    }
    func isFavorite(song: Song) -> Bool {
        guard let i = playlists.firstIndex(where: { $0.name == "Liked Songs" }) else { return false }
        return playlists[i].songIDs.contains(song.id)
    }
    func savePlaylists() {
        if let d = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(d, forKey: "savedPlaylists")
        }
    }
    func loadPlaylists() {
        if let d = UserDefaults.standard.data(forKey: "savedPlaylists"),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: d) { playlists = decoded }
        if !playlists.contains(where: { $0.name == "Liked Songs" }) {
            playlists.insert(Playlist(id: UUID(), name: "Liked Songs", songIDs: []), at: 0)
            savePlaylists()
        }
    }

    func loadPrefs() {
        if let rate = UserDefaults.standard.object(forKey: "asmusic_rate") as? Float { playbackRate = rate }
        // `integer(forKey:)` returns a non-optional Int, so the old
        // `as Int?` + `if let` dance never actually guarded anything.
        if let r = UserDefaults.standard.object(forKey: "asmusic_repeat") as? Int,
           let m = RepeatMode(rawValue: r) { repeatMode = m }
        if let eqName = UserDefaults.standard.string(forKey: "asmusic_eq"), let e = EQPreset(rawValue: eqName) { eqPreset = e }
        else { eqPreset = .flat }
        if let accId = UserDefaults.standard.string(forKey: "asmusic_accent"),
           let a = AppAccent.list.first(where: { $0.id == accId }) { accent = a }
        smartRadioMode = UserDefaults.standard.bool(forKey: "asmusic_radio")
        preampDB = UserDefaults.standard.object(forKey: "asmusic_preamp") as? Float ?? 0.0
        spatialEnhance = UserDefaults.standard.bool(forKey: "asmusic_spatial")
        stopAtSongEnd = UserDefaults.standard.bool(forKey: "asmusic_stopend")
        if let t = UserDefaults.standard.string(forKey: "asmusic_transition"),
           let m = TransitionMode(rawValue: t) { transitionMode = m }
        if let s = UserDefaults.standard.object(forKey: "asmusic_xfade_secs") as? Double {
            crossfadeSeconds = max(1.5, min(12, s))
        }
        if let lastIdStr = UserDefaults.standard.string(forKey: "asmusic_last_song"),
           let lastId = UUID(uuidString: lastIdStr) {
            lastSongId = lastId
            lastSongTime = UserDefaults.standard.double(forKey: "asmusic_last_time")
        }
    }

    func saveResumePosition() {
        guard let s = currentSong else { return }
        lastSongId = s.id
        lastSongTime = currentTime
        UserDefaults.standard.set(s.id.uuidString, forKey: "asmusic_last_song")
        UserDefaults.standard.set(currentTime, forKey: "asmusic_last_time")
    }

    /// Call this when the app is backgrounded or about to terminate to persist
    /// the current playback position. Public so AppDelegate can invoke it.
    func appWillBackground() {
        saveResumePosition()
    }

    // MARK: - Artwork

    /// Always calls `completion` on the main thread — callers (notably
    /// `updateNowPlayingInfo`) depend on a consistent, asynchronous contract.
    /// The old version called back synchronously for cached files, which is
    /// what broke the lock-screen artwork.
    func artworkImage(for song: Song, size: CGFloat = 200, completion: @escaping (UIImage?) -> Void) {
        let sidecar = song.url.deletingPathExtension().appendingPathExtension("jpg")
        let cached = artworkCacheDir.appendingPathComponent("\(song.id.uuidString).jpg")
        let artURL = song.artworkURL.flatMap { URL(string: $0) }
        let finish: (UIImage?) -> Void = { img in
            DispatchQueue.main.async { completion(img) }
        }
        // Disk decoding happens off the main thread so library scrolling stays smooth.
        DispatchQueue.global(qos: .userInitiated).async {
            if let img = UIImage(contentsOfFile: sidecar.path) { finish(img); return }
            if let img = UIImage(contentsOfFile: cached.path) { finish(img); return }
            guard let u = artURL else { finish(nil); return }
            URLSession.shared.dataTask(with: u) { data, _, _ in
                guard let data = data, let img = UIImage(data: data) else { finish(nil); return }
                try? data.write(to: cached, options: .atomic)
                finish(img)
            }.resume()
        }
    }

    func isDuplicateByVID(_ vid: String) -> Bool { songs.contains { $0.sourceVid == vid } }
    func songByVID(_ vid: String) -> Song? { songs.first { $0.sourceVid == vid } }

    static private let metaURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".asmusic_meta.json")
    }()
    static private func loadSongMeta() -> [String: Song] {
        guard let d = try? Data(contentsOf: metaURL),
              let arr = try? JSONDecoder().decode([Song].self, from: d) else { return [:] }
        var out = [String: Song]()
        for s in arr { out[s.url.lastPathComponent] = s }
        return out
    }
    func saveSongMeta() {
        if let d = try? JSONEncoder().encode(songs) { try? d.write(to: Self.metaURL, options: .atomic) }
    }
    func registerDownloadedSong(title: String, artist: String, url: URL, sourceVid: String?, artworkURL: String?) {
        DispatchQueue.main.async {
            let (t,a) = TitleCleaner.clean(title, artistHint: artist)
            let song = Song(id: Self.stableID(for: url.lastPathComponent), title: t, url: url,
                            artist: a.isEmpty ? "AS Music" : a,
                            artworkURL: artworkURL, sourceVid: sourceVid)
            self.songs.removeAll { $0.url.lastPathComponent == url.lastPathComponent }
            self.songs.append(song)
            self.songs.sort { $0.title.lowercased() < $1.title.lowercased() }
            self.saveSongMeta()
            if let art = artworkURL, let u = URL(string: art) {
                let sidecar = url.deletingPathExtension().appendingPathExtension("jpg")
                if !self.fileManager.fileExists(atPath: sidecar.path) {
                    URLSession.shared.downloadTask(with: u) { loc, _, _ in
                        if let loc = loc { try? self.fileManager.moveItem(at: loc, to: sidecar) }
                    }.resume()
                }
            }
            // No cover came with the download — let iTunes (free, key-less)
            // find the real artwork, artist name and genre.
            if artworkURL == nil {
                ITunesEnricher.shared.enrich(song: song)
            }
            // Measure the new file and (debounced) rebuild the smart playlists,
            // so a fresh download lands in "Fresh Finds" without a relaunch.
            AudioLab.shared.ensureAnalyzed(song)
            SmartPlaylistEngine.shared.scheduleAutoSync(delay: 25)
            // Write proper MP3 tags (title/artist/cover) once the sidecar
            // artwork has had a moment to land. Pre-tagged files are skipped.
            if url.pathExtension.lowercased() == "mp3" {
                let tagURL = url
                let tagSidecar = url.deletingPathExtension().appendingPathExtension("jpg")
                let tagTitle = t
                let tagArtist = (a.isEmpty ? "AS Music" : a)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.2) {
                    var artData: Data? = nil
                    if let d = try? Data(contentsOf: tagSidecar), d.count > 500 { artData = d }
                    _ = ID3TagWriter.tagIfNeeded(at: tagURL, title: tagTitle,
                                                 artist: tagArtist, album: "", artworkJPEG: artData)
                }
            }
        }
    }

    // MARK: - Importing your own files

    /// Copies audio files chosen in the Files app (or opened from AirDrop /
    /// another app) into the Library.
    ///
    /// Everything a downloaded song gets, an imported one gets too: a stable
    /// id, metadata read from its own tags, artwork/genre enrichment, acoustic
    /// analysis and a smart-playlist refresh. Returns (imported, skipped).
    @discardableResult
    func importAudioFiles(from urls: [URL]) -> (imported: Int, skipped: Int) {
        var imported = 0
        var skipped = 0
        let exts = Set(["mp3","m4a","wav","webm","mp4","aac","ogg","opus","flac","aiff","aif","caf"])

        for src in urls {
            let ext = src.pathExtension.lowercased()
            guard exts.contains(ext) else { skipped += 1; continue }

            // Security-scoped access is required for files picked outside the
            // sandbox; harmless (and false) for ones already inside it.
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }

            // Prefer the embedded tags over the file name for the final name.
            let asset = AVURLAsset(url: src)
            var tagTitle = ""
            var tagArtist = ""
            for meta in asset.commonMetadata {
                guard let key = meta.commonKey?.rawValue, let value = meta.stringValue else { continue }
                if key == "title", tagTitle.isEmpty { tagTitle = value }
                if key == "artist", tagArtist.isEmpty { tagArtist = value }
            }
            let rawName = src.deletingPathExtension().lastPathComponent
            let cleaned = TitleCleaner.clean(tagTitle.isEmpty ? rawName : tagTitle,
                                             artistHint: tagArtist.isEmpty ? nil : tagArtist)
            let title = cleaned.0
            let artist = tagArtist.isEmpty ? cleaned.1 : tagArtist
            let base = (artist.isEmpty || artist == "AS Music") ? title : "\(artist) - \(title)"
            var fileName = Self.safeFileName(base)
            if fileName.isEmpty { fileName = Self.safeFileName(rawName) }
            if fileName.isEmpty { fileName = "Imported \(Int(Date().timeIntervalSince1970))" }

            // Never clobber an existing file: add " 2", " 3", …
            var dest = documentsDirectory.appendingPathComponent("\(fileName).\(ext)")
            var n = 2
            while fileManager.fileExists(atPath: dest.path) {
                // Same name AND same size = the user already has this file.
                let existing = (try? fileManager.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                let incoming = (try? fileManager.attributesOfItem(atPath: src.path)[.size] as? Int64) ?? -1
                if existing == incoming, incoming > 0 { break }
                dest = documentsDirectory.appendingPathComponent("\(fileName) \(n).\(ext)")
                n += 1
                if n > 50 { break }
            }
            if fileManager.fileExists(atPath: dest.path) { skipped += 1; continue }

            do {
                try fileManager.copyItem(at: src, to: dest)
            } catch {
                skipped += 1
                continue
            }

            registerDownloadedSong(title: title.isEmpty ? rawName : title,
                                   artist: artist.isEmpty ? "AS Music" : artist,
                                   url: dest,
                                   sourceVid: nil,
                                   artworkURL: nil)
            imported += 1
        }

        if imported > 0 {
            loadSongs()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AudioLab.shared.prime(self.songs)
                ITunesEnricher.shared.enrichLibrary()
            }
        }
        return (imported, skipped)
    }

    /// Sets a song's genre (used by the identifier and the enricher).
    func setGenre(songID: UUID, genre: String) {
        let clean = genre.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = songs.firstIndex(where: { $0.id == songID }) else { return }
        guard songs[i].genre != clean else { return }
        songs[i].genre = clean
        saveSongMeta()
    }

    /// Sets a song's artwork URL and drops the stale cached thumbnail so the
    /// new cover is fetched on next display.
    func setArtworkURL(songID: UUID, url: String) {
        let clean = url.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = songs.firstIndex(where: { $0.id == songID }) else { return }
        guard songs[i].artworkURL != clean else { return }
        songs[i].artworkURL = clean
        try? fileManager.removeItem(at: artworkCacheDir.appendingPathComponent("\(songID.uuidString).jpg"))
        saveSongMeta()
    }

    // MARK: - Queue

    func playNext(_ song: Song) {
        if let cur = currentSong, cur.id == song.id { return }
        upNextQueue.insert(song, at: 0)
        objectWillChange.send()
    }
    func playLater(_ song: Song) {
        if let cur = currentSong, cur.id == song.id { return }
        if !upNextQueue.contains(where: { $0.id == song.id }) { upNextQueue.append(song) }
        objectWillChange.send()
    }
    func toggleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
        UserDefaults.standard.set(repeatMode.rawValue, forKey: "asmusic_repeat")
        objectWillChange.send()
    }
    func toggleSmartRadio() {
        smartRadioMode.toggle()
        UserDefaults.standard.set(smartRadioMode, forKey: "asmusic_radio")
        objectWillChange.send()
    }

    func setSleepTimer(minutes: Int) {
        sleepTimer?.invalidate(); sleepTimer = nil
        fadeTimer?.invalidate(); fadeTimer = nil
        sleepTimerMinutes = minutes
        if minutes > 0 {
            if stopAtSongEnd {
                // The stop happens at the natural end of the song (see
                // songFinished); this timer is only a failsafe for very long
                // tracks that outlast the requested sleep duration.
                pendingStopAtEnd = true
            }
            let fireDelay: TimeInterval = stopAtSongEnd
                ? TimeInterval(minutes * 60)
                : max(60, TimeInterval(minutes * 60) - sleepFadeSeconds)
            sleepTimer = Timer.scheduledTimer(withTimeInterval: fireDelay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async { self.beginFadeThenPause() }
            }
        } else {
            pendingStopAtEnd = false
        }
    }

    /// Smoothly fades the output down over `sleepFadeSeconds`, pauses, then
    /// restores the user's preamp level. Much gentler than the old hard stop.
    private func beginFadeThenPause() {
        guard isPlaying else {
            pendingStopAtEnd = false
            sleepTimerMinutes = 0
            return
        }
        sleepTimer?.invalidate(); sleepTimer = nil
        preFadeDB = preampDB
        let steps = 30
        var i = 0
        let timer = Timer.scheduledTimer(withTimeInterval: sleepFadeSeconds / Double(steps),
                                         repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            i += 1
            let frac = Float(i) / Float(steps)
            self.preampDB = self.preFadeDB * (1.0 - frac)
            if i >= steps {
                t.invalidate()
                self.fadeTimer = nil
                self.pausePlayback()
                self.preampDB = self.preFadeDB
                self.sleepTimerMinutes = 0
                self.pendingStopAtEnd = false
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Cancels an in-progress sleep fade (the user took back control).
    private func cancelSleepFade() {
        guard fadeTimer != nil else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        preampDB = preFadeDB
        sleepTimerMinutes = 0
        pendingStopAtEnd = false
    }

    // MARK: - Transitions (gapless / crossfade / auto-DJ)

    /// The song that will play after the current one, without consuming the
    /// queue — needed to pre-load the next deck before the current track ends.
    private func peekNextSong() -> Song? {
        if let first = upNextQueue.first { return first }
        if repeatMode == .one { return nil }             // handled by re-scheduling
        if smartRadioMode, let cur = currentSong {
            return SmartRadio.nextTrack(after: cur, recent: recentlyPlayedIDs())
        }
        if isShuffle {
            let recent = recentlyPlayedIDs()
            let pool = songs.filter {
                $0.id != currentSong?.id && !ListenHistory.shared.isDisliked($0) && !recent.contains($0.id)
            }
            return (pool.isEmpty ? songs.filter { $0.id != currentSong?.id } : pool).randomElement()
        }
        guard let c = currentSong, let i = songs.firstIndex(of: c) else { return songs.first }
        if i + 1 < songs.count { return songs[i + 1] }
        if repeatMode == .all { return songs.first }
        return nil
    }

    /// How long the blend into `next` should last, in seconds.
    ///
    /// Auto-DJ reads the measured features of both tracks: two steady, similar
    /// beat-driven songs can take a long overlap, while anything quiet, spoken
    /// or very different gets a short one (a long blend into a recitation or a
    /// ballad sounds like a mistake, not a mix).
    private func transitionLength(from: Song?, to next: Song) -> Double {
        let base = max(1.5, min(12, crossfadeSeconds))
        guard transitionMode == .autoDJ else { return base }
        guard let a = from.flatMap({ AudioLab.shared.features(for: $0) }),
              let b = AudioLab.shared.features(for: next) else { return min(base, 3) }

        // Both need a real, similar beat for a long blend to work.
        let beatish = min(a.beatStrength, b.beatStrength)
        let tempoGap = abs(a.tempo - b.tempo)
        let energyGap = abs(a.energy - b.energy)

        var secs = base
        if beatish < 0.25 { secs = min(secs, 2.5) }        // rubato / spoken
        if tempoGap > 24 { secs = min(secs, 3.0) }         // very different pace
        if energyGap > 0.35 { secs = min(secs, 3.0) }      // loud -> quiet
        if b.looksInstrumental && a.vocalForward { secs = min(secs, 3.5) }
        if beatish > 0.45 && tempoGap < 8 && energyGap < 0.18 {
            secs = min(12, max(secs, base * 1.5))          // a genuine DJ blend
        }
        return max(1.5, secs)
    }

    /// Called from the display tick: starts the next track early enough to
    /// overlap, or exactly at the end for gapless.
    private func maybeArmTransition() {
        guard transitionMode != .off, !transitionArmed, isPlaying, !isSeeking else { return }
        guard repeatMode != .one else { return }
        guard duration > 3 else { return }

        // Where the audio really ends (a rip often has dead air at the tail).
        let tail = currentSong.flatMap { AudioLab.shared.features(for: $0)?.tailSilence } ?? 0
        let audioEnd = max(1, duration - min(tail, max(0, duration - 2)))

        guard let next = peekNextSong() else { return }
        let blend = transitionMode.blends ? transitionLength(from: currentSong, to: next) : 0
        // Gapless still needs a moment of lead time to open the file.
        let lead = transitionMode.blends ? blend : 0.35
        guard currentTime >= audioEnd - lead else { return }

        transitionArmed = true
        pendingNextSong = next
        if transitionMode.blends {
            startCrossfade(to: next, over: blend)
        } else {
            startGapless(to: next)
        }
    }

    private func cancelPendingTransition() {
        transitionArmed = false
        pendingNextSong = nil
        fadeLink?.invalidate()
        fadeLink = nil
        if isCrossfading { isCrossfading = false }
        // Restore deck volumes so nothing is left half-faded.
        playerNodes.indices.forEach { playerNodes[$0].volume = ($0 == activeDeck) ? 1.0 : 0.0 }
    }

    /// Gapless: hand over to the next track with no blend and no silence.
    private func startGapless(to next: Song) {
        beginTrack(next, onDeck: idleDeck, fadeIn: false) { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.transitionArmed = false; self.pendingNextSong = nil; return }
            self.completeHandover(to: next)
        }
    }

    /// Crossfade: bring the next track up on the idle deck while this one
    /// fades down, then hand over.
    private func startCrossfade(to next: Song, over seconds: Double) {
        beginTrack(next, onDeck: idleDeck, fadeIn: true) { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.transitionArmed = false; self.pendingNextSong = nil; return }
            self.runFade(seconds: seconds, next: next)
        }
    }

    /// Ramps the two decks past each other with an equal-power curve, then
    /// completes the handover.
    private func runFade(seconds: Double, next: Song) {
        let outgoing = activeDeck
        let incoming = idleDeck
        let start = CACurrentMediaTime()
        let dur = max(0.4, seconds)

        isCrossfading = true
        fadeLink?.invalidate()
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in
            guard let self = self else { return }
            let t = min(1.0, (CACurrentMediaTime() - start) / dur)
            // Equal-power (constant loudness) crossfade — a linear ramp dips
            // audibly in the middle.
            let outVol = Float(cos(t * Double.pi / 2))
            let inVol = Float(sin(t * Double.pi / 2))
            if self.playerNodes.indices.contains(outgoing) { self.playerNodes[outgoing].volume = outVol }
            if self.playerNodes.indices.contains(incoming) { self.playerNodes[incoming].volume = inVol }
            if t >= 1.0 {
                self.fadeLink?.invalidate()
                self.fadeLink = nil
                self.isCrossfading = false
                self.completeHandover(to: next)
            }
        }, selector: #selector(DisplayLinkProxy.tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        fadeLink = link
    }

    /// Opens `song` on `deck` and starts it. `completion(false)` when the file
    /// could not be read, so the caller can fall back to the normal path.
    private func beginTrack(_ song: Song, onDeck deck: Int, fadeIn: Bool,
                            completion: @escaping (Bool) -> Void) {
        playerQueue.async { [weak self] in
            guard let self = self, self.playerNodes.indices.contains(deck) else {
                DispatchQueue.main.async { completion(false) }; return
            }
            do {
                let file = try AVAudioFile(forReading: song.url)
                let node = self.playerNodes[deck]
                node.stop()
                let lead = VocalStudio.shared.leadOffset(for: song)
                let sr = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : 44100
                let startFrame = max(0, min(AVAudioFramePosition(lead * sr), max(0, file.length - 1)))
                let frames = AVAudioFrameCount(max(0, file.length - startFrame))
                guard frames > 0 else { DispatchQueue.main.async { completion(false) }; return }

                // The incoming deck is silent until the fade moves it.
                node.volume = fadeIn ? 0.0 : 1.0

                // This deck is about to become the active one, so it needs the
                // same end-of-track callback the normal path installs — without
                // it the app would play this song and then simply stop.
                // Bumping the generation also retires the OUTGOING deck's
                // handler, which is what we want: the transition, not that
                // handler, is what advances the queue now.
                self.scheduleGeneration &+= 1
                let gen = self.scheduleGeneration
                let endFrame = startFrame + AVAudioFramePosition(frames)
                node.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil) { [weak self] in
                    guard let self = self else { return }
                    playerQueue.async {
                        if self.scheduleGeneration != gen { return }
                        self.isScheduled = false
                        if self.isPlaying && endFrame >= file.length - 1 {
                            DispatchQueue.main.async { self.songFinished() }
                        }
                    }
                }
                self.pendingScheduledEnd = endFrame
                self.ensureEngineRunning()
                node.rate = self.playbackRate
                node.play()

                // Stash what the new deck is playing; completeHandover promotes it.
                self.incomingFile = file
                self.incomingLead = lead
                DispatchQueue.main.async { completion(true) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// Promotes the incoming deck to be the active one and updates all the
    /// published state as if `playSong` had run.
    private func completeHandover(to song: Song) {
        let newDeck = idleDeck
        // Stop the old deck and make the new one authoritative.
        let oldDeck = activeDeck
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            if self.playerNodes.indices.contains(oldDeck) {
                self.playerNodes[oldDeck].stop()
                self.playerNodes[oldDeck].volume = 0.0
            }
            guard let file = self.incomingFile else { return }
            // The incoming deck has already been audible for the length of the
            // blend, so report where it really is rather than its start.
            var elapsed = self.incomingLead
            if self.playerNodes.indices.contains(newDeck) {
                let n = self.playerNodes[newDeck]
                if let lrt = n.lastRenderTime, let pt = n.playerTime(forNodeTime: lrt) {
                    let sr = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : 44100
                    let rate = Double(self.playbackRate > 0 ? self.playbackRate : 1.0)
                    elapsed += (Double(pt.sampleTime) / rate) / sr
                }
            }
            self.audioFile = file
            self.fileLength = file.length
            self.fileSampleRate = file.processingFormat.sampleRate
            self.seekFrame = AVAudioFramePosition(self.incomingLead * self.fileSampleRate)
            self.scheduledSegmentEnd = self.pendingScheduledEnd
            self.isScheduled = true
            self.activeDeck = newDeck
            if self.playerNodes.indices.contains(newDeck) { self.playerNodes[newDeck].volume = 1.0 }
            self.incomingFile = nil

            let startedAt = elapsed
            DispatchQueue.main.async {
                // Book the OUTGOING track first, while currentTime still refers
                // to it — otherwise its listening time is credited from the new
                // track's clock and every crossfade logs a bogus skip.
                self.closeOutCurrentPlay()
                self.pushHistory(song)
                if let i = self.upNextQueue.firstIndex(where: { $0.id == song.id }) {
                    self.upNextQueue.remove(at: i)
                }
                self.duration = Double(self.fileLength) / self.fileSampleRate
                self.currentTime = startedAt
                self.currentSong = song
                self.isPlaying = true
                self.lastSongId = song.id
                self.lastSongTime = 0
                ListenHistory.shared.recordPlay(song)
                // The blend already counts as listening time for the new track.
                self.playbackWatch = (song: song, startedAt: Date(), startOffset: self.incomingLead)
                VocalStudio.shared.applyTuning(for: song)
                self.applyEQ(); self.applyGain()
                self.transitionArmed = false
                self.pendingNextSong = nil
                self.updateDisplayLinkState()
                self.updateNowPlayingInfo()
                SpokenFeedback.shared.announceNowPlaying(song)
                self.didAutoSearchForRadio = false
            }
        }
    }

    /// Books the outgoing track's listening time before a new one starts.
    ///
    /// This is what turns "started playing" into an honest signal: the amount
    /// actually heard decides whether the smart engines see a play or a skip.
    /// Safe to call repeatedly — the watch is cleared once consumed.
    private func closeOutCurrentPlay() {
        guard let watch = playbackWatch else { return }
        playbackWatch = nil
        // Elapsed wall-clock is wrong when the user paused or scrubbed, so use
        // the transport position we were already tracking, which follows both.
        let heard = max(0, currentTime - watch.startOffset)
        let dur = duration > 1 ? duration : watch.song.id == currentSong?.id ? duration : 0
        ListenHistory.shared.recordFinish(watch.song, playedSeconds: heard, duration: dur)
    }

    /// Remembers where we've been so `playPrevious()` can retrace it.
    private func pushHistory(_ song: Song) {
        if suppressHistoryPush { suppressHistoryPush = false; return }
        if playHistory.last == song.id { return }
        playHistory.append(song.id)
        if playHistory.count > 100 { playHistory.removeFirst(playHistory.count - 100) }
    }

    func playSong(_ song: Song) {
        // Book the outgoing track's listening time BEFORE anything changes,
        // and abandon any transition that was mid-flight (the user just chose
        // something else — a fade into the "next" track would be wrong now).
        onMain { [weak self] in
            guard let self = self else { return }
            self.cancelPendingTransition()
            self.closeOutCurrentPlay()
            self.pushHistory(song)
        }
        // Always run on playerQueue to serialize with seeks/rate changes.
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                if !self.audioSessionConfigured {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                    self.audioSessionConfigured = true
                }
                try AVAudioSession.sharedInstance().setActive(true)
                DispatchQueue.main.async { UIApplication.shared.beginReceivingRemoteControlEvents() }

                // Stop BOTH decks: a crossfade may have left the other one
                // rendering, and leaving it running would play two songs.
                for (i, node) in self.playerNodes.enumerated() {
                    node.stop()
                    node.volume = (i == self.activeDeck) ? 1.0 : 0.0
                }
                self.isScheduled = false
                self.audioFile = nil
                self.incomingFile = nil
                self.seekFrame = 0

                let file = try AVAudioFile(forReading: song.url)
                self.audioFile = file
                self.fileLength = file.length
                self.fileSampleRate = file.processingFormat.sampleRate

                // Per-song EQ/loudness from the on-device analysis, and skip
                // the dead air a bad rip starts with.
                VocalStudio.shared.applyTuning(for: song)
                let lead = VocalStudio.shared.leadOffset(for: song)
                self.applyEQ(); self.applyGain(); self.applySpatial()

                DispatchQueue.main.async {
                    self.duration = Double(self.fileLength) / self.fileSampleRate
                    self.currentTime = lead
                    self.currentSong = song
                    self.isPlaying = true
                    self.lastSongId = song.id
                    self.lastSongTime = 0
                    ListenHistory.shared.recordPlay(song)
                    // Start the completion watch for THIS track (lead is the
                    // dead-air offset we skipped, so it isn't counted as heard).
                    self.playbackWatch = (song: song, startedAt: Date(), startOffset: lead)
                    self.updateDisplayLinkState()
                    self.updateNowPlayingInfo()
                    SpokenFeedback.shared.announceNowPlaying(song)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }

                self.playCurrent(resumeFrom: lead > 0.05 ? lead : nil)
                self.didAutoSearchForRadio = false
            } catch {
                print("playSong error:", error)
                DispatchQueue.main.async {
                    self.isPlaying = false
                    self.updateDisplayLinkState()
                }
            }
        }
    }

    func resumeLastSongIfAvailable() {
        guard let id = lastSongId, let s = songs.first(where: { $0.id == id }) else { return }
        playSong(s)
        if lastSongTime > 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.seek(to: self?.lastSongTime ?? 0)
            }
        }
    }

    func pausePlayback() {
        // A fade in progress must not keep ramping a deck we just paused.
        onMain { [weak self] in self?.cancelPendingTransition() }
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            for node in self.playerNodes where node !== self.playerNode { node.stop() }
            self.playerNode.pause()
            DispatchQueue.main.async {
                self.isPlaying = false
                self.saveResumePosition()
                self.updateDisplayLinkState()
                self.updateNowPlayingInfo()
            }
        }
    }

    @objc func songFinished() {
        DispatchQueue.main.async {
            // A crossfade/gapless handover already started the next track —
            // the old track's completion must not ALSO advance the queue, or
            // the app would skip a song on every transition.
            if self.transitionArmed || self.isCrossfading { return }
            // Sleep timer with "stop at song end" — rest after this track.
            if self.pendingStopAtEnd {
                self.pendingStopAtEnd = false
                self.sleepTimer?.invalidate(); self.sleepTimer = nil
                self.sleepTimerMinutes = 0
                playerQueue.async { [weak self] in self?.playerNode.pause() }
                self.isPlaying = false
                self.saveResumePosition()
                self.updateDisplayLinkState()
                self.updateNowPlayingInfo()
                return
            }
            if self.repeatMode == .one, let cur = self.currentSong {
                self.playSong(cur); return
            }
            self.playNext(autoAdvance: true)
        }
    }

    func checkEndOfTrack() {
        // End-of-track is now driven by the scheduleSegment completion handler.
        // This remains as a safety net for the rare case the completion doesn't fire.
        guard isPlaying, audioFile != nil, duration > 1 else { return }
        if currentTime >= duration - 0.15 && !isScheduled {
            songFinished()
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pausePlayback()
        } else {
            cancelSleepFade()
            if audioFile == nil, let cur = currentSong {
                playSong(cur); return
            }
            let resumeAt = currentTime
            playerQueue.async { [weak self] in
                guard let self = self else { return }
                if !self.isScheduled, let file = self.audioFile {
                    // Nothing scheduled (e.g. after a stop/seek failure) — reschedule
                    let sr = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : self.fileSampleRate
                    let f = max(0, min(AVAudioFramePosition(resumeAt * sr), self.fileLength - 1))
                    let rem = AVAudioFrameCount(max(0, self.fileLength - f))
                    if rem > 0 { self.scheduleSegmentOnPlayer(file: file, startFrame: f, framesToPlay: rem) }
                }
                self.timePitch.rate = self.playbackRate
                self.ensureEngineRunning()
                self.playerNode.rate = self.playbackRate
                self.playerNode.play()
                DispatchQueue.main.async {
                    self.isPlaying = true
                    self.updateDisplayLinkState()
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    func playNext() { playNext(autoAdvance: false) }
    func playNext(autoAdvance: Bool) {
        // Snapshot the OUTGOING track before anything calls playSong — the old
        // code read `currentSong` afterwards, which is updated asynchronously,
        // so Smart Radio always searched for the wrong (or previous) artist.
        let outgoingArtist = currentSong?.artist ?? ""
        let outgoingTitle  = currentSong?.title ?? ""
        // The auto-search block used to sit after several `return`s, so in the
        // one mode that needs it (smartRadioMode) it never ran at all.
        defer { maybeAutoSearchRadio(artist: outgoingArtist, title: outgoingTitle) }

        guard !songs.isEmpty || !upNextQueue.isEmpty else {
            if repeatMode == .all, let first = songs.first { playSong(first) }
            else {
                isPlaying = false
                currentSong = nil
                saveResumePosition()
                updateDisplayLinkState()
            }
            return
        }
        if !upNextQueue.isEmpty {
            let next = upNextQueue.removeFirst()
            playSong(next); return
        }
        // Smart Radio: pick the song that genuinely sounds closest to what is
        // playing (acoustic feature space + harmonic distance), not a random
        // one. Shuffle stays random by design, but both now avoid songs you
        // keep skipping and songs you just heard.
        if smartRadioMode, let cur = currentSong,
           let next = SmartRadio.nextTrack(after: cur, recent: recentlyPlayedIDs()) {
            playSong(next); return
        }
        if isShuffle || smartRadioMode {
            let recent = recentlyPlayedIDs()
            let others = songs.filter {
                $0.id != currentSong?.id
                    && !ListenHistory.shared.isDisliked($0)
                    && !recent.contains($0.id)
            }
            let pool = others.isEmpty
                ? songs.filter { $0.id != currentSong?.id && !ListenHistory.shared.isDisliked($0) }
                : others
            if let s = pool.randomElement() ?? songs.randomElement() { playSong(s); return }
        }
        guard let c = currentSong, let i = songs.firstIndex(of: c) else {
            if let first = songs.first { playSong(first) }
            return
        }
        if i + 1 < songs.count { playSong(songs[i+1]) }
        else if repeatMode == .all, let first = songs.first { playSong(first) }
        else if autoAdvance {
            isPlaying = false
            saveResumePosition()
            updateDisplayLinkState()
        }
    }

    /// The last handful of songs played, so radio and shuffle don't loop back
    /// onto something you just heard.
    func recentlyPlayedIDs(_ limit: Int = 12) -> Set<UUID> {
        Set(playHistory.suffix(limit))
    }

    /// Fires the Smart Radio "find more like this" search exactly once per track.
    private func maybeAutoSearchRadio(artist: String, title: String) {
        guard smartRadioMode, !didAutoSearchForRadio else { return }
        guard !artist.isEmpty, artist != "AS Music" else { return }
        didAutoSearchForRadio = true
        NotificationCenter.default.post(name: .smartRadioAutoSearch, object: nil, userInfo: [
            "artist": artist,
            "title": title
        ])
    }

    // MARK: - Named / smart playlist playback (used by Siri and automation)

    /// Plays a playlist in its own order, queueing the rest. Returns how many
    /// of its songs still exist in the Library.
    @discardableResult
    func playPlaylist(_ pl: Playlist) -> Int {
        let list = pl.songIDs.compactMap { id in songs.first { $0.id == id } }
        guard let first = list.first else { return 0 }
        upNextQueue = Array(list.dropFirst())
        playSong(first)
        return list.count
    }

    /// Plays a playlist in random order without touching the global shuffle
    /// switch — "shuffle this list once" is what people actually mean.
    @discardableResult
    func shufflePlaylist(_ pl: Playlist) -> Int {
        let list = pl.songIDs.compactMap { id in songs.first { $0.id == id } }.shuffled()
        guard let first = list.first else { return 0 }
        upNextQueue = Array(list.dropFirst())
        playSong(first)
        return list.count
    }

    func playSmartPlaylist(kind: String) {        guard let id = SmartPlaylistStore.shared.playlistID(for: kind),
              let pl = playlists.first(where: { $0.id == id }) else { return }
        playPlaylist(pl)
    }

    /// Fuzzy name match for voice: exact → contains → shared-word score.
    /// Finds a playlist from spoken or typed text.
    ///
    /// Folded through ArabicFold rather than plain `lowercased()`: dictation
    /// returns أنت with a hamza where the saved name has none (and vice
    /// versa), so an exact comparison almost never fires on Arabic names.
    func playlist(matching text: String) -> Playlist? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let want = ArabicFold.key(raw)
        guard !want.isEmpty else { return nil }
        if let exact = playlists.first(where: { ArabicFold.key($0.name) == want }) { return exact }
        if let has = playlists.first(where: {
            let n = ArabicFold.key($0.name)
            return !n.isEmpty && (n.contains(want) || want.contains(n))
        }) { return has }
        let words = want.split(separator: " ").filter { $0.count > 2 }.map(String.init)
        guard !words.isEmpty else { return nil }
        var best: (pl: Playlist, score: Int)? = nil
        for p in playlists {
            let hay = ArabicFold.key(p.name)
            let score = words.reduce(0) { hay.contains($1) ? $0 + 1 : $0 }
            if score > (best?.score ?? 0) { best = (p, score) }
        }
        return best?.pl
    }

    func shuffleAll() {
        if !isShuffle { isShuffle = true }
        guard let s = songs.randomElement() else { return }
        playSong(s)
    }

    /// Back button. Restarts the track if you're more than 3 s in (the
    /// universal convention), otherwise retraces the songs you actually
    /// played — including through shuffle and Smart Radio, where walking the
    /// library array used to send you somewhere you'd never been.
    func playPrevious() {
        if currentTime > 3 { seek(to: 0); return }
        guard !songs.isEmpty else { return }

        // Drop the current track off the history, then take the one before it.
        if playHistory.count >= 2 {
            playHistory.removeLast()
            let prevID = playHistory.removeLast()
            if let s = songs.first(where: { $0.id == prevID }) {
                suppressHistoryPush = true
                playHistory.append(prevID)
                playSong(s)
                return
            }
        }

        // Nothing in history (fresh launch): fall back to library order.
        if isShuffle { if let s = songs.randomElement() { playSong(s) }; return }
        if let c = currentSong, let i = songs.firstIndex(of: c), i > 0 { playSong(songs[i-1]) }
        else if repeatMode == .all, let last = songs.last { playSong(last) }
    }

    func setupRemoteCommandCenter() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            guard let s = self else { return .commandFailed }
            if s.isPlaying { return .commandFailed }
            s.togglePlayPause(); return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            guard let s = self else { return .commandFailed }
            if !s.isPlaying { return .commandFailed }
            s.togglePlayPause(); return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.playNext(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.playPrevious(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] ev in
            guard let s = self, let e = ev as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            s.seek(to: e.positionTime); return .success
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5]
        c.changePlaybackRateCommand.addTarget { [weak self] ev in
            guard let s = self, let e = ev as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            s.setPlaybackRate(e.playbackRate); return .success
        }
    }

    func updateNowPlayingInfo() {
        guard let c = currentSong else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        let base: [String: Any] = [
            MPMediaItemPropertyTitle: c.title,
            MPMediaItemPropertyArtist: c.artist.isEmpty ? "AS Music" : c.artist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
        ]
        // Publish text/position immediately, then patch the artwork in when it
        // resolves. The old code wrote the artwork-less dictionary *after* the
        // artwork one (artworkImage calls back synchronously for cached files),
        // so the cover art was always clobbered and never appeared.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = base
        let songID = c.id
        artworkImage(for: c, size: 600) { [weak self] img in
            guard let self = self, let img = img else { return }
            DispatchQueue.main.async {
                // Ignore artwork that arrives after the user skipped on.
                guard self.currentSong?.id == songID else { return }
                var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? base
                updated[MPMediaItemPropertyArtwork] =
                    MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
            }
        }
    }
}

class DisplayLinkProxy: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func tick() { block() }
}

