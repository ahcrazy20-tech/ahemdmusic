# AS Music — Smart Pack 2 (Sept 2026): AI auto-playlists + voice

Everything in this pack is **additive and switch-off-safe**: with every toggle off
the app behaves exactly as it did before, and every feature that can run on-device
does run on-device (no key, no account, no upload).

---

## 0. Read this first — the repo/CI drift that this pack fixed

`build.yml` does not compile the `.swift` files in this repo. It **deletes them**
and rewrites them from copies embedded inside the workflow. While this pack was
being written, that had already silently gone wrong:

| Thing | Repo (before) | CI build.yml (before) |
|---|---|---|
| `ExtractorKit.swift` (774 lines: Piped/Invidious/Cobalt racing, backend registry, `EngineSettingsView`) | **missing entirely** | present, shipped in the IPA |
| `SmartKit.swift` (Gemini auto-model self-healing) | older | newer |
| `SmartDownloader.swift` (extra race contenders) | older | newer |
| `Views.swift`, `DiscoverView.swift` (engine settings UI) | older | newer |
| `backend-registry.json` the app tries to fetch | missing (404) | referenced |

So the repo was *not* the source of truth, and running the old `sync_build_yaml.py`
would have **deleted** the multi-engine downloaders and the AI self-healing from
the next build. Fixed in this pack:

* **`scripts/restore_sources_from_workflow.py`** — the reverse sync: copies the
  workflow's embedded sources back into `TrollMusicApp/TrollMusicApp/`
  (`--check` for CI/diagnostics). Used it to restore the 5 drifted files.
* **`backend-registry.json`** added at the repo root so the app's remote engine
  config resolves instead of 404-ing (tune mirrors, enable/disable engines, change
  the Gemini model — **no app rebuild needed**).
* **`scripts/check_swift_syntax.py`** — 1-second structural pre-flight for people
  without a Mac (see §5).
* `build.yml.ready` regenerated from the repo, so installing it can only ever add.

> ⚠️ **One command you must run** to make any of this code reach the IPA:
> `bash scripts/install_ci_fix.sh && git push`
> (The Arena GitHub App can't push to `.github/workflows/`; grant it the
> *workflows* permission and this step disappears forever.)

---

## 1. 🧠 The app now knows what a song *sounds* like — `AudioAnalysis.swift`

`AudioLab` reads each file with `AVAudioFile` and scans the PCM once, on-device:

| Measured | How | Used by |
|---|---|---|
| gated loudness (EBU R128-style, −10 dB relative gate) | window RMS histogram | loudness matching, energy axis |
| tempo + beat strength | onset envelope → autocorrelation, 70–180 BPM fold | workout/party recipes, flow ordering |
| band split: sub / warm / body / presence / air | 5 cascaded one-pole low-passes | Smart Master EQ, brightness |
| center-vs-side ratio in 300 Hz–5 kHz | M/S band energy | "vocal-forward" detection, karaoke |
| stereo width, dynamic range, clipping ratio | per-sample accumulators | quality score, rip repair |
| leading / trailing dead air | silence-gated window scan | auto-skip silence on bad rips |

No FFT, no model download, no network. Cached in `.asmusic_audio.json`
(≈ a few seconds for a whole library, once). Budgeted at 60 songs per launch with
the current + liked songs first, so a 500-song library never freezes the app.

## 2. ✨ Auto-playlists — `SmartPlaylists.swift` (the thing you asked for)

**12 built-in recipes** score every song and build a playlist when enough match:
`Gym & Run · Farah / Party · Wind Down · Sleep · Focus (No Words) · Road Trip ·
Arabic Nights · Late Night · Fresh Finds · On Repeat · Hidden Gems · Best Sounding`.

On top of that, **vibe clusters**: a deterministic k-means over
`[energy, brightness, warmth, vocal, tempo]` groups whatever is left and each group
gets named from its own centroid ("Fast Bright Mix", "نشيط · Loud Set"), Arabic
naming when the cluster is Arabic-heavy.

Then the **auto-DJ ordering** (`PlaylistFlow`): greedy nearest-neighbour chain +
adjacent-swap smoothing, where the cost function double-weights tempo jumps, adds
energy jumps, penalises back-to-back same artist and rewards same genre. A
playlist created by this app now *flows* instead of listing.

Also:
* **Daypart-aware** — `ListenHistory` now buckets every play by hour of day, and
  ranking gets a `+0.3 × hourFit` nudge, so what you play at 7 am surfaces in the
  morning mix and not at 2 am.
* **Auto-create** (on by default): runs on launch and 25 s after the last download
  in a batch, throttled to once per 6 h *unless the library changed*.
* **In-place refresh**: `SmartPlaylistStore` remembers which playlists the app
  owns (kind → playlist id), so "Refresh" updates the same playlist instead of
  creating "Gym & Run 2". ✨ badges mark them in the Playlists tab.
* **One-tap from Siri**: `playMoment("gym")` builds, saves and plays.

### "Describe a playlist" — with or without AI

* **No key (default)**: `PlaylistBriefParser` — keyword tables in **English,
  Arabic and Franco-Arabic** ("جيم حماسية", "quiet arabic for a rainy drive",
  "مذاكرة بدون غنا") → weighted feature recipe, exclusion parsing
  ("no rap", "بدون مهرجانات"), artist names recognised from your own library,
  and genre words. Fully offline.
