import Foundation
import AVFoundation
import Speech
import AppIntents
import SwiftUI

// ===========================================================================
// MARK: - VoiceRemote (hands-free AS Music)
//
// Three voice features, one file:
//
//   1. SIRI / SHORTCUTS — real App Intents, so "Hey Siri, play my gym mix in
//      AS Music", "next", "like this song", "sleep in 30", "make me a playlist
//      for a rainy drive" all work from the lock screen, CarPlay-ish Siri and
//      the Shortcuts app. No entitlement, no Info.plist key needed.
//   2. DICTATION SEARCH — say what you want to find and the search field types
//      it for you (Arabic-first). Needs mic + speech permissions, and the UI
//      hides itself if the build doesn't declare them, so an unsynced CI build
//      can never TCC-crash.
//   3. SPOKEN REPLIES — the app talks back: now-playing announcements and AI
//      results, ducking the music while it speaks, using an ar-SA voice when
//      the text is Arabic and en-GB/en-US otherwise.
// ===========================================================================

// MARK: - Permissions

enum VoicePermissions {
    /// The build must carry the usage strings in Info.plist, or touching the
    /// mic/speech APIs crashes at launch. That's why every voice UI checks this.
    static var microphoneDeclared: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }
    static var speechDeclared: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }
    static var dictationPossible: Bool { microphoneDeclared && speechDeclared && SFSpeechRecognizer() != nil }
    static var recordingPossible: Bool { microphoneDeclared }

    static func requestBoth(_ done: @escaping (Bool) -> Void) {
        guard microphoneDeclared, speechDeclared else { done(false); return }
        SFSpeechRecognizer.requestAuthorization { status in
            let speechOK = status == .authorized
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async { done(speechOK && micOK) }
            }
        }
    }
}

// MARK: - 2. Dictation

final class VoiceSearchController: ObservableObject {
    static let shared = VoiceSearchController()

    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published var lastError: String? = nil
    /// Called with the final spoken text (search boxes subscribe to this).
    var onFinal: ((String) -> Void)? = nil

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer? = nil
    private var request: SFSpeechAudioBufferRecognitionRequest? = nil
    private var task: SFSpeechRecognitionTask? = nil
    private var stopItem: DispatchWorkItem? = nil
    private var tapInstalled = false

    var isAvailable: Bool { VoicePermissions.dictationPossible }

    private init() {}

    func toggle() {
        if isListening { stop() } else { start() }
    }

    func start(useArabic: Bool = true) {
        guard VoicePermissions.dictationPossible else {
            lastError = "This build has no microphone/speech entries in Info.plist — sync CI once (see scripts/install_ci_fix.sh)."
            return
        }
        guard !isListening else { return }
        lastError = nil
        transcript = ""
        VoicePermissions.requestBoth { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                self.lastError = "Microphone or Speech permission is off in Settings."
                return
            }
            self.begin(useArabic: useArabic)
        }
    }

    private func begin(useArabic: Bool) {
        // `Locale.Language` has no `identifier` — the tag is assembled from the
        // language/region codes (and an unknown tag is simply skipped below).
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier
        let current = region.map { "\(lang)-\($0)" } ?? lang
        let tags = useArabic ? ["ar-SA", "ar-EG", "ar"] : [current, lang, "en-US"]
        var rec: SFSpeechRecognizer? = nil
        for t in tags {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: t)), r.isAvailable {
                rec = r
                break
            }
        }
        guard let recognizer = rec else {
            lastError = "No speech recognizer is available for this language right now."
            return
        }
        self.recognizer = recognizer

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .search
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            lastError = "Audio input is busy — stop recording in Vocal Studio first."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch {
            lastError = "Could not start the mic: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            tapInstalled = false
            return
        }
        isListening = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.transcript = text }
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.stop()
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { self.onFinal?(t) }
                    }
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    if self.transcript.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.lastError = "Didn't catch that — try again."
                    }
                    self.stop()
                }
            }
        }

        // Safety valve: never leave the mic open forever.
        let item = DispatchWorkItem { [weak self] in self?.stop() }
        stopItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
    }

    func stop() {
        stopItem?.cancel()
        stopItem = nil
        guard isListening || task != nil else { return }
        isListening = false
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        recognizer = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}

// MARK: - 3. Spoken replies

