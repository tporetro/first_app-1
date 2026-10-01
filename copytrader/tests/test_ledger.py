import json

import pytest

from copytrader.ledger import Ledger, LedgerCorrupted, iter_records, verify


def test_chain_appends_and_verifies(tmp_path):
    p = tmp_path / "ledger.jsonl"
    led = Ledger(str(p), "DRY_RUN")
    for i in range(5):
        led.append("event", {"i": i})
    res = verify(str(p))
    assert res.ok and res.records == 5
    recs = list(iter_records(str(p)))
    assert all(r["mode"] == "DRY_RUN" for r in recs)
    assert recs[1]["prev_hash"] == recs[0]["hash"]


def test_reopen_continues_chain(tmp_path):
    p = str(tmp_path / "ledger.jsonl")
    Ledger(p, "DRY_RUN").append("a", {})
    Ledger(p, "DRY_RUN").append("b", {})
    res = verify(p)
    assert res.ok and res.records == 2


@pytest.mark.parametrize("mutation", ["edit", "delete", "reorder"])
def test_tampering_detected(tmp_path, mutation):
    p = tmp_path / "ledger.jsonl"
    led = Ledger(str(p), "DRY_RUN")
    for i in range(4):
        led.append("order_planned", {"count": i})
    lines = p.read_text().splitlines()
    if mutation == "edit":
        rec = json.loads(lines[1])
        rec["data"]["count"] = 999
        lines[1] = json.dumps(rec)
    elif mutation == "delete":
        del lines[2]
    else:
        lines[1], lines[2] = lines[2], lines[1]
    p.write_text("\n".join(lines) + "\n")
    assert not verify(str(p)).ok
    with pytest.raises(LedgerCorrupted):
        Ledger(str(p), "DRY_RUN")
