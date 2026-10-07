// pm2 process file. Start with:  pm2 start ecosystem.config.js && pm2 save
// Uses the project venv created by deploy/setup_server.sh. Secrets come from .env (never in this file).
const path = require("path");
const ROOT = __dirname;
const PY = path.join(ROOT, ".venv", "bin", "python");

const base = { cwd: ROOT, interpreter: PY, script: "lab_cli.py", env: { PYTHONUNBUFFERED: "1" },
               time: true, max_memory_restart: "500M" };
// one-shot job: runs on the cron schedule, then stays "stopped" until the next tick
const job = (name, cmd, cron, extra = []) => ({
  ...base, name, args: [cmd, ...extra], cron_restart: cron, autorestart: false });

module.exports = {
  apps: [
    // 24/7 recorder: snapshots both venues + wallet fills + settles resolved markets every 5 min
    { ...base, name: "lab-record", args: ["loop"], autorestart: true, restart_delay: 15000 },

    // staggered hourly jobs (offset minutes so they don't hammer Kalshi's rate limit together)
    job("lab-pairs",  "pairs",  "7 * * * *"),
    job("lab-decide", "decide", "20 * * * *"),

    // AI forecasts every 3h; spend is hard-capped per run by FORECAST_BUDGET_USD (default $2)
    // worst case = 8 runs/day x budget. Edit FORECAST_BUDGET_USD / FORECAST_LIMIT in .env.
    job("lab-forecast", "forecast", "30 */3 * * *"),

    // daily report: refit weights, score AI vs market, real-money gate -> reports/daily-YYYY-MM-DD.json
    job("lab-daily", "daily", "50 6 * * *"),
  ],
};
