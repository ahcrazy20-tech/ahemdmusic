#!/usr/bin/env python3
"""
restore_sources_from_workflow.py — the REVERSE of sync_build_yaml.py.

The CI workflow (.github/workflows/build.yml) builds from .swift sources that
are EMBEDDED inside it (it deletes the repo files and rewrites them from
heredocs). That means the workflow can end up holding code the repo has never
seen — exactly what happened with ExtractorKit.swift, which existed ONLY inside
build.yml. Without this script, running sync_build_yaml.py at that moment would
have silently deleted the extra download engines from the next IPA.

What it does, by default (safe):
  • a file the workflow has and the repo does NOT  → restored into the repo
  • a file both have, with different content      → REPORTED only, and the
    workflow's copy is written to .ci-copy/<name> so you can diff it
    (never overwritten: the repo is normally AHEAD of the workflow, and
    clobbering it would destroy real work)
  • a file the repo has and the workflow does NOT  → warned about (CI deletes
    it before building, so it is not in the shipped app)

Pass --force to overwrite differing files from the workflow (only do that when
you know the workflow is the newer copy).

    python3 scripts/restore_sources_from_workflow.py            # restore missing, report drift
    python3 scripts/restore_sources_from_workflow.py --check     # report only (CI gate)
    python3 scripts/restore_sources_from_workflow.py --force     # workflow wins, everything
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
YML = ROOT / ".github" / "workflows" / "build.yml"
APP_DIR = ROOT / "TrollMusicApp" / "TrollMusicApp"
SIDE_DIR = ROOT / ".ci-copy"
PLIST = APP_DIR / "Info.plist"
INDENT = " " * 10
HEREDOC = re.compile(
    r"cat << '(\w+)' > TrollMusicApp/TrollMusicApp/([\w.]+)\n(.*?)\n[ ]*?\1\n",
    re.S,
)


def dedent(text: str) -> str:
    return "\n".join(t[len(INDENT):] if t.startswith(INDENT) else t
                     for t in text.split("\n"))


def embedded(yml: str) -> dict:
    return {m.group(2): dedent(m.group(3)) for m in HEREDOC.finditer(yml)}


def text_of(content: str) -> str:
    return content if content.endswith("\n") else content + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="report only, change nothing")
    ap.add_argument("--force", action="store_true",
                    help="let the workflow win for files that exist in both")
    args = ap.parse_args()

    if not YML.exists():
        print(f"FATAL: {YML} not found", file=sys.stderr)
        return 2
    emb = embedded(YML.read_text())
    if not emb:
        print("FATAL: no embedded sources found in the workflow", file=sys.stderr)
        return 2

    repo_files = {p.name: p for p in APP_DIR.iterdir() if p.suffix in {".swift", ".plist"}}
    restored, diverging = [], []

    for name, content in sorted(emb.items()):
        if name == "Info.plist":      # handled once, below
            continue
        text = text_of(content)
        target = APP_DIR / name
        if name not in repo_files:
            print(f"  RESTORED  {name}  (was only inside build.yml)")
            restored.append(name)
            if not args.check:
                target.write_text(text)
            continue
        if target.read_text().rstrip("\n") == text.rstrip("\n"):
            print(f"  ok        {name}")
            continue
        diverging.append(name)
        print(f"  DIFFERS   {name}  (workflow != repo — repo kept, workflow copy written to .ci-copy/)")
        if not args.check:
            if args.force:
                target.write_text(text)
                print(f"            → overwritten from the workflow (--force)")
            else:
                SIDE_DIR.mkdir(exist_ok=True)
                (SIDE_DIR / name).write_text(text)

    orphan = sorted(set(repo_files) - set(emb))
    for name in orphan:
        if name == "Info.plist":
            continue
        print(f"  WARNING   {name} is in the repo but NOT in the workflow — "
              f"CI deletes it before building, so it is not in the shipped app. "
              f"Run: python3 scripts/sync_build_yaml.py")

    plist = PLIST.read_text().rstrip("\n") if PLIST.exists() else ""
    pm = re.search(r"cat << 'PLIST' > TrollMusicApp/TrollMusicApp/Info\.plist\n"
                   r"(.*?)\n[ ]*?PLIST\n", YML.read_text(), re.S)
    if pm:
        wtext = text_of(dedent(pm.group(1))).rstrip("\n")
        if plist != wtext:
            diverging.append("Info.plist (workflow copy is older)")
            print("  DIFFERS   Info.plist (repo != workflow copy — repo kept)")
            if args.check is False and args.force:
                PLIST.write_text(wtext + "\n")
        else:
            print("  ok        Info.plist")

    if restored:
        print(f"\nRestored {len(restored)} missing file(s): {', '.join(restored)}.")
        print("Commit them, then run scripts/sync_build_yaml.py so both match.")
    if diverging:
        print("\nDiverging files (repo was kept — inspect .ci-copy/, then merge by hand):")
        for n in diverging:
            print(f"  • {n}")
        print("If the workflow really is newer for one of them:")
        print(f"  diff -u TrollMusicApp/TrollMusicApp/<name> .ci-copy/<name>")
    if not restored and not diverging:
        print("\nRepo and workflow hold identical sources — the repo is the source of truth.")
    return 1 if (args.check and (restored or diverging)) else 0


if __name__ == "__main__":
    sys.exit(main())
