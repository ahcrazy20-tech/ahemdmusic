# AS Music — Smart Upgrades (Sept 2026)

This document describes the intelligence & strength upgrade pack added to the app,
and the **free APIs** it uses.

## 🔧 Build integrity fix (important!)

`build.yml` used to delete all source files and rewrite them from **old copies
embedded inside the workflow** — which meant the built IPA was missing the
"For You" tab and other newer code even though the repo had them.

The workflow's *Write Swift Files* step is now regenerated from the actual
repo files, so **every CI build matches the code in this repo**. To add a new
`.swift` file in the future, commit it to `TrollMusicApp/TrollMusicApp/` and
re-run the sync script (or copy the new file into the *Write Swift Files*
step).

## 🧠 New intelligence (all free APIs)

| Feature | Where | API | Key needed? |
|---|---|---|---|
| Auto cover-art + real artist name + genre for every song | Library, player, Now Playing | **Apple iTunes Search** (`itunes.apple.com/search`) | No |
| "About the Artist" — bio + photo in the player (Arabic-aware) | Full player → ⓘ button | **Wikipedia REST** (`{en,ar}.wikipedia.org/api/rest_v1`) | No |
| Regional trending charts — Egypt / Saudi / Morocco / USA / UK / France / Worldwide | For You → Trending, Magic DL → Trending | **Deezer** (`api.deezer.com/chart/{code}/tracks`) | No |
| Listening stats — Recently Played, total/weekly plays, most played song & artist | Library top, For You "Your Listening" card | on-device | No |
| Smarter recommendations — taste weighting now uses real play history, not just downloads/likes | For You | on-device | No |
| **AI Music Assistant** — ask "5 new Egyptian pop songs about summer" → one-tap downloadable results | For You → AI section | **Google Gemini** (`generativelanguage.googleapis.com`) | **Optional** free key (aistudio.google.com), entered in player → ⋯ → Equalizer → "AI Music Assistant". With no key the feature is off and nothing is sent. |

## 🎵 Sound & files

- **Real audio-reactive spectrum** in the player — 24 log-spaced bands from a
  live Hann-windowed FFT in the audio engine (pre-allocated buffers, no
  allocations on the render thread).
- **Sleep timer with fade-out** — fades volume over the last 45 s instead of a
  hard stop, and has a "Stop at song end" option (player → ⋯ → sleep menu).
- **Auto MP3 tagging** — successful MP3 downloads get a proper ID3v2.4 tag
  (title, artist, embedded cover) written to the file so it looks right in any
  other player. Pre-tagged files are left untouched.

## 🆓 Free APIs used (and why they're safe)

1. **iTunes Search API** — official Apple endpoint, free, no key, HTTPS.
   The app makes at most ~60 enrichment calls per session, only for songs that
   are missing cover art.
2. **Wikipedia REST API** — free, no key, HTTPS. One call per artist view,
   cached in memory.
3. **Deezer catalog API** — free public catalog, no key, HTTPS (already used
   by the For You tab).
4. **Google Gemini free tier** — optional; the key belongs to the user and is
   stored only in the app's UserDefaults on their device. Default model:
   `gemini-3.5-flash` (2.5-flash was retired by Google in Oct 2026).
   The app now self-heals model retirements automatically — see
   "Resilience pack" below.

## ✅ CI FIX — INSTALLED (Sept 7, 2026)

**Status: fixed.** `.github/workflows/build.yml` now embeds the current repo
sources and pins Swift 5 mode, so CI builds exactly what's in the repo and
the exit-65 failure is gone. The copy in `build.yml.ready` is kept identical
as a backup.

> If the build ever fails with exit code 65 again, first check for drift:
> `build.yml` rewrites every `.swift` file from embedded copies, so after
> changing any `.swift` file run `python3 scripts/sync_build_yaml.py` (or
> `bash scripts/install_ci_fix.sh`) before pushing — otherwise CI keeps
> compiling the old embedded code.

### Why a source fix isn't enough

`.github/workflows/build.yml` doesn't just build the app — it **deletes every
`.swift` file and rewrites them from copies embedded inside the workflow**.
So fixing a bug in `TrollMusicApp/TrollMusicApp/*.swift` changes nothing on
CI until those embedded copies are refreshed too. (This is exactly why the
previous fix attempt still failed: it corrected the sources but not the
workflow, so CI kept recompiling the same broken code.)

The Arena GitHub App is not allowed to push to `.github/workflows/` — that
requires the *workflows* permission — so the corrected workflow ships here as
**`build.yml.ready`**.

### Install it

```bash
bash scripts/install_ci_fix.sh && git push
```

<details>
<summary>…or do it by hand</summary>

```bash
cp build.yml.ready .github/workflows/build.yml
git add .github/workflows/build.yml
git commit -m "Sync CI build with the fixed sources"
git push
```
</details>

