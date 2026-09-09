# AS Music — Feature Audit & Roadmap to "extraordinary"

**Date:** 9 Sept 2026 · **Reviewed:** 22 Swift files, 16,747 lines, `TrollMusicApp/TrollMusicApp/`
**Verdict:** the app is already in the top ~5% of sideloaded music players. It is **not**
missing "features" in the normal sense — it is missing **memory, senses and reach**:

| The app can… | but it… |
|---|---|
| measure how every song *sounds* (tempo, loudness, bands, stereo, clipping) | never learns what you **reject** |
| build 12 kinds of auto-playlist from your own library | can't tell you what a badly-named rip actually **is** |
| talk to 20+ AI models with never-stop failover | can't answer a question **about your own library** |
| order a playlist by acoustic flow | still **hard-cuts** between the songs it just ordered |
| download from 5 racing engines | **stops downloading** the moment you leave the app |

This document is the list you asked for: what to add, why it matters *for this app
specifically*, where it plugs into the existing code, and what it costs.

Legend — **Cost:** S = a day, M = a few days, L = a week+ ·
**Runs:** 📱 on-device/no key · 🌐 free API, no key · 🔑 needs an AI key · 🔐 needs an entitlement

---

## 0. Scorecard — where you stand today

**Strong (leave alone, build on top):**
`AudioAnalysis.swift` (real DSP feature extraction) · `SmartPlaylists.swift` (12 recipes +
brief parser in EN/AR/Franco + flow ordering) · `AICore.swift`/`SmartKit.swift` (3 providers,
model rotation, bounded failover, 8 passing logic tests) · `LibraryDoctor` +
`LibraryTrash` + `LibraryHealth` + `BackupKit` (a genuinely careful data-safety story) ·
`ExtractorKit`/`SmartDownloader` (multi-engine racing with a remote registry) ·
`VocalStudio` (per-song corrective EQ, karaoke/acapella export) · `LyricsLive` (real synced LRC).

**Thin:**
implicit feedback · metadata truth (no album/year/key) · background execution ·
input (you cannot add your own MP3s) · surfaces outside the app (no widget, no CarPlay,
no Spotlight) · Arabic UI (the *content* is Arabic-aware, the *interface* is English-only).

---

## 1. Fix these five first — they quietly break the "smart" claim

These are cheap, and every intelligence feature below gets better the moment they land.

### 1.1 🔴 Every skip counts as a full play
`MusicManager.swift:1228` calls `ListenHistory.shared.recordPlay(song)` **at the instant
playback starts**. Skip a song after 2 seconds and it is recorded exactly like a song you
loved to the last bar.

Everything downstream is trained on that lie: `familiarity` in `SongVector`, the
`repeat`/`gems` recipes, `tasteWeight()`, the "Because you like…" row in For You, and the
hour-of-day model.

**Fix (S, 📱):** record on *completion ratio*. Keep `plays`, add `finishes`, `skips` and
`totalSeconds` to `ListenRecord` (it already decodes optional fields safely). Count a play
at ≥60% or ≥90 s, a skip at <20%. Expose `affinity = f(finishes, skips, recency)` and use it
where `playCount` is used today.

### 1.2 🔴 Downloads die when the user leaves the app
`SmartDownloader.swift:415` builds the session with `URLSessionConfiguration.default`.
iOS suspends it on background; a long mix will not finish while the phone is in a pocket.
There is also no `beginBackgroundTask` anywhere in the repo, and `UIBackgroundModes` is
`audio` only.

**Fix (M, 📱):** `URLSessionConfiguration.background(withIdentifier:)` + implement
`handleEventsForBackgroundURLSession`. The chunked/Range path in `ChunkedDownloader` needs a
resume-data strategy; keep the racing logic in the foreground and hand only the **winning
URL** to the background session.

### 1.3 🟠 Downloads are strictly one-at-a-time
`startNext()` keeps a single `activeTask`. Ten queued songs = ten serial waits, even though
`httpMaximumConnectionsPerHost = 8`.

**Fix (S, 📱):** a concurrency window of 2–3 (user-settable), plus a **Wi-Fi-only** toggle.

