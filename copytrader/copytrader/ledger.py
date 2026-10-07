"""Append-only, hash-chained JSONL ledger. Editing or deleting any line breaks verify()."""
import hashlib, json, os, time

GENESIS = "0" * 64


class Ledger:
    def __init__(self, path: str):
        self.path = path
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self._prev = self._last_hash()

    def _last_hash(self) -> str:
        if not os.path.exists(self.path):
            return GENESIS
        last = GENESIS
        with open(self.path) as f:
            for line in f:
                if line.strip():
                    last = json.loads(line)["hash"]
        return last

    @staticmethod
    def _digest(prev: str, body: dict) -> str:
        return hashlib.sha256((prev + json.dumps(body, sort_keys=True)).encode()).hexdigest()

    def append(self, kind: str, data: dict) -> dict:
        body = {"ts": time.time(), "kind": kind, "data": data}
        rec = {**body, "prev": self._prev, "hash": self._digest(self._prev, body)}
        with open(self.path, "a") as f:
            f.write(json.dumps(rec, sort_keys=True) + "\n")
            f.flush(); os.fsync(f.fileno())
        self._prev = rec["hash"]
        return rec

    def verify(self) -> bool:
        prev = GENESIS
        if not os.path.exists(self.path):
            return True
        with open(self.path) as f:
            for line in f:
                if not line.strip():
                    continue
                r = json.loads(line)
                body = {k: r[k] for k in ("ts", "kind", "data")}
                if r["prev"] != prev or r["hash"] != self._digest(prev, body):
                    return False
                prev = r["hash"]
        return True

    def records(self):
        if os.path.exists(self.path):
            with open(self.path) as f:
                for line in f:
                    if line.strip():
                        yield json.loads(line)
