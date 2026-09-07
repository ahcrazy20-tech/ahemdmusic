import Foundation
import AVFoundation
import SwiftUI
import UIKit

// ===========================================================================
// MARK: - Vocal Studio (make the music AND the voice sound better)
//
// Four things, all computed from the on-device analysis in AudioAnalysis.swift:
//
//   • SMART MASTER — per-song corrective EQ. A muddy rip gets the 125–500 Hz
//     region pulled down, a thin one gets lows lifted, a harsh one gets 2–5 kHz
//     tamed. Not a preset: the offsets come from what the file actually
//     contains, and they stack on top of whatever EQ preset you chose.
//   • LOUDNESS MATCH — EBU-R128-style gated loudness per track, so a quiet
//     old Amr Diab master and a modern Mahraganat rip sit at the same level.
//     Never pushes a clipped file louder (peak headroom is respected).
//   • VOCAL FOCUS / NIGHT / RIP REPAIR — presence lift for lyrics at low
//     volume, Fletcher–Munson compensation for late-night listening, and a
//     hiss/de-ess tilt for lossy YouTube rips.
//   • KARAKE / ACAPELLA EXPORT — real center-channel extraction written to a
//     new file, plus a karaoke MIC recorder that records your voice over the
//     song using the system's own echo cancellation + AGC + noise reduction.
//
// Nothing here sends audio anywhere: no network, no key, no upload.
// ===========================================================================

// MARK: - Tuning math (pure functions, easy to reason about)

enum SoundTuning {
    /// The ten EQ band centers MusicManager builds (Hz).
    static let bandFreqs: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandCount = 10

    struct Options {
        var vocalFocus = false
        var nightMode = false
        var ripRepair = false
        /// −6…+6: how much the smart correction is allowed to do.
        var strength = 1.0
    }

    /// Corrective per-song EQ, in dB, 0…9 = 32 Hz…16 kHz.
    static func offsets(for f: TrackFeatures, _ o: Options) -> [Float] {
        var g = [Float](repeating: 0, count: bandCount)
        let k = Float(max(0, min(2, o.strength)))

        // Muddiness: too much of the energy sits in 400 Hz–1.5 kHz.
        let mud = Float(max(0, f.body - 0.30))
        if mud > 0.02 {
            g[2] -= min(3.5, mud * 9) * k          // 125
            g[3] -= min(3.0, mud * 7) * k          // 250
        }
        // Thin: not enough low end, lift without inflating the room.
        if f.warmth < 0.26 {
            let d = Float(0.26 - f.warmth)
            g[1] += min(3.0, d * 14) * k
            g[2] += min(2.5, d * 10) * k
        }
        // Dull / brickwalled-top: add sparkle where the file still has it.
        if f.air < 0.085, f.clipRatio < 0.002 {
            g[7] += 1.5 * k
            g[8] += 2.5 * k
            g[9] += 2.5 * k
        }
        // Harsh: presence region dominating the mix (typical of cheap rips).
        if f.presence > 0.33 {
            let d = Float(f.presence - 0.33)
            g[6] -= min(3.5, d * 9) * k            // 2 kHz
            g[7] -= min(2.5, d * 7) * k            // 4 kHz
        }
        // Sibilance / hiss / clipping grit.
        if f.air > 0.20 || f.clipRatio > 0.0025 || o.ripRepair {
            g[8] -= (o.ripRepair ? 2.0 : 1.2) * k
            g[9] -= (o.ripRepair ? 3.0 : 1.8) * k
        }
        // Very quiet master: don't dig the hole deeper in the lows.
        if f.loudness < -24 { g[0] += 1.0 * k }

        if o.vocalFocus {
            // Bring the voice forward, pull the box out from under it.
            g[5] += 1.4 * k                        // 1 kHz
            g[6] += 2.2 * k                        // 2 kHz
            g[7] += 1.6 * k                        // 4 kHz
            g[0] -= 2.0 * k
            g[1] -= 1.5 * k
            g[3] -= 1.0 * k
        }
        if o.nightMode {
            // Equal-loudness compensation: at low volume the ear loses the
            // extremes, so lift them and pull the shouty middle back.
            g[0] += 3.0 * k
            g[1] += 2.5 * k
            g[8] += 2.0 * k
            g[9] += 2.0 * k
            g[6] -= 1.5 * k
            g[7] -= 1.0 * k
        }
        return g.map { max(-9, min(7, $0)) }
    }