### 1.4 🟠 You cannot put your own music in
`Info.plist` has no `UIFileSharingEnabled`, no `LSSupportsOpeningDocumentsInPlace`, no
`CFBundleDocumentTypes`, and there is no audio `fileImporter` anywhere (the only
`UIDocumentPicker` is for backup JSON). For a sideloaded app whose whole point is owning
your files, that is the biggest missing door.

**Fix (S, 📱):** three plist keys + one `.fileImporter` + `onOpenURL` so "Open in AS Music"
and AirDrop work. Route imports through the existing `registerDownloadedSong` path so ID3
tagging, analysis and enrichment all fire.

### 1.5 🟠 Smart Radio is `randomElement()`
`MusicManager.swift:1367` — the mode named "Smart Radio" picks a *random* song that doesn't
share a word with the current one. Meanwhile `AcousticRadio` (`ExtrasKit.swift:25`) already
does true nearest-neighbour selection in the feature space.

**Fix (S, 📱):** make Smart Radio call the vector engine (nearest neighbour, artist
cool-down, no repeats inside 2 h). ~15 lines. Also give `playPrevious()` a real history
stack — today it walks the library array, so "back" after a shuffle is wrong.

> Also worth ten minutes each: API keys live in `UserDefaults`
> (`SmartKit.swift:472,477`) — move to Keychain; and `upNextQueue` is never persisted, so a
> relaunch throws the queue away.

---

## 2. Tier 1 — The Brain 🧠 (this is what makes it "most intelligent")

### 2.1 ⭐ Auto-identify your badly-named rips (the single highest-value feature)
Your library is full of `Amr Diab - Tamally Maak (Official Video) [HD] 1.mp3`. `NameTidy`
cleans the *string*; nothing knows the *song*.

**ShazamKit can identify a local file** — `SHSignatureGenerator` builds a signature from the
audio on-device, `SHSession` matches it against Apple's catalog and returns the real title,
artist, **album**, release year, artwork and ISRC.

Why it's transformative here — it fixes the root data problem, and five features improve for
free: lyrics matching (`LyricsLive` searches by title+artist), duplicate detection
(`identityKey` stops guessing), iTunes enrichment (exact match instead of fuzzy), genre
coverage, and recommendations.

**Cost:** M · **Runs:** 🔐 needs the ShazamKit capability — verify it works on your
TrollStore install before committing; prototype behind a toggle. Fallback if the entitlement
is refused: match the *cleaned* name against iTunes Search (already implemented) and let the
AI arbitrate low-confidence cases.

Ship it as: Library → "Identify unknown songs (N)" → review sheet → Apply, reusing the
`NameTidy` review UI so nothing is renamed without you.

### 2.2 ⭐ Musical key + Camelot wheel → harmonic mixing
You already run a vDSP FFT (`SpectrumAnalyzer.swift`). Fold the spectrum into a 12-bin
**chroma** vector and correlate with Krumhansl–Schmuckler profiles → key (e.g. `F# minor`)
and Camelot code (`11A`). Store it in `TrackFeatures` (bump `version`, cache re-analyzes
automatically).

Then: `PlaylistFlow.transitionCost()` gets a harmonic term (±1 Camelot step is free, a
tritone is expensive) — your playlists stop just *flowing by tempo* and start **mixing like a
DJ**. Bonus: Vocal Studio can offer "transpose to my range" for karaoke.

**Cost:** M · **Runs:** 📱 no key, no network.

### 2.3 Genre by contagion (fix the metadata holes)
iTunes enrichment only labels songs it can match — mahraganat and YouTube rips stay
genre-less, which blinds the `focus`/`arabic` recipes. Use **label propagation**: an
unlabelled song takes the majority genre of its k nearest neighbours in feature space when
they agree strongly. Mark it `inferred` so the UI can show it dimmer.

**Cost:** S · **Runs:** 📱

### 2.4 "Ask your library" — a real AI assistant surface
You have 3 providers, failover and 20+ models, but the AI can only *generate a playlist*.
Add one chat surface that can answer questions **about the user's own data**:
"what did I play most last Ramadan?", "which of my songs are recorded badly?",
"make a 40-minute drive mix that ends calm", "who do I listen to at 2am?".

