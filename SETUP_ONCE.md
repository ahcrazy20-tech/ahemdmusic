# ⚠️ Merge the PR, then move one file — 2 taps, one time

## Why the features you asked for were not in the app

They **are** written. The AI playlist generator, the duplicate finder,
Recently Deleted, synced lyrics and backup & restore all exist in
`TrollMusicApp/TrollMusicApp/`.

They never reached your phone because of the **build file**, not the app.
`.github/workflows/build.yml` on your working branches is a 463 KB file that
starts like this:

```bash
find . -name "*.swift" -delete        # throw away the real app
cat << 'SWIFT' > .../Views.swift      # …and paste a copy stored inside the workflow
```

That embedded copy is frozen months old, so every build went **green** while
shipping an old app — no AI playlists, no duplicate finder, no lyrics. Nine
source files in this repo have never been compiled by CI at all.

The fix is a **38-line workflow** that runs `scripts/ci_build.sh` and simply
compiles what is in the repo. GitHub does not let the assistant's app write
under `.github/workflows/`, so the file has to be put in place by you — once.

---

## ✅ The way you asked for it: merge PR #9, then move one file

### 1. Merge the pull request

<https://github.com/ahcrazy20-tech/ahemdmusic/pull/9> → **Merge pull request**
→ **Confirm merge**.

### 2. Move `workflows/build.min.yml` into `.github/workflows/`

Open this file on `main` after the merge:

<https://github.com/ahcrazy20-tech/ahemdmusic/blob/main/workflows/build.min.yml>

1. Tap the **✏️ pencil** (Edit this file).
2. In the **file name box at the top**, replace

   ```
   workflows/build.min.yml
   ```

   with

   ```
   .github/workflows/build.yml
   ```

3. **Commit changes** (green button).

That is it. GitHub creates the folder and the build starts by itself.

> If GitHub ever refuses the rename, the same 38 lines are also at
> `workflows/build.yml`, `ci/build.yml` and `build.yml.ready` — use whichever
> opens. Or create a new file at `.github/workflows/build.yml` and paste this:

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

### 3. Nothing else, ever again

The new workflow contains **no copy of the app** — it only calls
`scripts/ci_build.sh`, which lives in the repo and compiles whatever is in
`TrollMusicApp/TrollMusicApp/`. Add a `.swift` file, commit it, it ships.

---

## Alternative: let me do it (no tapping at all)

The app's GitHub permission is the only thing stopping me. Grant it once and I
will install the file, watch the build and fix any compile error myself:

1. <https://github.com/settings/installations>
2. **Arena AI Coding Agent** → **Configure**
3. **Permissions** → **Workflows** → **Read and write** → **Save**
4. Reply here: **done**

---

## How to know it worked

Open the run in the **Actions** tab → step **Build the app from the repo's own
sources**. Its first lines must be:

```
== 1/6  Sources that will be compiled
    AudioAnalysis.swift
    BackupKit.swift
    ExtrasKit.swift
    …
    count: 21
```

**21 files, including `ExtrasKit.swift`.** The old build printed no list at all,
because it had just deleted them.

If the step is **red**, that is the first time this code has met a real Swift
compiler (the old workflow compiled its own embedded copy instead). The errors
are posted on the commit automatically — tell me “it’s red” and they get fixed
and pushed.

---

## بالعربي — دمج الـ PR ثم نقل ملف واحد

المزايا موجودة في الكود فعلاً، لكن ملف البناء كان **يحذف كل ملفات التطبيق**
ويكتب نسخة قديمة محفوظة بداخله، فيطلع التطبيق بدون أي ميزة جديدة.

1. **ادمج الـ PR:** <https://github.com/ahcrazy20-tech/ahemdmusic/pull/9> →
   **Merge pull request** → **Confirm merge**.
2. **انقل الملف:** افتح `workflows/build.min.yml` في الفرع `main`، اضغط **✏️
   تعديل**، ثم غيّر اسم الملف في الأعلى إلى:

   ```
   .github/workflows/build.yml
   ```

   واضغط **Commit changes**.

3. خلاص. البناء يشتغل تلقائيًا، وأي تعديل في الكود بعدها يوصل للتطبيق مباشرة.

**أو الأسهل:** أعطِ التطبيق صلاحية الكتابة على الـ workflows من
<https://github.com/settings/installations> (**Arena AI Coding Agent** →
**Configure** → **Permissions** → **Workflows: Read and write**) واكتبلي «تم»
وأنا أتكفل بكل شيء.

**كيف تتأكد:** في صفحة البناء، خطوة *Build the app from the repo's own sources*
لازم تطبع قائمة الملفات وفيها **21 ملف** ومن ضمنها `ExtrasKit.swift`.