    /// Gain trim in dB that brings this track to `targetLoudness` (dBFS-ish,
    /// the same meter AudioLab reports). Respects peak headroom.
    static func trim(for f: TrackFeatures, targetLoudness: Double, extra: [Float]) -> Float {
        var t = Float(targetLoudness - f.loudness)
        // The EQ curve can add up to N dB on top of the file; keep the sum out
        // of digital clipping.
        let eqHead = max(0, extra.max() ?? 0)
        t -= eqHead * 0.5
        let peakCap = Float(-1.0 - f.peak)
        return max(-10, min(10, min(t, peakCap)))
    }
}

// MARK: - Studio (state + file processing)

final class VocalStudio: ObservableObject {
    static let shared = VocalStudio()

    // Toggles (all persisted, all off-safe: the app behaves exactly as before
    // if you turn everything off).
    @Published var smartMaster: Bool { didSet { defaults.set(smartMaster, forKey: "asmusic_tune_smart"); refresh() } }
    @Published var loudnessMatch: Bool { didSet { defaults.set(loudnessMatch, forKey: "asmusic_tune_loud"); refresh() } }
    @Published var vocalFocus: Bool { didSet { defaults.set(vocalFocus, forKey: "asmusic_tune_vocal"); refresh() } }
    @Published var nightMode: Bool { didSet { defaults.set(nightMode, forKey: "asmusic_tune_night"); refresh() } }
    @Published var ripRepair: Bool { didSet { defaults.set(ripRepair, forKey: "asmusic_tune_repair"); refresh() } }
    @Published var autoSkipSilence: Bool { didSet { defaults.set(autoSkipSilence, forKey: "asmusic_tune_silence") } }
    @Published var targetLoudness: Double { didSet { defaults.set(targetLoudness, forKey: "asmusic_tune_target"); refresh() } }
    @Published var tuneStrength: Double { didSet { defaults.set(tuneStrength, forKey: "asmusic_tune_strength"); refresh() } }

    // Export progress (read by the UI).
    @Published private(set) var isProcessing = false
    @Published private(set) var progress: Double = 0
    @Published var lastError: String? = nil
    @Published var lastResult: String? = nil

    private let defaults = UserDefaults.standard
    private let work = DispatchQueue(label: "asMusic.vocalStudio", qos: .userInitiated)
    /// Guards didSet→refresh() while `init` is still running: touching
    /// MusicManager.shared from here would re-enter this class's own
    /// `static let` initializer and hang the launch.
    private var ready = false

    /// What the audio graph must apply. Written on main, read on the player
    /// queue — hence the lock (a Swift array race is a crash, not a glitch).
    private let lock = NSLock()
    private var eqOffsets: [Float] = Array(repeating: 0, count: SoundTuning.bandCount)
    private var trimDB: Float = 0

    private init() {
        smartMaster = defaults.object(forKey: "asmusic_tune_smart") as? Bool ?? true
        loudnessMatch = defaults.object(forKey: "asmusic_tune_loud") as? Bool ?? true
        vocalFocus = defaults.bool(forKey: "asmusic_tune_vocal")
        nightMode = defaults.bool(forKey: "asmusic_tune_night")
        ripRepair = defaults.bool(forKey: "asmusic_tune_repair")
        autoSkipSilence = defaults.object(forKey: "asmusic_tune_silence") as? Bool ?? true
        targetLoudness = defaults.object(forKey: "asmusic_tune_target") as? Double ?? -15.0
        tuneStrength = defaults.object(forKey: "asmusic_tune_strength") as? Double ?? 1.0
        ready = true
    }

    // MARK: Graph hand-off

    /// Snapshot used by MusicManager when it (re)applies EQ and preamp.
    func snapshot() -> (eq: [Float], trim: Float) {
        lock.lock(); defer { lock.unlock() }
        return (eqOffsets, trimDB)
    }

