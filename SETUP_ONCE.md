# ⚠️ Right now GitHub has **no workflow at all**, so no build can start

*Last checked: 2026-09-07 14:20 UTC against `ahcrazy20-tech/ahemdmusic`.*

Two separate things were wrong; only one of them is yours to fix.

| # | Problem | Status |
|---|---|---|
| 1 | `.github/workflows/build.yml` (the old 463 KB one) deleted the repo's Swift files and compiled a frozen copy of its own → every green build shipped a months-old app | fixed in the code; needs step 1 below installed |
| 2 | **`.github/workflows/` does not exist in the repo at all** → GitHub has `0` registered workflows, so a push starts **nothing** (no run, no error, nothing) | **needs you — 20 seconds, see below** |

## Why #2 happened

The workflow file lives in this repo at **`workflows/build.yml`** — a folder named
`workflows` at the *root* of the repo. GitHub does not look there. It only ever
reads:

```
.github/workflows/build.yml
^^^^^^
this hidden folder is mandatory
```

On 2026-09-07 the file at `.github/workflows/build.yml` was **deleted** (13:32 UTC),
and the two "Rename …" commits afterwards (13:34 and 14:15 UTC) both moved copies
*inside* `workflows/`, i.e. from `ci/build.yml` → `workflows/build.yml`. Renaming
in the web editor can also not create the hidden `.github/` folder — that is the
trap. A build cannot run until a file exists at the exact path `.github/workflows/build.yml`.

---

## ✅ Fix it once — 20 seconds, phone works

### 1. Open this link (it pre-fills the correct path for you)

<https://github.com/ahcrazy20-tech/ahemdmusic/new/main?filename=.github/workflows/build.yml>

It is GitHub's "create a new file" page with the name already typed in as
`.github/workflows/build.yml`. **Do not change that name.**

### 2. Paste, then create

