#!/usr/bin/env bash
# create_investmenttracker1_2.sh
# Creates the investmenttracker1.2 project folder with all files and zips it.
# Usage:
#   1) Save this file locally: curl -o create_investmenttracker1_2.sh "PASTE_THIS_CONTENT"
#   2) Make executable: chmod +x create_investmenttracker1_2.sh
#   3) Run: ./create_investmenttracker1_2.sh
# After running you'll have:
#   - ./investmenttracker1.2/        (project folder ready to drag into GitHub)
#   - ./investmenttracker1.2.zip    (zip archive of the folder)
#
set -e

ROOT_DIR="investmenttracker1.2"
ZIP_NAME="${ROOT_DIR}.zip"

echo "Creating project folder ./${ROOT_DIR} ..."
rm -rf "$ROOT_DIR" "$ZIP_NAME"
mkdir -p "$ROOT_DIR/templates"

cat > "$ROOT_DIR/tracker_app.py" <<'PY'
# tracker_app.py
import os
import asyncio
import logging
from typing import List, Dict, Any, Optional
from datetime import datetime, timezone

import httpx
import aiosqlite
from dotenv import load_dotenv
from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel

load_dotenv()

# Logging
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("investortracker")

# Config from env
DB_PATH = os.getenv("TRACKER_DB", "tracker.db")
QUIVER_API_KEY = os.getenv("QUIVER_API_KEY")
FMP_API_KEY = os.getenv("FMP_API_KEY")
DISCORD_WEBHOOK = os.getenv("DISCORD_WEBHOOK_URL")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL_SECONDS", "30"))
RUN_POLLER = os.getenv("RUN_POLLER", "true").lower() in ("1", "true", "yes")

# Available people (same as before)
AVAILABLE_PEOPLE = [
    "Nancy Pelosi", "Michael McCaul", "Ro Khanna", "Brian Higgins", "David Rouzer",
    "Daniel Goldman", "Josh Gottheimer", "John Curtis", "Susie Lee", "Kevin Hern",
    "Warren Buffett", "Michael Burry", "Bill Ackman", "Carl Icahn", "George Soros",
    "Steve Cohen", "Ken Griffin", "David Tepper"
]

user_selected_people: List[str] = []

QUIVER_CONGRESS_URL = "https://api.quiverquant.com/beta/historical/congresstrading"
FMP_13F_URL = "https://financialmodelingprep.com/api/v4/institutional-ownership-filings"

app = FastAPI(title="PTR & Investor Tracker App")

# If you add static files, create the "static" directory
app.mount("/static", StaticFiles(directory="static"), name="static", create_dir=True)
templates = Jinja2Templates(directory="templates")

# Will be set on startup
app.state.http_client: Optional[httpx.AsyncClient] = None
app.state.poll_task: Optional[asyncio.Task] = None


class Filing(BaseModel):
    id: str
    person: str
    ticker: str
    side: str
    amount: str
    reported_date: str
    source: str


async def ensure_db_dir(path: str) -> None:
    dirpath = os.path.dirname(path) or "."
    if dirpath and not os.path.exists(dirpath):
        os.makedirs(dirpath, exist_ok=True)
        logger.info("Created DB directory %s", dirpath)


async def init_db():
    await ensure_db_dir(DB_PATH)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            """
            CREATE TABLE IF NOT EXISTS filings (
                id TEXT PRIMARY KEY,
                person TEXT,
                ticker TEXT,
                side TEXT,
                amount TEXT,
                reported_date TEXT,
                source TEXT,
                seen_at TEXT
            )
            """
        )
        await db.commit()
    logger.info("Initialized DB at %s", DB_PATH)


async def send_notifications(new_filings: List[Dict[str, Any]]):
    if not DISCORD_WEBHOOK or not new_filings:
        return
    msg_lines = [
        f"{f.get('reported_date','')} | {f.get('person','')} | {f.get('ticker','')} | {f.get('side','')} | {f.get('amount','')}"
        for f in new_filings
    ]
    msg = "**New Public Filings Detected**\n" + "\n".join(msg_lines)
    try:
        async with app.state.http_client as client:
            await client.post(DISCORD_WEBHOOK, json={"content": msg})
    except Exception as e:
        logger.warning("Failed to send Discord notification: %s", e)


async def store_new_entries(new_filings: List[Dict[str, Any]]):
    if not new_filings:
        return
    async with aiosqlite.connect(DB_PATH) as db:
        for f in new_filings:
            try:
                await db.execute(
                    "INSERT INTO filings (id, person, ticker, side, amount, reported_date, source, seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        f["id"],
                        f.get("person", ""),
                        f.get("ticker", ""),
                        f.get("side", ""),
                        f.get("amount", ""),
                        f.get("reported_date", ""),
                        f.get("source", ""),
                        datetime.now(timezone.utc).isoformat(),
                    ),
                )
                await db.commit()
            except aiosqlite.IntegrityError:
                continue
    await send_notifications(new_filings)


