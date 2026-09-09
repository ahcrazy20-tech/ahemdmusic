#!/usr/bin/env python3
"""
test_pack6_logic.py — executable checks for the Pack 6 logic that is pure
maths, mirrored from the Swift so it can be verified without a Mac.

The repo already does this for the AI failover chain
(`test_ai_engine_logic.py`); the same reasoning applies here: these are the
decisions that silently corrupt the app's "intelligence" if they are wrong,
and a GitHub Actions round trip costs ten minutes.

Covered:
  1. MusicKey  — Krumhansl-Schmuckler key estimation + Camelot mapping
  2. MusicKey.harmonicDistance — the DJ wheel distances
  3. ListenRecord.affinity — completion-ratio taste signal
  4. recordFinish — the finish/skip thresholds
  5. transitionLength — the auto-DJ blend rules
  6. Equal-power crossfade — constant loudness through the blend

Run:  python3 scripts/test_pack6_logic.py
"""
import math
import sys

FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print(f"PASS  {name}")
    else:
        print(f"FAIL  {name}  {detail}")
        FAILURES.append(name)


# ===========================================================================
# 1. Musical key detection  (mirrors MusicKey in AudioAnalysis.swift)
# ===========================================================================

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
MAJOR_PROFILE = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
MINOR_PROFILE = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]


def correlation(a, b):
    n = len(a)
    ma, mb = sum(a) / n, sum(b) / n
    num = sum((a[i] - ma) * (b[i] - mb) for i in range(n))
    da = sum((x - ma) ** 2 for x in a)
    db = sum((y - mb) ** 2 for y in b)
    den = math.sqrt(da * db)
    return num / den if den > 1e-12 else 0.0


def estimate_key(chroma):
    """-> (tonic, is_major, confidence)"""
    if len(chroma) != 12 or sum(chroma) <= 1e-9:
        return (-1, True, 0.0)
    best = (-1, True, -1e30)
    second = -1e30
    for tonic in range(12):
        for is_major in (True, False):
            profile = MAJOR_PROFILE if is_major else MINOR_PROFILE
            rotated = [profile[(i - tonic + 12) % 12] for i in range(12)]
            score = correlation(chroma, rotated)
            if score > best[2]:
                second = best[2]
                best = (tonic, is_major, score)
            elif score > second:
                second = score
    margin = max(0.0, best[2] - second) if second > -1e30 else 0.0
    return (best[0], best[1], max(0.0, min(1.0, margin * 2.2)))


def camelot(tonic, is_major):
    major_numbers = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    minor_numbers = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
    n = major_numbers[tonic % 12] if is_major else minor_numbers[tonic % 12]
    return f"{n}{'B' if is_major else 'A'}"


def rotate(profile, tonic):
    return [profile[(i - tonic + 12) % 12] for i in range(12)]


print("\n--- 1. Key detection -------------------------------------------------")

t, m, conf = estimate_key(list(MAJOR_PROFILE))
check("C major profile resolves to C major",
      t == 0 and m, f"got {NOTE_NAMES[t]} major={m}")
check("C major maps to Camelot 8B", camelot(t, m) == "8B", camelot(t, m))

t, m, _ = estimate_key(rotate(MINOR_PROFILE, 9))
check("A minor profile resolves to A minor",
      t == 9 and not m, f"got {NOTE_NAMES[t]} major={m}")
check("A minor maps to Camelot 8A", camelot(t, m) == "8A", camelot(t, m))

t, m, _ = estimate_key(rotate(MINOR_PROFILE, 6))
check("F# minor maps to Camelot 11A", camelot(t, m) == "11A", camelot(t, m))

# Every key must round-trip to a distinct Camelot code.
codes = {camelot(t, mm_) for t in range(12) for mm_ in (True, False)}
check("all 24 keys produce unique Camelot codes", len(codes) == 24, str(len(codes)))

# Relative major/minor share a wheel number (C major 8B <-> A minor 8A).
check("relative major/minor share a wheel number",
      camelot(0, True)[:-1] == camelot(9, False)[:-1])

# Percussion / noise must NOT produce a confident key.
_, _, flat_conf = estimate_key([1.0] * 12)
check("flat chroma yields no confident key (<0.18)", flat_conf < 0.18, f"{flat_conf:.3f}")

# A real key must clear the same bar comfortably.
_, _, real_conf = estimate_key(rotate(MAJOR_PROFILE, 7))
check("a clean tonal profile is confident (>=0.18)", real_conf >= 0.18, f"{real_conf:.3f}")

# Detection must survive noise on top of the profile.
noisy = [v + 1.4 for v in rotate(MAJOR_PROFILE, 2)]
t, m, _ = estimate_key(noisy)
check("key survives a DC noise floor", t == 2 and m, f"got {NOTE_NAMES[t]} major={m}")


# ===========================================================================
# 2. Harmonic distance (the wheel)
# ===========================================================================