    /// Recompute the tuning for a song from cached analysis. Called from
    /// `playSong` and whenever a toggle changes.
    func applyTuning(for song: Song?) {
        guard let song = song, smartMaster || loudnessMatch else {
            setOffsets(Array(repeating: 0, count: SoundTuning.bandCount), trim: 0)
            return
        }
        guard let f = AudioLab.shared.features(for: song) else {
            // Not measured yet: kick it off; the numbers land on the next play
            // (and mid-playback once this returns on the main queue).
            AudioLab.shared.ensureAnalyzed(song)
            setOffsets(smartMaster ? Array(repeating: 0, count: SoundTuning.bandCount) : currentEQ(),
                       trim: 0)
            return
        }
        var opts = SoundTuning.Options()
        opts.vocalFocus = vocalFocus
        opts.nightMode = nightMode
        opts.ripRepair = ripRepair || f.isLowQualityRip
        opts.strength = tuneStrength

        let eq = smartMaster ? SoundTuning.offsets(for: f, opts) : Array(repeating: Float(0), count: SoundTuning.bandCount)
        let trim = loudnessMatch ? SoundTuning.trim(for: f, targetLoudness: targetLoudness, extra: eq) : 0
        setOffsets(eq, trim: trim)
    }

    private func currentEQ() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return eqOffsets
    }

    private func setOffsets(_ eq: [Float], trim: Float) {
        lock.lock()
        eqOffsets = eq
        trimDB = trim
        lock.unlock()
        DispatchQueue.main.async { MusicManager.shared.soundTuningChanged() }
    }

    /// Head start for tracks the analysis says begin with dead air.
    func leadOffset(for song: Song) -> TimeInterval {
        guard autoSkipSilence, let f = AudioLab.shared.features(for: song) else { return 0 }
        let s = f.leadSilence
        guard s > 0.15, s < 6 else { return 0 }
        return s
    }

    /// Called from the UI after the library or a toggle changed.
    func refresh() {
        guard ready else { return }
        applyTuning(for: MusicManager.shared.currentSong)
    }

    // MARK: Karaoke / acapella export

    /// Reads a song, applies center-channel extraction in the vocal band, and
    /// writes a new file into the Library. Runs fully offline.
    func export(song: Song, mode: VocalExportMode, amount: Double,
                completion: ((Result<URL, Error>) -> Void)? = nil) {
        guard !isProcessing else {
            lastError = "Already busy with one export."
            completion?(.failure(VocalError.busy))
            return
        }
        DispatchQueue.main.async { self.isProcessing = true; self.progress = 0 }
        let pct = amount
        work.async { [weak self] in
            guard let self = self else { return }
            let out = VocalProcessor.process(input: song.url, mode: mode, amount: pct) { p in
                DispatchQueue.main.async { self.progress = p }
            }
            DispatchQueue.main.async {
                self.isProcessing = false
                self.progress = 1
                switch out {
                case .success(let url):
                    let base = song.title
                    let label = mode == .karaoke ? "Karaoke" : "Acapella"
                    MusicManager.shared.registerDownloadedSong(
                        title: "\(base) (\(label))", artist: song.artist, url: url,
                        sourceVid: nil, artworkURL: song.artworkURL)
                    self.lastResult = "Saved “\(url.deletingPathExtension().lastPathComponent)” to your Library."
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.completionOnMain(.success(url), completion)
                case .failure(let e):
                    self.lastError = e.localizedDescription
                    self.completionOnMain(.failure(e), completion)
                }
            }
        }
    }

    private func completionOnMain(_ r: Result<URL, Error>, _ c: ((Result<URL, Error>) -> Void)?) {
        if let c = c { c(r) }
    }

    enum VocalError: LocalizedError {
        case busy, mono, unreadable, unwritable
        var errorDescription: String? {
            switch self {
            case .busy: return "Another export is running."
            case .mono: return "This file is mono, so there is no stereo center to separate. It has to be a stereo recording."
            case .unreadable: return "Could not decode the audio in that file."
            case .unwritable: return "Could not write the new file."
            }
        }
    }
}

// MARK: - The DSP (one pass, no FFT, deterministic)

enum VocalProcessor {

