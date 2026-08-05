"""AD-4.1: word-level diff between the last two snapshots, with noise
suppression so a page's rotating date/counter doesn't produce a "change"
every single crawl — that's what makes AD-3.2.3's skip_unchanged actually
useful in practice, since content_hash alone would still flip on any
cosmetic churn a plain hash comparison can't see past.
"""

from __future__ import annotations

import difflib
import re
from dataclasses import dataclass

# Matches things that legitimately change on every render but never carry
# reward-policy meaning: ISO/common dates, "as of <date>", pure standalone
# numbers under 4 digits (page-view counters, "1,234 people viewed this").
_NOISE_PATTERNS = [
    re.compile(r"^\d{1,2}[/-]\d{1,2}[/-]\d{2,4}$"),  # 05/08/2026, 5-8-26
    re.compile(r"^\d{4}-\d{2}-\d{2}$"),  # 2026-08-05
    re.compile(r"^(january|february|march|april|may|june|july|august|"
               r"september|october|november|december)$", re.IGNORECASE),
    re.compile(r"^\d{1,3}$"),  # small standalone counters
]


@dataclass
class DiffResult:
    added: list[str]
    removed: list[str]

    @property
    def has_meaningful_change(self) -> bool:
        return bool(self.added or self.removed)

    def summary(self, max_words: int = 40) -> str:
        parts = []
        if self.removed:
            parts.append("- " + " ".join(self.removed[:max_words]))
        if self.added:
            parts.append("+ " + " ".join(self.added[:max_words]))
        return "\n".join(parts)


def _is_noise(word: str) -> bool:
    stripped = word.strip(".,;:()")
    return any(pattern.match(stripped) for pattern in _NOISE_PATTERNS)


def compute_diff(old_text: str, new_text: str) -> DiffResult:
    old_words = old_text.split()
    new_words = new_text.split()

    matcher = difflib.SequenceMatcher(a=old_words, b=new_words, autojunk=False)
    added: list[str] = []
    removed: list[str] = []

    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        removed_words = [w for w in old_words[i1:i2] if not _is_noise(w)]
        added_words = [w for w in new_words[j1:j2] if not _is_noise(w)]
        removed.extend(removed_words)
        added.extend(added_words)

    return DiffResult(added=added, removed=removed)
