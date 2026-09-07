# ⚠️ ONE STEP LEFT — 60 seconds, then everything appears

**Nothing is wrong with the code. The build is compiling the wrong copy of it.**

`.github/workflows/build.yml` is not a normal build file. Its first steps do
this:

```
find . -name "*.swift" -delete          # throw away the real app
cat << 'SWIFT' > .../Views.swift        # …and paste an old copy from inside
```

Every Swift file is **pasted inside that workflow**, frozen at whatever it was
months ago. That snapshot has no AI playlist card, no duplicate finder, no
Recently Deleted, no lyrics. So the build goes green and the IPA is old code.
That is exactly what you saw.

GitHub does not let the Arena app touch anything under `.github/workflows/`
(that permission is only grantable by you), so this last step has to be done
from your side — **once, ever**. After it, every change reaches the app
automatically.

---

## Easiest way (works on a phone, no typing) — 2 taps

The fixed workflow is already in your repo at **`ci/build.yml`** (140 lines,
compiles whatever is really in the repo).

1. **Delete the old one**
   → open <https://github.com/ahcrazy20-tech/ahemdmusic/blob/main/.github/workflows/build.yml>
   → tap **⋯ / trash icon → Delete file** → *Commit changes*.

2. **Move the new one into place**
   → open <https://github.com/ahcrazy20-tech/ahemdmusic/blob/main/ci/build.yml>
   → tap the **✏️ pencil (Edit)**
   → in the **file-name box at the top**, replace `ci/build.yml` with:

   ```
   .github/workflows/build.yml
   ```

   → *Commit changes*.

That's it. The build starts by itself and the IPA it produces has everything.

> Do the same two steps on the branch `arena/01a07bef-ahemdmusic` **or** simply
> merge the pull request into `main` first — the new features live in that
> branch's source files.

## If you prefer copy-paste

Open `ci/build.yml` → **Raw** → select all → copy.
Open `.github/workflows/build.yml` → **✏️ Edit** → select all → paste → commit.

## If you have a computer with git

```bash
git pull
cp ci/build.yml .github/workflows/build.yml
git add .github/workflows/build.yml
git commit -m "ci: build the repo's real sources"
git push
```

(or just run `bash scripts/install_ci_fix.sh && git push` — it now installs the
same lean workflow.)

---

## بالعربي — خطوة واحدة فقط

المشكلة ليست في الكود. ملف البناء `build.yml` كان **يحذف ملفات التطبيق الحقيقية**
ويكتب نسخة قديمة محفوظة بداخله، فيخرج التطبيق بدون المزايا الجديدة.

الحل (مرة واحدة فقط، من جوالك):

1. افتح `.github/workflows/build.yml` على GitHub واضغط **Delete file** ثم Commit.
2. افتح `ci/build.yml` واضغط **✏️ تعديل**، ثم غيّر اسم الملف في الأعلى إلى
   `.github/workflows/build.yml` واضغط Commit.

بعدها أي تعديل في الكود يصل للتطبيق مباشرة، ولن تحتاج لهذه الخطوة مرة أخرى.

---

## How to be sure it worked

The new workflow prints, right at the start of the run, a step called
**“Show what will be compiled”**:

```
Swift files in the repo:
AudioAnalysis.swift
BackupKit.swift
LibraryDoctor.swift
LibraryHealth.swift
LibraryTrash.swift
LyricsLive.swift
...
count: 20
```

If you see **20 files** including `BackupKit.swift`, `LibraryTrash.swift`,
`LyricsLive.swift`, `LibraryHealth.swift` and `LibraryDoctor.swift`, the IPA
from that run contains:

* Playlists tab → **AI Playlist Generator** card + Select/bulk-delete + Undo
* Library → **duplicate finder button** (badged) with AI review
* Library ⋯ → **Library Health**, **Recently Deleted**, **Backup & Restore**
* Player → **synced karaoke lyrics** (tap the quote icon)

If that run goes **red** instead, open it and copy the lines under
“COMPILE ERRORS” to me — that is the first time this new code ever reaches a
real Swift compiler, and I'll fix whatever it flags immediately.