**Permanent fix:** grant the Arena GitHub App the *workflows* permission for
this repo. Then every code push can auto-sync the build and it can never
drift again. Until then, after changing any `.swift` file run
`python3 scripts/sync_build_yaml.py` (or the script above) before pushing.

## What was broken (Sept 2026 build failure)

All of it came in with the Smart Pack commit, which never compiled
successfully — the green checkmarks before it were builds of the *older*
embedded sources.

| File | Bug |
|---|---|
| `SpectrumAnalyzer.swift` | The FFT used APIs that don't exist: a made-up type `vDSP_FFT_ZEROPHASE_STAGGERED_DIT64_INPLACEDescriptor`, a constant `FFTRADIX2`, a `withUnsafeMutableBufferPointer(of:)` helper, and the wrong `vDSP_fft_zrip` signature. Rewritten on the real `vDSP_create_fftsetup` / `vDSP_ctoz` / `vDSP_fft_zrip` / `vDSP_zvmags` pipeline, still allocation-free on the render thread. |
| `SmartKit.swift` | `override private init()` on `ListenHistory`, `ITunesEnricher`, `GeminiAI` — none has a superclass, so `override` is illegal. |
| `MusicManager.swift` | Sleep fade multiplied a `Float` by a `Double`; the `Bool` from `ID3TagWriter.tagIfNeeded` was discarded. |
| `Views.swift` | `EQView` used `$ai` without declaring it; unused `song` binding. |

Also hardened in the workflow: `SWIFT_VERSION` is pinned to 5.0 (Xcode 26
would otherwise compile this as Swift 6 and fail on strict concurrency), the
deployment target is iOS 16.0 (installs on iOS 16.4), and the build step now
prints compile errors as GitHub annotations and uploads `build.log`, so the
next failure is readable at a glance.

## Files

| File | What it is |
|---|---|
| `SmartKit.swift` | ListenHistory, ITunesEnricher, WikipediaAPI, GeminiAI, ChartRegion |
| `SpectrumAnalyzer.swift` | FFTProcessor + SpectrumMeter (real-time spectrum) |
| `ID3TagWriter.swift` | ID3v2.4 tag writer for downloaded MP3s |
| `MusicManager.swift` | play-history hooks, sleep fade, spectrum tap, tag/enrich hooks |
| `MusicIntelligence.swift` | regional charts, play-history taste weighting |
| `Views.swift` / `DiscoverView.swift` | spectrum view, artist-info sheet, stats card, AI assistant UI, region pickers |

## 🛡️ Resilience pack (Sept 2026) — self-healing AI + alternative engines

Classic download/search behavior is untouched. Everything below is additive:
new engines join the fast race as extra contenders (probe-validated — a dead
engine just loses quietly) or run after a classic path already failed.

**AI self-healing (`SmartKit.swift` + `DiscoverView.swift`)**
- Default model is now `gemini-3.5-flash` (2.5-flash retired Oct 2026).
- New **Auto model** toggle (AI Assistant setup screen, on by default):
  - Proactive: before each ask, `GeminiDiscovery.preSwitchIfGone` checks
    Google's ListModels; if the stored id vanished, it silently adopts a
    verified replacement.
  - Reactive: a retired-model error (404 / "model … retired|deprecated|
    unsupported|…") rotates to the next candidate and retries the same ask
    once (`attempt` cap = 1, so it can never loop).
  - Candidates come from `backend-registry.json` (`geminiFallbacks`), with a
    hardcoded 3.5→3.6→3.7→3.8-flash backup. Toggle off = classic behavior.

**Alternative engines (`ExtractorKit.swift`, new file)**
- `PipedAudio` (15 mirrors), `InvidiousAudio` (itag 140 + proxied variant),
  `CobaltAudio` (dormant until the registry enables an instance), and
  `CustomExtractor` (your own extractor server) join `startFastRace` via
  `NewExtractors.racers()` — the classic 3 contenders run first, unchanged.
- `SoundCloudResolver` (yt-dlp technique: scrape `client_id`, resolve/search
  via api-v2, follow the progressive transcoding) runs once per task in
  `failOrRetry` after the classic engines + 3 auto-retries fail.
- `BackendHealth` backs off repeatedly-failing new backends (classic engines
  are never skipped). `EngineSettingsView` (gear icon on Magic DL) shows
  engine status, the custom-server field + test button, and a registry
  refresh button.

**Remote healing without an app release**
- `backend-registry.json` (repo root, fetched daily, cached) overlays the
  bundled config: Gemini model list, Piped/Invidious/Cobalt mirrors + enable
  flags. Push to `main` and every device picks it up within 24h.
- `extractor-server/` is a tiny deployable yt-dlp server (Render-ready) for
  the BYO path: `GET /extract?v={id}` → proxied audio URL.

**Also fixed along the way:** `probeForAudio` read `b[4]…b[7]` from a 4-byte
prefix (out-of-bounds crash on some responses) — now `prefix(8)` with the
existing `count >= 8` guard.
