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
    /// Live FFT spectrum (24 log-spaced bands in dB), written by the audio
    /// render thread, read by the player UI.
    let spectrum = SpectrumMeter()
    private var fft = FFTProcessor()
    private var fftScratch: [Float] = Array(repeating: -100, count: SpectrumMeter.bands)
    private var pendingStopAtEnd = false
    private var fadeTimer: Timer?
    private var preFadeDB: Float = 0
    private let sleepFadeSeconds: TimeInterval = 45

    // Signal chain: playerNode -> eqNode -> preampMixer -> reverb -> timePitch -> mainMixerNode
    private var engine: AVAudioEngine!
    private var playerNode: AVAudioPlayerNode!
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
        playerNode = AVAudioPlayerNode()
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
        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(preampMixer)
        engine.attach(reverb)
        engine.attach(timePitch)
        // Connect once with format:nil; engine auto-negotiates per-file format.
        engine.connect(playerNode, to: eqNode, format: nil)
        engine.connect(eqNode, to: preampMixer, format: nil)
        engine.connect(preampMixer, to: reverb, format: nil)
        engine.connect(reverb, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 1.0
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

    private func applyGain() {
        let db = max(-12, min(9, preampDB))
        preampMixer?.outputVolume = pow(10.0, db / 20.0)
    }

    private func applySpatial() {
        reverb?.wetDryMix = spatialEnhance ? 25 : 0
    }

    func applyEQ() {
        let gains = eqPreset.gains
        for (i,b) in eqNode.bands.enumerated() where i < gains.count {
            b.gain = gains[i]
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

    func deleteSong(_ s: Song) {
        try? fileManager.removeItem(at: s.url)
        try? fileManager.removeItem(at: s.url.deletingPathExtension().appendingPathExtension("jpg"))
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
        ListenHistory.shared.remove(songID: s.id)
        saveSongMeta()
        loadSongs()
    }

    func renameSong(song: Song, newName: String) {
        let ext = song.url.pathExtension
        let (t,a) = TitleCleaner.clean(newName)
        let finalTitle = t
        var newUrl = documentsDirectory.appendingPathComponent(finalTitle + "." + ext)
        var i = 2
        while fileManager.fileExists(atPath: newUrl.path) {
            newUrl = documentsDirectory.appendingPathComponent("\(finalTitle) \(i)." + ext)
            i += 1
        }
        do {
            try fileManager.moveItem(at: song.url, to: newUrl)
            let oldSide = song.url.deletingPathExtension().appendingPathExtension("jpg")
            let newSide = newUrl.deletingPathExtension().appendingPathExtension("jpg")
            if fileManager.fileExists(atPath: oldSide.path) { try? fileManager.moveItem(at: oldSide, to: newSide) }
            loadSongs()
            if let idx = songs.firstIndex(where: { $0.id == song.id }) {
                songs[idx].url = newUrl
                songs[idx].title = finalTitle
                songs[idx].artist = a
                saveSongMeta()
            }
            if currentSong?.id == song.id {
                currentSong?.title = finalTitle
                currentSong?.url = newUrl
                currentSong?.artist = a
                updateNowPlayingInfo()
            }
        } catch {}
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
                    ID3TagWriter.tagIfNeeded(at: tagURL, title: tagTitle,
                                             artist: tagArtist, album: "", artworkJPEG: artData)
                }
            }
        }
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
            let frac = Double(i) / Double(steps)
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

    func playSong(_ song: Song) {
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

                self.playerNode.stop()
                self.isScheduled = false
                self.audioFile = nil
                self.seekFrame = 0

                let file = try AVAudioFile(forReading: song.url)
                self.audioFile = file
                self.fileLength = file.length
                self.fileSampleRate = file.processingFormat.sampleRate

                self.applyEQ(); self.applyGain(); self.applySpatial()

                DispatchQueue.main.async {
                    self.duration = Double(self.fileLength) / self.fileSampleRate
                    self.currentTime = 0
                    self.currentSong = song
                    self.isPlaying = true
                    self.lastSongId = song.id
                    self.lastSongTime = 0
                    ListenHistory.shared.recordPlay(song)
                    self.updateDisplayLinkState()
                    self.updateNowPlayingInfo()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }

                self.playCurrent(resumeFrom: nil)
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
        playerQueue.async { [weak self] in
            guard let self = self else { return }
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
        if isShuffle || smartRadioMode {
            let others = songs.filter { $0.id != currentSong?.id }
            let candidates: [Song] = {
                guard let cur = currentSong else { return others }
                let words = cur.artist.split(separator: " ").filter { $0.count >= 3 }.map(String.init)
                    + cur.title.split(separator: " ").filter { $0.count >= 3 }.map(String.init)
                let different = others.filter { s in
                    !words.contains(where: { s.title.localizedCaseInsensitiveContains($0) || s.artist.localizedCaseInsensitiveContains($0) })
                }
                return different.isEmpty ? others : different
            }()
            if let s = candidates.randomElement() ?? songs.randomElement() { playSong(s); return }
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

    func playPrevious() {
        if currentTime > 3 { seek(to: 0); return }
        guard !songs.isEmpty else { return }
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