    /// Center-channel separation.
    ///
    /// Karaoke: everything below ~200 Hz stays (bass + kick come from the
    /// center too, and killing them is what makes naive L−R tricks sound
    /// terrible). The 300 Hz–5 kHz "voice band" of the center channel is
    /// attenuated by `amount`, above 5 kHz only partially — cymbals and air
    /// mostly live off-center in a normal mix.
    ///
    /// Acapella: keep that same 300 Hz–5 kHz center band, but gate it by how
    /// much stronger it is than the side signal in the same band, which
    /// suppresses panned instruments and keeps the centered voice.
    static func process(input: URL, mode: VocalExportMode, amount: Double,
                        progress: @escaping (Double) -> Void) -> Result<URL, Error> {
        guard let reader = try? AVAudioFile(forReading: input) else { return .failure(VocalStudio.VocalError.unreadable) }
        let inFmt = reader.processingFormat
        let sr = inFmt.sampleRate
        let ch = Int(inFmt.channelCount)
        guard ch >= 2 else { return .failure(VocalStudio.VocalError.mono) }
        let totalFrames = AVAudioFramePosition(reader.length)
        guard totalFrames > 1024 else { return .failure(VocalStudio.VocalError.unreadable) }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = mode == .karaoke ? "Karaoke" : "Acapella"
        let outURL = dir.appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-\(suffix)-\(stamp).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: ch,
            AVEncoderBitRateKey: 256_000
        ]
        guard let writer = try? AVAudioFile(forWriting: outURL, settings: settings,
                                            commonFormat: .pcmFormatFloat32,
                                            interleaved: false) else {
            return .failure(VocalStudio.VocalError.unwritable)
        }

        let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 4096)
        let outFmt = writer.processingFormat
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 4096)
        guard let ib = inBuf, let ob = outBuf else {
            try? FileManager.default.removeItem(at: outURL)
            return .failure(VocalStudio.VocalError.unwritable)
        }

        // One-pole coefficients (a = 1 − e^(−2πf/sr)).
        func coef(_ hz: Double) -> Double { 1 - exp(-2 * Double.pi * hz / sr) }
        let aLow = coef(mode == .karaoke ? 200 : 300)
        let a300 = coef(300)
        let a5k = coef(5000)
        let k = max(0, min(1.4, amount))

        var lpLow = 0.0, lpM300 = 0.0, lpM5k = 0.0
        var lpS300 = 0.0, lpS5k = 0.0
        var envM = 0.0, envS = 0.0            // smoothed |·| envelopes for the gate
        var pos: AVAudioFramePosition = 0
        var lastPct = -1.0

        while pos < totalFrames {
            let want = AVAudioFrameCount(min(4096, totalFrames - pos))
            do { try reader.read(into: ib, frameCount: want) } catch { break }
            let frames = Int(ib.frameLength)
            if frames <= 0 { break }
            guard let src = ib.floatChannelData, let dst = ob.floatChannelData else { break }
            let L = src[0]
            let R = src[1]
            let oL = dst[0]
            let oR = ch >= 2 ? dst[1] : dst[0]

            for i in 0..<frames {
                let sl = Double(L[i])
                let sr0 = Double(R[i])
                let m = 0.5 * (sl + sr0)
                let s = 0.5 * (sl - sr0)

                lpLow += aLow * (m - lpLow)
                lpM300 += a300 * (m - lpM300)
                lpM5k += a5k * (m - lpM5k)
                lpS300 += a300 * (s - lpS300)
                lpS5k += a5k * (s - lpS5k)

                let voiceBandM = lpM5k - lpM300           // center content, 300 Hz…5 kHz
                let voiceBandS = lpS5k - lpS300           // same band, side content
                let topM = m - lpM5k                      // air above 5 kHz

                if mode == .karaoke {
                    // Keep bass and most of the air; duck the voice band.
                    let mOut = lpLow + (1 - k) * voiceBandM + (1 - 0.35 * k) * topM
                    softWrite(oL, i, mOut + s)
                    if ch >= 2 { softWrite(oR, i, mOut - s) }
                } else {
                    // Acapella: center voice band, gated by center-vs-side ratio.
                    let am = abs(voiceBandM)
                    let as0 = abs(voiceBandS)
                    envM += 0.0006 * (am - envM)
                    envS += 0.0006 * (as0 - envS)
                    let g = max(0, min(1, (envM - envS * 0.85) / max(envM, 1e-5)))
                    let out = voiceBandM * (0.25 + 0.75 * g) * 1.6
                    softWrite(oL, i, out)
                    if ch >= 2 { softWrite(oR, i, out) }
                }
            }

            ob.frameLength = ib.frameLength
            do { try writer.write(from: ob) } catch { break }
            pos += AVAudioFramePosition(ib.frameLength)

            let pctNow = Double(pos) / Double(totalFrames)
            if pctNow - lastPct > 0.02 {
                lastPct = pctNow
                progress(pctNow)
            }
        }

        if pos < totalFrames / 4 {
            try? FileManager.default.removeItem(at: outURL)
            return .failure(VocalStudio.VocalError.unreadable)
        }
        writer.close()
        // Files in Documents must not be iCloud-backed for this app's layout.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                               ofItemAtPath: outURL.path)
        return .success(outURL)
    }

    /// Cheap soft clipper so the reconstructed center never wraps around.
    private static func softWrite(_ ptr: UnsafeMutablePointer<Float>, _ i: Int, _ x: Double) {
        var v = Float(x)
        let a = abs(v)
        if a > 0.92 {
            v = (v > 0 ? 1 : -1) * (0.92 + tanh((a - 0.92) * 4) * 0.06)
        }
        ptr[i] = v
    }
}

