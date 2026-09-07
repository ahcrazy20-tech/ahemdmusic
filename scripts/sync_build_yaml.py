#!/usr/bin/env python3
"""
sync_build_yaml.py — keep .github/workflows/build.yml in sync with the real
Swift sources in TrollMusicApp/TrollMusicApp/.

The workflow deletes all sources and rewrites them from heredocs embedded in
build.yml (this is how the self-contained CI build works). If those embedded
copies drift from the repo, the built IPA silently builds STALE code.

Run from anywhere:
    python3 scripts/sync_build_yaml.py

It rewrites:
  • the "Write Swift Files" step (every .swift file in the app directory)
  • the Info.plist heredoc inside "Create Project Config (Signing Disabled)"
and verifies the result by re-parsing the YAML and diffing the dedented
heredoc content against the repo files.
"""
import io
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
YML = ROOT / ".github" / "workflows" / "build.yml"
APP_DIR = ROOT / "TrollMusicApp" / "TrollMusicApp"
PLIST = APP_DIR / "Info.plist"

# Preferred order (logical, not alphabetical) — new files not listed here are
# appended at the end.
PREFERRED_ORDER = [
    "TrollMusicAppApp.swift",
    "MusicManager.swift",
    "Views.swift",
    "WebBrowser.swift",
    "SmartDownloader.swift",
    "ExtractorKit.swift",
    "MusicIntelligence.swift",
    "DiscoverView.swift",
    "SmartKit.swift",
    "AudioAnalysis.swift",
    "SmartPlaylists.swift",
    "VocalStudio.swift",
    "VoiceRemote.swift",
    "SpectrumAnalyzer.swift",
    "ID3TagWriter.swift",
]

INDENT = " " * 10  # heredoc content indent used throughout build.yml


def swift_files():
    found = {p.name: p for p in APP_DIR.glob("*.swift")}
    ordered = [found[n] for n in PREFERRED_ORDER if n in found]
    ordered += [p for n, p in sorted(found.items()) if n not in PREFERRED_ORDER]
    return ordered


def indent_content(text: str) -> str:
    """Indent every non-empty line by INDENT (YAML block-scalar style)."""
    lines = text.split("\n")
    # drop a single trailing newline so the final 'SWIFT' terminator sits right
    if lines and lines[-1] == "":
        lines = lines[:-1]
    out = []
    for ln in lines:
        out.append(INDENT + ln if ln else "")
    return "\n".join(out)


def main():
    yml = YML.read_text()
    lines = yml.split("\n")

    # ---- 1) Replace the "Write Swift Files" step --------------------------
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == "- name: Write Swift Files")
    except StopIteration:
        sys.exit("FATAL: could not find the 'Write Swift Files' step in build.yml")
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("      - name: ")),
        len(lines),
    )

    files = swift_files()
    new_step = ["      - name: Write Swift Files", "        run: |"]
    for f in files:
        rel = f"TrollMusicApp/TrollMusicApp/{f.name}"
        new_step.append(f"{INDENT}cat << 'SWIFT' > {rel}")
        new_step.append(indent_content(f.read_text()))
        new_step.append(f"{INDENT}SWIFT")

    lines[start:end] = new_step

    # ---- 2) Replace the Info.plist heredoc --------------------------------
    yml2 = "\n".join(lines)
    plist_pat = re.compile(
        r"(cat << 'PLIST' > TrollMusicApp/TrollMusicApp/Info\.plist\n).*?(\n          PLIST)",
        re.S,
    )
    if not plist_pat.search(yml2):
        sys.exit("FATAL: could not find the Info.plist heredoc in build.yml")
    yml2 = plist_pat.sub(
        lambda m: m.group(1) + indent_content(PLIST.read_text()) + m.group(2),
        yml2,
    )

    YML.write_text(yml2)

    # ---- 3) Verify ---------------------------------------------------------
    try:
        import yaml  # type: ignore
        yaml.safe_load(yml2)
        print("YAML parse: OK")
    except ImportError:
        print("YAML parse: skipped (pyyaml not installed)")

    yml3 = YML.read_text()
    pat = re.compile(r"cat << 'SWIFT' > (\S+)\n(.*?)\n          SWIFT", re.S)
    ok = True
    for m in pat.finditer(yml3):
        rel, content = m.group(1), m.group(2)
        dedented = "\n".join(
            ln[10:] if ln.startswith(INDENT) else ln for ln in content.split("\n")
        )
        repo_file = ROOT / rel
        if not repo_file.exists():
            print(f"  MISSING IN REPO: {rel}")
            ok = False
            continue
        if repo_file.read_text().rstrip("\n") != dedented.rstrip("\n"):
            print(f"  DRIFT: {rel}")
            ok = False
    plist_m = re.search(
        r"cat << 'PLIST' > TrollMusicApp/TrollMusicApp/Info\.plist\n(.*?)\n          PLIST",
        yml3,
        re.S,
    )
    if plist_m:
        dedented = "\n".join(
            ln[10:] if ln.startswith(INDENT) else ln for ln in plist_m.group(1).split("\n")
        )
        if PLIST.read_text().rstrip("\n") != dedented.rstrip("\n"):
            print("  DRIFT: Info.plist")
            ok = False

    print(f"build.yml regenerated with {len(files)} Swift files: "
          + ", ".join(f.name for f in files))
    print("Verification: " + ("OK — CI now builds exactly what's in the repo" if ok else "FAILED"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
