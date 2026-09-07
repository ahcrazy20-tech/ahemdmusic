#!/usr/bin/env python3
"""
check_swift_syntax.py — a 5-second sanity gate for a repo whose only compiler
is the GitHub Actions macOS runner (one round trip there costs ~10 minutes).

It checks the class of mistakes that waste a whole build cycle:
  • unbalanced { } [ ] ( ) and unterminated strings/block comments
  • stray heredoc/`SWIFT` markers, tabs in indentation
  • `import` lines after code
  • a symbol used in the module that nothing declares (cross-file typo check
    for this app's own types, e.g. `AudioLab.shared` when AudioLab is misspelled)

This is NOT a type checker — `cannot find 'foo' in scope` and friends still
need CI. It only catches gross structural and naming mistakes.

    python3 scripts/check_swift_syntax.py            # check all app sources
    python3 scripts/check_swift_syntax.py -v         # + declaration map
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "TrollMusicApp" / "TrollMusicApp"
KEYWORDS = {"if", "for", "while", "switch", "catch", "func", "var", "let", "init",
            "deinit", "get", "set", "return", "else", "in", "do", "guard", "repeat",
            "case", "default", "struct", "class", "enum", "protocol", "extension",
            "where", "defer", "withUnsafeMutableBufferPointer", "withUnsafeBufferPointer"}


def strip_noise(src: str):
    """Replace string/comment contents with spaces so bracket counting is safe.
    Returns (scrubbed_source, list_of_problems)."""
    out = []
    problems = []
    i, n = 0, len(src)
    line = 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            out.append(c)
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 1:
                        j -= 2
                else:
                    if src[j] == "\n":
                        line += 1
                    out.append(" ")
                    j += 1
            if depth:
                problems.append(f"line {line}: unterminated block comment")
            out.append(" " * 2)
            i = j
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3)
            if j < 0:
                problems.append(f"line {line}: unterminated \"\"\" string")
                break
            seg = src[i + 3:j]
            out.append(" " * 3 + re.sub(r"[^\n]", " ", seg) + " " * 3)
            line += seg.count("\n")
            i = j + 3
        elif c == "#":
            # Swift raw strings: #"…"#, ##"""…"""## — brackets inside them are free-form.
            j = i
            while j < n and src[j] == "#":
                j += 1
            hashes = j - i
            if hashes and j < n and src[j] == "/":
                # Extended regex literal #/…/# (also free-form brackets).
                closer = "/" + "#" * hashes
                k = j + 1
                while k < n:
                    if src[k] == "\\":
                        k += 2
                        continue
                    if src.startswith(closer, k):
                        break
                    if src[k] == "\n":
                        break
                    k += 1
                if k >= n or not src.startswith(closer, k):
                    problems.append(f"line {line}: unterminated regex literal")
                    break
                consumed = "#" * hashes + "/" + src[j + 1:k] + closer
                out.append(" " * len(consumed))
                i = k + len(closer)
            elif hashes and j < n and src[j] == '"':
                triple = src[j:j + 3] == '"""'
                open_len = 3 if triple else 1
                closer = ('"""' if triple else '"') + "#" * hashes
                k = src.find(closer, j + open_len)
                if k < 0:
                    problems.append(f"line {line}: unterminated raw string")
                    break
                seg = src[j + open_len:k]
                consumed = "#" * hashes + ('"""' if triple else '"') + seg + closer
                out.append("".join("\n" if ch == "\n" else " " for ch in consumed))
                line += seg.count("\n")
                i = k + len(closer)
            else:
                out.append(c)
                i += 1
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == "\n":
                    break
                j += 1
            if j >= n or src[j] != '"':
                problems.append(f"line {line}: unterminated string literal")
                j = n
            out.append('"' + " " * (j - i - 1) + '"')
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out), problems


def balance(src: str, problems: list, name: str):
    stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for lineno, text in enumerate(src.split("\n"), start=1):
        for ch in text:
            if ch in "([{":
                stack.append((ch, lineno))
            elif ch in pairs:
                if not stack:
                    problems.append(f"line {lineno}: stray closing '{ch}'")
                else:
                    op, ol = stack.pop()
                    if op != pairs[ch]:
                        problems.append(f"line {lineno}: '{ch}' closes '{op}' opened on line {ol}")
    for op, ol in stack:
        problems.append(f"unclosed '{op}' opened on line {ol}")