Implementation is cheap because the answers are local: build a compact JSON context
(library stats, top artists, hour histogram, feature summaries, health report) and give the
model a small **tool vocabulary** it can return as JSON — `play`, `make_playlist`,
`download`, `set_eq`, `explain` — which you execute. No key? The same questions route to the
on-device stats engine with templated answers.

**Cost:** M · **Runs:** 🔑 with 📱 fallback.

### 2.5 Learned recipes (the app tunes itself)
Once 1.1 exists: keep per-recipe weights and nudge them from behaviour — if songs you skip in
"Gym & Run" are consistently below 120 BPM, raise the tempo gate for *you*. Store overrides in
`SmartPlaylistStore`; add a "reset to default" so it's never a black box.

**Cost:** M · **Runs:** 📱

### 2.6 Lyrics-aware search & mood
You already cache LRC/plain lyrics. Index them (title + artist + **lyrics**) so
"the song that goes ya habibi" actually finds it — the #1 way people search for Arabic music.
Second use: a crude valence signal from lyric sentiment for the `night`/`calm` recipes (AI
when a key exists, keyword lexicon offline).

**Cost:** S–M · **Runs:** 📱 / 🔑

### 2.7 Hearing-safety dose meter
You measure gated loudness per track and know playback level. Track a rolling
WHO-style dose; warn at 100% of a weekly safe dose and offer a −3 dB protect mode.
Nobody else in this category has it, and it is genuinely good for the user.

**Cost:** M · **Runs:** 📱

### 2.8 Write the intelligence back into the files
BPM, key, ReplayGain and a mood comment into `TXXX`/`TBPM`/`TKEY` frames
(`ID3TagWriter` already writes valid ID3v2.4; `album` is currently always `""` —
`MusicManager.swift:826,1101`). Your numbers then survive a restore and benefit every other
player.

**Cost:** S · **Runs:** 📱

---

## 3. Tier 2 — The Experience ✨ (this is what makes it "extraordinary")

### 3.1 ⭐ Crossfade & beat-aware auto-DJ
The playlist engine already knows the next song's tempo, energy and (after 2.2) key — and
then the player hard-cuts. Add a **second `AVAudioPlayerNode`**, pre-schedule the next track,
and ramp volumes over 1.5–6 s. Because you know the tempo, you can align the fade to a bar
boundary and trim the tail silence you already measure (`tailSilence`).

Modes: Off / Gapless (albums, live sets, Quran) / Crossfade / **Auto-DJ** (energy-matched,
harmonic, beat-aligned). This is the feature people *hear* immediately.

**Cost:** M–L · **Runs:** 📱 · Touches `MusicManager.setupEngine()` and the schedule path.

### 3.2 ⭐ Home-Screen widget + Live Activity / Dynamic Island
Five App Intents already exist (`VoiceRemote.swift`) — the hard modelling is done. Add a
widget extension: now-playing widget, and "tap to play my Gym mix" moment buttons. Live
Activity puts artwork + scrubber in the Dynamic Island.

**Cost:** M · **Runs:** 📱 · Needs a new target in `ci_build.sh`'s XcodeGen spec + an App
Group for shared state. Flag: check how your TrollStore signing handles app groups.

### 3.3 CarPlay
`CPNowPlayingTemplate` + a browsable list template over Playlists/Artists/Smart lists.
Egypt drive-time is a big chunk of this app's use, and the Siri intents already exist.

**Cost:** M–L · **Runs:** 🔐 CarPlay entitlement — verify on your install first.

### 3.4 Spotlight indexing
`CSSearchableItem` per song + per playlist. Typing "Tamally" in the iOS search field jumps
straight into the app and plays it. Cheap, feels magic.

**Cost:** S · **Runs:** 📱

### 3.5 Voice control *while playing* (not just dictation)
Today the mic only fills a search box. Add a tiny local grammar over the same
`SFSpeechRecognizer` pipe — "louder", "more bass", "night mode", "skip", "like this",
"sleep in 20", "اعمل قائمة هادية" — parsed offline and routed to existing setters. No key,
no upload, and `SpokenFeedback` already talks back.

