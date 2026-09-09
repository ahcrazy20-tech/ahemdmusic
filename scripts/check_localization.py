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

PAIR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
LINE_RE = re.compile(r'^\s*"(?:[^"\\]|\\.)*"\s*=\s*"(?:[^"\\]|\\.)*"\s*;\s*$')

# The SwiftUI constructors whose first string argument is a LocalizedStringKey.
UI_RE = re.compile(
    r'(?:Text|Label|Button|navigationTitle|Section\(header:\s*Text|Toggle|Picker)'
    r'\(\s*"([^"\\]{2,80})"'
)

# Explicitly localized strings. Needed wherever the value flows through a
# Swift `String` first: Text(someString) uses the NON-localizing overload, so
# those call sites must say NSLocalizedString / LocalizedStringKey by hand.
EXPLICIT_RE = re.compile(
    r'(?:NSLocalizedString|LocalizedStringKey)\(\s*"([^"\\]{2,200})"'
)

# Literals that are deliberately not translated.
SKIP_PREFIXES = ("http", "asmusic_", "com.")


def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    return re.sub(r'//[^\n]*', '', src)


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


def ui_strings():
    found = {}
    for f in sorted(glob.glob(os.path.join(APP, "*.swift"))):
        text = open(f, encoding="utf-8").read()
        for rx in (UI_RE, EXPLICIT_RE):
            for m in rx.finditer(text):
                s = m.group(1)
                if not s.strip() or s.startswith(SKIP_PREFIXES):
                    continue
                found.setdefault(s, os.path.basename(f))
    return found


def main():
    strict = "--strict" in sys.argv
    tables = {}
    problems = []

    for lproj in sorted(glob.glob(os.path.join(APP, "*.lproj"))):
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

    if not tables:
        print("no .lproj bundles found")
        return 1

    used = ui_strings()
    print(f"\nuser-visible literals in Swift: {len(used)}")

    base = tables.get("en", {})
    exit_code = 0
    for lang, table in sorted(tables.items()):
        if lang == "en":
            # The base file should describe every literal, so translators see
            # the full surface.
            missing = sorted(k for k in used if k not in table)
        else:
            missing = sorted(k for k in used if k not in table)
        covered = len(used) - len(missing)
        pct = (100 * covered // len(used)) if used else 100
        print(f"{lang}: {covered}/{len(used)} translated ({pct}%)")
        if missing:
            print(f"  MISSING in {lang}:")
            for k in missing:
                print(f"    {k!r}   ({used[k]})")
            exit_code = 2

    # Keys that exist in a translation but no longer in the app: harmless at
    # runtime, but they rot, so surface them.
    for lang, table in sorted(tables.items()):
        stale = sorted(k for k in table if k not in used)
        if stale:
            print(f"\n{lang}: {len(stale)} key(s) no longer used in the UI")
            for k in stale[:10]:
                print(f"    {k!r}")
            if len(stale) > 10:
                print(f"    … and {len(stale) - 10} more")

    if exit_code and not strict:
        print("\n(warning only — pass --strict to fail the build on this)")
        return 0
    if exit_code == 0:
        print("\nLOCALIZATION OK")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