def parse_camelot(code):
    if len(code) < 2:
        return None
    last = code[-1]
    if last in "Bb":
        is_major = True
    elif last in "Aa":
        is_major = False
    else:
        return None
    try:
        n = int(code[:-1])
    except ValueError:
        return None
    if not 1 <= n <= 12:
        return None
    return (n, is_major)


def harmonic_distance(a, b):
    x, y = parse_camelot(a), parse_camelot(b)
    if x is None or y is None:
        return None
    if x[0] == y[0] and x[1] == y[1]:
        return 0.0
    if x[0] == y[0]:
        return 0.15
    raw = abs(x[0] - y[0])
    steps = min(raw, 12 - raw)
    if steps == 1 and x[1] == y[1]:
        return 0.2
    return min(1.0, 0.3 + steps / 12.0)


print("\n--- 2. Harmonic distance ---------------------------------------------")
check("same key costs nothing", harmonic_distance("8A", "8A") == 0.0)
check("relative major/minor is cheap", harmonic_distance("8A", "8B") == 0.15)
check("one step on the wheel is cheap", harmonic_distance("8A", "9A") == 0.2)
check("wheel wraps 12 -> 1 as one step", harmonic_distance("12A", "1A") == 0.2)
check("distant keys cost more than neighbours",
      harmonic_distance("8A", "2A") > harmonic_distance("8A", "9A"))
check("unknown key returns None (caller falls back)",
      harmonic_distance("", "8A") is None and harmonic_distance("8A", "zz") is None)
check("distance never exceeds 1.0",
      all(harmonic_distance(f"{i}A", f"{j}B") <= 1.0
          for i in range(1, 13) for j in range(1, 13)))
check("distance is symmetric",
      all(harmonic_distance(f"{i}A", f"{j}A") == harmonic_distance(f"{j}A", f"{i}A")
          for i in range(1, 13) for j in range(1, 13)))


# ===========================================================================
# 3 + 4. Listening affinity  (mirrors ListenRecord / recordFinish)
# ===========================================================================

class Record:
    def __init__(self):
        self.plays = 0
        self.finishes = 0
        self.skips = 0
        self.total_seconds = 0.0
        self.disliked = False

    @property
    def affinity(self):
        if self.disliked:
            return -1.0
        f, s = float(self.finishes), float(self.skips)
        n = f + s
        if n < 1:
            return 0.0
        ratio = (f + 1.0) / (n + 2.0)
        confidence = min(1.0, n / 6.0)
        return (ratio * 2 - 1) * confidence

    def record_finish(self, played, duration):
        """Mirrors ListenHistory.recordFinish."""
        if played <= 0.5:
            return
        self.total_seconds += played
        if duration > 1:
            frac = played / duration
            if frac >= 0.6 or played >= 90:
                self.finishes += 1
            elif frac < 0.2:
                self.skips += 1


print("\n--- 3. Completion thresholds -----------------------------------------")

r = Record()
r.record_finish(200, 210)          # played to the end
check("full listen counts as a finish", r.finishes == 1 and r.skips == 0)

r = Record()
r.record_finish(2, 210)            # bailed after 2 s
check("2 s of a 3.5 min song is a skip", r.skips == 1 and r.finishes == 0)

r = Record()
r.record_finish(84, 210)           # 40% — the deliberate middle band
check("40% is neither a finish nor a skip",
      r.finishes == 0 and r.skips == 0)

r = Record()
r.record_finish(120, 2400)         # 2 min of a 40 min mix
check("90 s of a long mix counts as a finish (not 60%)",
      r.finishes == 1, f"finishes={r.finishes}")

r = Record()
r.record_finish(0.2, 210)
check("an accidental tap is ignored entirely",
      r.finishes == 0 and r.skips == 0 and r.total_seconds == 0)

r = Record()
r.record_finish(100, 200)
r.record_finish(50, 200)
check("total listening time accumulates", abs(r.total_seconds - 150) < 1e-9)

print("\n--- 4. Affinity ------------------------------------------------------")

check("no data is neutral", Record().affinity == 0.0)

loved = Record()
for _ in range(9):
    loved.record_finish(200, 210)
check("a song finished 9x scores strongly positive",
      loved.affinity > 0.5, f"{loved.affinity:.2f}")

hated = Record()
for _ in range(9):
    hated.record_finish(3, 210)
check("a song skipped 9x scores strongly negative",
      hated.affinity < -0.5, f"{hated.affinity:.2f}")

one_skip = Record()
one_skip.record_finish(3, 210)
check("a single skip is only a mild signal (smoothing works)",
      -0.35 < one_skip.affinity < 0, f"{one_skip.affinity:.2f}")

disliked = Record()
for _ in range(5):
    disliked.record_finish(200, 210)
disliked.disliked = True
check("an explicit dislike overrides play history",
      disliked.affinity == -1.0, f"{disliked.affinity:.2f}")

