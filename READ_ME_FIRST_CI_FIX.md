# ⚠️ Read this first — why your features never showed up

> **All instructions now live in `SETUP_ONCE.md`.** This file only explains the
> problem, so it stops being repeated in three places.

## The short version

Everything you asked for **is written and committed** — AI playlist generator in
the Playlists tab, duplicate finder in the Library, Recently Deleted, synced
lyrics, backup & restore, and (as of Pack 4) an Artists browser, library lenses,
"More like this" radio and AI name clean-up.

They never reached your phone because of this file:

`.github/workflows/build.yml`

It is not a normal build file. Its first steps are:

```
find . -name "*.swift" -delete          # delete the real app
cat << 'SWIFT' > .../Views.swift        # paste a copy stored INSIDE the workflow
```

That embedded copy was frozen months ago. So the build went **green** and the
IPA it produced was an old app. Editing the Swift files changed nothing —
which is exactly what you experienced.

**And as of 2026-09-07 13:32 UTC it is worse:** that file was deleted and the
replacement copies were renamed around inside a root-level `workflows/` folder
instead of `.github/workflows/`. GitHub now has **0 workflows registered**, so a
push starts *nothing* — no run, no failure, just silence. That is the state
`SETUP_ONCE.md` tells you how to clear.

## The fix

Replace it with the short workflow that just compiles what is in the repo:

**→ open [`SETUP_ONCE.md`](SETUP_ONCE.md)** — Option A (grant the Arena app the
*workflows* permission, then I do everything) or Option B (paste the file
yourself, once).

After that one step, this never needs touching again: `scripts/ci_build.sh`
does the building, and it lives in the repo where it can be updated normally.

## If the first real build goes red

That is expected-ish: this code has never met a Swift compiler before (the old
workflow compiled its own embedded copy instead). The workflow posts the compile
errors on the commit automatically — say "it's red" and they get fixed and
pushed.
