#!/usr/bin/env python3
"""
test_widget_logic.py — checks for the widget bridge that don't need a Mac.

The widget is the one feature here that spans two processes and two build
targets, so the failure modes are structural rather than algorithmic:

  * the app and the widget disagreeing about the App Group id, the URL scheme
    or a link's shape — each of which turns every widget tap into a no-op;
  * onOpenURL routing a widget link into the audio importer (they arrive
    through the same callback);
  * the generated XcodeGen spec being subtly wrong, which costs a full CI
    round trip to discover.

Run:  python3 scripts/test_widget_logic.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
APP = os.path.join(ROOT, "TrollMusicApp", "TrollMusicApp")
WIDGET = os.path.join(ROOT, "TrollMusicApp", "ASMusicWidget")
CI = os.path.join(ROOT, "scripts", "ci_build.sh")

FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print(f"PASS  {name}")
    else:
        print(f"FAIL  {name}  {detail}")
        FAILURES.append(name)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


# ===========================================================================
# 1. Deep links: mirror of WidgetLink, then assert the round trip
# ===========================================================================

SCHEME = "asmusic"


def link_for(action, arg=None):
    if action == "moment":
        return f"{SCHEME}://moment/{arg}"
    return f"{SCHEME}://{action}"


def parse(url):
    """Mirror of WidgetLink.action(from:)."""
    m = re.match(r"^([a-zA-Z][\w+.-]*)://([^/?#]*)(/[^?#]*)?", url)
    if not m:
        return None
    scheme, host, path = m.group(1).lower(), m.group(2).lower(), m.group(3) or ""
    if scheme != SCHEME:
        return None
    if host in ("nowplaying", "playpause", "next", "previous"):
        return (host, None)
    if host == "moment":
        kind = [c for c in path.split("/") if c]
        return ("moment", kind[0].lower()) if kind else None
    return None


print("\n--- 1. Deep link round trip ------------------------------------------")

for act in ("nowplaying", "playpause", "next", "previous"):
    check(f"{act} link round-trips", parse(link_for(act)) == (act, None),
          str(parse(link_for(act))))

check("moment link carries its kind",
      parse(link_for("moment", "gym")) == ("moment", "gym"),
      str(parse(link_for("moment", "gym"))))

# The important negative: a file URL must NOT look like a widget link, or
# onOpenURL would route an imported song into the transport controls.
check("file:// URL is not a widget link",
      parse("file:///var/mobile/song.mp3") is None)
check("https:// URL is not a widget link",
      parse("https://example.com/nowplaying") is None)
check("unknown asmusic host is rejected",
      parse("asmusic://destroy-everything") is None)
check("moment with no kind is rejected",
      parse("asmusic://moment") is None and parse("asmusic://moment/") is None)
check("scheme match is case-insensitive",
      parse("ASMUSIC://NowPlaying") == ("nowplaying", None))


# ===========================================================================
# 2. The two targets must agree
# ===========================================================================

print("\n--- 2. App / widget agreement ----------------------------------------")

shared = read(os.path.join(APP, "SharedNowPlaying.swift"))

m = re.search(r'appGroupID\s*=\s*"([^"]+)"', shared)
group_id = m.group(1) if m else None
check("App Group id is declared once, in the shared file", group_id is not None,
      "not found")

m = re.search(r'static let scheme\s*=\s*"([^"]+)"', shared)
check("URL scheme is declared in the shared file", m and m.group(1) == SCHEME,
      m.group(1) if m else "not found")

ci = read(CI)
if group_id:
    # Both targets need the entitlement, so the id must appear at least twice
    # in the generated spec (app + widget).
    n = ci.count(group_id)
    check("App Group id appears in the CI spec for BOTH targets", n >= 2,
          f"found {n} occurrence(s)")

    for name, path in (("app", os.path.join(APP, "TrollMusicApp.entitlements")),
                       ("widget", os.path.join(WIDGET, "ASMusicWidget.entitlements"))):
        if os.path.exists(path):
            check(f"{name} entitlements file grants the same group",
                  group_id in read(path))
        else:
            check(f"{name} entitlements file exists", False, path)

check("asmusic scheme is registered in CFBundleURLTypes",
      "CFBundleURLSchemes" in ci and SCHEME in ci)

# Every link the widget builds must be one the app can parse.
widget_src = read(os.path.join(WIDGET, "ASMusicWidget.swift"))
used_actions = set(re.findall(r"WidgetLink\.Action\.(\w+)", widget_src))
used_actions |= set(re.findall(r"action:\s*\.(\w+)", widget_src))
known = {"openNowPlaying", "playPause", "next", "previous", "moment"}
unknown = used_actions - known
check("widget only builds links the app knows how to handle",
      not unknown, f"unknown: {unknown}")

# And the app must actually route them.
bridge = read(os.path.join(APP, "WidgetBridge.swift"))
for case in sorted(known):
    check(f"router handles .{case}", f"case .{case}" in bridge)


# ===========================================================================
# 3. Widget moments must map to real smart-playlist recipes
# ===========================================================================

print("\n--- 3. Moments map to real recipes -----------------------------------")

widget_moments = set(re.findall(r'WidgetMoment\(id:\s*"([^"]+)"', shared))
check("widget defines moments", len(widget_moments) >= 4, str(widget_moments))

playlists = read(os.path.join(APP, "SmartPlaylists.swift"))
voice = read(os.path.join(APP, "VoiceRemote.swift"))
# recipeKind in VoiceRemote is the canonical list of moment keys.
recipe_kinds = set(re.findall(r'return "([a-z]+)"', voice))
unknown = {m for m in widget_moments if m not in recipe_kinds and f'"{m}"' not in playlists}
check("every widget moment matches a known recipe kind",
      not unknown, f"unmatched: {unknown}")


# ===========================================================================
# 4. Widget target isolation
# ===========================================================================

print("\n--- 4. Widget target isolation ---------------------------------------")

# The widget compiles ONLY its own sources + SharedNowPlaying.swift. If it
# references an app type, it will not link.
app_only_types = ["MusicManager", "SmartPlaylistEngine", "AudioLab", "AppTheme",
                  "DownloadCenter", "ListenHistory", "VocalStudio"]
leaked = [t for t in app_only_types if re.search(rf"\b{t}\b", widget_src)]
check("widget does not reference app-only types", not leaked, f"leaked: {leaked}")

# Conversely the shared file must not drag the app's frameworks into the
# widget process.
bad_imports = [i for i in re.findall(r"^import (\w+)", shared, re.M)
               if i in ("AVFoundation", "WidgetKit", "MediaPlayer", "Combine")]
check("shared file imports nothing target-specific", not bad_imports,
      f"imports: {bad_imports}")

check("shared file is compiled into the widget target",
      "SharedNowPlaying.swift" in ci)

# WidgetBridge is app-only and must NOT be in the widget's source list.
m = re.search(r"ASMusicWidgetExtension:.*?(?=\n  \w|\nYAML)", ci, re.S)
widget_block = m.group(0) if m else ""
check("app-only WidgetBridge.swift is not in the widget target",
      "WidgetBridge.swift" not in widget_block)


# ===========================================================================
# 5. iOS 16 deployment target
# ===========================================================================

print("\n--- 5. iOS 16 compatibility ------------------------------------------")

def strip_swift_comments(src):
    """Drop // and /* */ so a comment ABOUT an API isn't read as a use of it."""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