Copy this whole block (GitHub shows a copy button on it — tap it, don't select by hand):

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
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Setup Xcode
        uses: maxim-lobanov/setup-xcode@v1
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

1. Open <https://github.com/ahcrazy20-tech/ahemdmusic/blob/main/workflows/build.yml>
   if you prefer to copy from the source file — everything from the line
   `name: Build TrollMusicApp` down to the last line. The `#` block at the top
   is instructions for you, not needed by GitHub — pasting it too is harmless.
2. Paste into the editor of the page from step 1. **Do not retype indentation** —
   YAML breaks on re-typed spaces, copy/paste preserves them.
3. **Create file…** → **Commit directly to the `main` branch**.

The build starts on its own the moment you commit.


### 3. Nothing else, ever again

The workflow contains no copy of the app — it runs `scripts/ci_build.sh`, which
compiles whatever is in `TrollMusicApp/TrollMusicApp/`. Add a `.swift` file,
commit it, it ships. If I ever need to change how the app is built I edit that
script, which I *can* write — that is why this is the last manual step.

> **Alternative, if you'd rather not tap at all:** give the Arena app permission
> to write workflows and I will install, watch and fix the build myself:
> <https://github.com/settings/installations> → **Arena AI Coding Agent** →
> **Configure** → **Permissions** → **Workflows** → **Read and write** → **Save**,
> then reply **done** here.
>
> (I verified this session: any push of mine touching `.github/workflows/` is
> rejected by GitHub with *"refusing to allow a GitHub App to create or update
> workflow … without `workflows` permission"*. Same for the API.)

---

## How to know it worked

`Actions` tab → the newest run → step **"Build the app from the repo's own
sources"**. Its first lines must be:

```
== 1/6  Sources that will be compiled
    AudioAnalysis.swift
    BackupKit.swift
    DiscoverView.swift
    …
    count: 21
```

**21 files, including `ExtrasKit.swift`.** The old build printed no list at all,
because it had just deleted them. If the run shows steps named
*"Clean Environment"* / *"Write Swift Files"*, you are looking at an old run —
the fix is not installed yet.

Also useful (any machine with `gh`):

```bash
bash scripts/install_ci_fix.sh --check   # tells you if GitHub has 0 workflows
gh api repos/ahcrazy20-tech/ahemdmusic/actions/workflows --jq '.total_count'   # must be 1
```

## If the first real build goes red

Expected-ish: **no build in this repo's history ever compiled the repo's own
sources** (I checked the last 30 runs — all of them ran the embedded copies), so
Pack 4 (`ExtrasKit.swift`, artists browser, library lenses, AI name tidy) has
never met a Swift compiler. The workflow posts the compile errors on the commit
and in the job summary — say **"it's red"** and they get fixed and pushed.

Two things make that round trip cheaper:

1. **A 2-second pre-flight.** Step `1/6` runs `scripts/check_swift_syntax.py`, and
   if it rejects a file the run stops *before* the 8-minute archive and says
   which line. It catches unbalanced braces, unterminated strings, stray
   `SWIFT`/`YAML` heredoc markers and invalid escapes — which is exactly how the
   first real build failed, on five lines like

   ```swift
   static var parameterSummary: some ParameterSummary { Summary("Play \.$moment") }   // ✗
   static var parameterSummary: some ParameterSummary { Summary("Play \(\.$moment)") } // ✓
   ```

   App Intents still needs Swift's own interpolation parens around the `$name`.
2. **The log is not truncated.** A full archive log is uploaded as the
   *build-log* artifact, so the 20-error cap on-screen is not the end of it.

Running it locally (any machine, no Xcode needed):

```bash
python3 scripts/check_swift_syntax.py          # "structure OK in 21 file(s)."
python3 scripts/check_swift_syntax.py -v       # + the type map it built
```

It is a structural gate, not a type checker — `cannot find 'foo' in scope` and
friends still need CI. If it ever cries wolf, the fix belongs in that script.

---

## بالعربي — لا يوجد أي ملف بناء الآن، ولهذا لا يبدأ شيء

المشكلة ليست في الكود، المشكلة في **مكان الملف**:

1. الملف الصحيح موجود في المستودع باسم `workflows/build.yml` — وهذا المجلد
   **لا تقرأه GitHub إطلاقاً**. GitHub يقرأ فقط من
   **`.github/workflows/build.yml`** (مجلد مخفي اسمه `.github`).
2. ملف البناء القديم كان **يحذف ملفات التطبيق** (`find . -name "*.swift" -delete`)
   ويرجّع نسخة قديمة محفوظة داخله — لذلك كل بناء كان «أخضر» والتطبيق قديم.
3. عمليات «إعادة التسمية» التي تمت (13:34 و 14:15) نقلت النسخ داخل مجلد
   `workflows/` العادي، ولازم تنقلها إلى `.github/workflows/` — ومحرر التعديل في
   المتصفح لا يستطيع إنشاء مجلد `.github` بالإعادة-تسمية.

**الحل في ٢٠ ثانية:**

1. افتح هذا الرابط (اسم الملف مكتوب فيه مسبقاً — لا تغيّره):
   <https://github.com/ahcrazy20-tech/ahemdmusic/new/main?filename=.github/workflows/build.yml>
2. انسخ محتوى <https://github.com/ahcrazy20-tech/ahemdmusic/blob/main/workflows/build.yml>
   من سطر `name: Build TrollMusicApp` ونزولاً، والصقه في المحرر (بدون إعادة كتابة المسافات).
3. **Create file** ← **Commit directly to the main branch**.

البناء بيشتغل لحاله. للتأكد: في تبويب Actions لازم خطوة
*Build the app from the repo's own sources* تطبع قائمة الملفات وفيها **21 ملف**
ومن ضمنها `ExtrasKit.swift`.

**أو الأسهل:** أعطِ تطبيق Arena صلاحية الكتابة على الـ workflows من
<https://github.com/settings/installations> (**Configure** → **Permissions** →
**Workflows: Read and write**) واكتبلي «تم» وأنا أركّب الملف وأتابع البناء وأصلّح
أي خطأ compile بنفسي.
