#!/usr/bin/env python3
"""
check_localization.py — keeps the Arabic build honest.

SwiftUI's Text("Play") takes a LocalizedStringKey, which is lovely (adding
ar.lproj localized the app without touching a single view) and also dangerous:
nothing tells you when a NEW Text("…") is added and never translated. It just
silently renders English inside an otherwise Arabic screen.

This script is that missing warning. It:
  1. parses every .lproj/Localizable.strings and reports malformed entries,
     duplicate keys and empty values;
  2. extracts the user-visible literals from the Swift sources;
  3. reports which of them have no Arabic translation.

Exit codes:  0 = fine   1 = broken .strings file   2 = missing translations
Run:  python3 scripts/check_localization.py [--strict]

Without --strict, missing translations are reported as warnings (exit 0) so an
in-progress feature doesn't block a build; with --strict they fail.
"""
import os
import re
import sys
import glob

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
APP = os.path.join(ROOT, "TrollMusicApp", "TrollMusicApp")
# The widget extension shows its own strings and shares the .strings files.
WIDGET = os.path.join(ROOT, "TrollMusicApp", "ASMusicWidget")

PAIR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
LINE_RE = re.compile(r'^\s*"(?:[^"\\]|\\.)*"\s*=\s*"(?:[^"\\]|\\.)*"\s*;\s*$')

# The SwiftUI constructors whose first string argument is a LocalizedStringKey.
UI_RE = re.compile(
    r'(?:Text|Label|Button|navigationTitle|Section\(header:\s*Text|Toggle|Picker'
    # WidgetKit's gallery strings. `.description(` is deliberately NOT matched
    # generically -- it collides with DispatchQueue labels and AI model
    # descriptors, neither of which should ever be translated.
    r'|configurationDisplayName)'
    # The upper bound is deliberately generous: explanatory Section footers
    # run long, and they are exactly the text a non-English reader needs most.
    # A 120-char cap silently exempted 24 of them from this check.
    r'\(\s*"([^"\\]{2,400})"'
)

# Explicitly localized strings. Needed wherever the value flows through a
# Swift `String` first: Text(someString) uses the NON-localizing overload, so
# those call sites must say NSLocalizedString / LocalizedStringKey by hand.
EXPLICIT_RE = re.compile(
    r'(?:NSLocalizedString|LocalizedStringKey)\(\s*"([^"\\]{2,200})"'
)

# Labels declared as plain data and rendered through LocalizedStringKey later
# (WidgetMoment). The literal lives in the shared file, the Text() is in the
# widget, so neither regex above would pair them up.
# Scoped to WidgetMoment specifically: a bare `label:` also matches
# DispatchQueue(label:) and the AI model table, which must stay untranslated.
DATA_LABEL_RE = re.compile(r'WidgetMoment\([^)]*?\blabel:\s*"([^"\\]{2,80})"')

# The widget gallery's subtitle. Scoped to a line that chains off
# .configurationDisplayName(...) so it can't catch DispatchQueue labels.
WIDGET_DESC_RE = re.compile(r'^\s*\.description\(\s*"([^"\\]{2,160})"', re.M)

# Literals that are deliberately not translated.
SKIP_PREFIXES = ("http", "asmusic_", "com.")