widget_code = strip_swift_comments(widget_src)

# Button(intent:) is iOS 17+. On a 16.0 target it must not appear at all.
check("no Button(intent:) — that API is iOS 17+",
      "Button(intent:" not in widget_code)

# containerBackground is iOS 17+ and must be behind an availability check.
if "containerBackground" in widget_code:
    idx = widget_code.index("containerBackground")
    window = widget_code[max(0, idx - 300):idx]
    check("containerBackground is guarded by #available",
          "#available(iOS 17" in window)

# The widget target's deployment target must match the app's.
check("widget target deploys to iOS 16.0",
      re.search(r'ASMusicWidgetExtension:.*?deploymentTarget:\s*"16\.0"', ci, re.S) is not None)


# ===========================================================================
# 6. Generated XcodeGen spec
# ===========================================================================

print("\n--- 6. XcodeGen spec -------------------------------------------------")

m = re.search(r"cat << 'YAML' > project\.yml\n(.*?)\nYAML\n", ci, re.S)
check("project.yml block is extractable from ci_build.sh", m is not None)

if m:
    spec_text = m.group(1)
    try:
        import yaml
        spec = yaml.safe_load(spec_text)
        check("project.yml is valid YAML", True)
        targets = spec.get("targets", {})
        check("both targets are declared",
              {"TrollMusicApp", "ASMusicWidgetExtension"} <= set(targets),
              str(list(targets)))

        app_t = targets.get("TrollMusicApp", {})
        wid_t = targets.get("ASMusicWidgetExtension", {})

        deps = app_t.get("dependencies") or []
        check("the app embeds the widget extension",
              any(d.get("target") == "ASMusicWidgetExtension" and d.get("embed")
                  for d in deps), str(deps))
        check("widget is an app-extension target",
              wid_t.get("type") == "app-extension", str(wid_t.get("type")))
        check("widget bundle id is nested under the app's",
              str(wid_t.get("settings", {}).get("PRODUCT_BUNDLE_IDENTIFIER", ""))
              .startswith("com.ahmedsoliman.trollmusicapp."),
              str(wid_t.get("settings", {}).get("PRODUCT_BUNDLE_IDENTIFIER")))
        check("widget declares the WidgetKit extension point",
              wid_t.get("info", {}).get("properties", {})
              .get("NSExtension", {})
              .get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension")
        # PyYAML coerces unquoted YES/NO to booleans, so compare loosely.
        def truthy(v):
            return str(v).strip().upper() in ("YES", "TRUE", "1")

        def falsy(v):
            return str(v).strip().upper() in ("NO", "FALSE", "0")

        check("widget skips install (it ships inside the app)",
              truthy(wid_t.get("settings", {}).get("SKIP_INSTALL")),
              repr(wid_t.get("settings", {}).get("SKIP_INSTALL")))
        # Signing must stay off for both, or CI can't archive.
        for tname, t in (("app", app_t), ("widget", wid_t)):
            st = t.get("settings", {})
            check(f"{tname} keeps code signing disabled",
                  falsy(st.get("CODE_SIGNING_ALLOWED", "NO")),
                  repr(st.get("CODE_SIGNING_ALLOWED")))
    except ImportError:
        print("SKIP  YAML parsing (pyyaml not installed)")


print()
if FAILURES:
    print(f"{len(FAILURES)} CHECK(S) FAILED: {', '.join(FAILURES)}")
    sys.exit(1)
print("ALL WIDGET CHECKS PASS")