/// Talks back over the music: ducks the engine, speaks, restores.
final class SpokenFeedback: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpokenFeedback()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "asmusic_speak") }
    }
    @Published var announcePlayback: Bool {
        didSet { UserDefaults.standard.set(announcePlayback, forKey: "asmusic_speak_np") }
    }
    @Published var rate: Double {
        didSet { UserDefaults.standard.set(rate, forKey: "asmusic_speak_rate") }
    }
    @Published private(set) var isSpeaking = false

    private let synth = AVSpeechSynthesizer()

    private override init() {
        enabled = UserDefaults.standard.object(forKey: "asmusic_speak") as? Bool ?? false
        announcePlayback = UserDefaults.standard.object(forKey: "asmusic_speak_np") as? Bool ?? false
        rate = UserDefaults.standard.object(forKey: "asmusic_speak_rate") as? Double ?? 0.5
        super.init()
        synth.delegate = self
    }

    /// Speaks `text`. Silence wins over speech when the user is mid-fade.
    func say(_ text: String, force: Bool = false) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, enabled || force else { return }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: clean)
        u.rate = Float(max(0.35, min(0.7, rate)))
        u.pitchMultiplier = 1.0
        u.volume = 0.95
        let ar = WikipediaAPI.hasArabicScript(clean)
        let code = ar ? Self.firstArabicVoice() : Self.firstEnglishVoice()
        if let code = code { u.voice = AVSpeechSynthesisVoice(language: code) }
        DispatchQueue.main.async {
            self.isSpeaking = true
            MusicManager.shared.setDuckLevel(0.35)
            self.synth.speak(u)
        }
    }

    func announceNowPlaying(_ song: Song) {
        guard enabled, announcePlayback else { return }
        let artist = song.artist.isEmpty || song.artist == "AS Music" ? "" : " — \(song.artist)"
        say("Now playing \(song.title)\(artist)", force: false)
    }

    private static func firstArabicVoice() -> String? {
        let wanted = ["ar-SA", "ar-EG", "ar-JO", "ar-AE", "ar"]
        let all = AVSpeechSynthesisVoice.speechVoices().map { $0.language }
        for w in wanted where all.contains(w) { return w }
        return all.first { $0.hasPrefix("ar") }
    }

    private static func firstEnglishVoice() -> String? {
        let wanted = ["en-GB", "en-US", "en-IE", "en"]
        let all = AVSpeechSynthesisVoice.speechVoices().map { $0.language }
        for w in wanted where all.contains(w) { return w }
        return all.first { $0.hasPrefix("en") }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            MusicManager.shared.setDuckLevel(1.0)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            MusicManager.shared.setDuckLevel(1.0)
        }
    }
}

// MARK: - 1. App Intents (Siri + Shortcuts)

/// The moments the auto-DJ knows how to score.
enum MusicMoment: String, AppEnum {
    case gym
    case focus
    case chill
    case sleep
    case party
    case arabic
    case drive
    case fresh

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Moment"
    static var caseDisplayRepresentations: [MusicMoment: DisplayRepresentation] = [
        .gym: "a workout mix",
        .focus: "a focus mix",
        .chill: "something calm",
        .sleep: "something for sleep",
        .party: "a party mix",
        .arabic: "Arabic songs",
        .drive: "a driving mix",
        .fresh: "my newest songs"
    ]

    /// The smart-playlist recipe that matches this moment.
    var recipeKind: String {
        switch self {
        case .gym: return "gym"
        case .focus: return "focus"
        case .chill: return "calm"
        case .sleep: return "sleep"
        case .party: return "party"
        case .arabic: return "arabic"
        case .drive: return "drive"
        case .fresh: return "fresh"
        }
    }

    var spokenFallback: String {
        switch self {
        case .gym: return "Gym & Run"
        case .focus: return "Focus / No Words"
        case .chill: return "Wind Down"
        case .sleep: return "Sleep"
        case .party: return "Farah / Party"
        case .arabic: return "Arabic Nights"
        case .drive: return "Road Trip"
        case .fresh: return "Fresh Finds"
        }
    }
}

/// "Play something for the gym" → builds (or reuses) that smart playlist and
/// starts it.
struct PlayMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Moment Mix"
    static var description = IntentDescription("Builds and plays the smart playlist for the moment you choose.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Moment") var moment: MusicMoment

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$moment)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let kind = moment.recipeKind
        let picked = await MainActor.run { () -> String in
            SmartPlaylistEngine.shared.playMoment(kind)
        }
        return .result(dialog: IntentDialog(stringLiteral: "Playing \(picked)."))
    }
}