check("affinity always stays within -1..+1",
      all(-1.0 <= rec.affinity <= 1.0 for rec in (loved, hated, one_skip, disliked)))

# The bug this whole feature exists to fix.
started_only = Record()
started_only.plays = 20            # 20 starts, every one abandoned instantly
for _ in range(20):
    started_only.record_finish(2, 210)
check("20 starts that were all skipped do NOT look like a loved song",
      started_only.affinity < -0.5, f"{started_only.affinity:.2f}")


# ===========================================================================
# 5. Auto-DJ blend length  (mirrors transitionLength)
# ===========================================================================

def transition_length(a, b, base=4.0, auto=True):
    if not auto:
        return base
    if a is None or b is None:
        return min(base, 3.0)
    beatish = min(a["beat"], b["beat"])
    tempo_gap = abs(a["tempo"] - b["tempo"])
    energy_gap = abs(a["energy"] - b["energy"])
    secs = base
    if beatish < 0.25:
        secs = min(secs, 2.5)
    if tempo_gap > 24:
        secs = min(secs, 3.0)
    if energy_gap > 0.35:
        secs = min(secs, 3.0)
    if b["instrumental"] and a["vocal_forward"]:
        secs = min(secs, 3.5)
    if beatish > 0.45 and tempo_gap < 8 and energy_gap < 0.18:
        secs = min(12.0, max(secs, base * 1.5))
    return max(1.5, secs)


def track(beat=0.5, tempo=120, energy=0.6, instrumental=False, vocal_forward=False):
    return dict(beat=beat, tempo=tempo, energy=energy,
                instrumental=instrumental, vocal_forward=vocal_forward)


print("\n--- 5. Auto-DJ blend length ------------------------------------------")

two_bangers = transition_length(track(0.6, 128, 0.7), track(0.6, 130, 0.72))
check("two matched club tracks get a long blend",
      two_bangers > 4.0, f"{two_bangers:.1f}s")

into_quiet = transition_length(track(0.6, 128, 0.8), track(0.1, 70, 0.2))
check("banger into a quiet track gets a short blend",
      into_quiet <= 3.0, f"{into_quiet:.1f}s")

rubato = transition_length(track(0.05, 90, 0.4), track(0.05, 95, 0.4))
check("two rubato/spoken tracks get the shortest blend",
      rubato <= 2.5, f"{rubato:.1f}s")

unknown = transition_length(None, track())
check("unmeasured tracks fall back to a safe short blend",
      unknown <= 3.0, f"{unknown:.1f}s")

check("blend is never below the 1.5 s floor",
      all(transition_length(track(b, t, e), track(b2, t2, e2)) >= 1.5
          for b in (0.0, 0.5) for t in (60, 180) for e in (0.0, 1.0)
          for b2 in (0.0, 0.5) for t2 in (60, 180) for e2 in (0.0, 1.0)))

check("blend never exceeds the 12 s ceiling",
      all(transition_length(track(0.9, 128, 0.7), track(0.9, 128, 0.7), base=b) <= 12.0
          for b in (1.5, 4.0, 8.0, 12.0)))

fixed = transition_length(track(0.05, 90, 0.1), track(0.9, 180, 0.9), auto=False)
check("plain crossfade ignores the audio and uses the set length",
      fixed == 4.0, f"{fixed:.1f}s")


# ===========================================================================
# 6. Equal-power crossfade curve
# ===========================================================================

print("\n--- 6. Crossfade curve -----------------------------------------------")

def curve(t):
    return (math.cos(t * math.pi / 2), math.sin(t * math.pi / 2))

start_out, start_in = curve(0.0)
end_out, end_in = curve(1.0)
check("fade starts with the outgoing track at full volume",
      abs(start_out - 1.0) < 1e-9 and abs(start_in) < 1e-9)
check("fade ends with the incoming track at full volume",
      abs(end_out) < 1e-9 and abs(end_in - 1.0) < 1e-9)

powers = [curve(i / 100)[0] ** 2 + curve(i / 100)[1] ** 2 for i in range(101)]
check("total power stays constant through the blend (no volume dip)",
      all(abs(p - 1.0) < 1e-9 for p in powers),
      f"min={min(powers):.4f} max={max(powers):.4f}")

# A naive linear fade would dip to 0.5 power at the midpoint — the reason
# equal-power is used at all.
linear_mid = 0.5 ** 2 + 0.5 ** 2
check("equal-power beats a linear fade at the midpoint",
      abs(curve(0.5)[0] ** 2 + curve(0.5)[1] ** 2 - 1.0) < 1e-9 and linear_mid < 0.75)

check("both gains stay within 0..1 for the whole fade",
      all(0.0 <= v <= 1.0 for i in range(101) for v in curve(i / 100)))


# ===========================================================================

print()
if FAILURES:
    print(f"{len(FAILURES)} CHECK(S) FAILED: {', '.join(FAILURES)}")
    sys.exit(1)
print("ALL PACK 6 LOGIC CHECKS PASS")
