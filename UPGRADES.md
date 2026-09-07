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

## Files

| File | What it is |
|---|---|
| `SmartKit.swift` | ListenHistory, ITunesEnricher, WikipediaAPI, GeminiAI, ChartRegion |
| `SpectrumAnalyzer.swift` | FFTProcessor + SpectrumMeter (real-time spectrum) |
| `ID3TagWriter.swift` | ID3v2.4 tag writer for downloaded MP3s |
| `MusicManager.swift` | play-history hooks, sleep fade, spectrum tap, tag/enrich hooks |
| `MusicIntelligence.swift` | regional charts, play-history taste weighting |
| `Views.swift` / `DiscoverView.swift` | spectrum view, artist-info sheet, stats card, AI assistant UI, region pickers |
