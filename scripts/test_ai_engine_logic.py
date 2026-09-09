#!/usr/bin/env python3
"""
Simulates the Swift failover engine (GeminiAI.buildChain / runChat +
AITransport response parsing) against realistic API payloads, to catch
logic bugs without a Mac. Mirrors the Swift code path-for-path.
"""
import json, sys

FAILS = []

def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ((" — " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)

# ---------------- AITransport parsing mirrors ----------------

def openai_content_text(j):
    choices = j.get("choices")
    if not isinstance(choices, list) or not choices:
        return None
    msg = choices[0].get("message")
    if not isinstance(msg, dict):
        return None
    c = msg.get("content")
    if isinstance(c, str):
        return c or None
    if isinstance(c, list):
        t = "\n".join(p.get("text", "") for p in c if isinstance(p, dict))
        return t or None
    return None

def gemini_content_text(j):
    cands = j.get("candidates")
    if not isinstance(cands, list) or not cands:
        return None
    content = cands[0].get("content")
    if not isinstance(content, dict):
        return None
    parts = content.get("parts")
    if not isinstance(parts, list):
        return None
    t = "\n".join(p.get("text", "") for p in parts if isinstance(p, dict))
    return t or None

def api_error_message(j):
    e = j.get("error")
    if isinstance(e, dict) and isinstance(e.get("message"), str):
        return e["message"][:160]
    if isinstance(j.get("message"), str):
        return j["message"][:160]
    return None

def is_model_gone(status, message):
    if status == 404:
        return True
    m = (message or "").lower()
    if "model" not in m:
        return False
    return any(k in m for k in ("not found", "not exist", "unknown", "invalid",
                                "retired", "deprecated", "unsupported", "removed", "unavailable"))

def is_key_rejected(status):
    return status in (401, 403)

def parse_model_ids(j):
    data = j.get("data")
    if not isinstance(data, list):
        return None
    ids = [d.get("id") for d in data if isinstance(d, dict) and d.get("id")]
    return ids or None

def balance_string(j):
    for k in ("balance_usd", "balance", "usd", "credits"):
        if k in j:
            v = j[k]
            if isinstance(v, (int, float)):
                return f"${v:.2f}"
            if isinstance(v, str) and v:
                return v
    return None

# ---------------- GeminiAI chain mirrors ----------------

class Cfg:
    def __init__(self, provider, auto_failover=True, auto_model=True,
                 gemini_key="", gemini_model="gemini-3.5-flash",
                 apinex_key="", apinex_model="free/glm-5.3-flash",
                 gemini_fallbacks=None, apinex_fallbacks=None):
        self.provider = provider
        self.auto_failover = auto_failover
        self.auto_model = auto_model
        self.gemini_key = gemini_key
        self.gemini_model = gemini_model
        self.apinex_key = apinex_key
        self.apinex_model = apinex_model
        self.gemini_fallbacks = gemini_fallbacks or ["gemini-3.5-flash", "gemini-3.6-flash", "gemini-2.5-flash"]
        self.apinex_fallbacks = apinex_fallbacks or [
            "free/glm-5.3-flash", "free/gpt-5.6-luna", "free/gemini-3.8-flash",
            "gemini/3.8-flash", "deepseek/v4-flash"]

def build_chain(c):
    out = []
    def push(p):
        if len(out) >= 8:
            return
        if p == "onDevice":
            return
        if p == "gemini":
            k = c.gemini_key.strip()
            if not k:
                return
            models = [c.gemini_model] + (c.gemini_fallbacks if c.auto_model else [])
            for m in models:
                if not m:
                    continue
                if any(a["provider"] == "gemini" and a["model"] == m for a in out):
                    continue
                out.append({"provider": "gemini", "model": m, "key": k})
                if len(out) >= 8:
                    break
        if p == "apinex":
            k = c.apinex_key.strip()
            if not k:
                return
            models = [c.apinex_model] + (c.apinex_fallbacks if c.auto_failover else [])
            for m in models:
                if not m:
                    continue
                if any(a["provider"] == "apinex" and a["model"] == m for a in out):
                    continue
                out.append({"provider": "apinex", "model": m, "key": k})
                if len(out) >= 8:
                    break
    push(c.provider)
    if c.auto_failover:
        push("apinex" if c.provider == "gemini" else "gemini")
    return out

def run_chat(c, responders, chain=None, index=0, last_failure=None, steps=None):
    """responders: dict (provider, model) -> (status, body_json). Mirrors runChat."""
    if steps is None:
        steps = []
    attempts = chain if chain is not None else build_chain(c)
    if index >= len(attempts):
        return None, (last_failure or "No AI provider answered."), steps
    a = attempts[index]
    status, body = responders.get((a["provider"], a["model"]), (500, {"error": {"message": "no responder"}}))
    steps.append((a["provider"], a["model"], status))
    if status == 200 and body.get("__text__") is not None:
        # success path
        return body["__text__"], None, steps
    if status == 200:
        # transport treats empty/unparseable content as failure
        text = openai_content_text(body) if a["provider"] == "apinex" else gemini_content_text(body)
        if text:
            return text, None, steps
        err = "The model returned an empty answer."
    else:
        err = api_error_message(body) or f"Server error {status}."
    nxt = index + 1
    if is_key_rejected(status):
        while nxt < len(attempts) and attempts[nxt]["provider"] == a["provider"]:
            nxt += 1
    if nxt < len(attempts):
        note = f'{a["provider"]}: {err}'
        t, e, steps = run_chat(c, responders, attempts, nxt, note, steps)
        return t, e, steps
    return None, err, steps

# ================= scenarios =================

print("— response parsing —")
check("openai string content",
      openai_content_text({"choices":[{"message":{"role":"assistant","content":'[{"artist":"Wegz"}]'}}]}).startswith("["))

check("openai parts content",
      openai_content_text(json.loads('{"choices":[{"message":{"content":[{"type":"text","text":"hello"},{"type":"text","text":"world"}]}}]}')) == "hello\nworld")
check("openai missing choices -> None", openai_content_text({}) is None)
check("gemini candidates text",
      gemini_content_text(json.loads('{"candidates":[{"content":{"parts":[{"text":"a"},{"text":"b"}]}}]}')) == "a\nb")
check("gemini empty -> None", gemini_content_text({"candidates": []}) is None)
check("error message from {error:{message}}",
      api_error_message(json.loads('{"error":{"message":"Invalid API key provided"}}')) == "Invalid API key provided")
check("error message from {message}", api_error_message(json.loads('{"message":"Model free/x does not exist"}')).startswith("Model free/x"))
check("models list parse", parse_model_ids(json.loads('{"object":"list","data":[{"id":"free/glm-5.3-flash"},{"id":"gpt/5.6-luna"}]}')) == ["free/glm-5.3-flash", "gpt/5.6-luna"])
check("models list bad -> None", parse_model_ids({"data": "nope"}) is None)
check("balance numeric", balance_string({"balance_usd": 4.2}) == "$4.20")
check("balance string", balance_string({"balance": "3.50 USD"}) == "3.50 USD")
check("balance none", balance_string({"ok": True}) is None)

print("— model-gone / key-rejected detection —")
check("404 is model gone", is_model_gone(404, ""))
check("model not found is gone", is_model_gone(400, "Model free/gpt-5.6-luna not found"))
check("key error is NOT model gone", not is_model_gone(401, "Invalid API key"))
check("rate limit 429 is not model-gone flag (still rotates)", not is_model_gone(429, "Rate limit exceeded"))
check("401 key rejected", is_key_rejected(401))
check("403 key rejected", is_key_rejected(403))

print("— chain building —")
c = Cfg("apinex", apinex_key="sk-apx-1", apinex_fallbacks=[f"free/model-{i}" for i in range(12)])
chain = build_chain(c)
check("apinex chain starts with chosen model", chain[0]["model"] == "free/glm-5.3-flash")
check("apinex chain is free-first", chain[1]["model"] == "free/model-0")
check("apinex chain caps at 8", len(chain) == 8, f"len={len(chain)}")
check("apinex chain has no gemini (no key)", all(a["provider"] == "apinex" for a in chain))

c2 = Cfg("gemini", gemini_key="gk", apinex_key="sk-apx-1")
chain2 = build_chain(c2)
check("gemini chain starts with chosen model", chain2[0] == {"provider": "gemini", "model": "gemini-3.5-flash", "key": "gk"})
check("gemini chain crosses to apinex", chain2[-1]["provider"] == "apinex")
check("no duplicate models", len({(a["provider"], a["model"]) for a in chain2}) == len(chain2))

c3 = Cfg("apinex", auto_failover=False, apinex_key="k")
check("failover off -> single attempt", len(build_chain(c3)) == 1)

c4 = Cfg("onDevice")
check("on-device chain is empty", build_chain(c4) == [])

print("— never-stop scenarios —")

# 1: chosen apinex model retired -> next free model answers
resp = {("apinex", "free/glm-5.3-flash"): (404, {"error": {"message": "Model free/glm-5.3-flash not found"}}),
        ("apinex", "free/gpt-5.6-luna"): (200, {"__text__": "OK-LUNA"})}
t, e, s = run_chat(Cfg("apinex", apinex_key="k"), resp)
check("retired model rotates to next free model", t == "OK-LUNA", f"steps={s}")
check("rotation made exactly 2 calls", len(s) == 2, f"steps={s}")

# 2: whole apinex key rejected -> cross to gemini
resp = {("apinex", m): (401, {"error": {"message": "Invalid API key"}}) for m in
        ["free/glm-5.3-flash", "free/gpt-5.6-luna", "free/gemini-3.8-flash", "gemini/3.8-flash", "deepseek/v4-flash"]}
resp[("gemini", "gemini-3.5-flash")] = (200, {"__text__": "OK-GEMINI"})
t, e, s = run_chat(Cfg("apinex", apinex_key="bad", gemini_key="gk"), resp)
check("rejected key skips to other provider in ONE hop", t == "OK-GEMINI" and s[1] == ("gemini", "gemini-3.5-flash", 200), f"steps={s}")

# 3: gemini model retired, no apinex key -> gemini fallbacks
resp = {("gemini", "gemini-3.5-flash"): (404, {}),
        ("gemini", "gemini-3.6-flash"): (200, {"__text__": "OK-36"})}
t, e, s = run_chat(Cfg("gemini", gemini_key="gk"), resp)
check("gemini self-heal rotates to fallback", t == "OK-36", f"steps={s}")

# 4: everything fails -> error, bounded calls, no infinite loop
resp = {}
t, e, s = run_chat(Cfg("gemini", gemini_key="gk", apinex_key="k2"), resp)
check("all dead -> bounded attempt count", t is None and len(s) == 8, f"steps={s}")
check("all dead -> human error", bool(e), f"err={e}")

# 5: 200-but-empty content rotates instead of dead-ending
resp = {("apinex", "free/glm-5.3-flash"): (200, {"choices": [{"message": {"content": ""}}]}),
        ("apinex", "free/gpt-5.6-luna"): (200, {"__text__": "FIXED"})}
t, e, s = run_chat(Cfg("apinex", apinex_key="k"), resp)
check("empty reply rotates to next model", t == "FIXED", f"steps={s}")

# 6: failover OFF surfaces the error (single attempt)
resp = {("apinex", "free/glm-5.3-flash"): (500, {"error": {"message": "upstream boom"}})}
t, e, s = run_chat(Cfg("apinex", auto_failover=False, apinex_key="k"), resp)
check("failover off -> exactly one attempt + error", t is None and len(s) == 1 and "boom" in e, f"steps={s} err={e}")

# 7: 429 rate limit rotates
resp = {("apinex", "free/glm-5.3-flash"): (429, {"error": {"message": "Rate limit exceeded"}}),
        ("apinex", "free/gpt-5.6-luna"): (200, {"__text__": "OK"})}
t, e, s = run_chat(Cfg("apinex", apinex_key="k"), resp)
check("rate limit rotates to next model", t == "OK", f"steps={s}")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURES:", FAILS)
    sys.exit(1)
print("ALL SCENARIOS PASS ✅")
