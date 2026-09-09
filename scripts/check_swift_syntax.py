#!/usr/bin/env python3
"""
check_swift_syntax.py — a 5-second sanity gate for a repo whose only compiler
is the GitHub Actions macOS runner (one round trip there costs ~10 minutes).

It checks the class of mistakes that waste a whole build cycle:
  • unbalanced { } [ ] ( ) and unterminated strings/block comments
  • invalid escape sequences inside string literals — the bug that cost a full
    archive once: `Summary("Play \.$moment")` in an AppIntent. The App Intents
    parameter form has to sit inside interpolation parens:
        Summary("Play \(\.$moment)")
  • stray heredoc/`SWIFT` markers, tabs in indentation
  • `import` lines after code
  • a symbol used in the module that nothing declares (cross-file typo check
    for this app's own types, e.g. `AudioLab.shared` when AudioLab is misspelled)

Raw strings (#"…"#), regex literals (#/…/#) and comment bodies are exempt from
escape checking (backslashes are free-form in them), and interpolation is read
properly, so legal Swift such as `"\(n == 1 ? "" : "s")"` is not mistaken for
an unterminated string.

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

# The only sequences a Swift *escaped* string literal may contain after a
# backslash. Raw strings and regex literals are exempt.
VALID_ESCAPES = set("\\0()'\"tnxrUvb") | set("0123456789")

HEREDOC = re.compile(r"^\s*(SWIFT|ICON|YAML|EOF|PY|PLIST|END)\s*$", re.M)

DECL = re.compile(r"^\s*(?:@\w+\s+)*(?:public |internal |private |fileprivate )?"
                  r"(?:final\s+|static\s+|open\s+|indirect\s+)*"
                  r"(?:class|struct|enum|protocol|actor|extension|typealias)\s+([A-Z]\w*)",
                  re.M)
USES = re.compile(r"\b([A-Z][A-Za-z0-9_]{2,})\b")

# Top-level `let`/`var` at column 0 — file-scope globals, which are NOT members
# and so must never be written as `self.name`.
FILE_GLOBAL = re.compile(
    r"^(?:private |fileprivate |internal |public )?(?:let|var)\s+([a-z_]\w*)",
    re.M)

BS = chr(92)          # backslash
DQ = chr(34)          # one double quote
TQ = DQ * 3           # the delimiter of a Swift multiline literal
NL = "\n"


def _skip_str(src, i, n, line, triple, raw):
    """Index just after the literal body starting at `i`, plus the new line count.

    A nested literal inside an interpolation that runs into a newline is not
    broken: it is the *enclosing* literal ending, so we stop there instead of
    reporting a second error about it.
    """
    closer = (TQ if triple else DQ) + "#" * raw
    while i < n:
        c = src[i]
        if src.startswith(closer, i) and not (triple and src[i + 3:i + 4] == DQ):
            return i + len(closer), line
        if c == BS:
            if i + 1 < n and src[i + 1] == NL:
                line += 1
            i += 2
            continue
        if c == NL:
            if not (triple or raw):
                return i, line
            line += 1
        i += 1
    return n, line


def _str_end(src, i, n, triple, raw):
    """Index of the quote that ends the literal whose body starts at `i` (or n).

    Nested literals are skipped — the closer of an outer string is not the first
    quote it meets: `\(x ? "a" : "b")` contains two of them.
    """
    closer = (TQ if triple else DQ) + "#" * raw
    mode = "skip" if raw else ("str" if triple else "str")
    while i < n:
        if src.startswith(closer, i) and not (triple and src[i + 3:i + 4] == DQ):
            return i
        c = src[i]
        if c == BS:
            if raw:
                i += 2
                continue
            if src[i + 1:i + 2] == "(":
                end, _ = _interp_end(src, i + 2, n, 1)
                i = end if end > 0 else i + 2
                continue
            i += 2
            continue
        if c == DQ:
            i += 1
            continue
        i += 1
    return n


def _skip_raw(src, i, n, raw, triple):
    """Index just after a raw string / regex body starting at `i`, else -1."""
    closer = (TQ if triple else DQ) + "#" * raw
    while i < n:
        if src.startswith(closer, i):
            return i + len(closer)
        i += 1
    return -1


def _interp_end(src, i, limit, line):
    """Index just after the `)` that closes a `\(…)` starting at `i`, else -1.

    Swift ends an interpolation at the first *unmatched* closing paren, so
    `\(count)` closes there even though the `(` of `count(` was never opened
    inside the expression, while `\(x.map { $0.id })` survives because the
    closure's braces are balanced. Nested literals are skipped, which is what
    keeps `\(n == 1 ? "" : "s")` legal. `limit` is the end of the enclosing
    literal: an expression cannot run past it.
    """
    depth = 0
    while i < limit:
        c = src[i]
        if c == ")":
            if depth == 0:
                return i + 1, line
            depth -= 1
            i += 1
            continue
        if c == "(":
            depth += 1
            i += 1
            continue
        if c == "#":
            j = i
            while j < limit and src[j] == "#":
                j += 1
            hashes = j - i
            if hashes and j < limit and src[j] == DQ:
                t3 = src[j:j + 3] == TQ
                end = _skip_raw(src, j + (3 if t3 else 1), limit, hashes, t3)
                if end < 0:
                    return -1, line
                line += src.count(NL, i, end)
                i = end
                continue
            if hashes and j < limit and src[j] == "/":
                rcloser = "/" + "#" * hashes
                stop = src.find(rcloser, j + 1, limit)
                if stop < 0:
                    return -1, line
                i = stop + len(rcloser)
                continue
            i += 1
            continue
        if c == DQ:
            t3 = src[i:i + 3] == TQ
            end, line = _skip_str(src, i + (3 if t3 else 1), limit, line, t3, 0)
            if end <= i:
                return -1, line
            i = end
            continue
        if c == BS and i + 1 < limit:
            i += 2
            continue
        if c == NL:
            line += 1
        i += 1
    return -1, line


REGEX_HINTS = ("regularExpression", "NSRegularExpression", "NSPredicate", "matches:",
               "range(of:", "firstMatch", "pattern:", "predicate(from:")
# `\s \d \w [^ … $` and friends only show up in patterns, never in prose — so a
# line containing one of them is treated as regex, where `\(` means "literal (".
REGEX_TOKENS = ("[^", "$", "\\s", "\\S", "\\d", "\\w", "\\b", "\\k", "\\p", "\\Q",
                "\\E", "(?i)", "(?x)", "(?:")


def _looks_like_regex(src, i):
    """True when a `\\\\(` inside a string is most likely a regex escape.

    Ambiguity is real here (`"\\\\("` is a legitimate regex escape and also what a
    broken interpolation looks like), so the rule is deliberately permissive:
    skip the warning when the surrounding call takes patterns, or when the same
    line carries any other regex token.
    """
    window = src[max(0, i - 160):i]
    if any(h in window for h in REGEX_HINTS):
        return True
    ls = src.rfind(NL, 0, i) + 1
    le = src.find(NL, i)
    line_text = src[ls:le if le >= 0 else len(src)]
    return any(t in line_text for t in REGEX_TOKENS)


def scan(src, i, n, line, problems, out, mode="code", triple=False, raw=0):
    """Walk `src` from `i`, scrubbing literals/comments and collecting problems.

    `mode` is "code" (real code, a comment), "str" (inside an escaped literal)
    or "skip" (inside a raw string / regex literal, whose contents are
    free-form). Returns (index_after, line).

    Invariant: every source character contributes exactly one scrub character
    and every newline survives at its own index, so `len(scrubbed) == len(src)`
    and line numbers still match the file — that lets `balance()` count
    brackets on the scrubbed text (literal and comment bodies are blanked).
    """
    closer = (TQ if triple else DQ) + "#" * raw
    while i < n:
        before = i
        c = src[i]

        if mode == "skip":
            if src.startswith(closer, i):
                out.append(" " * len(closer))
                return i + len(closer), line
            if c == BS and i + 1 < n:
                if src[i + 1] == NL:
                    out.append(NL + " ")
                    line += 1
                else:
                    out.append("  ")
                i += 2
                continue
            if c == BS:
                out.append(" ")
                i += 1
                continue
            if c == NL:
                line += 1
                out.append(NL)
                i += 1
                continue
            out.append(" ")
            i += 1
            continue

        if mode == "str":
            if c == DQ:
                if src.startswith(closer, i):
                    if not (triple and src[i + 3:i + 4] == DQ):
                        out.append(" " * len(closer))
                        return i + len(closer), line
                    out.append("   ")        # four quotes = escaped quote + delimiter
                    i += 3
                    continue
                if triple and not raw and src[i:i + 3] == TQ:
                    out.append("  ")         # three quotes inside a block = one quote
                    i += 2
                    continue
                out.append(" ")
                i += 1
                continue
            if c == BS:
                if i + 1 >= n:
                    out.append(" ")
                    i += 1
                    continue
                nxt = src[i + 1]
                if nxt == "(":
                    j = i + 2
                    while j < n and src[j] in " \t":
                        j += 1
                    if j < n and src[j] == ")":
                        problems.append(f"line {line}: empty interpolation "
                                        f"'{BS}()' — did you mean "
                                        f"'{BS}({BS}.$name)'?")
                        out.append("  ")
                        i += 2
                        continue
                    limit = _str_end(src, i, n, triple, raw)
                    end, line2 = _interp_end(src, i + 2, limit, line)
                    eol = src.find(NL, i)
                    eol = n if eol < 0 else eol
                    if end < 0:
                        out.append(" " * (eol - i))
                        problems.append(f"line {line}: interpolation "
                                        f"'{BS}(' that is never closed on this line")
                        if eol < n:
                            out.append(NL)
                            line = line2 if end < 0 else line + 1
                            return eol + 1, line
                        out.append(" " * (n - eol))
                        return n, line
                    out.append(" " * (end - i))
                    i = end
                    line = line2
                    continue
                if nxt == NL and not triple and not raw:
                    line += 1                 # trailing backslash = line continuation
                    out.append(NL)
                    i += 2
                    continue
                if nxt == NL:
                    problems.append(f"line {line}: a multiline literal needs no "
                                    f"backslash before a newline")
                    out.append("  ")
                    i += 2
                    continue
                if nxt in VALID_ESCAPES:
                    if nxt == BS and src[i + 2:i + 3] == "(" and not _looks_like_regex(src, i):
                        problems.append(
                            f"line {line}: '{BS}{BS}(' inside a string prints a literal "
                            f"backslash rather than interpolating — use one backslash")
                    out.append("  ")
                    i += 2
                    continue
                what = (f"a property/parameter reference — inside a string literal it "
                        f"must be interpolated: '{BS}({BS}.$name)'" if nxt == "."
                        else f"'{BS}{nxt}'")
                problems.append(f"line {line}: invalid escape sequence in string "
                                f"literal: {what}")
                out.append("  ")
                i += 2
                continue
            if c == NL:
                if triple or raw:
                    line += 1
                    out.append(NL)
                    i += 1
                    continue
                problems.append(f"line {line}: string literal is never closed — if "
                                f"there was an invalid escape on this line, that is "
                                f"the real cause")
                out.append(NL)
                return i + 1, line + 1
            out.append(" ")
            i += 1
            continue

        # ---- mode == "code" --------------------------------------------------
        if c == DQ:
            t3 = not raw and src[i:i + 3] == TQ
            out.append(" " * (3 if t3 else 1))
            i, line = scan(src, i + (3 if t3 else 1), n, line, problems, out,
                           mode="str", triple=t3, raw=raw)
            continue
        if not raw and c == "#":
            j = i
            while j < n and src[j] == "#":
                j += 1
            hashes = j - i
            # Only treat `#` as a raw-literal prefix when its closer also exists
            # on the same line; otherwise `#` is ordinary code (e.g. `#if`, a
            # markdown heading in a comment) and must not swallow the line.
            eol_probe = src.find(NL, i)
            eol_probe = n if eol_probe < 0 else eol_probe
            if hashes and j < n and src[j] == DQ and src.find(DQ + "#" * hashes, j + 1, eol_probe) < 0:
                out.append(" ")
                i += 1
                continue
            if hashes and j < n and src[j] == "/":
                rcloser = "/" + "#" * hashes
                k = j + 1
                eol = src.find(NL, i)
                eol = n if eol < 0 else eol
                while k < eol and not src.startswith(rcloser, k):
                    k += 2 if src[k] == BS else 1
                if k >= eol or not src.startswith(rcloser, k):
                    problems.append(f"line {line}: unterminated regex literal")
                    out.append(" " * (eol - i))
                    if eol < n:
                        out.append(NL)
                        line += 1
                    return eol + 1, line
                end = k + len(rcloser)
                out.append(" " * (end - i))
                line += src.count(NL, i, end)
                i = end
                continue
            if hashes and j < n and src[j] == DQ:
                t3 = src[j:j + 3] == TQ
                out.append(" " * (hashes + 3 if t3 else hashes + 1))
                i, line = scan(src, j + (3 if t3 else 1), n, line, problems, out,
                                mode="skip", triple=t3, raw=hashes)
                continue
            out.append(" ")
            i += 1
            continue
        if not raw and src.startswith("//", i):
            j = src.find(NL, i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if not raw and src.startswith("/*", i):
            depth, j = 1, i + 2
            out.append("  ")
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    out.append("  ")
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    out.append("  ")
                    j += 2
                else:
                    if src[j] == NL:
                        line += 1
                        out.append(NL)
                    else:
                        out.append(" ")
                    j += 1
            if depth:
                problems.append(f"line {line}: unterminated block comment")
            i = j
            continue
        if c == NL:
            line += 1
            out.append(NL)
            i += 1
            continue
        out.append(c)
        i += 1
        if i == before:                     # cannot happen, but never hang
            i += 1
    if mode == "str":
        problems.append(f"line {line}: unterminated string literal")
    elif mode == "skip":
        problems.append(f"line {line}: unterminated raw string / regex literal")
    return n, line


def strip_noise(src: str):
    """Replace string/comment contents with spaces so bracket counting is safe.
    Returns (scrubbed_source, list_of_problems). The gate must never be the
    reason a build fails, so a pathological file just gets skipped."""
    problems = []
    out = []
    try:
        scan(src, 0, len(src), 1, problems, out)
    except RecursionError:
        return src, []                      # nesting too deep to analyse, don't lie
    scrubbed = "".join(out)
    if scrubbed.count(NL) != src.count(NL):
        problems.append("internal: literal scanner lost track of lines — trusting "
                        "bracket counts from the raw source instead")
        return src, problems
    return scrubbed, problems


def balance(src: str, problems: list, name: str):
    stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for lineno, text in enumerate(src.split(NL), start=1):
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


def check_file(path: pathlib.Path):
    """Full gate for one file → (set of declared types, list of problems)."""
    raw = path.read_text()
    scrubbed, problems = strip_noise(raw)
    balance(scrubbed, problems, path.name)
    if "\t" in raw:
        problems.append("contains tab characters (use spaces)")
    for m in HEREDOC.finditer(raw):
        line = raw[:m.start()].count(NL) + 1
        problems.append(f"line {line}: stray heredoc marker '{m.group(1)}' left in the source")
    seen_code = False
    for ln in raw.split(NL):
        s = ln.strip()
        if not s or s.startswith("//"):
            continue
        # Conditional-compilation directives are not "code": a header block of
        #     #if canImport(ShazamKit)
        #     import ShazamKit
        #     #endif
        # is the correct way to import a framework that may be unavailable, and
        # it must not be reported as "import after code". Anything that is real
        # code still flips the flag, so a genuine late import is still caught.
        if s.startswith(("#if", "#else", "#elseif", "#endif")):
            continue
        if s.startswith("import "):
            if seen_code:
                problems.append("import after code — move it to the top of the file")
        else:
            seen_code = True

    # `self.foo` where foo is a file-level global, not a member.
    #
    # This compiles in your head and fails in Xcode with "value of type 'X' has
    # no member 'foo'". It is easy to write when moving code into a closure
    # that already qualifies everything else with self, which is exactly how it
    # reached CI once. Costs nothing to catch here instead of eight minutes in.
    globals_here = set(FILE_GLOBAL.findall(raw))
    if globals_here:
        for i, ln in enumerate(raw.split(NL), 1):
            st = ln.strip()
            if st.startswith("//"):
                continue
            for m in re.finditer(r"\bself\.([A-Za-z_][A-Za-z0-9_]*)", ln):
                if m.group(1) in globals_here:
                    problems.append(
                        f"line {i}: 'self.{m.group(1)}' — {m.group(1)} is a file-level "
                        f"global, not a member; drop the 'self.'"
                    )
    return set(DECL.findall(raw)), problems


APP_TYPE_PREFIX = (r"^(Audio|Smart|Vocal|Voice|Track|Playlist|Song|Speak|Karaoke|Sound|"
                   r"Play|Queue|Like|Sleep|Generate|Discover|Backup|Library|Lyrics|ID3|Spectrum|Troll)")

FOUNDATION_TYPES = {
    "UUID", "Data", "Date", "URL", "URLSession", "URLRequest", "JSONDecoder",
    "JSONEncoder", "JSONSerialization", "NotificationCenter", "UserDefaults",
    "FileManager", "DispatchQueue", "DispatchWorkItem", "OperationQueue", "Timer",
    "UIImage", "UIColor", "Color", "View", "ObservableObject", "Published", "State",
    "Binding", "EnvironmentObject", "StateObject", "ObservedObject", "Identifiable",
    "Equatable", "Codable", "Hashable", "Decodable", "Encodable", "RawRepresentable",
    "NSObject", "NSError", "NSObjectProtocol", "CaseIterable", "Set", "NSLock",
    "NSThread", "NSCache", "Thread", "Locale", "NumberFormatter", "DateFormatter",
    "Calendar", "ComparisonResult", "CGColorSpace", "CGAffineTransform", "CGContext",
    "CGGradient", "CGImage", "CIContext", "CIFilter", "NSAttributedString", "NSFont",
    "NSImage", "NSBitmapImageRep", "NSGraphicsContext", "UIImpactFeedbackGenerator",
    "UINotificationFeedbackGenerator", "UIApplication", "UIHostingController",
    "UIActivityViewController", "UIDocumentPickerViewController",
    "UIImagePickerController", "UIGraphicsImageRenderer", "UIScreen", "UIScrollView",
    "UIStackView", "UILabel", "UIButton", "UIVisualEffectView", "UIBlurEffect",
    "UIBlurStyle", "UITabBarController", "UINavigationController", "UIViewController",
    "CADisplayLink", "AVAudioEngine", "AVAudioPlayerNode", "AVAudioFile",
    "AVAudioFormat", "AVAudioUnitEQ", "AVAudioUnitEQFilterType", "AVAudioMixerNode",
    "AVAudioUnitReverb", "AVAudioUnitTimePitch", "AVAudioUnitVarispeed",
    "AVAudioPCMBuffer", "AVAudioSession", "AVAudioRecorder", "AVAudioPlayer",
    "AVAsset", "AVAssetImageGenerator", "AVPlayer", "AVPlayerItem", "AVPlayerLayer",
    "AVAudioTime", "AVCaptureSession", "MPMusicPlayerController",
    "MPRemoteCommandCenter", "MPNowPlayingInfoCenter", "MPMediaItemArtwork",
    "MPFeedbackGenerator", "WKWebView", "WKNavigationDelegate", "WKWebViewConfiguration",
    "WKUIDelegate", "CNContact", "MKMapView", "LocalizedStringResource", "IntentDescription",
    "IntentParameter", "ParameterSummary", "AppEntity", "EntityQuery", "ItemCollection",
    "AudioFile", "AudioConverter",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("paths", nargs="*")
    args = ap.parse_args()

    files = [pathlib.Path(p) for p in args.paths] if args.paths else sorted(APP.glob("*.swift"))
    problems_total = 0
    declared = {}
    scrubbed_all = {}
    for f in files:
        declared[f], problems = check_file(f)
        scrubbed_all[f] = strip_noise(f.read_text())[0]
        if problems:
            problems_total += len(problems)
            print(f"FAIL {f.name}")
            for p in problems[:10]:
                print(f"     {p}")
        else:
            print(f"ok   {f.name}  ({len(declared[f])} types)")

    known = set().union(*declared.values()) if declared else set()
    for f in files:
        used = set(USES.findall(scrubbed_all[f]))
        unknown = sorted(u for u in used
                         if u not in known and u not in FOUNDATION_TYPES and not u.isupper())
        suspects = [u for u in unknown if re.match(APP_TYPE_PREFIX, u)]
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
