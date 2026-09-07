#!/usr/bin/env bash
# ===========================================================================
# ci_build.sh — build the app from the Swift files that are ACTUALLY in this
# repository.
#
# WHY THE BUILD LOGIC LIVES IN A SCRIPT
# -------------------------------------
# GitHub Actions only reads workflows from `.github/workflows/`, and the GitHub
# App used by this repo's assistant is not allowed to write there (it lacks the
# `workflows` permission). So the workflow file has to be installed by a human
# exactly ONCE. To keep that one copy-paste as short as possible (and to make
# it never need updating again), all of the build logic lives here, in a normal
# script that lives in the repo and can be updated by anyone, at any time.
#
# `.github/workflows/build.yml` should be nothing more than:
#
#     - name: Build
#       run: bash scripts/ci_build.sh
#
# WHAT IT DOES
#   1. refuses to run if the sources look deleted (the old broken workflow used
#      to `find . -name "*.swift" -delete` and paste its own frozen copies);
#   2. generates the XcodeGen spec + app icon;
#   3. archives with signing disabled and prints every compile error as a
#      GitHub annotation, in the job summary, and on the commit;
#   4. packages Payload/TrollMusicApp.app into TrollMusicApp.ipa.
#
# Bash 3.2 compatible (that is what macOS ships) — no mapfile/assoc arrays.
# ===========================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

APP_DIR="TrollMusicApp/TrollMusicApp"
LOG="build.log"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Pre-flight — what is going to be compiled?
# ---------------------------------------------------------------------------
say "1/6  Sources that will be compiled"

