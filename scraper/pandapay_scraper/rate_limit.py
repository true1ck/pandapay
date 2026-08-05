"""AD-3.1.3: aggressive rate limiting — >=5s between requests per host,
<=1 concurrent request per host. Enforced here rather than trusted to
caller discipline, since this is the one thing standing between "polite
weekly crawl" and "a bank notices load from us."
"""

from __future__ import annotations

import threading
import time
from urllib.parse import urlparse

MIN_INTERVAL_SECONDS = 5.0


class PerHostRateLimiter:
    def __init__(self, min_interval: float = MIN_INTERVAL_SECONDS):
        self._min_interval = min_interval
        self._last_request_at: dict[str, float] = {}
        # One lock per host would allow cross-host concurrency; a single
        # global lock is simpler and correct for the "<=1 concurrent
        # request, period" requirement across a single scraper process —
        # AD-3.3.3's pilot set is a handful of sources, not a fleet where
        # this would become a real bottleneck.
        self._lock = threading.Lock()

    def wait_for_turn(self, url: str) -> None:
        host = urlparse(url).netloc
        with self._lock:
            last = self._last_request_at.get(host)
            now = time.monotonic()
            if last is not None:
                elapsed = now - last
                if elapsed < self._min_interval:
                    time.sleep(self._min_interval - elapsed)
            self._last_request_at[host] = time.monotonic()
