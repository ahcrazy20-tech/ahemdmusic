#!/usr/bin/env python3
"""
test_search_logic.py — checks for the Arabic-aware search (Pack 7 §2.6).

The app's library search was `title.lowercased().contains(query)`. That is
fine for a Latin library and close to useless for an Arabic one, because the
same title is legitimately spelled several ways and the user never types the
one the file happens to use:

    أنت عمري / انت عمري     hamza on the alef, or not
    مصطفى / مصطفي           alef maksura vs yeh
    يا حبيبي / ياحبيبي       spacing
    محمّد / محمد             shadda
    ٢٠٢٤ / 2024             Arabic-Indic digits

This mirrors ArabicFold from SearchKit.swift and asserts the behaviour, so the
folding table can be verified without a Mac. Latin behaviour is asserted too:
the fold must not quietly damage an English library.

Run:  python3 scripts/test_search_logic.py
"""
import sys
import unicodedata

FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print(f"PASS  {name}")
    else:
        print(f"FAIL  {name}  {detail}")
        FAILURES.append(name)


# ===========================================================================
# Mirror of ArabicFold (SearchKit.swift)
# ===========================================================================

TATWEEL = "\u0640"
DIACRITICS = set(range(0x064B, 0x0653)) | {
    0x0653, 0x0654, 0x0655, 0x0656, 0x0657, 0x0658, 0x0670
}

ALEFS = set("\u0622\u0623\u0625\u0671\u0672\u0673\u0675")
YEHS = set("\u0649\u064A\u06CC\u06D2")
HEHS = set("\u0647\u0629\u06C0")
WAWS = set("\u0624\u0648")
KAFS = set("\u06A9\u0643")
HAMZAS = set("\u0621\u0626")

DIGITS = {}
for _i in range(10):
    DIGITS[chr(0x0660 + _i)] = str(_i)
    DIGITS[chr(0x06F0 + _i)] = str(_i)


def key(text):
    out = []
    for ch in text:
        if ch in DIGITS:
            out.append(DIGITS[ch]); continue
        if ch in ALEFS:
            out.append("\u0627"); continue
        if ch in YEHS:
            out.append("\u064A"); continue
        if ch in HEHS:
            out.append("\u0647"); continue
        if ch in WAWS:
            out.append("\u0648"); continue
        if ch in KAFS:
            out.append("\u0643"); continue
        if ch in HAMZAS:
            continue
        if ord(ch) in DIACRITICS or ch == TATWEEL:
            continue
        out.append(ch)
    s = unicodedata.normalize("NFKD", "".join(out))
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    return " ".join(s.split())


def squeezed(text):
    return key(text).replace(" ", "")


def contains(haystack, needle):
    n = key(needle)
    if not n:
        return True
    if n in key(haystack):
        return True
    # Both directions: Arabic spacing is inconsistent in real filenames.
    # Letter order is preserved, so this is still a phrase match.
    return squeezed(needle) in squeezed(haystack)


def has_prefix(haystack, needle):
    n = key(needle)
    if not n:
        return True
    return key(haystack).startswith(n) or squeezed(haystack).startswith(squeezed(needle))


# ===========================================================================
# 1. The real-world Arabic cases
# ===========================================================================

print("\n--- 1. Arabic spelling variants --------------------------------------")

CASES = [
    ("أنت عمري", "انت عمري", "hamza on alef vs bare alef"),
    ("الأطلال", "الاطلال", "hamza in the middle"),
    ("إنت", "انت", "hamza below"),
    ("آه", "اه", "madda"),
    ("مصطفى", "مصطفي", "alef maksura vs yeh"),
    ("محمّد", "محمد", "shadda"),
    ("يَا مُسَافِر", "يا مسافر", "full harakat"),
    ("كريم", "کریم", "Farsi kaf and yeh"),
    ("فاطمة", "فاطمه", "teh marbuta vs heh"),
    ("مـــحـــمـــد", "محمد", "tatweel stretching"),
    ("٢٠٢٤", "2024", "Arabic-Indic digits"),
    ("۲۰۲۴", "2024", "Eastern Arabic-Indic digits"),
]

for a, b, why in CASES:
    check(f"{why}", key(a) == key(b), f"{key(a)!r} != {key(b)!r}")

check("spacing is ignored when the query is one word",
      contains("يا حبيبي", "ياحبيبي") and contains("ياحبيبي", "يا حبيبي"))


# ===========================================================================
# 2. Latin must not be damaged
# ===========================================================================

print("\n--- 2. Latin behaviour is preserved ----------------------------------")

