"""Bounded refresh workers and a real background polling loop."""

from __future__ import annotations

from concurrent.futures import Future, ThreadPoolExecutor, wait
from datetime import datetime, timedelta
import logging
import threading
from typing import Callable

from .cache import SnapshotCache, parse_date, utcnow
from .espn_provider import ESPNProvider, provider_url


class RefreshService:
    def __init__(self, provider: ESPNProvider, cache: SnapshotCache,
                 clock: Callable[[], datetime] = utcnow, tick_seconds: float = 15.0):
        self.provider = provider
        self.cache = cache
        self.clock = clock
        self.tick_seconds = tick_seconds
        self.executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="espn-refresh")
        self.slots = threading.BoundedSemaphore(32)
        self.lock = threading.RLock()
        self.pending: dict[str, Future] = {}
        self.requested: dict[str, datetime] = {}
        self.kickoffs: dict[str, datetime] = {}
        self.stop = threading.Event()
        self.thread: threading.Thread | None = None

    def start(self):
        if self.thread is None:
            self.thread = threading.Thread(target=self._run, name="context-scheduler", daemon=True)
            self.thread.start()

    def close(self):
        self.stop.set()
        if self.thread:
            self.thread.join(timeout=3)
        self.executor.shutdown(wait=True, cancel_futures=True)

    def interval(self, now: datetime | None = None) -> int:
        now = now or self.clock()
        with self.lock:
            close_game = any(-4 * 3600 <= (date - now).total_seconds() <= 6 * 3600 for date in self.kickoffs.values())
        return 120 if close_game else 900

    def watch(self, keys: list[str], game_id: str | None = None, kickoff: datetime | None = None):
        now = self.clock()
        with self.lock:
            # Bounded watch set: expire unattended games and feeds after a day.
            self.requested = {key: date for key, date in self.requested.items() if now - date < timedelta(days=1)}
            self.kickoffs = {key: date for key, date in self.kickoffs.items() if date > now - timedelta(hours=6)}
            for key in keys:
                provider_url(key)  # Validate before storing even in tests/custom providers.
                if key in self.requested or len(self.requested) < 192:
                    self.requested[key] = now
            if game_id and kickoff and (game_id in self.kickoffs or len(self.kickoffs) < 64):
                self.kickoffs[game_id] = kickoff

    def refresh(self, key: str, force: bool = False) -> Future | None:
        provider_url(key)
        now = self.clock()
        with self.lock:
            if key in self.pending:
                return self.pending[key]
            entry = self.cache.get(key)
            last_attempt = parse_date(entry.get("attempted_at")) if entry else None
            # Retry errors on the same schedule, avoiding storms from repeated client GETs.
            if not force and last_attempt and (now - last_attempt).total_seconds() < self.interval(now):
                return None
            if not self.slots.acquire(blocking=False):
                return None
            future = self.executor.submit(self._fetch, key)
            self.pending[key] = future
            future.add_done_callback(lambda completed: self._complete(key, completed))
            return future

    def _complete(self, key: str, future: Future):
        with self.lock:
            self.pending.pop(key, None)
            self.slots.release()

    def _fetch(self, key: str):
        try:
            payload, modified = self.provider.fetch(key)
            self.cache.record_success(key, payload, self.clock(), modified)
            return True
        except Exception as error:
            # HTTP errors and schema changes are data unavailability, never proof of health.
            self.cache.record_failure(key, self.clock(), str(error))
            logging.warning("ESPN refresh failed (%s): %s", key, type(error).__name__)
            return False

    def ensure(self, keys: list[str], budget_seconds: float = 8.0):
        futures = [future for key in keys if (future := self.refresh(key)) is not None]
        if futures and budget_seconds > 0:
            wait(futures, timeout=budget_seconds)

    def tick(self):
        now = self.clock()
        today = "scoreboard:" + now.strftime("%Y%m%d")
        self.watch(["injuries", "news", today])
        with self.lock:
            keys = list(self.requested)
        for key in keys:
            self.refresh(key)

    def _run(self):
        while not self.stop.is_set():
            try:
                self.tick()
            except Exception:
                logging.exception("Scheduler iteration failed")
            self.stop.wait(self.tick_seconds)