* **With your Gemini key**: the model is given *only* your library as a numbered
  catalog (`index|title|artist|genre|E/B/tempo`) and must answer
  `{"name","selection":[indexes],"why"}` — so it can pick and name, but it can
  never invent a song and make the app download it. If it errors or refuses, the
  local parser finishes the job in the same tap.

## 3. 🎚 Sound & voice improvements — `VocalStudio.swift`

Playback (all per-song, from the measurements above, applied on top of your EQ
preset — zero offsets when off):

* **Smart Master** — corrective EQ: muddiness ⇒ −125/250 Hz, thin ⇒ +64/125 Hz,
  dull ⇒ +4/8/16 kHz, harsh ⇒ −2/4 kHz, sibilant/hissing rip ⇒ −8/16 kHz, and it
  never pushes a clipped file louder.
* **Match loudness across songs** — per-track trim to your target
  (−22…−8 dBFS, default −15, clamped ±10 dB) with peak headroom respected, so an
  old Amr Diab rip and a modern Mahraganat track sit at the same level.
* **Vocal Focus** — +1.4/+2.2/+1.6 dB through 1–4 kHz with the box (125–500 Hz)
  pulled out from under the voice: lyrics in a noisy room or in the car.
* **Night / low-volume mode** — equal-loudness compensation (Fletcher-Munson):
  gives back the bass and air your ears lose at low volume, tames the shouty mid.
* **Rip repair** — de-hiss / de-ess tilt for lossy YouTube rips.
* **Skip dead air** — starts a file after its measured lead silence instead of
  making you watch 1.5 s of nothing.

Export (one pass, plain Swift, nothing leaves the phone):

* **Karaoke** — real center-channel extraction with a crossover: everything under
  ~200 Hz is preserved (that's why this doesn't sound like the naive L−R trick),
  the 300 Hz–5 kHz voice band is ducked by your "removal" amount, air above 5 kHz
  only partly. Result is written as a **new** `.m4a` in your Library.
* **Acapella** — keeps that same centered band, gated by the center-vs-side ratio
  so panned instruments fall away and the lead voice stays.

Record (this is the literal "improve voices" feature):

* **Karaoke mic take** — records your voice over the playing song and saves it
  into the Library, with the system's own **`.voiceChat`** processing (echo
  cancellation, AGC, noise suppression) plus a 90 Hz rumble high-pass, a noise
  gate between lines, +2.5 dB and a soft limiter in the tap. Toggle off the system
  DSP to get raw `.measurement`-quality capture instead.

## 4. 🎙 Voice control — `VoiceRemote.swift`

* **App Intents / Siri / Shortcuts** (no entitlement, no plist key):
  `Play a Moment Mix` (gym/focus/chill/sleep/party/arabic/drive/fresh),
  `Build a Playlist` (free-text → §2's curator), `Play a Playlist` (fuzzy name
  match), `Control Playback` (next / previous / pause / resume / like / shuffle),
  `Set Sleep Timer`. Phrases are registered via `AppShortcutsProvider`, so
  "Hey Siri, play my workout mix in AS Music" works from the lock screen.
* **Dictation search** — `VoiceSearchController` (SFSpeechRecognizer, **ar-SA →
  ar-EG → ar** first, then the system language), mic buttons added to the Library
  search field and the Magic DL bar. Prefers on-device recognition when the
  language supports it, 12 s auto-stop.
* **Spoken replies** — `SpokenFeedback` (AVSpeechSynthesizer): announces the song
  that starts and reads AI results back, picks an **ar-SA voice for Arabic text**
  and en-GB/en-US otherwise, and ducks the master output to −9 dB only while it
  talks.

**Crash-proofing:** dictation/recording are hidden when the build lacks
`NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription`. Both keys
were added to `Info.plist`, but because the workflow writes its own copy of the
plist, they only reach the IPA after the CI sync in §0 — until then the app shows
a hint instead of crashing on a missing usage string.

## 5. Tooling

```bash
python3 scripts/check_swift_syntax.py          # structure + cross-file symbol pre-flight
python3 scripts/restore_sources_from_workflow.py --check   # repo vs CI drift
python3 scripts/sync_build_yaml.py             # repo → CI (run after adding a .swift file)
bash scripts/install_ci_fix.sh && git push     # you (workflows permission)
```
`check_swift_syntax.py` needs no Xcode and no pip packages: it balances
brackets/strings/comments (Swift raw strings and `#/regex/#` included), rejects
imports after code, and warns about PascalCase symbols **this app** never
declares — which is how a missing `import Combine`-style mistake gets caught in a
second instead of a 10-minute CI cycle. It does **not** type-check; CI still does.

## 6. Not in this pack (deliberate, with the reason)

| Idea | Why it waits |
|---|---|
| Auto-crossfade between songs | needs a second `AVAudioPlayerNode` in the graph + volume ramps; every bug there is a playback bug. Needs a real device in the loop, not a CI guess. |
| True ML genre/mood tagging (CoreML) | ships a 20–150 MB model in the IPA; would also need the model file in the workflow's source-rewrite step. |
| "What's playing?" (Shazam-style) | needs a fingerprint DB; no free API exists. |
| CarPlay / Siri audio provider | needs `entitlements` + a real device to test, and TrollStore installs have limited entitlement support. |
| Per-song key/mood (chroma) | needs a real STFT; the one-pole analysis here is deliberately cheap. |
| Smart-playlist *ordering* learned from your skips | needs a skip log (only plays are recorded today) — 20 lines once that exists. |