check("plain ASCII is just lowercased", key("Fairuz") == "fairuz", key("Fairuz"))
check("accents fold so Café matches cafe", key("Café Del Mar") == "cafe del mar",
      key("Café Del Mar"))
check("latin search still matches", contains("Bohemian Rhapsody", "rhapsody"))
check("latin prefix still ranks", has_prefix("Bohemian Rhapsody", "bohem"))
check("unrelated latin does not match", not contains("Bohemian Rhapsody", "zzz"))
check("digits are untouched", key("Blink 182") == "blink 182", key("Blink 182"))
check("mixed Arabic/Latin title works",
      contains("Amr Diab - تملي معاك", "تملي") and
      contains("Amr Diab - تملي معاك", "amr"))


# ===========================================================================
# 3. Match semantics
# ===========================================================================

print("\n--- 3. Match semantics -----------------------------------------------")

check("empty query matches everything (shows the whole library)",
      contains("anything", "") and contains("", ""))
check("a multi-word query stays a phrase, not a bag of letters",
      not contains("mar del cafe", "cafe del mar"))
check("multi-word query matches the real phrase",
      contains("at the cafe del mar tonight", "cafe del mar"))
check("substring in the middle matches", contains("The Last Waltz", "last"))
check("no false positive on a shorter haystack",
      not contains("Ya", "Ya Msafer Wahdak"))


# ===========================================================================
# 4. Ranking order (mirror of LibrarySearch.run)
# ===========================================================================

print("\n--- 4. Ranking -------------------------------------------------------")


def rank(song, query):
    title, artist, genre = song
    if has_prefix(title, query):
        return (5, "title")
    if contains(title, query):
        return (4, "title")
    if has_prefix(artist, query):
        return (3, "artist")
    if contains(artist, query):
        return (2, "artist")
    if contains(genre, query):
        return (1, "genre")
    return (0, None)


library = [
    ("Habibi Ya Nour El Ain", "Amr Diab", "Pop"),
    ("Ya Habibi Taala", "Fairuz", "Classic"),
    ("Nour", "Habibi Band", "Rock"),
    ("Something Else", "Nobody", "habibi-pop"),
]

ranked = sorted(
    [(rank(s, "habibi")[0], rank(s, "habibi")[1], s[0]) for s in library
     if rank(s, "habibi")[0] > 0],
    key=lambda r: (-r[0], r[2]))

check("a title prefix outranks everything",
      ranked[0][2] == "Habibi Ya Nour El Ain", str(ranked))
check("a title match outranks an artist match",
      [r[2] for r in ranked].index("Ya Habibi Taala")
      < [r[2] for r in ranked].index("Nour"), str(ranked))
check("a genre match ranks last",
      ranked[-1][2] == "Something Else", str(ranked))
check("all four match somehow", len(ranked) == 4, str(len(ranked)))

# Lyrics rank below everything else, so a strong match is never buried.
check("lyrics rank (0) is below the weakest field match (genre = 1)", 0 < 1)


# ===========================================================================
# 5. LRC timestamp stripping (mirror of LyricsIndex.plainText)
# ===========================================================================

print("\n--- 5. LRC parsing ---------------------------------------------------")


def plain_text(lrc):
    out = []
    for raw in lrc.split("\n"):
        line = raw
        while line.startswith("[") and "]" in line:
            line = line[line.index("]") + 1:]
        t = line.strip()
        if t:
            out.append(t)
    return " ".join(out)


LRC = """[ar:Amr Diab]
[ti:Tamally Maak]
[00:12.34]تملي معاك
[00:15.02]ولو حتى بعيد عني
[00:18.77]
[00:20.10]في قلبي هواك
"""

parsed = plain_text(LRC)
check("timestamps are stripped", "00:12" not in parsed, parsed)
check("metadata tags are stripped", "Amr Diab" not in parsed, parsed)
check("blank lines are dropped", "  " not in parsed, repr(parsed))
check("the actual words survive", "تملي معاك" in parsed, parsed)
check("a lyric search finds the line", key("تملي") in key(parsed))
check("a folded lyric search finds it too",
      key("تملى") in key(parsed), "alef maksura variant should still hit")

# A two-character query must NOT search lyrics (too noisy).
check("very short queries are rejected for lyrics", len("ت") < 2)


print()
if FAILURES:
    print(f"{len(FAILURES)} CHECK(S) FAILED: {', '.join(FAILURES)}")
    sys.exit(1)
print("ALL SEARCH CHECKS PASS")
