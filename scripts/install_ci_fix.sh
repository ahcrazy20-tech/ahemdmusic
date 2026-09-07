#!/usr/bin/env bash
#
# install_ci_fix.sh — make the GitHub build compile the sources in THIS repo.
#
# WHY THIS EXISTS
# ---------------
# The old .github/workflows/build.yml carried a copy of every Swift file inside
# itself: it deleted the real sources (`find . -name "*.swift" -delete`) and
# rewrote them from those embedded copies. Result: editing the app changed
# nothing in the IPA — a green build shipped a months-old app.
#
# `workflows/build.yml` is the fixed workflow — it only calls
# `scripts/ci_build.sh`, which compiles TrollMusicApp/TrollMusicApp/*.swift.
# Nothing is embedded in it, so it never needs regenerating.
#
# GitHub's rules are what make this script necessary:
#   • Actions runs ONLY files under `.github/workflows/`. A workflow sitting at
#     `workflows/build.yml` (repo root) is a plain text file as far as GitHub is
#     concerned — no build starts, and nothing warns you.
#   • The Arena GitHub App (and any other GitHub App) is refused by GitHub when
#     it writes under `.github/workflows/` ("workflows" permission), so this
#     last mile has to be done by the repo owner. Once. Forever after, only
#     scripts/ci_build.sh and the Swift files change — and those are writable.
#
# Usage
#   bash scripts/install_ci_fix.sh --check    # report only, change nothing
#                                             # (also checks GitHub itself)
#   bash scripts/install_ci_fix.sh --link     # print the one-tap URL to fix it
#   bash scripts/install_ci_fix.sh            # install + commit (needs a push)
#
set -euo pipefail
cd "$(dirname "$0")/.."

LEAN="workflows/build.yml"                    # source of truth, in the repo
LIVE=".github/workflows/build.yml"            # the only path GitHub reads
REPO="${GITHUB_REPOSITORY:-ahcrazy20-tech/ahemdmusic}"
NEWFILE_URL="https://github.com/${REPO}/new/main?filename=.github/workflows/build.yml"

die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# --- report what GitHub actually has, independent of this checkout ----------
status_from_github() {
  command -v gh >/dev/null 2>&1 || { echo "   (gh not installed — skipping the remote check)"; return 0; }
  local body total
  body=$(gh api "repos/${REPO}/contents/.github/workflows" --jq '[.[].name] | join(" ")' 2>/dev/null || true)
  case "$body" in
    ''|*'"message"'*) echo "   ✗ GitHub has no .github/workflows/ folder on main → pushes start NO build." ;;
    *)                echo "   .github/workflows/ on main contains: $body" ;;
  esac
  total=$(gh api "repos/${REPO}/actions/workflows" --jq '.total_count' 2>/dev/null || echo 0)
  case "$total" in
    ''|*[!0-9]*) total=0 ;;
  esac
  echo "   workflows GitHub Actions has registered: $total"
  if [ "$total" = "0" ]; then
    echo "   ✗ zero registered workflows = the IPA can never update. Fix it here:"
    echo "     $NEWFILE_URL"
  fi
}

if [ "${1:-}" = "--check" ]; then
  echo "→ Swift sources parse?"
  python3 scripts/check_swift_syntax.py
  echo
  echo "→ what is installed where?"
  if [ ! -f "$LIVE" ]; then
    echo "   ✗ $LIVE does not exist. GitHub runs NOTHING from this repo."
    echo "     (a workflow file in any other folder is inert — path must be $LIVE)"
  elif grep -q "Write Swift Files" "$LIVE" 2>/dev/null; then
    echo "   ✗ $LIVE still embeds its own copies of the sources — the IPA is NOT"
    echo "     built from this repo. Run:  bash scripts/install_ci_fix.sh && git push"
  else
    echo "   ✓ $LIVE builds the repo's sources directly."
  fi
  echo
  echo "→ live state on GitHub (main):"
  status_from_github
  echo
  echo "→ the file GitHub must have, from your phone in ~20 seconds:"
  echo "   $NEWFILE_URL"
  exit 0
fi

if [ "${1:-}" = "--link" ]; then
  echo "$NEWFILE_URL"
  exit 0
fi

[ -f "$LEAN" ] || die "$LEAN is missing — restore it from git before continuing."

echo "→ 1/2: Swift structure pre-flight"
python3 scripts/check_swift_syntax.py

echo
echo "→ 2/2: installing the lean workflow at $LIVE"
mkdir -p "$(dirname "$LIVE")"
cp "$LEAN" "$LIVE"
chmod +x scripts/ci_build.sh

git add "$LIVE" scripts/ci_build.sh "$LEAN"
if git diff --cached --quiet -- "$LIVE"; then
  echo
  echo "Workflow already up to date here. Checking GitHub:"
  status_from_github
  exit 0
fi

git commit -q -m "ci: build the repo's real sources instead of stale embedded copies"
echo
echo "Done. If you are the repo owner:   git push        (a GitHub App cannot push this path)"
echo "Then watch it:                     gh run watch"
echo
echo "If push is refused with \"refusing to allow a GitHub App to create or update"
echo "workflow\": use the browser instead → $NEWFILE_URL"
