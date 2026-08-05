"""AD-3.2.2/3.2.3: normalize a fetched page to boilerplate-free text and
hash it, so nav/footer churn (a date in a footer, a rotating banner) doesn't
produce a false "the page changed" diff every single crawl.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

from selectolax.parser import HTMLParser

# Tags whose content is never the actual reward-T&C prose we care about.
_BOILERPLATE_TAGS = ("script", "style", "nav", "footer", "header", "noscript", "svg", "form")


@dataclass
class ExtractedContent:
    text: str
    content_hash: str


def extract(html: str, selector_hint: str | None = None) -> ExtractedContent:
    """`selector_hint` (source_pages.selector_hint) scopes extraction to a
    specific container when the page's boilerplate/content ratio is bad
    (e.g. '#main-content'); falls back to <body> when absent or not found.
    """
    tree = HTMLParser(html)

    for tag in _BOILERPLATE_TAGS:
        for node in tree.css(tag):
            node.decompose()

    root = None
    if selector_hint:
        root = tree.css_first(selector_hint)
    if root is None:
        root = tree.body or tree.root

    text = root.text(separator=" ", strip=True) if root is not None else ""
    normalized = " ".join(text.split())  # collapse whitespace runs

    content_hash = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    return ExtractedContent(text=normalized, content_hash=content_hash)