/// "Play my <name> playlist" — matched fuzzily against your real playlists.
struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Playlist"
    static var description = IntentDescription("Plays a playlist by name, falling back to the closest match.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Playlist") var name: String

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$name)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let asked = name
        let outcome = await MainActor.run { () -> (String, Int) in
            let mm = MusicManager.shared
            if let pl = mm.playlist(matching: asked) {
                let n = mm.playPlaylist(pl)
                return (pl.name, n)
            }
            // Not a playlist you have — try the smart recipes instead.
            let brief = PlaylistBriefParser.parse(asked)
            SmartPlaylistEngine.shared.rebuild(force: true)
            if !brief.title.isEmpty, let s = SmartPlaylistEngine.shared.suggestions.first(where: { $0.title == brief.title }) {
                SmartPlaylistEngine.shared.apply(s)
                mm.playSmartPlaylist(kind: s.kind)
                return (s.title, s.count)
            }
            mm.shuffleAll()
            return ("shuffled Library", mm.songs.count)
        }
        if outcome.1 == 0 {
            return .result(dialog: IntentDialog(stringLiteral: "I couldn't find anything to play."))
        }
        return .result(dialog: IntentDialog(stringLiteral: "Playing \(outcome.0) — \(outcome.1) songs."))
    }
}

/// Skip / like / sleep in one intent, so Siri can be lazy about wording.
struct QueueControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Control Playback"
    static var description = IntentDescription("Next, previous, pause, resume, or like the current song.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Action") var action: PlaybackAction

    static var parameterSummary: some ParameterSummary { Summary("\(\.$action)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await MainActor.run { () -> String in
            let mm = MusicManager.shared
            switch action {
            case .next: mm.playNext(); return "Next song."
            case .previous: mm.playPrevious(); return "Previous."
            case .pause: if mm.isPlaying { mm.togglePlayPause() }; return "Paused."
            case .resume: if !mm.isPlaying { mm.togglePlayPause() }; return "Playing."
            case .like:
                if let s = mm.currentSong { mm.toggleFavorite(song: s); SpokenFeedback.shared.say("Saved to your liked songs.") }
                return mm.currentSong == nil ? "Nothing is playing." : "Liked."
            case .shuffle: mm.isShuffle.toggle(); return mm.isShuffle ? "Shuffle on." : "Shuffle off."
            }
        }
        return .result(dialog: IntentDialog.spoken(said.isEmpty ? "Done." : said))
    }
}

enum PlaybackAction: String, AppEnum, CaseIterable {
    case next, previous, pause, resume, like, shuffle

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
    static var caseDisplayRepresentations: [PlaybackAction: DisplayRepresentation] = [
        .next: "next", .previous: "previous", .pause: "pause",
        .resume: "resume", .like: "like this song", .shuffle: "shuffle"
    ]
}

/// "Set a sleep timer for 30 minutes."
struct SleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Sleep Timer"
    static var description = IntentDescription("Stops playback after the given number of minutes, with a fade.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutes") var minutes: Int

    static var parameterSummary: some ParameterSummary { Summary("Sleep in \(\.$minutes) minutes") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = max(1, min(180, minutes))
        await MainActor.run { MusicManager.shared.setSleepTimer(minutes: m) }
        if m == 1 { return .result(dialog: IntentDialog(stringLiteral: "Sleeping in one minute.")) }
        return .result(dialog: IntentDialog(stringLiteral: "Sleeping in \(m) minutes."))
    }
}

/// The AI playlist builder, reachable by voice.
struct GeneratePlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Build a Playlist"
    static var description = IntentDescription("Describe a mood in plain language and AS Music builds the playlist from your library.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Description") var request: String

    static var parameterSummary: some ParameterSummary { Summary("Build a playlist for \(\.$request)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = request
        // `generate` is callback-based (and can call back synchronously in the
        // offline path), so bridge it once — resumed exactly once either way.
        let said: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let once = OnceFlag()
            let reply: (String) -> Void = { msg in
                if once.fire() { cont.resume(returning: msg) }
            }
            if Thread.isMainThread {
                SmartPlaylistEngine.shared.generate(from: text) { reply($0 ?? "Playlist built from your library.") }
            } else {
                DispatchQueue.main.async {
                    SmartPlaylistEngine.shared.generate(from: text) { reply($0 ?? "Playlist built from your library.") }
                }
            }
        }
        return .result(dialog: IntentDialog.spoken(said))
    }
}

