#!/usr/bin/env bash
#
# install_ci_fix.sh — make the GitHub build compile the sources in THIS repo.
#
# WHY THIS EXISTS
# ---------------
# The old .github/workflows/build.yml carried a copy of every Swift file inside
# itself: it deleted the real sources and rewrote them from those embedded
# copies. Result: editing the app changed nothing in the IPA.
#
# `workflows/build.yml` is the fixed workflow — 38 lines that call
# `scripts/ci_build.sh`, which compiles TrollMusicApp/TrollMusicApp/*.swift.
# Nothing is embedded in the workflow any more, so it never needs regenerating.
#
# The Arena GitHub App is not allowed to write .github/workflows/, so this has
# to be run by you — but only ONCE. After that the workflow never needs to be
# touched again (no more sync step for new files).
#
# Prefer the phone-friendly route? See SETUP_ONCE.md.
#
# Usage
#   bash scripts/install_ci_fix.sh            # install + commit
#   bash scripts/install_ci_fix.sh --check     # report only, change nothing
#
set -euo pipefail
cd "$(dirname "$0")/.."

LEAN="workflows/build.yml"
LIVE=".github/workflows/build.yml"

if [ "${1:-}" = "--check" ]; then
  echo "→ do the Swift sources parse?"
  python3 scripts/check_swift_syntax.py
  echo
  if grep -q "Write Swift Files" "$LIVE" 2>/dev/null; then
    echo "✗ $LIVE still embeds its own copies of the sources — the IPA is NOT"
    echo "  built from this repo. Run:  bash scripts/install_ci_fix.sh && git push"
  else
    echo "✓ $LIVE builds the repo's sources directly."
  fi
  exit 0
fi

[ -f "$LEAN" ] || { echo "$LEAN missing" >&2; exit 1; }

echo "→ 1/2: Swift structure pre-flight"
python3 scripts/check_swift_syntax.py

echo
echo "→ 2/2: installing the lean workflow"
mkdir -p .github/workflows
cp "$LEAN" "$LIVE"
# build.yml.ready and ci/build.yml are the same file kept for the manual
# (phone) install path documented in SETUP_ONCE.md — keep them in step.
cp "$LEAN" build.yml.ready
cp "$LEAN" ci/build.yml
chmod +x scripts/ci_build.sh

git add "$LIVE" build.yml.ready ci/build.yml scripts/ci_build.sh
if git diff --cached --quiet -- "$LIVE"; then
  echo
  echo "Workflow already up to date — nothing to commit."
  exit 0
fi

git commit -q -m "ci: build the repo's real sources instead of stale embedded copies"
echo
echo "Done. Now:  git push"
echo "Watch it:   gh run watch"