**Cost:** S–M · **Runs:** 📱

### 3.6 Karaoke that scores you
The mic tap and karaoke/acapella extraction already exist. Add YIN pitch detection on the
mic buffer, compare against the lead-vocal pitch track extracted from the center channel,
and show note accuracy + a score. Then: duet mode, punch-in, and "share my take".

**Cost:** M · **Runs:** 📱

### 3.7 Library polish that users feel daily
Multi-select bulk actions in the Library (delete / add to playlist / tidy — the pattern
exists in Playlists at `Views.swift:1624`) · drag-to-reorder playlists and Up Next
(no `onMove` anywhere today) · album art picker in `SongInfoEditorView` · a Storage screen
(you already compute `libraryBytes`) · persistent queue across launches.

**Cost:** S each · **Runs:** 📱

### 3.8 A real "Your Year in Music" / stats screen
You have hour-of-day histograms, play counts, artists and acoustic features — that is a
Wrapped-style story waiting to happen: top artists, listening clock, "your sound signature"
(average energy/brightness vs. last month), longest streak. Shareable card image.

**Cost:** M · **Runs:** 📱

---

## 4. Tier 3 — Reach & polish

| # | Feature | Why | Cost |
|---|---|---|---|
| 4.1 | **Arabic UI + RTL** | Zero `NSLocalizedString` in 16.7k lines. The app *understands* Arabic but only *speaks* English. `Localizable.strings` (ar/en) + RTL layout pass. Biggest credibility win for your actual users. | M |
| 4.2 | **Accessibility & Dynamic Type** | 8 accessibility modifiers total; the player is fixed-size white-on-black. VoiceOver labels + type scaling + a light theme. | M |
| 4.3 | **iCloud sync** | `BackupKit` is a manual JSON file. CloudKit (or an iCloud Drive auto-export) for playlists, likes, history — survives the re-sideload every TrollStore user knows. | M–L |
| 4.4 | **m3u import/export** | One-line interop with every other player; also lets people share playlists. | S |
| 4.5 | **Local notifications** | "12 downloads finished" while you were away. Pairs with 1.2. | S |
| 4.6 | **Chart → mixtape** | "Make me the Egyptian top 20 *and download what I'm missing*" — Deezer charts + `enqueueBatch` + dedupe already exist; it's glue, rate-limited and opt-in. | M |
| 4.7 | **Apple Watch app** | Remote + offline playback of Liked Songs. | L |

---

## 5. My recommendation — "Pack 6", in this order

If it were my call, this is the exact build order. It front-loads the cheap fixes that make
everything else smarter, then lands two headline features.

| Order | Item | § | Cost | Why here | Status |
|---|---|---|---|---|---|
| 1 | Completion-ratio history + dislike | 1.1 | S | Every other AI feature is trained on this data | ✅ shipped |
| 2 | Smart Radio → real vectors + history stack | 1.5 | S | 15 lines, fixes a feature that's lying in its name | ✅ shipped |
| 3 | Import your own music (plist + importer) | 1.4 | S | Opens the front door of the app | ✅ shipped |
| 4 | Background + parallel downloads | 1.2/1.3 | M | The #1 daily frustration | ✅ shipped |
| 5 | **ShazamKit identify unknown rips** | 2.1 | M | Headline. Fixes the root data problem | ✅ shipped |
| 6 | **Crossfade / gapless / auto-DJ** | 3.1 | M–L | Headline. The thing you *hear* in 3 seconds | ✅ shipped |
| 7 | Key detection + harmonic flow | 2.2 | M | Turns good playlists into DJ sets | ✅ shipped |
| 8 | Widget + Live Activity | 3.2 | M | Makes the app visible all day | ✅ shipped (widgets; Live Activity deferred) |
| 9 | Arabic localization + RTL | 4.1 | M | The audience you actually built this for | ✅ shipped |

**Prototype-first items** (verify the entitlement on your TrollStore install *before* building
the feature around them): ShazamKit (2.1), CarPlay (3.3), App Groups for widgets (3.2).