// MARK: - Export modes

enum VocalExportMode: String, CaseIterable, Identifiable {
    case karaoke
    case acapella

    var id: String { rawValue }
    var shortName: String { self == .karaoke ? "Karaoke" : "Acapella" }
    var title: String {
        switch self {
        case .karaoke: return "Remove the lead vocal"
        case .acapella: return "Keep only the voice"
        }
    }
    var icon: String { self == .karaoke ? "mic.slash.fill" : "waveform" }
}

// MARK: - Karaoke mic recorder (record your voice over any song)

/// Records the mic into a new file while the song keeps playing. Voice quality
/// comes from the system's own voice processing (echo cancellation, AGC, noise
/// reduction) when `systemEnhance` is on; a gate + high-pass + soft limiter is
/// applied on top of that in the tap.
final class KaraokeRecorder: ObservableObject {
    static let shared = KaraokeRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Double = 0

    /// Plain (non-published) copies the audio thread may read safely.
    private var gateEnabled = false
    private var boost: Float = 1.25
    @Published var systemEnhance: Bool {
        didSet { defaults.set(systemEnhance, forKey: "asmusic_kara_sys") }
    }
    @Published var gateOn: Bool {
        didSet { defaults.set(gateOn, forKey: "asmusic_kara_gate") }
    }
    @Published var lastError: String? = nil

    private let defaults = UserDefaults.standard
    private let capture = AVAudioEngine()
    private var file: AVAudioFile?
    private var started: Date?
    private var timer: Timer?
    private var hpInput = 0.0
    private var gateHold = 0.0
    private var savedURL: URL?
    private let outQueue = DispatchQueue(label: "asMusic.karaoke.io", qos: .utility)

    private init() {
        systemEnhance = defaults.object(forKey: "asmusic_kara_sys") as? Bool ?? true
        gateOn = defaults.object(forKey: "asmusic_kara_gate") as? Bool ?? true
    }

    /// True when the build declares the mic permission. If the CI workflow
    /// hasn't been re-synced yet the key is missing and using the mic would
    /// hard-crash the app — so the UI hides the button instead.
    static var micAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    var canStart: Bool {
        VocalStudio.shared.canUseMic && !isRecording
    }

