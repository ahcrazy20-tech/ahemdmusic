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
   `gemini-2.5-flash` (free tier: ~10 req/min, 500 req/day). Changeable in
   settings.

## ⚠️ ONE-TIME CI FIX — REQUIRED, the build fails without it (2 minutes)

**Status: the GitHub build is currently failing with exit code 65 (Swift
compile error). The code fixes are committed, but CI cannot pick them up
until you run the command below.**

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
