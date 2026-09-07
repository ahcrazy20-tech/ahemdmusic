#!/usr/bin/env bash
#
# install_ci_fix.sh — make the GitHub build compile EXACTLY the sources in this
# repo, then commit that workflow.
#
# WHY THIS EXISTS
# ---------------
# .github/workflows/build.yml doesn't just build the app: its first steps
# DELETE every .swift file and rewrite them from copies embedded inside the
# workflow. So editing TrollMusicApp/TrollMusicApp/*.swift changes nothing on CI
# until those embedded copies are refreshed — and the drift can also run the
# other way (it happened: ExtractorKit.swift existed only inside the workflow,
# so syncing at that moment would have silently deleted the extra download
# engines from the built IPA).
#
# The Arena GitHub App can't push to .github/workflows/ (needs the "workflows"
# permission), so this script has to be run by you, once per code change.
#
# Usage
#   bash scripts/install_ci_fix.sh            # regenerate + stage + commit
#   bash scripts/install_ci_fix.sh --check     # report drift only, change nothing
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--check" ]; then
  echo "→ repo vs CI (workflow is the source of truth for what ships today)"
  python3 scripts/restore_sources_from_workflow.py --check || true
  echo
  echo "→ do the files in the repo parse?"
  python3 scripts/check_swift_syntax.py
  exit 0
fi

[ -f scripts/sync_build_yaml.py ] || { echo "scripts/sync_build_yaml.py missing" >&2; exit 1; }
[ -f .github/workflows/build.yml ] || { echo ".github/workflows/build.yml missing" >&2; exit 1; }

# 1) Anything the workflow knows about that git doesn't? restore it first, so
#    regenerating below can never delete a feature by accident.
echo "→ step 1/3: making the repo the source of truth"
python3 scripts/restore_sources_from_workflow.py

# 2) Structural pre-flight (unbalanced braces, imports after code, unknown
#    app-level types) — a 1-second check that saves a 10-minute CI cycle.
echo
echo "→ step 2/3: Swift structure pre-flight"
python3 scripts/check_swift_syntax.py

# 3) Re-embed the repo's sources (and Info.plist) into the workflow.
echo
echo "→ step 3/3: regenerating the workflow from the repo"
python3 scripts/sync_build_yaml.py
cp .github/workflows/build.yml build.yml.ready

git add .github/workflows/build.yml build.yml.ready
if git diff --cached --quiet -- .github/workflows/build.yml; then
  echo
  echo "Workflow already up to date — nothing to commit."
  exit 0
fi

echo
echo "Committing the synced workflow (build.yml + build.yml.ready)…"
git commit -q -m "ci: sync build workflow with the repo sources"
echo "Done. Now:  git push"
echo "Watch it:   gh run watch"