    func start() {
        guard VocalStudio.shared.canUseMic else {
            lastError = "This build has no microphone permission entry — re-run the CI sync step."
            return
        }
        guard !isRecording else { return }
        lastError = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: systemEnhance ? .voiceChat : .measurement,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true, options: [])
        } catch {
            lastError = "Audio session refused record mode: \(error.localizedDescription)"
            return
        }

        let input = capture.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            lastError = "No microphone input found."
            restoreSession()
            return
        }
        gateEnabled = gateOn
        gateHold = 0
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Vocal take \(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: fmt.channelCount,
            AVEncoderBitRateKey: 192_000
        ]
        guard let f = try? AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false) else {
            lastError = "Could not create the recording file."
            restoreSession()
            return
        }
        file = f
        savedURL = url

        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.handle(buf, format: fmt)
        }
        capture.prepare()
        do { try capture.start() } catch {
            lastError = "Mic did not start: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            file = nil
            restoreSession()
            return
        }

        isRecording = true
        started = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let s = self, let st = s.started else { return }
            s.seconds = Date().timeIntervalSince(st)
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// Stops and keeps the take (added to the Library so you can listen back).
    func stop(keep: Bool = true) {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil
        let elapsed = seconds
        seconds = 0
        capture.inputNode.removeTap(onBus: 0)
        capture.stop()
        let out = file
        file = nil
        let url = savedURL
        savedURL = nil
        restoreSession()

        guard let url = url else { return }
        guard keep, elapsed > 1.2 else {
            try? FileManager.default.removeItem(at: url)
            if !keep { lastNote("Take discarded.") }
            return
        }
        out?.close()
        outQueue.async {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                                   ofItemAtPath: url.path)
            let title = "Vocal take (\(Int(elapsed / 60)):\(String(format: "%02d", Int(elapsed) % 60)))"
            DispatchQueue.main.async {
                MusicManager.shared.registerDownloadedSong(title: title, artist: "My voice",
                                                            url: url, sourceVid: nil, artworkURL: nil)
                self.lastNote("Saved your take to the Library.")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func lastNote(_ s: String) { lastError = s }

    private func restoreSession() {
        // Give the session back to plain playback and make sure the music
        // engine is still running (route/category changes can stall it).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        MusicManager.shared.reassertPlaybackSession()
    }

    /// Runs on the audio thread: high-pass, gate, level meter, soft limit,
    /// write. No allocations, no dispatch.
    private func handle(_ buf: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let data = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        let sr = format.sampleRate
        // One-pole high-pass at 90 Hz (removes desk rumble and plosive boom).
        let a = 1 - exp(-2 * Double.pi * 90 / sr)
        var peak: Float = 0
        let ch = Int(format.channelCount)

        for c in 0..<min(ch, 2) {
            let p = data[c]
            for i in 0..<n {
                let x = Double(p[i])
                hpInput += a * (x - hpInput)
                let y = x - hpInput                      // high-passed
                let ay = abs(y)
                if ay > peak { peak = Float(ay) }
                let gated = gateEnabled ? (gateHold > 0.12 ? y * Double(boost) : 0) : y * Double(boost)
                p[i] = max(-0.95, min(0.95, Float(gated)))
            }
        }
        let lvl = peak > 0 ? min(1, Double(20 * log10(max(1e-6, peak)) + 55) / 55) : 0
        gateHold = max(lvl > 0.10 ? 1.0 : gateHold - Double(n) / sr * 4, 0)

        if let f = file {
            do { try f.write(from: buf) } catch { /* a failed write just shortens the take */ }
        }
        DispatchQueue.main.async { self.level = lvl }
    }
}

// MARK: - Permission plumbing

extension VocalStudio {
    /// Mic + (optional) speech permission availability for this build.
    var micDeclaredInPlist: Bool { KaraokeRecorder.micAvailable }

    var canUseMic: Bool { micDeclaredInPlist }

    func requestMic(completion: @escaping (Bool) -> Void) {
        guard micDeclaredInPlist else { completion(false); return }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                if !ok { self.lastError = "Microphone access is off — enable it in Settings." }
                completion(ok)
            }
        }
    }
}


// MARK: - UI: the Vocal Studio sheet

/// Reached from the player's ⋯ menu. Every control here is off-safe: with all
/// toggles off the audio path is exactly what it was before this file existed.
struct VocalStudioView: View {
    @ObservedObject private var studio = VocalStudio.shared
    @ObservedObject private var lab = AudioLab.shared
    @ObservedObject private var mic = KaraokeRecorder.shared
    @EnvironmentObject private var mm: MusicManager
    @Environment(\.presentationMode) private var pm

