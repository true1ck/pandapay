"""AD-3.1.1: robots.txt gate. A disallowed path is *never* fetched — this
check runs before every single fetch, not just once at source-creation time,
because a bank can change robots.txt at any point after we start crawling.
"""

from __future__ import annotations

import time
import urllib.robotparser
from dataclasses import dataclass
from urllib.parse import urljoin, urlparse

import httpx

USER_AGENT = "PandaPayBot/1.0 (+https://pandapay.example/bot; contact: bot@pandapay.example)"


@dataclass
class RobotsResult:
    allowed: bool
    checked_at: float


class RobotsChecker:
    """One robots.txt fetch per host, cached in-memory for the process
    lifetime (a scrape run is short-lived; a fresh process re-checks).
    """

    def __init__(self, client: httpx.Client):
        self._client = client
        self._cache: dict[str, urllib.robotparser.RobotFileParser] = {}

    def _parser_for_host(self, url: str) -> urllib.robotparser.RobotFileParser:
        parsed = urlparse(url)
        host_key = f"{parsed.scheme}://{parsed.netloc}"
        if host_key in self._cache:
            return self._cache[host_key]

        parser = urllib.robotparser.RobotFileParser()
        robots_url = urljoin(host_key, "/robots.txt")
        try:
            response = self._client.get(robots_url, headers={"User-Agent": USER_AGENT}, timeout=10)
            if response.status_code == 200:
                parser.parse(response.text.splitlines())
            else:
                # No robots.txt (404) or inaccessible — RobotFileParser's own
                # convention is "allow all" for a missing file, which matches
                # standard robots.txt semantics (absence != disallow).
                parser.parse([])
        except httpx.HTTPError:
            # Network failure fetching robots.txt itself: fail CLOSED, not
            # open — AD-3.1.1's whole point is "never fetch a disallowed
            # path", and an unreadable robots.txt is not proof of allowance.
            parser.parse(["User-agent: *", "Disallow: /"])

        self._cache[host_key] = parser
        return parser

    def is_allowed(self, url: str) -> RobotsResult:
        parser = self._parser_for_host(url)
        return RobotsResult(allowed=parser.can_fetch(USER_AGENT, url), checked_at=time.time())