FILE_COUNT=$(ls -1 "$APP_DIR"/*.swift 2>/dev/null | wc -l | tr -d ' ')
ls -1 "$APP_DIR"/*.swift 2>/dev/null | sed 's|.*/||' | sed 's/^/    /'
echo "    count: $FILE_COUNT"

if [ "${FILE_COUNT:-0}" -lt 15 ]; then
    fail "Only $FILE_COUNT Swift files found in $APP_DIR (expected 20)."
    fail ""
    fail "This almost always means the OLD workflow is still installed: its"
    fail "'Clean Environment'/'Write Swift Files' steps delete every .swift"
    fail "file in the repo and paste months-old copies from inside build.yml."
    fail ""
    fail "Fix: replace .github/workflows/build.yml with the short workflow"
    fail "kept in this repo at workflows/build.yml (see SETUP_ONCE.md)."
    echo "::error::Only $FILE_COUNT Swift sources found — the repo's sources were deleted before the build. Replace .github/workflows/build.yml with workflows/build.yml."
    exit 2
fi

# Structural pre-flight (unbalanced braces, stray heredoc markers, …). Cheap,
# and it catches the mistakes that would otherwise cost a full 3-minute build.
if command -v python3 >/dev/null 2>&1; then
    echo "    structure check:"
    python3 scripts/check_swift_syntax.py 2>&1 | sed 's/^/      /' || true
fi

# ---------------------------------------------------------------------------
# 2. Clean leftovers — NEVER the sources
# ---------------------------------------------------------------------------
say "2/6  Cleaning build leftovers"
rm -rf TrollMusicApp/*.xcodeproj
rm -rf TrollMusicApp.xcodeproj build Payload TrollMusicApp.ipa
mkdir -p "TrollMusicApp/TrollMusicApp/Preview Content"
mkdir -p DummyAssets
test -f "$APP_DIR/Info.plist" || { fail "$APP_DIR/Info.plist is missing"; exit 2; }

# ---------------------------------------------------------------------------
# 3. XcodeGen spec
# ---------------------------------------------------------------------------
say "3/6  Writing project.yml"
cat << 'YAML' > project.yml
name: TrollMusicApp
options:
  bundleIdPrefix: com.ahmedsoliman
  deploymentTarget:
    iOS: "16.0"
settings:
  # Pin the language mode. Xcode 26's toolchain defaults new targets to Swift 6,
  # whose strict-concurrency checking turns this app's valid Swift 5 code into
  # hard errors.
  SWIFT_VERSION: "5.0"
  CODE_SIGNING_ALLOWED: NO
  CODE_SIGNING_REQUIRED: NO
  CODE_SIGN_IDENTITY: ""
  DEVELOPMENT_TEAM: ""
  PROVISIONING_PROFILE: ""
targets:
  TrollMusicApp:
    type: application
    platform: iOS
    deploymentTarget: "16.0"
    sources:
      - path: TrollMusicApp/TrollMusicApp
        excludes:
          - "Preview Content"
    info:
      path: TrollMusicApp/TrollMusicApp/Info.plist
      properties:
        UILaunchScreen: {}
        UIBackgroundModes: [audio]
        # ATS stays ON for our own API traffic (every backend we use is HTTPS).
        # Only the in-app WKWebView may load plain HTTP pages.
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: false
          NSAllowsArbitraryLoadsInWebContent: true
    settings:
      GENERATE_INFOPLIST_FILE: NO
      ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
      DEVELOPMENT_ASSET_PATHS: "DummyAssets"
      CODE_SIGNING_ALLOWED: NO
      CODE_SIGNING_REQUIRED: NO
      CODE_SIGN_IDENTITY: ""
      DEVELOPMENT_TEAM: ""
      PROVISIONING_PROFILE: ""
YAML

# ---------------------------------------------------------------------------
# 4. App icon
# ---------------------------------------------------------------------------
say "4/6  Generating the app icon"
mkdir -p "$APP_DIR/Assets.xcassets/AppIcon.appiconset"
cat << 'ICON' > /tmp/make_icon.swift
import AppKit
let size = CGSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let colors = [NSColor.systemPurple.cgColor, NSColor.black.cgColor] as CFArray
let grad = CGGradient(colorsSpace: nil, colors: colors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])
let attr: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 500), .foregroundColor: NSColor.white]
let str = NSAttributedString(string: "AS", attributes: attr)
let r = str.boundingRect(with: size, options: .usesLineFragmentOrigin)
str.draw(at: NSPoint(x: (size.width - r.width)/2, y: (size.height - r.height)/2 - 80))
img.unlockFocus()
let data = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: data)!
let png = rep.representation(using: .png, properties: [:])!
let u = URL(fileURLWithPath: "TrollMusicApp/TrollMusicApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
try! png.write(to: u)
ICON
swift /tmp/make_icon.swift
echo '{ "images": [ { "filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ], "info": { "author": "xcode", "version": 1 } }' \
    > "$APP_DIR/Assets.xcassets/AppIcon.appiconset/Contents.json"
echo '{ "info": { "version": 1, "author": "xcode" } }' \
    > "$APP_DIR/Assets.xcassets/Contents.json"

# ---------------------------------------------------------------------------
# 5. Generate + archive
# ---------------------------------------------------------------------------
say "5/6  Generating the Xcode project"
if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen
fi
xcodegen --version
xcodegen generate --spec project.yml

say "6/6  Archiving (signing disabled)"
set -o pipefail
xcodebuild archive \
    -project TrollMusicApp.xcodeproj \
    -scheme TrollMusicApp \
    -configuration Release \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -archivePath "$PWD/build/TrollMusicApp.xcarchive" \
    SWIFT_VERSION=5.0 \
    IPHONEOS_DEPLOYMENT_TARGET=16.0 \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE="" \
    DEVELOPMENT_ASSET_PATHS="" \
    2>&1 | tee "$LOG"
status=$?
set +o pipefail

if [ "$status" -ne 0 ]; then
    ERRORS=$(grep -E "error:" "$LOG" | sed -E 's/^[[:space:]]+//' | sort -u | head -60)

    echo "----- COMPILE ERRORS -----"
    printf '%s\n' "$ERRORS"

    # Job annotations (visible in the Actions UI and via the checks API).
    printf '%s\n' "$ERRORS" | while IFS= read -r line; do
        [ -n "$line" ] && echo "::error::$line"
    done

    # Job summary.
    {
        echo "### ❌ Build failed"
        echo
        echo '```'
        printf '%s\n' "$ERRORS"
        echo '```'
        echo
        echo "Full log is in the **build-log** artifact."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

    # A copy on the commit itself, so the assistant can read the errors back
    # without needing to download the run's zip.
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_SHA:-}" ]; then
        ERROR_TEXT="$ERRORS" python3 - <<'PY' || true
import json, os, urllib.request
body = json.dumps({"body": "**CI: the app failed to compile.**\n\n```\n"
                   + os.environ.get("ERROR_TEXT", "")[:60000]
                   + "\n```"}).encode()
req = urllib.request.Request(
    "https://api.github.com/repos/%s/commits/%s/comments" % (os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]),
    data=body,
    headers={"Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
             "Accept": "application/vnd.github+json",
             "Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=30).read()
    print("compile errors posted to the commit")
except Exception as e:
    print("could not post compile errors:", e)
PY
    fi

    exit "$status"
fi

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------
say "Packaging TrollMusicApp.ipa"
mkdir -p Payload
cp -R "build/TrollMusicApp.xcarchive/Products/Applications/TrollMusicApp.app" Payload/
/usr/bin/zip -q -r TrollMusicApp.ipa Payload
test -f TrollMusicApp.ipa || { fail "IPA was not produced"; exit 1; }

{
    echo "### ✅ Build OK"
    echo
    echo "* Swift sources compiled: **$FILE_COUNT**"
    echo "* Artifact: **TrollMusicApp.ipa** ($(du -h TrollMusicApp.ipa | cut -f1))"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

say "Done — TrollMusicApp.ipa is ready ($(du -h TrollMusicApp.ipa | cut -f1))"
