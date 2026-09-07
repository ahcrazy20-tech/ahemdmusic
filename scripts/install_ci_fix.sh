#!/usr/bin/env bash
#
# install_ci_fix.sh — installs the fixed CI workflow.
#
# WHY THIS EXISTS
# ---------------
# .github/workflows/build.yml doesn't just build the app: it DELETES every
# .swift file and rewrites them from copies embedded inside the workflow
# itself. So fixing a bug in TrollMusicApp/TrollMusicApp/*.swift has no
# effect on CI until those embedded copies are refreshed too.
#
# The Arena GitHub App can't push changes to .github/workflows/ (that needs
# the "workflows" permission), so the corrected workflow ships in this repo
# as build.yml.ready. This script installs it.
#
# Usage:
#   bash scripts/install_ci_fix.sh && git push
#
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f build.yml.ready ]; then
  echo "build.yml.ready not found — nothing to install." >&2
  exit 1
fi

cp build.yml.ready .github/workflows/build.yml
git add .github/workflows/build.yml

if git diff --cached --quiet -- .github/workflows/build.yml; then
  echo "Workflow already up to date — nothing to commit."
  exit 0
fi

git commit -m "Sync CI build with the fixed sources"

echo
echo "Done. Now run:  git push"
echo "Then watch the build:  gh run watch"
