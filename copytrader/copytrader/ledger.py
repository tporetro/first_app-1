"""Append-only, hash-chained text ledger.

Every line is one JSON record. Each record embeds the SHA-256 of the previous
record, so editing, deleting or reordering any historical line breaks the chain
and is caught by ``verify()`` (and on every startup). The file is only ever
opened in append mode and fsync'd after each write.

For OS-level immutability on Linux you can additionally run
``sudo chattr +a <ledger>`` which makes the file append-only even for root
processes that don't first remove the attribute.
"""
from __future__ import annotations

import hashlib
import json
import os
import threading
import time
from dataclasses import dataclass
from typing import Iterator, Optional

GENESIS = "0" * 64

try:  # POSIX advisory lock so two engines can't interleave writes
    import fcntl
except ImportError:  # pragma: no cover - windows
    fcntl = None


class LedgerCorrupted(RuntimeError):
    pass


def _canonical(obj: dict) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str)


def _hash_record(rec: dict) -> str:
    body = {k: v for k, v in rec.items() if k != "hash"}
    return hashlib.sha256(_canonical(body).encode()).hexdigest()


@dataclass
class VerifyResult:
    ok: bool
    records: int
    last_hash: str
    error: Optional[str] = None


class Ledger:
    def __init__(self, path: str, mode: str):
        self.path = path
        self.mode = mode  # "DRY_RUN" | "LIVE" -- stamped on every record
        self._lock = threading.Lock()
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        res = verify(path)
        if not res.ok:
            raise LedgerCorrupted(
                f"Refusing to append to {path}: {res.error}. "
                "Archive the file and start a new ledger."
            )
        self._seq = res.records
        self._prev = res.last_hash

    def append(self, kind: str, data: dict) -> dict:
        with self._lock:
            rec = {
                "seq": self._seq,
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "ts_unix": round(time.time(), 3),
                "mode": self.mode,
                "kind": kind,
                "data": data,
                "prev_hash": self._prev,
            }
            rec["hash"] = _hash_record(rec)
            line = _canonical(rec) + "\n"
            with open(self.path, "a", encoding="utf-8") as fh:
                if fcntl:
                    fcntl.flock(fh, fcntl.LOCK_EX)
                try:
                    fh.write(line)
                    fh.flush()
                    os.fsync(fh.fileno())
                finally:
                    if fcntl:
                        fcntl.flock(fh, fcntl.LOCK_UN)
            self._seq += 1
            self._prev = rec["hash"]
            return rec


def iter_records(path: str) -> Iterator[dict]:
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                yield json.loads(line)


def verify(path: str) -> VerifyResult:
    prev = GENESIS
    n = 0
    if not os.path.exists(path):
        return VerifyResult(True, 0, GENESIS)
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                return VerifyResult(False, n, prev, f"line {lineno}: invalid JSON ({e})")
            if rec.get("seq") != n:
                return VerifyResult(False, n, prev, f"line {lineno}: expected seq {n}, got {rec.get('seq')}")
            if rec.get("prev_hash") != prev:
                return VerifyResult(False, n, prev, f"line {lineno}: prev_hash mismatch (chain broken)")
            if _hash_record(rec) != rec.get("hash"):
                return VerifyResult(False, n, prev, f"line {lineno}: hash mismatch (record modified)")
            prev = rec["hash"]
            n += 1
    return VerifyResult(True, n, prev)
