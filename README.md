[README_Version6.md](https://github.com/user-attachments/files/23350029/README_Version6.md)
```markdown
# investmenttracker1.2

This repository contains a small FastAPI app that tracks public filings (lawmakers PTR & institutional 13F filings).
This README highlights Render-specific steps for a reliable deployment.

1) Key deployment decisions for Render
- Use a Render Persistent Disk (recommended) for the SQLite file, or migrate to Postgres for production.
- Run one Web service (RUN_POLLER=false) for serving the UI and one Worker service (RUN_POLLER=true) for polling and notifications. This avoids duplicate polling when Render scales.
- Do NOT commit .env or API keys to the repo.

2) Important environment variables
- QUIVER_API_KEY (required)
- FMP_API_KEY (required)
- DISCORD_WEBHOOK_URL (optional)
- TRACKER_DB (path to SQLite; on Render point to persistent disk, e.g., /data/tracker.db)
- POLL_INTERVAL_SECONDS (optional integer)
- RUN_POLLER=true|false (worker=true)

3) Quick local test
- Copy .env.example to .env and fill keys (do not commit)
- python -m venv .venv && source .venv/bin/activate
- pip install -r requirements.txt
- uvicorn tracker_app:app --host 0.0.0.0 --port 8000 --reload

4) Render setup summary
- Create two services (or one if you accept duplicated pollers):
  A) Web service (RUN_POLLER=false)
     - Start command: uvicorn tracker_app:app --host 0.0.0.0 --port $PORT --proxy-headers
     - Set env vars (QUIVER_API_KEY, FMP_API_KEY, DISCORD_WEBHOOK_URL, TRACKER_DB, POLL_INTERVAL_SECONDS, RUN_POLLER=false)
  B) Worker service (RUN_POLLER=true)
     - Start command (worker): python -c "import asyncio, tracker_app; asyncio.run(tracker_app.poll_sources(asyncio.Event()))"
     - Set env vars (QUIVER_API_KEY, FMP_API_KEY, DISCORD_WEBHOOK_URL, TRACKER_DB=/data/tracker.db, POLL_INTERVAL_SECONDS, RUN_POLLER=true)
     - Attach a Persistent Disk and set TRACKER_DB to the persistent disk path (e.g., /data/tracker.db)

5) Notes
- Render ephemeral filesystem: if you don't attach a Persistent Disk, the tracker.db will be lost on redeploys.
- If you use the Dockerfile, set TRACKER_DB to the disk mount on Render or use /data by default.

```