extension IntentDialog {
    /// A dialog built from a string produced at runtime.
    ///
    /// `IntentDialog` has no plain-string initialiser (the available ones take a
    /// `LocalizedStringResource`), which is why the literal replies above use
    /// `IntentDialog(stringLiteral:)`. A runtime string is exactly one
    /// interpolation segment of a `LocalizableStringInterpolation`, so that is how
    /// we hand it over — no strings file or lookup involved.
    static func spoken(_ text: String) -> IntentDialog {
        var interp = LocalizableStringInterpolation()
        interp.appendInterpolation(text)
        return IntentDialog(LocalizedStringResource(interp))
    }
}

/// Thread-safe "only the first call wins" flag, so a continuation can never be
/// resumed twice (that is a hard crash, not a warning).
private final class OnceFlag {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - Shortcut catalogue

struct ASMusicAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMomentIntent(),
            phrases: [
                "Play a mix in \(.applicationName)",
                "Play my workout mix in \(.applicationName)"
            ],
            shortTitle: "Play a Mix",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: GeneratePlaylistIntent(),
            phrases: [
                "Make a playlist in \(.applicationName)",
                "Build me a playlist in \(.applicationName)"
            ],
            shortTitle: "Build Playlist",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play my playlist in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: QueueControlIntent(),
            phrases: [
                "Like this song in \(.applicationName)",
                "Shuffle \(.applicationName)"
            ],
            shortTitle: "Playback",
            systemImageName: "forward.end"
        )
        AppShortcut(
            intent: SleepTimerIntent(),
            phrases: [
                "Set a sleep timer in \(.applicationName)"
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz"
        )
    }
}

// MARK: - UI bits

/// The mic button used in the Library / Magic DL search fields.
struct VoiceSearchButton: View {
    @ObservedObject private var voice = VoiceSearchController.shared
    var placeholderHint: String = "say a song or artist"
    var onText: (String) -> Void

    var body: some View {
        Group {
            if voice.isAvailable {
                Button {
                    if voice.isListening {
                        voice.stop()
                    } else {
                        voice.onFinal = onText
                        voice.start()
                    }
                } label: {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(voice.isListening ? .white : AppTheme.accent)
                        .padding(7)
                        .background(voice.isListening ? AppTheme.accent : Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .accessibilityLabel(voice.isListening ? "Stop listening" : "Search by voice (\(placeholderHint))")
            } else {
                EmptyView()
            }
        }
    }
}

/// Voice/speech settings, shown inside the Audio Settings sheet.
struct VoiceSettingsSection: View {
    @ObservedObject private var speak = SpokenFeedback.shared
    @ObservedObject private var voice = VoiceSearchController.shared

    var body: some View {
        Section(header: Text("Voice control"),
                footer: VStack(alignment: .leading, spacing: 6) {
                    Text("Say to Siri: “Play a mix in AS Music”, “Build me a playlist for a rainy drive”, “Like this song”, “Sleep in 30 minutes”. Add your own in the Shortcuts app.")
                    if !voice.isAvailable {
                        Label("Dictation needs the mic + speech permission entries in Info.plist — re-sync CI once (scripts/install_ci_fix.sh).",
                              systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    }
                    if speak.enabled {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Speech rate").font(.caption).foregroundColor(.secondary)
                            Slider(value: $speak.rate, in: 0.35...0.7)
                        }
                    }
                }) {
            Toggle(isOn: $speak.enabled) {
                Label("Let the app talk back", systemImage: "person.speaking.wave.2")
            }
            Toggle(isOn: $speak.announcePlayback) {
                Label("Announce the song that starts", systemImage: "megaphone.fill")
            }
            .disabled(!speak.enabled)
            Button {
                voice.toggle()
            } label: {
                Label(voice.isListening ? "Stop listening" : "Try voice search now",
                      systemImage: voice.isListening ? "stop.circle.fill" : "mic.circle")
            }
            .disabled(!voice.isAvailable)
            if let e = voice.lastError {
                Text(e).font(.caption).foregroundColor(.orange)
            }
        }
    }
}
