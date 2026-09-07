"""AS Music personal extractor server.

A tiny bridge between the app and yt-dlp. Deploy it once (free — see
README.md), paste its address into the app's Engines settings, and it joins
every download race as the "MyServer" contender.

Why this exists: yt-dlp is updated within hours whenever YouTube changes
anything, so a self-hosted extractor is the most durable download path of
all. The server streams the bytes itself (direct media URLs are IP-locked,
so it can't just hand the app a link).

Endpoints:
  GET /                 -> {"ok": true, "service": "asmusic-extractor"}
  GET /extract?v=VID    -> {"url": "<this-server>/audio?v=VID", "ext": "m4a"}
  GET /audio?v=VID      -> audio bytes (streamed from yt-dlp)

Personal use only — don't publish your instance publicly or share the URL.
"""

import os
import shutil
import subprocess

from flask import Flask, Response, jsonify, request

app = Flask(__name__)
YTDLP = shutil.which("yt-dlp") or "yt-dlp"


@app.get("/")
def index():
    return jsonify(ok=True, service="asmusic-extractor")


@app.get("/extract")
def extract():
    vid = (request.args.get("v") or "").strip()
    if not vid or len(vid) > 32:
        return jsonify(error="missing v"), 400
    base = request.host_url.rstrip("/")
    return jsonify(url=f"{base}/audio?v={vid}", ext="m4a")


@app.get("/audio")
def audio():
    vid = (request.args.get("v") or "").strip()
    if not vid or len(vid) > 32:
        return jsonify(error="missing v"), 400
    watch = f"https://www.youtube.com/watch?v={vid}"
    cmd = [
        YTDLP,
        "-f", "bestaudio[ext=m4a]/bestaudio",
        "--no-playlist",
        "--quiet",
        "--no-warnings",
        "-o", "-",
        watch,
    ]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return jsonify(error="yt-dlp is not installed on the server"), 500

    def generate():
        assert proc.stdout is not None
        try:
            while True:
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                yield chunk
        finally:
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.kill()

    return Response(generate(), mimetype="audio/mp4")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
