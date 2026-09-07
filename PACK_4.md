# AS Music — Pack 4 (Sept 2026): find the features you already paid for, then add four more

## 0. First: why none of it was in your IPA

This is the whole answer to *"I requested these features, I can see them in the
repo, but they are not in the app after I install it."*

The code was there. **The build was compiling something else.**

`.github/workflows/build.yml` on the working branches is a 463 KB file that
carries a copy of the app inside itself. Its first steps are:

```bash
find . -name "*.swift" -delete        # every real source file, gone
cat << 'SWIFT' > .../Views.swift      # …replaced by a copy pasted in the workflow
```

That embedded copy is frozen at whatever the app looked like when it was
generated. Eleven files, ~9,000 lines, months old. The other nine source files
in the repo — `SmartPlaylists.swift`, `LibraryDoctor.swift`, `LibraryTrash.swift`,
`LyricsLive.swift`, `BackupKit.swift`, `LibraryHealth.swift`, `AudioAnalysis.swift`,
`VocalStudio.swift`, `VoiceRemote.swift` — were never compiled by CI at all.

So: green checkmark, old IPA, missing features. Nothing about the app code was
wrong.

**The fix is one human step** (the assistant's GitHub App is not allowed to
write to `.github/workflows/`): install the 38-line workflow that simply runs
`scripts/ci_build.sh`, which compiles whatever is in `TrollMusicApp/TrollMusicApp/`.
Instructions: **[`SETUP_ONCE.md`](SETUP_ONCE.md)**.

To make sure this can never silently happen again, `scripts/ci_build.sh` now
refuses to build when it does not see the repo's sources:

```
Only 0 Swift files found in TrollMusicApp/TrollMusicApp (expected 20).
This almost always means the OLD workflow is still installed…
```

and the build step prints, at the top of every run, the exact list of files it
is about to compile.

---

## 1. ✅ Feature 1 — AI playlists in the Playlists tab + delete any list

Already written (Smart Pack 3); it was invisible because of §0. What you get:

| | |
|---|---|
| **Generate** | One field at the top of the Playlists tab: *"sad arabic for a rainy night"*, *"جيم حماسية"*, *"90s road trip"* → a real playlist built **from your own library** |
| **With/without AI** | A free Gemini key makes the model pick and name the list; with no key the on-device Arabic/English parser does the same job, offline |
| **Zero typing** | Mood chips (Gym · Party · Chill · Focus · Drive · Sleep · Arabic) and **Surprise me** (time-of-day aware) |
| **Delete** | Swipe a list → Delete · **Select** in the nav bar → delete many at once · ⋯ → **Delete all ✨ playlists** |
| **Undo** | Every delete shows *Undo* for 10 seconds |
| **Regenerate** | Long-press a generated playlist → your original sentence runs again against your (now bigger) library |
| **DJ ordering** | Tempo/energy-smoothed, no two songs by the same artist back to back |

## 2. ✅ Feature 2 — duplicate finder in the Library

Also already written, also invisible because of §0 — **and it was easy to miss
even once shipped: it was a bare `doc.on.doc` icon in the nav bar.** It is now a
labelled row inside the Library itself:

```
🧰 Library tools
   ⧉  Duplicates found — 7 extra copies
      4 groups · 38 MB to reclaim · you decide what goes     ›
   Shuffle all      Play 312      Artists
```

* **Layer 1 — names:** normalized artist+title, so `Amr Diab - Tamally Maak
  (Official Video)` and `tamally maak 1` land in one group.
* **Layer 2 — sound:** length (±1.5 s), tempo (±2.5 BPM), loudness (±1.5 dB),
  dynamics, stereo width and the five-band tone profile. This is how
  `audio_2831.mp3` is caught next to `Nancy Ajram - Ah W Noss.mp3`
  (marked **SAME AUDIO**).