async def fetch_quiver_filings():
    if not QUIVER_API_KEY or not user_selected_people:
        return []
    headers = {"Authorization": f"Token {QUIVER_API_KEY}"}
    try:
        res = await app.state.http_client.get(QUIVER_CONGRESS_URL, headers=headers, timeout=15.0)
        res.raise_for_status()
        data = res.json()
    except Exception as e:
        logger.debug("Quiver request failed: %s", e)
        return []
    filings = []
    for i in data:
        person = i.get("representative", "") or i.get("member", "")
        if not any(p.lower() in person.lower() for p in user_selected_people):
            continue
        fid = i.get("transaction_id") or f"{person}_{i.get('ticker','')}_{i.get('date','')}"
        filings.append(
            {
                "id": str(fid),
                "person": person,
                "ticker": i.get("ticker", ""),
                "side": (i.get("type", "") or "").lower(),
                "amount": i.get("amount", "") or i.get("range", ""),
                "reported_date": i.get("date", ""),
                "source": QUIVER_CONGRESS_URL,
            }
        )
    return filings


async def fetch_investor_filings():
    if not FMP_API_KEY or not user_selected_people:
        return []
    try:
        res = await app.state.http_client.get(f"{FMP_13F_URL}?apikey={FMP_API_KEY}", timeout=15.0)
        res.raise_for_status()
        data = res.json()
    except Exception as e:
        logger.debug("FMP request failed: %s", e)
        return []
    filings = []
    for i in data:
        name = i.get("name", "")
        if not any(p.lower() in name.lower() for p in user_selected_people):
            continue
        fid = i.get("cik") or f"{name}_{i.get('symbol','')}_{i.get('filingDate','')}"
        filings.append(
            {
                "id": str(fid),
                "person": name,
                "ticker": i.get("symbol", ""),
                "side": "hold",
                "amount": str(i.get("value", "")),
                "reported_date": i.get("filingDate", ""),
                "source": FMP_13F_URL,
            }
        )
    return filings


async def poll_sources(stop_event: asyncio.Event):
    logger.info("Poller started (interval=%s seconds)", POLL_INTERVAL)
    await init_db()
    while not stop_event.is_set():
        try:
            congress = await fetch_quiver_filings()
            investors = await fetch_investor_filings()
            all_data = (congress or []) + (investors or [])
            new_data = []
            async with aiosqlite.connect(DB_PATH) as db:
                for f in all_data:
                    cur = await db.execute("SELECT 1 FROM filings WHERE id = ?", (f["id"],))
                    if not await cur.fetchone():
                        new_data.append(f)
            if new_data:
                logger.info("Found %d new filings", len(new_data))
                await store_new_entries(new_data)
        except Exception as e:
            logger.exception("Polling error: %s", e)
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=POLL_INTERVAL)
        except asyncio.TimeoutError:
            continue
    logger.info("Poller stopped")


@app.on_event("startup")
async def startup_event():
    app.state.http_client = httpx.AsyncClient()
    await ensure_db_dir(DB_PATH)
    if RUN_POLLER:
        stop_event = asyncio.Event()
        app.state._stop_event = stop_event
        app.state.poll_task = asyncio.create_task(poll_sources(stop_event))
        logger.info("Poller task created")
    else:
        logger.info("RUN_POLLER is false; skipping poller")


@app.on_event("shutdown")
async def shutdown_event():
    if getattr(app.state, "poll_task", None):
        logger.info("Stopping poller...")
        app.state._stop_event.set()
        await app.state.poll_task
    if getattr(app.state, "http_client", None):
        await app.state.http_client.aclose()
    logger.info("Shutdown complete")


@app.get("/", response_class=HTMLResponse)
async def select_names(request: Request):
    return templates.TemplateResponse("select_names.html", {"request": request, "available": AVAILABLE_PEOPLE})


@app.post("/set_names")
async def set_names(request: Request, selected: List[str] = Form(...)):
    global user_selected_people
    user_selected_people = selected
    return RedirectResponse(url="/dashboard", status_code=303)


@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard(request: Request):
    await init_db()
    async with aiosqlite.connect(DB_PATH) as db:
        cur = await db.execute(
            "SELECT person, ticker, side, amount, reported_date, source FROM filings ORDER BY seen_at DESC LIMIT 50"
        )
        rows = await cur.fetchall()
    return templates.TemplateResponse("dashboard.html", {"request": request, "rows": rows, "selected": user_selected_people})
PY

cat > "$ROOT_DIR/templates/select_names.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>Select People to Track</title>
  <style>
    body { font-family: Arial, sans-serif; padding: 20px; }
    .person { margin: 6px 0; }
    .submit { margin-top: 12px; }
  </style>
</head>
<body>
  <h1>Select people to follow</h1>
  <form action="/set_names" method="post">
    {% for p in available %}
      <div class="person">
        <label>
          <input type="checkbox" name="selected" value="{{ p }}">
          {{ p }}
        </label>
      </div>
    {% endfor %}
    <div class="submit">
      <button type="submit">Save selection and go to dashboard</button>
    </div>
  </form>
</body>
</html>
HTML

