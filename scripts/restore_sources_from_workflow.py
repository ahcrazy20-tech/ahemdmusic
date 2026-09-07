#!/usr/bin/env python3
"""
restore_sources_from_workflow.py — the REVERSE of sync_build_yaml.py.

The CI workflow (.github/workflows/build.yml) builds from .swift sources that
are EMBEDDED inside it (it deletes the repo files and rewrites them from
heredocs).  That means the workflow can end up holding NEWER code than the repo
— exactly what happened with ExtractorKit.swift, which existed only inside
build.yml.  Editing the repo and re-syncing would then silently delete that
feature from the build.

This script restores the repo so it matches the workflow:

    python3 scripts/restore_sources_from_workflow.py          # report + write
    python3 scripts/restore_sources_from_workflow.py --check  # report only, exit 1 on drift

After running it, commit the restored files so TrollMusicApp/TrollMusicApp/ is
the single source of truth again, then re-run scripts/sync_build_yaml.py to
prove they match.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
YML = ROOT / ".github" / "workflows" / "build.yml"
APP_DIR = ROOT / "TrollMusicApp" / "TrollMusicApp"
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="only report drift")
    ap.add_argument("--plist", action="store_true", help="also restore Info.plist")
    args = ap.parse_args()

    if not YML.exists():
        print(f"FATAL: {YML} not found", file=sys.stderr)
        return 2
    yml = YML.read_text()
    emb = embedded(yml)
    if not emb:
        print("FATAL: no embedded sources found in the workflow", file=sys.stderr)
        return 2

    repo = {p.name: p for p in APP_DIR.iterdir() if p.suffix in {".swift", ".plist"}}
    drift = []
    for name, content in sorted(emb.items()):
        target = APP_DIR / name
        text = content if content.endswith("\n") else content + "\n"
        if name not in repo:
            print(f"  RESTORE  {name}  (exists only inside build.yml)")
            drift.append(name)
            if not args.check:
                target.write_text(text)
        elif target.read_text().rstrip("\n") != text.rstrip("\n"):
            print(f"  DRIFT    {name}  (workflow is newer — restoring into repo)")
            drift.append(name)
            if not args.check:
                target.write_text(text)
        else:
            print(f"  ok       {name}")

    for name in sorted(set(repo) - set(emb)):
        print(f"  WARNING  {name} is in the repo but NOT in the workflow — "
              f"CI deletes it before building, so it is not in the shipped app.")

    if args.plist or True:
        pm = re.search(r"cat << 'PLIST' > TrollMusicApp/TrollMusicApp/Info\.plist\n"
                       r"(.*?)\n[ ]*?PLIST\n", yml, re.S)
        if pm:
            target = APP_DIR / "Info.plist"
            text = dedent(pm.group(1)) + "\n"
            if not target.exists() or target.read_text().rstrip("\n") != text.rstrip("\n"):
                print("  DRIFT    Info.plist")
                drift.append("Info.plist")
                if not args.check:
                    target.write_text(text)
            else:
                print("  ok       Info.plist")

    if drift:
        msg = ("Restored %d file(s) from the workflow. Commit them now."
               % len(drift)) if not args.check else \
              ("Drift: %d file(s) in the workflow are newer/missing in the repo. "
               "Run without --check to restore." % len(drift))
        print("\n" + msg)
        return 0 if not args.check else 1
    print("\nRepo matches the workflow — the repo is the source of truth.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
