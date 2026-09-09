#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ID3v2.4 tag writer checks.

The tag writer emits raw bytes. A wrong byte doesn't crash and doesn't fail
the build -- the file just reads back wrong in OTHER apps, which is somewhere
we never look. That is exactly how the encoding-byte bug below survived: the
frames were written without the mandatory text-encoding byte, so every reader
consumed the BOM's 0xFF as the encoding and then parsed the text one byte out
of alignment. Arabic titles, where every character is multi-byte, came out
mangled.

So this file mirrors the byte layout of ID3TagWriter.swift, builds a real tag,
and parses it back with an INDEPENDENT reader that asserts the spec's rules.
It also greps the Swift to make sure the mirror hasn't drifted from the source.
"""

import pathlib
import re
import sys

FAILURES = []
CHECKS = 0


def check(label, cond, detail=""):
    global CHECKS
    CHECKS += 1
    if cond:
        print(f"PASS  {label}")
    else:
        print(f"FAIL  {label}" + (f"\n        {detail}" if detail else ""))
        FAILURES.append(label)


def section(t):
    print(f"\n=== {t} ===")


# ---------------------------------------------------------------------------
# Mirror of the Swift byte builders
# ---------------------------------------------------------------------------

def syncsafe(n):
    """ID3v2 sizes are 4 bytes of 7 bits each -- the high bit is always 0."""
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])


def utf16_bom(s):
    return b"\xff\xfe" + s.encode("utf-16-le")


def text_frame(fid, text):
    if not text.strip():
        return b""
    payload = b"\x01" + utf16_bom(text)          # 0x01 = UTF-16 with BOM
    return fid.encode()[:4] + syncsafe(len(payload)) + b"\x00\x00" + payload


def txxx_frame(name, value):
    if not value.strip():
        return b""
    payload = b"\x01" + utf16_bom(name) + b"\x00\x00" + utf16_bom(value)
    return b"TXXX" + syncsafe(len(payload)) + b"\x00\x00" + payload


def pic_frame(jpeg):
    payload = b"\x00" + b"image/jpeg" + b"\x00" + b"\x03" + b"\x00" + jpeg
    return b"APIC" + syncsafe(len(payload)) + b"\x00\x00" + payload


def build_tag(frames):
    payload = b"".join(frames)
    return b"ID3" + bytes([4, 0x10, 0]) + syncsafe(len(payload)) + payload


# ---------------------------------------------------------------------------
# Independent reader -- deliberately NOT sharing code with the builders
# ---------------------------------------------------------------------------

def unsync(b):
    return (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3]


def split_at_utf16_null(buf):
    """Split at the first U+0000 CODE UNIT, honouring 2-byte alignment.

    Splitting on a raw b'\\x00\\x00' byte pair is wrong: plenty of ordinary
    UTF-16 characters contain a zero byte, so an unaligned search cuts a
    character in half.
    """
    for i in range(0, len(buf) - 1, 2):
        if buf[i] == 0 and buf[i + 1] == 0:
            return buf[:i], buf[i + 2:]
    return buf, b""


def parse(data):
    if data[:3] != b"ID3":
        raise ValueError("no ID3 identifier")
    size = unsync(data[6:10])
    pos, end = 10, 10 + size
    out = {}
    encodings = {}
    while pos < end - 10:
        fid = data[pos:pos + 4].decode("latin-1")
        if not fid.strip("\x00"):
            break
        fsize = unsync(data[pos + 4:pos + 8])
        body = data[pos + 10:pos + 10 + fsize]
        pos += 10 + fsize
        if not body:
            continue
        enc, raw = body[0], body[1:]
        encodings[fid] = enc
        if fid == "TXXX":
            nb, vb = split_at_utf16_null(raw)
            key = "TXXX:" + nb.decode("utf-16-le").lstrip("\ufeff")
            out[key] = vb.decode("utf-16-le").lstrip("\ufeff")
            encodings[key] = enc
        elif fid == "APIC":
            # enc byte, MIME (null-terminated), picture type, description
            # (null-terminated), then the image itself.
            mime_end = body.index(b"\x00", 1)
            desc_end = body.index(b"\x00", mime_end + 2)
            out[fid] = body[desc_end + 1:]
        else:
            # A frame written WITHOUT its encoding byte leaves the payload
            # misaligned; report that instead of raising.
            try:
                out[fid] = raw.decode("utf-16-le").lstrip("\ufeff")
            except UnicodeDecodeError:
                out[fid] = None
    return out, encodings, size


# ---------------------------------------------------------------------------
section("a full tag round-trips")
# ---------------------------------------------------------------------------

TITLE = "تملي معاك"          # Arabic: every character is multi-byte
ARTIST = "Amr Diab"
ALBUM = "Akter Wahed"
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 600 + b"\xff\xd9"

frames = [
    text_frame("TIT2", TITLE),
    text_frame("TPE1", ARTIST),
    text_frame("TALB", ALBUM),
    pic_frame(JPEG),
    text_frame("TBPM", "128"),
    text_frame("TKEY", "8A"),
    txxx_frame("INITIALKEY", "8A"),
    txxx_frame("KEY", "A minor"),
    txxx_frame("REPLAYGAIN_TRACK_GAIN", "%+.2f dB" % -3.25),
]
tag = build_tag(frames)
audio = b"\xff\xfb\x90\x00" * 128            # stand-in MPEG audio frames
fields, encs, declared = parse(tag + audio)

check("the Arabic title survives byte-for-byte", fields.get("TIT2") == TITLE,
      f"got {fields.get('TIT2')!r}")
check("artist and album survive",
      fields.get("TPE1") == ARTIST and fields.get("TALB") == ALBUM)
check("the declared tag size matches the real frame bytes",
      declared == len(tag) - 10, f"declared {declared}, actual {len(tag) - 10}")
check("audio frames follow the tag untouched",
      (tag + audio)[10 + declared:][:2] == b"\xff\xfb")
check("the cover art round-trips intact", fields.get("APIC") == JPEG)

# ---------------------------------------------------------------------------
section("the encoding byte -- the bug this file exists for")
# ---------------------------------------------------------------------------

check("every text frame declares UTF-16 (0x01)",
      all(encs[f] == 0x01 for f in ("TIT2", "TPE1", "TALB", "TBPM", "TKEY")),
      f"{ {k: hex(v) for k, v in encs.items()} }")
check("APIC declares ISO-8859-1 (0x00) for its MIME/description",
      encs.get("APIC") == 0x00)
check("no text frame starts straight at the BOM",
      not any(f.startswith(b"\xff\xfe") for f in frames if f[:4] != b"APIC"))

# A tag built the OLD way must be detected as broken by this same reader --
# proof the check above can actually fail.
bad = build_tag([b"TIT2" + syncsafe(len(utf16_bom(TITLE))) + b"\x00\x00" + utf16_bom(TITLE)])
_, bad_encs, _ = parse(bad + audio)
check("the pre-fix layout is caught (reads 0xFF as its encoding)",
      bad_encs.get("TIT2") == 0xFF, f"got {hex(bad_encs.get('TIT2', 0))}")

# ---------------------------------------------------------------------------
section("analysis frames")
# ---------------------------------------------------------------------------

check("BPM is a plain integer string", fields.get("TBPM") == "128")
check("TKEY carries the Camelot code", fields.get("TKEY") == "8A")
check("TXXX:INITIALKEY matches TKEY (what DJ software reads)",
      fields.get("TXXX:INITIALKEY") == "8A")
check("TXXX:KEY carries the human-readable key",
      fields.get("TXXX:KEY") == "A minor")
check("ReplayGain uses the conventional signed dB form",
      fields.get("TXXX:REPLAYGAIN_TRACK_GAIN") == "-3.25 dB",
      repr(fields.get("TXXX:REPLAYGAIN_TRACK_GAIN")))
check("a positive gain keeps its + sign", ("%+.2f dB" % 2.5) == "+2.50 dB")

# TXXX name and value must stay separable even when the NAME contains a
# character whose UTF-16 encoding includes a zero byte.
tricky = txxx_frame("KEY", "مقام")
f2, _, _ = parse(build_tag([tricky]) + audio)
check("a TXXX value in Arabic still splits from its name",
      f2.get("TXXX:KEY") == "مقام", repr(f2))

# ---------------------------------------------------------------------------
section("empty values are omitted, not written blank")
# ---------------------------------------------------------------------------

check("an empty text frame produces no bytes", text_frame("TALB", "") == b"")
check("a whitespace-only text frame produces no bytes",
      text_frame("TALB", "   ") == b"")
check("an empty TXXX produces no bytes", txxx_frame("KEY", "") == b"")

# ---------------------------------------------------------------------------
section("syncsafe integers")
# ---------------------------------------------------------------------------

check("no byte ever has its high bit set",
      all(b < 0x80 for n in (0, 1, 127, 128, 4096, 999999) for b in syncsafe(n)))
check("syncsafe round-trips", all(unsync(syncsafe(n)) == n
                                  for n in (0, 1, 127, 128, 255, 4096, 999999)))
check("a 200 KB cover art size still encodes",
      unsync(syncsafe(200_000)) == 200_000)

# ---------------------------------------------------------------------------
section("the Swift source still matches this mirror")
# ---------------------------------------------------------------------------

SRC = pathlib.Path(__file__).resolve().parents[1] / \
    "TrollMusicApp/TrollMusicApp/ID3TagWriter.swift"
swift = SRC.read_text(encoding="utf-8") if SRC.exists() else ""
check("ID3TagWriter.swift is present", bool(swift))

if swift:
    body = re.sub(r"//[^\n]*", "", swift)
    def swift_func(name, src):
        """Return a function body by brace-matching, not by regex."""
        i = src.find("func " + name)
        if i < 0:
            return ""
        j = src.find("{", i)
        depth = 0
        for k in range(j, len(src)):
            if src[k] == "{":
                depth += 1
            elif src[k] == "}":
                depth -= 1
                if depth == 0:
                    return src[i:k + 1]
        return src[i:]

    tf = swift_func("textFrame", body)
    check("textFrame writes the encoding byte before the BOM",
          "Data([0x01])" in tf and
          tf.index("Data([0x01])") < tf.index("utf16BOM"),
          "textFrame must start its payload with 0x01, before the BOM")
    check("a TXXX builder exists", "func txxxFrame" in body)
    check("TXXX separates name and value with a UTF-16 null",
          bool(re.search(r"txxxFrame.*?Data\(\[0x00, 0x00\]\)", body, re.S)))
    check("the analysis struct is threaded through tagIfNeeded",
          "analysis: Analysis = Analysis()" in body)
    check("ReplayGain is written under its conventional name",
          "REPLAYGAIN_TRACK_GAIN" in body)
    check("pre-tagged files are still skipped",
          "0x49, 0x44, 0x33" in body)
    check("the writer only touches mp3s",
          'pathExtension.lowercased() == "mp3"' in body)

    lab = SRC.parent / "AudioAnalysis.swift"
    if lab.exists():
        lt = re.sub(r"//[^\n]*", "", lab.read_text(encoding="utf-8"))
        check("write-back is opt-in via UserDefaults",
              "UserDefaults.standard.bool(forKey: Self.writeBackKey)" in lt)
        check("write-back refuses an untrustworthy tempo",
              re.search(r"beatStrength\s*>\s*0\.1", lt) is not None)
        check("write-back skips silent files rather than inventing a gain",
              re.search(r"loudness\s*>\s*-60", lt) is not None)

print()
if FAILURES:
    print(f"{len(FAILURES)} CHECK(S) FAILED out of {CHECKS}:")
    for f in FAILURES:
        print("  -", f)
    sys.exit(1)
print(f"ALL {CHECKS} ID3 CHECKS PASS")