def strip_comments(src):
    """Remove // and /* */ comments WITHOUT touching quoted text.

    A blind regex also ate the '//' inside a URL that appears in a
    translatable string ("https://my-extractor.onrender.com"), which then
    looked like a malformed line. Walk the source and track whether we are
    inside a double-quoted string instead.
    """
    out = []
    i, n = 0, len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:      # keep escape pairs intact
                out.append(src[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            end = src.find('*/', i + 2)
            i = n if end == -1 else end + 2
            continue
        out.append(c); i += 1
    return ''.join(out)


def load_strings(path):
    """-> (mapping, [problems])"""
    problems = []
    raw = open(path, encoding="utf-8").read()
    body = strip_comments(raw)

    for i, line in enumerate(body.splitlines(), 1):
        if line.strip() and not LINE_RE.match(line):
            problems.append(f"{os.path.basename(path)}:{i}: malformed line: {line.strip()[:60]}")

    pairs = PAIR_RE.findall(body)
    mapping = {}
    for key, value in pairs:
        if key in mapping:
            problems.append(f"{os.path.basename(path)}: duplicate key {key!r}")
        if not value.strip():
            problems.append(f"{os.path.basename(path)}: empty value for {key!r}")
        mapping[key] = value
    return mapping, problems


def ui_strings(directory):
    found = {}
    sources = sorted(glob.glob(os.path.join(directory, "*.swift")))
    shared = os.path.join(APP, "SharedNowPlaying.swift")
    if os.path.basename(directory) == "ASMusicWidget":
        # WidgetMoment's labels live in the shared file but are only ever
        # rendered by the widget, so they belong to the widget's surface...
        sources.append(shared)
    else:
        # ...and for the same reason they are NOT part of the app's.
        sources = [f for f in sources if os.path.abspath(f) != os.path.abspath(shared)]
    for f in sources:
        text = open(f, encoding="utf-8").read()
        rules = [UI_RE, EXPLICIT_RE, DATA_LABEL_RE]
        # Only widget sources declare WidgetKit gallery metadata.
        if os.path.basename(os.path.dirname(f)) == "ASMusicWidget":
            rules.append(WIDGET_DESC_RE)
        for rx in rules:
            for m in rx.finditer(text):
                s = m.group(1)
                if not s.strip() or s.startswith(SKIP_PREFIXES):
                    continue
                found.setdefault(s, os.path.basename(f))
    return found


def main():
    strict = "--strict" in sys.argv
    tables = {}
    overall = 0

    # The app and the widget are SEPARATE BUNDLES. A widget's Text("…")
    # resolves against the extension's own .strings, so each bundle is checked
    # against its own sources; a string translated in one does not help the
    # other.
    bundles = [("app", APP)]
    if os.path.isdir(WIDGET):
        bundles.append(("widget", WIDGET))

    for bundle_name, directory in bundles:
        print(f"\n=== {bundle_name} bundle ===")
        tables = {}
        problems = []

        for lproj in sorted(glob.glob(os.path.join(directory, "*.lproj"))):
            lang = os.path.basename(lproj).replace(".lproj", "")
            path = os.path.join(lproj, "Localizable.strings")
            if not os.path.exists(path):
                problems.append(f"{lang}: no Localizable.strings")
                continue
            table, probs = load_strings(path)
            tables[lang] = table
            problems.extend(probs)
            print(f"{lang}: {len(table)} entries")

        if problems:
            print("\nBROKEN:")
            for p in problems:
                print("  " + p)
            return 1

        used = ui_strings(directory)
        print(f"user-visible literals in Swift: {len(used)}")

        if not tables:
            if used:
                print(f"  no .lproj bundles, but {len(used)} literal(s) are shown to users")
                overall = 2
            continue

        for lang, table in sorted(tables.items()):
            missing = sorted(k for k in used if k not in table)
            covered = len(used) - len(missing)
            pct = (100 * covered // len(used)) if used else 100
            print(f"{lang}: {covered}/{len(used)} translated ({pct}%)")
            if missing:
                print(f"  MISSING in {lang}:")
                for k in missing:
                    print(f"    {k!r}   ({used[k]})")
                overall = 2

        # Keys that exist in a translation but no longer in the sources:
        # harmless at runtime, but they rot, so surface them.
        for lang, table in sorted(tables.items()):
            stale = sorted(k for k in table if k not in used)
            if stale:
                print(f"{lang}: {len(stale)} key(s) no longer used")
                for k in stale[:10]:
                    print(f"    {k!r}")
                if len(stale) > 10:
                    print(f"    … and {len(stale) - 10} more")

    print()
    if overall and not strict:
        print("(warning only — pass --strict to fail the build on this)")
        return 0
    if overall == 0:
        print("LOCALIZATION OK")
    return overall


if __name__ == "__main__":
    sys.exit(main())
