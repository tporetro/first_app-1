#!/usr/bin/env bash
# One-shot setup for the Vultr box (Ubuntu 24.04). Run from the copytrader/ directory:
#   bash deploy/setup_server.sh
# Safe to re-run. Opens NO network ports; nothing here listens for connections.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> system packages"
if ! command -v python3 >/dev/null || ! python3 -c "import venv" 2>/dev/null; then
  apt-get update -y && apt-get install -y python3 python3-venv python3-pip
fi
if ! command -v node >/dev/null; then apt-get install -y nodejs npm; fi
if ! command -v pm2 >/dev/null; then npm install -g pm2; fi

echo "==> python venv + deps (avoids --break-system-packages)"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt

echo "==> .env"
if [ ! -f .env ]; then
  cp .env.example .env
  cat >> .env <<'ENV'

# --- lab settings ---
ANTHROPIC_API_KEY=
FORECAST_MODEL=claude-opus-5-5
FORECAST_BUDGET_USD=2
FORECAST_LIMIT=10
ENV
  echo "created .env  -> EDIT IT NOW:  nano .env   (add ANTHROPIC_API_KEY)"
fi
chmod 600 .env

echo "==> tests"
.venv/bin/python -m pytest -q

echo "==> start under pm2"
pm2 start ecosystem.config.js
pm2 save
echo
echo "Boot persistence (run the command pm2 prints):  pm2 startup systemd -u $(whoami) --hp $HOME"
echo "Then:  pm2 save"
echo "Handy:  pm2 status | pm2 logs lab-record | pm2 logs lab-forecast | cat reports/daily-*.json"
echo "NOTE: lab-forecast does nothing useful until ANTHROPIC_API_KEY is set in .env, then: pm2 restart lab-forecast"
