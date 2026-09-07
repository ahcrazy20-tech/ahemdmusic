# ⚠️ One step, one time — then every feature reaches your phone

## Why the features you asked for were not in the app

They **are** in the code. The Playlists tab has the AI generator, the Library
has the duplicate finder, both were committed days ago.

The problem is the **build file**, not the app. `.github/workflows/build.yml`
on this repo is an old monster (463 KB) that starts like this:

```
find . -name "*.swift" -delete     # throw away the real app
cat << 'SWIFT' > .../Views.swift   # …and paste a copy from inside itself
```

That copy was frozen months ago. So every build went **green** while shipping
an old app: no AI playlist card, no duplicate finder, no lyrics, no
Recently Deleted. That is exactly what you installed.

**This one step replaces it with a 38-line workflow that compiles what is
actually in the repo.** After it, every change I make appears in the IPA
automatically — you never have to do this again.

---

## Option A — best: let me do it myself (30 seconds)

The assistant's GitHub App is not allowed to write to `.github/workflows/`
(that needs the **workflows** permission). Grant it once and I will install the
file, watch the build and fix any compile error without bothering you again.

1. Open <https://github.com/settings/installations>
2. **Arena AI Coding Agent** → **Configure**
3. Scroll to **Permissions** → **Workflows** → **Read and write** → *Save*
4. Reply here with one word: **done**

---

## Option B — do it yourself on your phone (2 minutes)

### 1. Create the file

Open this URL and sign in if asked:

<https://github.com/ahcrazy20-tech/ahemdmusic/new/arena/01a07c17-ahemdmusic?filename=.github/workflows/build.yml>

(GitHub opens the "new file" page with the path already filled in. If it asks
you to choose a branch, choose `arena/01a07c17-ahemdmusic`.)

Paste this, exactly as it is:

```yaml
name: Build TrollMusicApp
on:
  push:
    branches: ["main", "arena/**"]
  pull_request:
    branches: ["main"]
  workflow_dispatch:
permissions:
  contents: write
  actions: write
concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build:
    name: Build IPA
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - name: Build the app from the repo's own sources
        run: bash scripts/ci_build.sh
      - name: Upload build log
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: build-log
          path: build.log
          if-no-files-found: ignore
          retention-days: 7
      - name: Upload IPA Artifact
        uses: actions/upload-artifact@v4
        with:
          name: TrollMusicApp-IPA
          path: TrollMusicApp.ipa
          if-no-files-found: error
          retention-days: 30
```

Then **Commit changes** (green button, twice if it asks again).

### 2. If the file already exists there

If GitHub says the file exists, open
<https://github.com/ahcrazy20-tech/ahemdmusic/edit/arena/01a07c17-ahemdmusic/.github/workflows/build.yml> ,
press **✏️**, select everything, paste the block above, and commit.
(That old file is the 463 KB one that deletes the sources.)

### 3. Nothing else

The build starts by itself. Two minutes later, the **Actions** tab shows a run
called *Build IPA*; when it is green, open it and download
**TrollMusicApp-IPA** — that `.ipa` is the real app.

---

## How to know it worked

Open the green run → the **Build the app from the repo's own sources** step.
Its first lines must read:

```
== 1/6  Sources that will be compiled
    AudioAnalysis.swift
    BackupKit.swift
    ExtrasKit.swift
    …
    count: 21
```

21 files, including `ExtrasKit.swift`. The old build printed no file list at
all — it deleted them.

If that step is **red**, it is the first time this code has met a real Swift
compiler (the old workflow never compiled it). The errors are posted on the
commit automatically; just tell me "it's red" and I will fix them and push a
new build.

---

## بالعربي

المزايا موجودة في الكود فعلاً، لكن ملف البناء `.github/workflows/build.yml`
كان **يحذف كل ملفات التطبيق** ويكتب نسخة قديمة محفوظة بداخله، فيطلع التطبيق
بدون أي ميزة جديدة.

**الحل (مرة واحدة فقط):**

* **الأسهل:** افتح <https://github.com/settings/installations> →
  **Arena AI Coding Agent** → **Configure** → **Permissions** →
  **Workflows: Read and write** → Save، ثم اكتبلي «تم» وأنا أتكفل بالباقي.
* **أو يدويًا:** أنشئ الملف `.github/workflows/build.yml` في الفرع
  `arena/01a07c17-ahemdmusic` والصق محتوى الـ 38 سطرًا الموجود فوق (أو انسخه
  من `workflows/build.min.yml` في المستودع)، ثم **Commit**.

بعدها كل تعديل في الكود يوصل للتطبيق تلقائيًا، ولن تحتاج هذه الخطوة مرة أخرى.
