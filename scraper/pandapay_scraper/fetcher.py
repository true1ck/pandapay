"""AD-3.2.1: static fetch (httpx) tried first — cheaper and lighter than a
browser. Playwright fallback (for JS-rendered pages) is NOT implemented in
this build: it needs browser binaries (`playwright install chromium`, a few
hundred MB) that aren't provisioned in this environment. `fetch_with_js`
below raises rather than silently falling back to a possibly-empty static
fetch, so a JS-only page fails loudly instead of producing a false
"page has no content" result.
"""

from __future__ import annotations

from dataclasses import dataclass

import httpx

from .robots import USER_AGENT


@dataclass
class FetchResult:
    status_code: int
    html: str
    final_url: str


def fetch_static(client: httpx.Client, url: str) -> FetchResult:
    response = client.get(url, headers={"User-Agent": USER_AGENT}, timeout=20, follow_redirects=True)
    return FetchResult(status_code=response.status_code, html=response.text, final_url=str(response.url))


def fetch_with_js(url: str) -> FetchResult:
    raise NotImplementedError(
        "Playwright fallback (AD-3.2.1) is not implemented in this build — "
        "needs `playwright install chromium` (browser binaries not provisioned "
        "in this sandbox). Use fetch_static for now; a page requiring JS "
        "rendering will come back with thin/empty content from that path, "
        "which the caller should treat as a signal to investigate manually, "
        "not silently accept."
    )