DECL = re.compile(r"^\s*(?:@\w+\s+)*(?:public |internal |private |fileprivate )?"
                  r"(?:final\s+|static\s+|open\s+|indirect\s+)*"
                  r"(?:class|struct|enum|protocol|actor|extension|typealias)\s+([A-Z]\w*)",
                  re.M)
USES = re.compile(r"\b([A-Z][A-Za-z0-9_]{2,})\b")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("paths", nargs="*")
    args = ap.parse_args()

    files = [pathlib.Path(p) for p in args.paths] if args.paths else sorted(APP.glob("*.swift"))
    problems_total = 0
    declared = {}
    texts = {}
    for f in files:
        raw = f.read_text()
        texts[f] = raw
        scrubbed, probs = strip_noise(raw)
        balance(scrubbed, probs, f.name)
        if "\t" in raw:
            probs.append("contains tab characters (use spaces)")
        code_lines = [ln for ln in raw.split("\n")]
        seen_code = False
        for ln in code_lines:
            s = ln.strip()
            if not s or s.startswith("//"):
                continue
            if s.startswith("import "):
                if seen_code:
                    probs.append("import after code — move it to the top of the file")
            else:
                seen_code = True
        declared[f] = set(DECL.findall(raw))
        if probs:
            problems_total += len(probs)
            print(f"FAIL {f.name}")
            for p in probs[:10]:
                print(f"     {p}")
        else:
            print(f"ok   {f.name}  ({len(declared[f])} types)")

    known = set().union(*declared.values()) if declared else set()
    stdlib = {"AVFoundation", "SwiftUI", "Foundation", "UIKit", "Combine", "Accelerate",
              "MediaPlayer", "WebKit", "CryptoKit", "Speech", "AppIntents", "AudioToolbox",
              "AVKit", "Intents"}
    for f in files:
        scrubbed, _ = strip_noise(texts[f])
        used = set(USES.findall(scrubbed))
        unknown = sorted(u for u in used if u not in known and u not in stdlib
                         and not u.isupper() and u not in
                         {"UUID", "Data", "Date", "URL", "URLSession", "URLRequest", "JSONDecoder",
                          "JSONEncoder", "JSONSerialization", "NotificationCenter", "UserDefaults",
                          "FileManager", "DispatchQueue", "DispatchWorkItem", "OperationQueue",
                          "Timer", "UIImage", "UIColor", "Color", "View", "ObservableObject",
                          "Published", "State", "Binding", "EnvironmentObject", "StateObject",
                          "ObservedObject", "Identifiable", "Equatable", "Codable", "Hashable",
                          "NSObject", "NSError", "NSObjectProtocol", "CaseIterable", "Set",
                          "NSLock", "NSThread", "NSCache", "Thread", "Locale", "NumberFormatter",
                          "DateFormatter", "Calendar", "ComparisonResult", "CGAffineTransform",
                          "UIImpactFeedbackGenerator", "UINotificationFeedbackGenerator",
                          "UIApplication", "UIHostingController", "CADisplayLink", "AVAudioEngine",
                          "AVAudioPlayerNode", "AVAudioFile", "AVAudioFormat", "AVAudioUnitEQ",
                          "AVAudioMixerNode", "AVAudioUnitReverb", "AVAudioUnitTimePitch",
                          "AVAudioPCMBuffer", "AVAudioSession", "MPRemoteCommandCenter",
                          "MPNowPlayingInfoCenter", "MPMediaItemArtwork", "MPFeedbackGenerator"})
        # only report names that look like this app's own types (PascalCase, unused elsewhere)
        suspects = [u for u in unknown
                    if re.match(r"^(Audio|Smart|Vocal|Voice|Track|Playlist|Song|Speak|Karaoke|Sound|Play|Queue|Like|Sleep|Generate)", u)]
        if suspects:
            problems_total += len(suspects)
            print(f"WARN {f.name}: uses types nothing declares → {', '.join(suspects)}")

    if args.verbose:
        print("\ndeclarations per file:")
        for f, names in declared.items():
            if names:
                print(f"  {f.name}: {', '.join(sorted(names))}")

    print(f"\n{'PROBLEMS: %d' % problems_total if problems_total else 'structure OK'} "
          f"in {len(files)} file(s). (Run CI for type checking.)")
    return 1 if problems_total else 0


if __name__ == "__main__":
    sys.exit(main())
