import json
import time

from copytrader.config import Config
from copytrader.engine import Engine
from copytrader.ledger import Ledger, iter_records, verify
from copytrader.models import Leader

from conftest import trade
from test_router import FakeKalshi


class FakeDataAPI:
    def __init__(self):
        self.board = [Leader("0xabc", "whale", 1, 1e6, 1e7)]

    def leaderboard(self, *a, **k):
        return self.board

    def trades(self, wallet, limit=50):
        return []

    def positions(self, wallet, limit=500):
        return []


class IndexedKalshi(FakeKalshi):
    def __init__(self, cands, **kw):
        super().__init__(**kw)
        self.cands = cands

    def list_candidates(self, categories):
        return self.cands


def build(tmp_path, candidates, live=False):
    cfg = Config()
    cfg.state_path = str(tmp_path / "state.json")
    cfg.mapping.overrides_path = None
    cfg.polymarket.aggregation_window_s = 0
    led = Ledger(str(tmp_path / "ledger.jsonl"), "LIVE" if live else "DRY_RUN")
    k = IndexedKalshi(candidates)
    eng = Engine(cfg, k, led, live, data_api=FakeDataAPI())
    eng.bootstrap()
    return eng, k, led


def test_end_to_end_dry_run(tmp_path, candidates):
    eng, k, led = build(tmp_path, candidates)
    # split fills of one decision get aggregated into one signal
    eng.process_trade(trade(size=6000, tx="0x1"))
    eng.process_trade(trade(size=6000, tx="0x2"))
    eng.process_trade(trade(title="Will Liverpool FC win on 2026-09-12?", tx="0x3", asset="222", cid="0xliv"))
    for s in eng.agg.flush(force=True):
        eng.process_signal(s)
    kinds = [r["kind"] for r in iter_records(led.path)]
    assert kinds.count("order_planned") == 1
    assert kinds.count("unmapped") == 1
    assert k.orders == []  # dry run never touches the order endpoint
    planned = [r for r in iter_records(led.path) if r["kind"] == "order_planned"][0]
    assert planned["mode"] == "DRY_RUN"
    assert planned["data"]["signal"]["fills"] == 2
    assert planned["data"]["order"]["ticker"] == "KXFEDDECISION-26OCT-C25"
    assert verify(led.path).ok


def test_stale_fills_ignored(tmp_path, candidates):
    eng, k, led = build(tmp_path, candidates)
    eng.process_trade(trade(ts=time.time() - 3600))
    assert eng.agg.flush(force=True) == []


def test_untracked_wallet_ignored_by_stream(tmp_path, candidates):
    eng, _, _ = build(tmp_path, candidates)
    payload = {"topic": "activity", "type": "trades", "payload": {
        "proxyWallet": "0xDEAD", "side": "BUY", "asset": "1", "conditionId": "c", "outcome": "Yes",
        "outcomeIndex": 0, "size": 100, "price": 0.5, "timestamp": int(time.time()), "title": "t",
        "transactionHash": "0x9"}}
    eng.stream.handle_ws_message(json.dumps(payload))
    assert eng.q.empty()
    payload["payload"]["proxyWallet"] = "0xABC"  # checksummed case still matches
    eng.stream.handle_ws_message(json.dumps(payload))
    eng.stream.handle_ws_message(json.dumps(payload))  # duplicate suppressed
    assert eng.q.qsize() == 1


def test_server_auth(tmp_path):
    import threading
    import urllib.error
    import urllib.request
    from http.server import ThreadingHTTPServer

    from copytrader.serve import Supervisor, make_handler

    led = tmp_path / "l.jsonl"
    Ledger(str(led), "DRY_RUN").append("x", {})
    html = tmp_path / "d.html"
    html.write_text("<p>dash</p>")
    sup = Supervisor(lambda: None, str(led), str(html))
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(sup, "secret"))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    assert json.loads(urllib.request.urlopen(base + "/health").read())["ledger_records"] == 1
    for path in ("/", "/?key=wrong", "/ledger.jsonl"):
        try:
            urllib.request.urlopen(base + path)
            raise AssertionError(path)
        except urllib.error.HTTPError as e:
            assert e.code == 403
    assert b"dash" in urllib.request.urlopen(base + "/?key=secret").read()
    srv.shutdown()