* **You decide:** each group pre-selects the copy worth keeping (liked >
  most played > measured quality > bitrate > has artwork). Tap another copy to
  override. Nothing is deleted until you press Delete, and deletes go to
  **Recently Deleted** first.

---

## 3. 🆕 Pack 4 — four more, chosen for how the app is actually used

### 3.1 "More like this" — acoustic radio from any song
Long-press a song (or use ⋯ → Options) → **More Like This**. The app measures
the song in the same 5-axis space the smart playlists use (energy, brightness,
warmth, vocal focus, tempo), finds the nearest neighbours, refuses to cross
Arabic↔Latin by accident, orders them like a DJ set and drops the result in
Playlists as *"More like ‹song›"* — then starts playing it. Works offline, on
device, no key.

### 3.2 Artists — the browser the app never had
Library → **Artists** (also in the ⋯ menu). Every artist in your library with
their song count, total minutes and play count, cover art from the first track,
Play / Shuffle, and **Make a playlist of ‹artist›** in one tap. Files ripped
from different sources that spell the same artist differently are merged under
the spelling your library uses most.

### 3.3 Library lenses — one tap to find what you meant
Chips above the song list: **All · New · Unplayed · Liked · Long · No art ·
Messy names**, each showing its count. "New" = added in the last two weeks.
"Long" = 10 minutes or more (mixes, live sets, recitations). "Unplayed" is the
one that finds the 200 songs you downloaded and forgot. Search still works
inside whichever lens you pick, and an empty result now explains itself.

### 3.4 Tidy up names — the file-name problem, fixed in bulk
The duplicate finder and the AI playlists both read file names. If your library
looks like `Amr_Diab_-_Tamally_Maak_(Official_Video)_320kbps.mp3`, they cannot
do their job.

Library → ⋯ → **Tidy up names** lists every file whose name still looks like a
download, proposes a clean *Artist – Title* for each (underscores, brackets,
"official video", "lyrics", "4K", bitrate tags removed), and lets you tick the
ones to apply. **Ask AI** (with a Gemini key) replaces the guesses with real
titles and artists — only file names are sent, never audio. Applying renames
the files; the audio is untouched.

### 3.5 Two bugs fixed on the way
* **Renaming a song used to drop it from every playlist.** A song's id is a
  hash of its file name, so `renameSong` silently orphaned it: it vanished from
  every playlist, from Liked Songs, and lost its play counts. `setSongInfo` now
  renames the file *and* carries the id across (playlists, likes, history and
  the Up Next queue are all updated), and re-writes the MP3 tag so other
  players show the new name too.
* **The Library's "no matches" screen only appeared while searching.** Picking
  an empty lens now says why it is empty instead of showing a blank list.

---

## Files

| File | Role |
|---|---|
| `scripts/ci_build.sh` *(new)* | **the real CI**: source pre-flight, project/icon generation, archive, IPA, and clear compile-error reporting (annotations + job summary + commit comment) |
| `workflows/build.yml` | the short workflow to install once at `.github/workflows/build.yml`. **One copy only now** — `workflows/build.min.yml`, `ci/build.yml` and `build.yml.ready` were deleted, because having four near-identical files is what led to renaming the wrong one into the wrong folder. `bash scripts/install_ci_fix.sh --link` prints the ready-made "create file" URL. |
| `ExtrasKit.swift` *(new)* | AcousticRadio, Artists browser, Library lenses, NameTidy, Song info editor |
| `Views.swift` | labelled duplicate row + Library tools, filter chips, new menu/sheet wiring, empty states |
| `MusicManager.swift` | `setSongInfo` / `safeFileName` — rename without losing the song's identity |
| `SETUP_ONCE.md` *(new)* | the one-time step, in English and Arabic |
| `PACK_4.md` *(new)* | this file |

```bash
python3 scripts/check_swift_syntax.py     # structure pre-flight, 1 second
bash scripts/install_ci_fix.sh && git push # if you have the repo on a computer
```
