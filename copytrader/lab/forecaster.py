"""Blind AI forecaster: Claude researches a market and returns a probability.

BLIND = the model is never shown the market price, so its forecast is an independent
signal we can later compare with the market (anchoring on the price would hide skill).
"""
import json, os, re, time
from datetime import datetime, timezone
from . import db

MODEL = os.getenv("FORECAST_MODEL", "claude-opus-5-5")
PRICES = {"claude-opus-5-5": (4.0, 20.0), "claude-sonnet-5-5": (2.0, 10.0), "claude-haiku-5-5": (0.10, 0.50)}

SYSTEM = """You are a superforecaster. Estimate the probability that a prediction-market question resolves to the stated outcome.
Rules: read the resolution rules literally; search the web for the latest facts (injuries, polls, official announcements, base rates);
reason about base rates before specifics; avoid overconfidence (rarely go below 0.03 or above 0.97 unless it is nearly settled);
distinguish what is known now from what is still uncertain. You are NOT shown the current market price; do not guess it.
Finish with ONLY a JSON object, no prose after it:
{"probability": <0..1>, "confidence": "low|medium|high", "reasoning": "<=120 words", "sources": ["url", ...]}"""


def build_prompt(m, now=None, event_title=None):
    now = now or datetime.now(timezone.utc)
    ev = f"Event: {event_title}\n" if event_title else ""
    return (f"Today (UTC): {now:%Y-%m-%d %H:%M}\n{ev}Question: {m['question']}\n"
            f"Forecast the probability that this resolves: {m['outcome_name']}\n"
            f"Closes: {m['close_time']}\nResolution rules:\n{(m['rules'] or 'n/a')[:3000]}")


def parse_forecast(text):
    """Extract the last JSON object containing 'probability'; clamp to (0.01, 0.99)."""
    for blob in reversed(re.findall(r"\{.*?\}", text, re.S)):
        try:
            d = json.loads(blob)
        except Exception:
            continue
        if "probability" in d:
            p = min(0.99, max(0.01, float(d["probability"])))
            return {"p": p, "confidence": str(d.get("confidence", "low")),
                    "reasoning": str(d.get("reasoning", ""))[:1500], "sources": d.get("sources", [])[:8]}
    raise ValueError("no forecast JSON found")


def forecast_market(client, m, model=MODEL, max_searches=4, event_title=None):
    msgs = [{"role": "user", "content": build_prompt(m, event_title=event_title)}]
    tools = [{"type": "web_search_20260209", "name": "web_search", "max_uses": max_searches}]
    in_tok = out_tok = 0
    for _ in range(4):                                      # resume pause_turn
        r = client.messages.create(model=model, max_tokens=6000, system=SYSTEM, tools=tools, messages=msgs)
        in_tok += r.usage.input_tokens; out_tok += r.usage.output_tokens
        if r.stop_reason == "pause_turn":
            msgs = [msgs[0], {"role": "assistant", "content": r.content}]
            continue
        if r.stop_reason == "refusal":
            raise RuntimeError("model refused")
        break
    text = "".join(b.text for b in r.content if getattr(b, "type", "") == "text")
    f = parse_forecast(text)
    pi, po = PRICES.get(model, (4.0, 20.0))
    f.update(input_tokens=in_tok, output_tokens=out_tok, cost_usd=(in_tok * pi + out_tok * po) / 1e6)
    return f


def pick_candidates(c, limit=10, max_days=7, recent_hours=24, now=None):
    """Unresolved, soon-closing markets with a live quote not forecast recently; prefer mid-range prices."""
    now = now or time.time()
    rows = c.execute("""SELECT * FROM markets WHERE resolved=0""").fetchall()
    out = []
    for m in rows:
        q = db.latest_quote(c, m["venue"], m["market_id"]); mid = db.mid_of(q)
        if mid is None or not (0.05 <= mid <= 0.95):
            continue
        try:
            ct = datetime.fromisoformat(m["close_time"].replace("Z", "+00:00")).timestamp()
        except Exception:
            continue
        if not (now < ct < now + max_days * 86400):
            continue
        if c.execute("SELECT 1 FROM forecasts WHERE venue=? AND market_id=? AND ts>?",
                     (m["venue"], m["market_id"], now - recent_hours * 3600)).fetchone():
            continue
        out.append((abs(mid - 0.5), ct, m))
    out.sort(key=lambda x: (x[0], x[1]))                    # most uncertain, then soonest
    return [m for _, _, m in out[:limit]]


def run(c, client, limit=10, model=MODEL, budget_usd=5.0, event_lookup=None):
    spent, n = 0.0, 0
    for m in pick_candidates(c, limit):
        if spent >= budget_usd:
            break
        q = db.latest_quote(c, m["venue"], m["market_id"])
        try:
            et = event_lookup(m["event_ticker"]) if (event_lookup and m["event_ticker"]) else None
            f = forecast_market(client, dict(m), model, event_title=et)
        except Exception as e:
            print("skip", m["market_id"], repr(e)[:120]); continue
        c.execute("INSERT INTO forecasts VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            time.time(), m["venue"], m["market_id"], model, f["p"], f["confidence"], f["reasoning"],
            json.dumps(f["sources"]), db.mid_of(q), q["ask"], q["bid"],
            f["input_tokens"], f["output_tokens"], f["cost_usd"]))
        c.commit(); spent += f["cost_usd"]; n += 1
        print(f"{m['venue']}:{m['market_id'][:24]} AI={f['p']:.2f} mkt={db.mid_of(q):.2f} ${f['cost_usd']:.3f}")
    return n, spent