### Pack 6 delivery notes

All nine landed; the build is green and the IPA is produced.

* **ShazamKit** is behind `#if canImport(ShazamKit)` and a settings toggle, with a
  cleaned-name iTunes lookup as the fallback, so a refused entitlement degrades instead of
  breaking the build.
* **Crossfade** needed a real change to the audio graph: a second `AVAudioPlayerNode`, both
  decks summing into a `blendMixer` ahead of the EQ. Ramps are equal-power (`cos`/`sin`) —
  a linear fade drops to 0.5 power mid-blend and you hear the dip. `Off` leaves the old
  hard-cut path byte-for-byte intact.
* **Auto-DJ** reads the already-measured `TrackFeatures`: long blends only when both tracks
  have a strong beat, similar tempo (<8 BPM apart) and similar energy; short ones into
  quiet, spoken or rubato material.
* **Widget (3.2)** shipped as two Home-Screen widgets (Now Playing, Moments), small and
  medium. It needed a second build target and an App Group, so it is the one item that can
  fail at *install* time on a TrollStore signing setup rather than at compile time —
  everything therefore degrades instead of crashing: `SharedStore` returns nil, the
  publisher no-ops, the app is unaffected, and the widget shows an explicit "can't reach
  the app's data yet" state. **Live Activity / Dynamic Island is deliberately deferred**:
  ActivityKit needs `NSSupportsLiveActivities` and a physical device to verify, and it is
  the part most likely to be silently refused by the signing setup.
* Because the deployment target is iOS 16, `Button(intent:)` does not exist. Widget controls
  are `Link`s to `asmusic://` URLs — a tap opens the app and acts, which is honest on iOS 16
  rather than a button that looks interactive and isn't.

**Verification without a Mac.** `scripts/test_pack6_logic.py` mirrors the pure maths in
Python and asserts it — 44 checks over key detection, Camelot distances, affinity
thresholds, auto-DJ lengths and the crossfade curve. `scripts/test_widget_logic.py` adds 43
checks for the cross-target mistakes a compiler cannot catch: app and widget agreeing on the
App Group id and URL scheme, every link the widget builds being one the app routes, a
`file://` URL never being mistaken for a widget link, the widget referencing no app-only
types, and the generated XcodeGen spec embedding the extension with a case-sensitive bundle
id prefix. `scripts/check_localization.py` is bundle-aware (app and widget have separate
string tables) and diffs each against its own sources. `scripts/check_swift_syntax.py`
gained a rule for `self.<file-level global>` after CI caught one, and now covers the widget
target too.

The build is a gate, not just a compile: it fails if a repo `.lproj` is missing from the
packaged app, and if the `.appex` was built but not embedded. Both failures are otherwise
invisible — you get a green build and an app that is quietly English-only, or quietly has
no widget.

---

## 6. Deliberately *not* recommended

* **Stem separation / AI vocal removal on-device** — a Demucs-class model is 100–300 MB and
  minutes per song on an iPhone. Your center-channel extraction already covers 80% of the
  need at 0 MB.
* **Whisper for Arabic lyrics** — same reason. Matching dictation against the lyrics you
  already cache (2.6) gets most of the value for kilobytes.
* **A login/account system** — it would destroy the "no account, nothing uploaded" property
  that is currently one of the app's best features. iCloud (4.3) achieves sync without it.
* **More download engines** — you have five racing with health tracking and a remote
  registry. Reliability now comes from *background execution* (1.2), not more mirrors.

---

## 7. Notes on process (unchanged, still true)

`.github/workflows/build.yml` now builds the repo's real sources via `scripts/ci_build.sh`,
so new files are picked up automatically — but two habits still matter:

```bash
python3 scripts/check_swift_syntax.py    # 1-second structural pre-flight
python3 scripts/test_ai_engine_logic.py  # AI failover scenarios (8 passing)
```

Anything added in Tier 1/2 that touches `TrackFeatures` must bump its `version` — `AudioLab`
drops mismatched cache entries and re-analyzes, which is exactly what you want.
