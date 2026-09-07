# AS Music — Smart Pack 3 (Sept 2026): playlists you control, a library that repairs itself

Three things you asked for, plus the safety net and the missing pieces a music
app needs to feel finished. Everything is additive, everything works offline,
and nothing deletes a file without asking you first.

---

## 0. Read this first — why nothing new showed up in your IPA

`.github/workflows/build.yml` is not a normal build file: its first steps
**delete every `.swift` file in the repo** and rewrite them from copies pasted
inside the workflow itself. Those copies are months old — no AI playlist card,
no duplicate finder, no Recently Deleted, no lyrics. The build goes green and
ships old code. (The same drift also cost the app its microphone/speech
`Info.plist` keys, which the repo has and the workflow's copy does not.)

**The fix is in the repo at `ci/build.yml`** — a 140-line workflow that simply
compiles what is in `TrollMusicApp/TrollMusicApp/`. GitHub blocks the Arena app
from writing anything under `.github/workflows/`, so you install it once:

> Open `.github/workflows/build.yml` on GitHub → **Delete file** → commit.
> Open `ci/build.yml` → **✏️ Edit** → change the file name at the top to
> `.github/workflows/build.yml` → commit.

Step-by-step (with Arabic) in **`READ_ME_FIRST_CI_FIX.md`**. After that one
time, every future change reaches the app automatically and this pack's 20
source files all compile.

---

## 1. ✨ Playlists tab — generate with AI, delete anything, undo mistakes

**Generating** (was already written, now actually ships):

* One field at the top of the Playlists tab: *"sad arabic for a rainy night"*,
  *"جيم حماسية"*, *"90s road trip"* → a real playlist built from **your own
  library**.
* With a free Gemini key: the model picks and names the list. Without a key:
  the on-device Arabic/English parser does the same job, offline.
* Mood chips (Gym · Party · Chill · Focus · Drive · Sleep · Arabic) and
  **Surprise me** (time-of-day aware) for zero typing.
* Tracks are ordered like a DJ set — tempo/energy-smoothed, no two songs by the
  same artist back to back.

**New in this pack:**

| New | What it does |
|---|---|
| **Select mode** | "Select" in the nav bar → tick several playlists → **Delete N** in one action. |
| **Undo banner** | Every playlist delete (single or bulk) shows *Undo* for 10 seconds. Nothing is lost by a mis-tap. |
| **Delete all ✨ playlists** | One item in the ⋯ menu removes every auto-generated list; your own playlists are untouched and the AI won't rebuild them uninvited. |
| **Regenerate with AI** | Long-press a generated playlist → the sentence you originally typed is re-run against your (now bigger) library. |
| **Swipe left / right** | Right-swipe = Play or Shuffle this list. Left-swipe = Rename or Delete. |
| **Sorting** | My order · Name · Most songs · AI playlists first. |
| **Real subtitles** | "12 songs · 48 min" using the on-device duration measurements. |
| **One-alert refactor** | All destructive confirmations now run through a single alert. Stacking five `.alert` modifiers on one view is exactly how "the Delete button does nothing" bugs happen in SwiftUI. |

## 2. 🩺 Library tab — the duplicate check, now with an ear as well as eyes

The button lives in the Library nav bar (badged with the number of extra copies)
and in the ⋯ menu → **Find Duplicates**.

* **Layer 1 — names.** Songs are grouped by a normalized artist+title key, so
  `Amr Diab - Tamally Maak (Official Video)` and `tamally maak 1` land together;
  groups are then split by measured length so a live version isn't confused with
  a duplicate rip.
* **Layer 2 — sound (new).** Everything the name matcher missed is compared on
  what was actually measured: length (±1.5 s), tempo (±2.5 BPM), loudness
  (±1.5 dB), dynamics, stereo width and the five-band tone profile. Files that
  agree on all of it are the same recording — this is how `audio_2831.mp3` gets
  caught next to `Nancy Ajram - Ah W Noss.mp3`. Marked **SAME AUDIO** in the UI.
* **The decision is always yours.** Each group pre-selects the copy worth
  keeping (liked > most played > best measured quality > higher bitrate > has
  artwork). Tap a different copy to override. Nothing is deleted until you press
  Delete.
* **AI review (optional).** With a Gemini key, "Ask AI which copy to keep" sends
  the *facts only* (never audio) and the model may re-pick with a short reason —
  shown as an **AI PICK** badge.
* **Deletes are reversible** (see §3).

## 3. 🗑️ Recently Deleted — the undo button the app never had

`deleteSong` used to call `FileManager.removeItem`. One wrong swipe, one
over-eager "clean all duplicates", and the download was gone.

Now every delete **moves** the file to `Documents/.trash/` (a dot-folder, so the
library scan never sees it) and remembers title, artist, size, whether it was
liked and **which playlists it belonged to**. Restoring puts the file back under
its original name with its original id — so it drops straight back into those
playlists and keeps its play count.

* Library ⋯ → **Recently Deleted**: restore one, restore everything, or erase.
* Retention: 7 / 30 / 90 days or "until I empty it" (default 30), plus a 2 GB
  ceiling, oldest first. Expired items are swept on launch.
* Safety net can be switched off if you prefer the old immediate erase.
* An **Undo** row appears at the top of the Library for 30 seconds after a
  delete, and the duplicate finder links straight into the trash after cleaning.

## 4. 🎤 Synced lyrics (karaoke) in the full player

The lyrics panel used to strip the timings out and show a wall of text. Now:

* The current line lights up and the view auto-scrolls as the song plays.
* **Tap any line to jump the player to that moment.**
* Per-song timing offset (±0.3 s steps) for rips with a different lead-in.
* Sources, in order: a `.lrc` file you dropped next to the audio → the on-device
  cache (so it works in airplane mode) → lrclib.net (free, open, no key, no
  account). Fetched lyrics are cached immediately, and "Keep offline with this
  song" writes a `.lrc` next to the audio file so it survives everything.
* Full RTL/Arabic layout.

## 5. 💾 Backup & Restore — for a sideloaded app that gets re-installed

Library ⋯ → **Backup & Restore**.

* Export writes one small JSON (a few hundred KB — **no audio inside**) into the
  app's Documents and opens the share sheet: AirDrop it, drop it in iCloud
  Drive, mail it to yourself.
* It carries: playlists, Liked Songs, play counts + listening hours, song
  titles/artists/genres/artwork links, and your app settings (theme, EQ, preamp,
  spatial, sort order, smart-playlist switches).
* Restore **merges** by default — nothing you have today is thrown away.
  "Replace my playlists" is an explicit toggle, and even then your audio files
  are never touched.
* Songs are matched by **file name**, never by internal id, so a backup restores
  correctly on a fresh install. Songs you haven't re-downloaded yet are simply
  reported — download them later and they land back in the right playlists.
* Backups already on the device are listed for one-tap restore.

## 6. ❤️ Library Health — one screen, every fix next to its problem

Library ⋯ → **Library Health**. A 0–100 score plus:

| Check | The fix, right there |
|---|---|
| Storage used by songs / by the trash | opens Recently Deleted |
| Duplicate copies + reclaimable MB | opens the duplicate finder |
| Sound-analysis coverage | **Measure the remaining N** (real full sweep) |
| Songs with no artist / no artwork | **Fetch missing artists & covers** (free iTunes lookup, no key) |
| Failed downloads (< 32 KB, unplayable) | delete them — safely, to Recently Deleted |
| Rough rips (clipping, very quiet, dead air) | listed with the reason, so you know what to re-download |

## 7. 🐛 Two real bugs fixed on the way

* **The analysis worker span forever.** `AudioLab.drain()` re-queued a job and
  `continue`d once the 60-songs-per-launch budget ran out — an infinite loop on
  a background queue at 100% CPU (battery drain, hot phone) for anyone with more
  than 60 unmeasured songs. It now parks the queue for the next launch and
  stops. The Health screen's "measure everything" lifts the budget deliberately.
* **Play counts died with a delete.** Deleting a song erased its listening
  history immediately, so a restore came back "never played". History is now
  kept while the song sits in Recently Deleted.

---

## Files in this pack

| File | Role |
|---|---|
| `LibraryTrash.swift` *(new)* | Recently Deleted store + UI, safe-delete plumbing |
| `LyricsLive.swift` *(new)* | LRC parser, offline lyric cache, karaoke view |
| `BackupKit.swift` *(new)* | backup payload, export/share, document-picker import, merge restore |
| `LibraryHealth.swift` *(new)* | health scan + one-tap fixes |
| `LibraryDoctor.swift` | + acoustic duplicate matching, trash-aware copy, AI prompt update |
| `MusicManager.swift` | safe delete, bulk playlist delete, playlist undo, shuffle-a-playlist |
| `Views.swift` | rebuilt Playlists tab, Library menu entries, karaoke panel in the player |
| `AudioAnalysis.swift` | spin-loop fix, `analyzeAll`, `pending(of:)` |
| `SmartPlaylists.swift` | remembers the sentence behind each generated playlist |
| `SmartKit.swift` | `ListenHistory.mergeImported` for restores |

Structural pre-flight for all 20 sources:

```
python3 scripts/check_swift_syntax.py     # 1 second, no Mac needed
bash scripts/install_ci_fix.sh && git push
```
