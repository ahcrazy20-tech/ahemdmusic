# AS Music — Pack 5 (Sept 2026): Settings tab + APInex multi-model AI + never-stop failover

Everything here is **additive and switch-off-safe**: with no key and no provider
selected the app behaves exactly as before (on-device AI only, nothing sent
anywhere), and every feature that can run on-device still does.

---

## 1. ⚙️ The new Settings tab

A sixth tab (gear icon) now holds **every setting the app has**, in one place:

| Section | What's in it |
|---|---|
| **AI Intelligence** | provider picker (On-device / APInex / Gemini), key fields, model picker with live list + FREE badges, custom model id, Auto-failover toggle, "Test key now", "Refresh model list" |
| **Voice control** | the same voice section that lived in Audio settings (talk-back, announcements, speech rate) |
| **Audio & Playback** | pushes to the existing EQ screen (presets, loudness boost, spatial, resume) |
| **Appearance** | accent color / theme picker |
| **Downloads** | pushes to Download Engines (Piped / Invidious / Cobalt / your server, health, mirrors) |
| **Library tools** | Backup & restore, Health report, Duplicate finder, Recently deleted, Name tidy-up, Artists browser |
| **About** | version, song count, active AI provider + model |

Anywhere the app used to say *"add a Gemini key in Audio Settings"* is now a
**tap-to-open** hint that jumps straight to the Settings tab
(`NotificationCenter .openAISettings`): the For-You AI card, the playlist
generator footer, the Discover key sheet, the duplicate-doctor message, the
name-tidy message and the EQ screen.

The Magic DL toolbar gear still opens Download Engines directly (that's where
downloads are configured); the same screen is also reachable from Settings.

## 2. 🧠 APInex — one key, 20+ models (`apinex.bond`)

The platform you asked about is **APInex** (`https://apinex.bond`, API root
`https://api.apinex.bond/v1`). It's OpenAI-compatible, one key (`sk-apx…`)
unlocks models from OpenAI, Anthropic, Google, Moonshot, DeepSeek, Zhipu and
xAI — **including free tiers**:

- `free/glm-5.3-flash`, `free/gpt-5.6-luna`, `free/gemini-3.8-flash`,
  `free/muse-spark-1.3`, `free/qwen-3.8-max`, `free/deepseek-v4-flash-0731`…
- cheap paid ones from $0.05/1M (`deepseek/v4-flash`, `glm/5.3-flash`,
  `gpt/5.6-luna`, `gemini/3.8-flash`…)

**Setup (in the app): Settings → AI Intelligence → "APInex · many models" →
paste key → Test key now.** The model list refreshes live from the platform
(`GET /v1/models`); the bundled snapshot works offline. Get the key at
apinex.bond → register → dashboard → create key.

What runs through it (when APInex is the active provider):
song-suggestion requests in For You ("5 new Wegz songs"), "describe a
playlist" AI naming/ranking, duplicate-copy AI review, and AI name tidy-up.
All of them already had on-device fallbacks — APInex just makes the cloud
answers smarter and free.

Keys are stored only on this device (UserDefaults) and are only ever sent to
`api.apinex.bond` (APInex) or `generativelanguage.googleapis.com` (Gemini).
Nothing else is attached. No key → no network AI at all.

## 3. 🛡️ "Never stop" — the failover chain

One request now walks a chain (SmartKit.swift `GeminiAI.buildChain` /
`runChat`):

```
chosen model of the chosen provider
  → next models of the same provider   (APInex: FREE tiers first;
                                        Gemini: verified fallbacks)
  → the OTHER provider, if it has a key
  → on-device engine (always the last resort)
```

Rules, all silent to the user (max 8 attempts, hard cap):

- **model retired / 404 / unknown** → next model in the chain
- **rate limit (429) / 5xx / network error / empty reply** → next model
- **key rejected (401/403)** → skip the *rest of that provider* (rotating
  models can't fix a wrong key) and cross to the other provider
- **whichever model actually answered becomes the stored model**
  (self-healing, same idea the Gemini Auto-model already had)
- **Auto-failover toggle OFF** → exactly one attempt, error shown (old
  behaviour); ON by default

Gemini-only self-healing (`GeminiDiscovery`) is unchanged and still consults
the remote registry.

## 4. 🐛 Hidden bugs found & fixed in this pack

1. **`completeJSON` had no self-healing at all** — `ask()` (song requests)
   could rotate to a newer model when Google retired one, but the four other
   AI features (playlists, duplicates, name tidy, ExtrasKit) failed
   permanently on the first retired/bad model id. All of them now share the
   same never-stop chain. *(SmartKit.swift)*
2. **Stale settings pointers** — six user-facing strings still told people to
   paste keys into "Audio Settings" (the EQ sheet), which no longer hosts
   them; one even advertised the wrong default model (`gemini-2.5-flash` vs
   the real `gemini-3.5-flash`). All now point at Settings → AI Intelligence
   and name the active provider/model. *(Views, DiscoverView, ExtrasKit,
   LibraryDoctor)*
3. **APInex `message.content` can be an array of parts** (models that return
  reasoning/content blocks) — the parser accepts both shapes plus
   `{error:{message}}` and bare `{message}` error bodies, and treats
   "200 but empty content" as a rotation trigger instead of a dead end.
   *(AICore.swift)*
4. **Key-paste UX**: pasting an APInex or Gemini key while "On-device only"
   is selected now switches the provider automatically instead of silently
   keeping the key unused. *(SmartKit.swift)*
5. The full failover logic is now **regression-tested on any machine** —
   `scripts/test_ai_engine_logic.py` mirrors the Swift chain decision-for-
   decision and runs 38 scenarios (retired model, rejected key, rate limit,
   empty reply, all-dead bound, failover-off). All pass.

## 5. New / changed files

```
TrollMusicApp/TrollMusicApp/AICore.swift        NEW  providers, catalog, transport, key tests
TrollMusicApp/TrollMusicApp/SmartKit.swift           GeminiAI → multi-provider engine + failover chain
TrollMusicApp/TrollMusicApp/Views.swift              Settings tab + AI section + tab wiring + hints
TrollMusicApp/TrollMusicApp/DiscoverView.swift       provider-aware key setup sheet
TrollMusicApp/TrollMusicApp/ExtractorKit.swift       registry: preferredApinexModel / apinexFallbacks
TrollMusicApp/TrollMusicApp/LibraryDoctor.swift      message + comment fixes
TrollMusicApp/TrollMusicApp/ExtrasKit.swift          message fix
TrollMusicApp/TrollMusicApp/SmartPlaylists.swift     comment fixes
TrollMusicApp/TrollMusicApp/VoiceRemote.swift        comment fix
backend-registry.json                           apinex model defaults (edit WITHOUT rebuilding)
scripts/test_ai_engine_logic.py                 NEW  38-scenario failover test (python3, no Mac)
```

`backend-registry.json` now also carries the APInex fallback order, so a dead
model id can be fixed for every installed phone by editing one file — no
rebuild, same as the mirror lists.

## 6. Checks

- `python3 scripts/check_swift_syntax.py` → **structure OK in 22 files**
  (includes the cross-file symbol check)
- `python3 scripts/test_ai_engine_logic.py` → **38/38 PASS**
- Live API smoke test of api.apinex.bond from this sandbox: not possible
  (the sandbox's egress blocks that host), so use **Settings → Test key now**
  on the phone — it reports key validity, balance and model count.

CI is unchanged: `scripts/ci_build.sh` picks up new files automatically
(XcodeGen compiles the whole folder). If `.github/workflows/build.yml` is
already the short one from SETUP_ONCE.md, nothing else to do.