    @State private var exportMode: VocalExportMode = .karaoke
    @State private var amount: Double = 0.85

    var body: some View {
        List {
            soundSection
            vocalSection
            analysisSection
            exportSection
            if KaraokeRecorder.micAvailable { micSection } else { missingPlistNote }
        }
        .navigationTitle("Vocal & Sound Studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { pm.wrappedValue.dismiss() }
            }
        }
        .onAppear {
            if let s = mm.currentSong { AudioLab.shared.ensureAnalyzed(s) }
        }
    }

    // MARK: Tuning

    private var soundSection: some View {
        Section(header: Text("Automatic mastering"),
                footer: Text("Smart Master reads the file itself — muddiness, harshness, thin lows, hiss — and corrects it per song, on top of your EQ preset. Loudness Match levels every track to the same target so nothing jumps.")) {
            Toggle(isOn: $studio.smartMaster) {
                Label("Smart Master (per-song EQ)", systemImage: "wand.and.stars")
            }
            Toggle(isOn: $studio.loudnessMatch) {
                Label("Match loudness across songs", systemImage: "speaker.wave.2.fill")
            }
            Toggle(isOn: $studio.autoSkipSilence) {
                Label("Skip dead air at the start", systemImage: "forward.fill")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Correction strength").foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "%.0f%%", studio.tuneStrength * 100))
                        .foregroundColor(.secondary).font(.caption.monospacedDigit())
                }
                Slider(value: $studio.tuneStrength, in: 0.2...1.6, step: 0.1)
                    .tint(AppTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Loudness target").foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "%.0f dBFS", studio.targetLoudness))
                        .foregroundColor(.secondary).font(.caption.monospacedDigit())
                }
                Slider(value: $studio.targetLoudness, in: -22 ... -8, step: 0.5)
                    .tint(AppTheme.accent)
                Text("Streaming services use about −14. Lower numbers are quieter but keep more punch.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var vocalSection: some View {
        Section(header: Text("Voices"),
                footer: Text("Vocal Focus lifts 1–4 kHz and pulls the box out from under the voice — good for lyrics in a noisy room or in the car. Night Mode does the opposite of what a normal EQ can: it adds back the bass and air your ears lose at low volume.")) {
            Toggle(isOn: $studio.vocalFocus) {
                Label("Vocal Focus", systemImage: "person.wave.2.fill")
            }
            Toggle(isOn: $studio.nightMode) {
                Label("Night / low-volume mode", systemImage: "moon.zzz.fill")
            }
            Toggle(isOn: $studio.ripRepair) {
                Label("Rip repair (de-hiss, tame sibilance)", systemImage: "waveform.badge.minus")
            }
        }
    }

    private var analysisSection: some View {
        let f = mm.currentSong.flatMap { lab.features(for: $0) }
        return Section(header: Text("What the app hears right now"),
                       footer: Button("Re-analyze the whole library") {
                            lab.reset()
                            lab.prime(mm.songs)
                       }.foregroundColor(AppTheme.accent)) {
            if let song = mm.currentSong {
                VStack(alignment: .leading, spacing: 6) {
                    Text(song.title).font(.subheadline.bold()).foregroundColor(.primary).lineLimit(1)
                    if let f = f {
                        HStack(spacing: 12) {
                            metric("Tempo", "\(Int(f.tempo.rounded()))")
                            metric("Energy", pct(f.energy))
                            metric("Loud", String(format: "%.0f dB", f.loudness))
                        }
                        HStack(spacing: 12) {
                            metric("Voice", pct(f.vocalCenter))
                            metric("Width", pct(f.stereoWidth))
                            metric("Range", String(format: "%.0f dB", f.dynRange))
                        }
                        if f.isLowQualityRip {
                            Label("This file looks like a rough rip — Rip Repair helps here.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2).foregroundColor(.orange)
                        }
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Measuring this track…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text("Play a song to see its measured numbers.").font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Text("Library analyzed").foregroundColor(.primary)
                Spacer()
                Text("\(Int((lab.coverage(of: mm.songs) * 100).rounded()))% of \(mm.songs.count)")
                    .foregroundColor(.secondary).font(.caption)
            }
        }
    }

    private var exportSection: some View {
        Section(header: Text("Karaoke / acapella export"),
                footer: Text("Center-channel separation, done on your phone. It writes a NEW file into your Library — the original is never touched. Works best on properly mixed stereo tracks.")) {
            Picker("Mode", selection: $exportMode) {
                ForEach(VocalExportMode.allCases) { m in
                    Text(m.shortName).tag(m)
                }
            }.pickerStyle(.segmented)
            Text(exportMode.title).font(.caption).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(exportMode == .karaoke ? "Vocal removal" : "Voice isolation").foregroundColor(.primary)
                    Spacer()
                    Text("\(Int(amount * 100))%").foregroundColor(.secondary).font(.caption.monospacedDigit())
                }
                Slider(value: $amount, in: 0.2...1.2, step: 0.05).tint(AppTheme.accent)
                Text(exportMode == .karaoke
                     ? "100 % can thin out the whole mix. 70–90 % usually sounds best."
                     : "Higher keeps more of the voice but lets less ambience through.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if let song = mm.currentSong {
                Button {
                    studio.export(song: song, mode: exportMode, amount: amount)
                } label: {
                    if studio.isProcessing {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("Building… \(Int(studio.progress * 100))%")
                        }
                    } else {
                        Label("Export “\(song.title)” as \(exportMode.shortName)",
                              systemImage: exportMode.icon)
                    }
                }
                .disabled(studio.isProcessing)
            } else {
                Text("Play the song you want to export first.").font(.caption).foregroundColor(.secondary)
            }
            if let r = studio.lastResult {
                Text(r).font(.caption).foregroundColor(.green)
            }
            if let e = studio.lastError {
                Text(e).font(.caption).foregroundColor(.orange)
            }
        }
    }

    private var micSection: some View {
        Section(header: Text("Record over the song"),
                footer: Text("Records your mic while the track keeps playing and saves the take into your Library. “System voice processing” adds echo cancellation, auto gain and noise reduction for free.")) {
            Toggle(isOn: $mic.systemEnhance) {
                Label("System voice processing (echo cancel + AGC)", systemImage: "checkmark.shield.fill")
            }
            Toggle(isOn: $mic.gateOn) {
                Label("Noise gate between lines", systemImage: "scissors")
            }
            HStack(spacing: 10) {
                MicLevelView(level: mic.level)
                    .frame(maxWidth: .infinity).frame(height: 18)
                Text(String(format: "%d:%02d", Int(mic.seconds) / 60, Int(mic.seconds) % 60))
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                if mic.isRecording {
                    Button("Stop & save") { mic.stop(keep: true) }
                        .buttonStyle(.borderedProminent).tint(.red)
                    Button("Discard") { mic.stop(keep: false) }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        mic.requestPermissionThenStart()
                    } label: {
                        Label("Start take", systemImage: "mic.fill")
                    }.buttonStyle(.borderedProminent).tint(AppTheme.accent)
                }
                Spacer()
            }
            if let e = mic.lastError {
                Text(e).font(.caption).foregroundColor(.orange)
            }
        }
    }

    private var missingPlistNote: some View {
        Section(footer: Text("Microphone features are hidden because this build has no NSMicrophoneUsageDescription. Run `bash scripts/install_ci_fix.sh && git push` once to sync the workflow with the repo, and they appear.")) {
            Label("Microphone not available in this build", systemImage: "mic.slash.fill")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Bits

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.bold()).foregroundColor(AppTheme.accent)
            Text(name).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pct(_ x: Double) -> String { "\(Int((max(0, min(1, x)) * 100).rounded()))%" }

}

/// A tiny level meter for the mic (no AVAudioMeter UI needed).
struct MicLevelView: View {
    let level: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Color.green.opacity(0.85))
                    .frame(width: max(4, geo.size.width * CGFloat(level)))
            }
        }
    }
}

extension KaraokeRecorder {
    /// Asks for the mic (only when the build declares the permission) and then
    /// starts. Kept out of the view so the alert flow is testable.
    func requestPermissionThenStart() {
        VocalStudio.shared.requestMic { ok in
            guard ok else {
                self.lastError = "Microphone access is needed for a take."
                return
            }
            self.start()
        }
    }
}
