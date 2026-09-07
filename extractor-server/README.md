# AS Music personal extractor server

Optional power-up: your own tiny download server that joins every race in
the app as the **MyServer** engine. It runs `yt-dlp` (updated within hours
whenever YouTube changes), so it's the most future-proof path in the app.

## Deploy (free, ~10 minutes)

**Render (easiest):**

1. Push this repo to GitHub (you already have).
2. Go to [render.com](https://render.com) → New → Web Service → select this
   repo. Render auto-detects `extractor-server/render.yaml`.
3. Deploy (Free plan is fine). Copy the service URL, e.g.
   `https://asmusic-extractor.onrender.com`.
4. In the app: Magic DL → gear (Engines) → paste the URL → Test connection.

**Any VPS / computer:**

```bash
cd extractor-server
pip install -r requirements.txt
gunicorn server:app --timeout 300 --workers 1 --bind 0.0.0.0:8080
```

Then use `http://YOUR-IP:8080` (or put it behind HTTPS — the app
requires HTTPS for non-local addresses).

## Notes

- Free hosts sleep when idle: the first race after a while may be slow
  (your server just loses that race — classic engines carry on).
- Keep your URL private (it's your personal bandwidth).
- Update `yt-dlp` occasionally: redeploy, or `pip install -U yt-dlp`.
