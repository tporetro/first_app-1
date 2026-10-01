"""Render one or more ledgers into a self-contained, phone-friendly HTML review page."""
from __future__ import annotations

import json
import os
import re
import time
from collections import Counter

from . import ledger as ledger_mod

SKIP_LABELS = [
    (r"no macro keyword|excluded keyword", "Not an election or macro market"),
    (r"price divergence", "Kalshi price too far from the leader's price (likely wrong match)"),
    (r"above limit", "Kalshi price above our limit"),
    (r"below min_price", "Price too close to zero"),
    (r"leader SELL but we hold no", "Leader sold something we never copied"),
    (r"ambiguous vs", "Two Kalshi contracts matched equally well"),
    (r"below min_score|no lexical overlap", "No similar Kalshi contract"),
    (r"no candidate passed", "Closest Kalshi contract pays out on different terms"),
    (r"no (yes|no) (ask|bid)", "No liquidity on Kalshi"),
    (r"rounds to 0", "Order would be under 1 contract"),
    (r"max_open_positions", "Open-position limit reached"),
    (r"not tradable", "Kalshi market closed"),
    (r"quote failed|balance unavailable", "Kalshi API error"),
]


def _label(reason: str) -> str:
    for pat, label in SKIP_LABELS:
        if re.search(pat, reason, re.I):
            return label
    return reason[:80]


def summarise(path: str, name: str) -> dict:
    v = ledger_mod.verify(path)
    kinds, skips, examples = Counter(), Counter(), {}
    orders, leaders, meta = [], [], {"category": None, "mode": None, "first": None, "last": None}
    for r in ledger_mod.iter_records(path):
        k, d = r["kind"], r["data"]
        kinds[k] += 1
        meta["mode"] = meta["mode"] or r["mode"]
        if k == "leader_fill":  # window = when the leaders actually traded
            t = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(d["timestamp"]))
            meta["first"] = min(meta["first"] or t, t)
            meta["last"] = max(meta["last"] or t, t)
        if k == "leaderboard":
            meta["category"] = d.get("category")
            leaders = [{"rank": l["rank"], "name": l["name"], "pnl": l["pnl"], "wallet": l["wallet"]}
                       for l in d["leaders"]]
        elif k in ("unmapped", "decision"):
            reason = d["reasons"][-1] if k == "unmapped" else d["reason"]
            lab = _label(reason)
            skips[lab] += 1
            examples.setdefault(lab, d["signal"]["title"])
        elif k == "order_planned":
            o, s, m = d["order"], d["signal"], d["match"]
            orders.append({
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(s["last_ts"])), "leader": s["leader_name"], "rank": s["leader_rank"],
                "leader_side": s["side"], "outcome": s["outcome"], "leader_price": round(s["vwap"], 3),
                "leader_usdc": round(s["usdc"], 2), "fills": s["fills"], "question": s["title"],
                "ticker": o["ticker"], "kalshi_title": m["kalshi_title"], "side": o["outcome_side"],
                "action": o["action"], "count": o["count"], "limit": o["limit_price"],
                "cost": o["est_cost"], "fee": o["est_fee"], "score": m["score"], "method": m["method"],
                "conviction": o["sizing"].get("conviction"), "live": d.get("live", False),
            })
    if not meta["first"]:
        meta["first"] = meta["last"] = None
    considered = kinds["unmapped"] + kinds["decision"] + kinds["order_planned"]
    return {
        "name": name, "file": os.path.basename(path), "meta": meta,
        "chain": {"ok": v.ok, "records": v.records, "head": v.last_hash, "error": v.error},
        "funnel": {"fills": kinds["leader_fill"], "signals": considered,
                   "matched": kinds["decision"] + kinds["order_planned"], "orders": kinds["order_planned"]},
        "skips": [{"label": l, "count": c, "example": examples[l]} for l, c in skips.most_common()],
        "orders": orders[::-1], "leaders": leaders,
        "position_changes": kinds["position_change"],
    }


def render(sources: list[tuple[str, str]], out: str) -> str:
    data = {"generated": time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime()),
            "sources": [summarise(p, n) for p, n in sources if os.path.exists(p)]}
    blob = json.dumps(data).replace("</", "<\\/")
    with open(os.path.join(os.path.dirname(__file__), "dashboard_template.html"), encoding="utf-8") as fh:
        html = fh.read().replace("__DATA__", blob)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(html)
    return out