cat > "$ROOT_DIR/templates/dashboard.html" <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>Investor / PTR Dashboard</title>
  <style>
    body { font-family: Arial, sans-serif; padding: 20px; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ddd; padding: 8px; }
    th { background: #f5f5f5; }
  </style>
</head>
<body>
  <h1>Dashboard</h1>
  <p>Tracking: {% if selected %}{{ selected | join(", ") }}{% else %}No one selected{% endif %}</p>
  <p><a href="/">Change selection</a></p>
  <table>
    <thead>
      <tr>
        <th>Reported Date</th>
        <th>Person</th>
        <th>Ticker</th>
        <th>Side</th>
        <th>Amount</th>
        <th>Source</th>
      </tr>
    </thead>
    <tbody>
      {% for row in rows %}
      <tr>
        <td>{{ row[4] or "" }}</td>
        <td>{{ row[0] or "" }}</td>
        <td>{{ row[1] or "" }}</td>
        <td>{{ row[2] or "" }}</td>
        <td>{{ row[3] or "" }}</td>
        <td><a href="{{ row[5] }}" target="_blank">source</a></td>
      </tr>
      {% else %}
      <tr><td colspan="6">No filings found yet.</td></tr>
      {% endfor %}
    </tbody>
  </table>
</body>
</html>
HTML

cat > "$ROOT_DIR/requirements.txt" <<'TXT'
fastapi
uvicorn[standard]
httpx
aiosqlite
python-dotenv
jinja2
pydantic
feedparser
TXT

cat > "$ROOT_DIR/README.md" <<'MD'
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
     - Attach a Persistent Disk and set TRACKER_DB to the disk path (e.g., /data/tracker.db)
  B) Worker service (RUN_POLLER=true)
     - Start command (worker): python -c "import asyncio, tracker_app; asyncio.run(tracker_app.poll_sources(asyncio.Event()))"
     - Set env vars and attach same Persistent Disk

5) Notes
- Render ephemeral filesystem: if you don't attach a Persistent Disk, the tracker.db will be lost on redeploys.
- Consider moving to Postgres for production.
MD

cat > "$ROOT_DIR/.env.example" <<'ENV'
# .env.example - DO NOT commit your real .env
QUIVER_API_KEY=your_quiver_api_key
FMP_API_KEY=your_financial_modeling_prep_api_key
DISCORD_WEBHOOK_URL=your_discord_webhook_url_optional
# For Render persistent disk use: /data/tracker.db
TRACKER_DB=tracker.db
POLL_INTERVAL_SECONDS=30
# Set RUN_POLLER=true on the worker service only
RUN_POLLER=true
LOG_LEVEL=INFO
ENV

cat > "$ROOT_DIR/Procfile" <<'PROC'
web: uvicorn tracker_app:app --host 0.0.0.0 --port $PORT --proxy-headers
PROC

cat > "$ROOT_DIR/render.yaml" <<'RND'
# render.yaml (optional) — you can also configure via Render UI.
services:
  - type: web
    name: investmenttracker-web
    env: python
    region: oregon
    buildCommand: pip install -r requirements.txt
    startCommand: uvicorn tracker_app:app --host 0.0.0.0 --port $PORT --proxy-headers
    plan: free
  - type: worker
    name: investmenttracker-worker
    env: python
    region: oregon
    buildCommand: pip install -r requirements.txt
    startCommand: python -c "import asyncio, tracker_app; asyncio.run(tracker_app.poll_sources(asyncio.Event()))"
    plan: free
RND

cat > "$ROOT_DIR/Dockerfile" <<'DOCK'
# Dockerfile - optional
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN mkdir -p /data

ENV TRACKER_DB=/data/tracker.db
ENV PORT=8000

EXPOSE 8000
CMD ["uvicorn", "tracker_app:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
DOCK

cat > "$ROOT_DIR/.gitignore" <<'GI'
# Generic
.DS_Store
Thumbs.db
.env
.vscode/
.idea/
*.log

# Python
__pycache__/
*.py[cod]
*.egg-info/
venv/
.env

# SQLite DB
*.db
GI

cat > "$ROOT_DIR/LICENSE" <<'LIC'
MIT License

Copyright (c) 2025 hkreybig-ctrl

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LIC

# create zip if zip is available
if command -v zip >/dev/null 2>&1; then
  echo "Creating zip archive ${ZIP_NAME} ..."
  (cd "$(dirname "$ROOT_DIR")" || true; zip -r "../$ZIP_NAME" "$(basename "$ROOT_DIR")") >/dev/null
  echo "Created ${ZIP_NAME}"
else
  echo "zip command not found; skipping zip creation. You can manually zip the folder: zip -r ${ZIP_NAME} ${ROOT_DIR}"
fi

echo "Project created at ./${ROOT_DIR}"
echo "You can now:"
echo "  - Open the folder and drag the 'investmenttracker1.2' folder into GitHub's 'Upload files' area, or"
echo "  - If zip was created, unzip it locally and drag the extracted folder, or"
echo "  - Initialize git and push: cd ${ROOT_DIR} && git init && git add . && git commit -m 'Initial import' && git branch -M main &&"
echo "    git remote add origin git@github.com:hkreybig-ctrl/investmenttracker1.2.git && git push -u origin main"
echo "Done."