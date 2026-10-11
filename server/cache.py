"""Atomic persistent snapshots; failed refreshes never renew successful timestamps."""

from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path
import threading
from typing import Any


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_date(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        date = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return date.astimezone(timezone.utc) if date.tzinfo else None
    except (ValueError, OverflowError):
        return None


class SnapshotCache:
    def __init__(self, path: Path | None = None):
        self.path = path
        self.lock = threading.RLock()
        self.entries: dict[str, dict[str, Any]] = {}
        self.sizes: dict[str, int] = {}
        if path and path.exists():
            try:
                if path.stat().st_size > 50_000_000:
                    raise ValueError("Cache file exceeds size limit")
                data = json.loads(path.read_text(encoding="utf-8"))
                if data.get("version") != 1 or not isinstance(data.get("entries"), dict):
                    raise ValueError("Unsupported cache format")
                self.entries = {
                    key: entry for key, entry in data["entries"].items()
                    if isinstance(key, str) and isinstance(entry, dict)
                    and (entry.get("fetched_at") is None or parse_date(entry.get("fetched_at")))
                    and (entry.get("payload") is None or isinstance(entry.get("payload"), dict))
                }
                self.sizes = {key: len(json.dumps(entry, ensure_ascii=False).encode("utf-8")) for key, entry in self.entries.items()}
                self._bound_entries()
            except (ValueError, OSError, AttributeError, TypeError):
                logging.exception("Cache could not be restored; starting without cached data")

    def get(self, key: str) -> dict[str, Any] | None:
        with self.lock:
            return deepcopy(self.entries.get(key))

    def all(self) -> dict[str, dict[str, Any]]:
        with self.lock:
            return deepcopy(self.entries)

    def record_success(self, key: str, payload: dict[str, Any], now: datetime, modified: str | None = None):
        with self.lock:
            self.entries[key] = {
                "payload": deepcopy(payload), "fetched_at": iso(now),
                "attempted_at": iso(now), "modified": modified, "error": None,
            }
            self.sizes[key] = len(json.dumps(self.entries[key], ensure_ascii=False).encode("utf-8"))
            self._bound_entries()
            self._save()

    def record_failure(self, key: str, now: datetime, error: str):
        with self.lock:
            entry = self.entries.setdefault(key, {"payload": None, "fetched_at": None, "modified": None})
            entry["attempted_at"] = iso(now)
            entry["error"] = error[:300]
            self.sizes[key] = len(json.dumps(entry, ensure_ascii=False).encode("utf-8"))
            self._bound_entries()
            self._save()

    def _bound_entries(self):
        # Public query dates/IDs cannot grow the persistent cache without a bound.
        if len(self.entries) > 256 or sum(self.sizes.values()) > 32 * 1024 * 1024:
            ordered = sorted(self.entries, key=lambda key: self.entries[key].get("attempted_at") or "")
            total = sum(self.sizes.values())
            for key in ordered:
                if len(self.entries) <= 256 and total <= 32 * 1024 * 1024:
                    break
                total -= self.sizes.pop(key, 0)
                self.entries.pop(key, None)

    def _save(self):
        if self.path is None:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(self.path.name + ".tmp")
        data = {"version": 1, "entries": self.entries}
        try:
            with temporary.open("w", encoding="utf-8") as output:
                json.dump(data, output, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
        except OSError:
            logging.exception("Snapshot remains in memory; disk cache update failed")
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass


def age_seconds(entry: dict[str, Any] | None, now: datetime) -> float | None:
    date = parse_date(entry.get("fetched_at")) if entry else None
    return max(0.0, (now - date).total_seconds()) if date else None


def entry_is_fresh(entry: dict[str, Any] | None, now: datetime, ttl: float) -> bool:
    age = age_seconds(entry, now)
    date = parse_date(entry.get("fetched_at")) if entry else None
    return bool(entry and entry.get("payload") is not None and date and date <= now and age is not None and age <= ttl)
