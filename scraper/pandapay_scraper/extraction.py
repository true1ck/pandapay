"""AD-4.3, originally scoped without an LLM key (see the Chunk 14 PROGRESS.md
entry): this is a deterministic, regex-based first pass — labeled
`model_name = 'heuristic-regex-v1'` everywhere it shows up, never anything
implying AI — that extracts percentage-rate and rupee-amount changes from a
diff. It is intentionally dumb: no LLM, no learned model, no claim of
understanding the text.

AD-4.3 follow-up (see `llm_extraction.py` and PROGRESS.md's AD-4.3 real-LLM
chunk): this module remains the fallback path. `llm_extraction.dispatch()` is
now the entry point run.py calls — it uses this heuristic when no
ANTHROPIC_API_KEY is configured (or EXTRACTION_MODE=heuristic is forced), and
falls back to it if a configured LLM call fails. It exists so
extraction_proposals/AD-4.4's "pre-filled, editable form" always has
*something* real to pre-fill from, with the same non-negotiable rule the plan
sets for real AI extraction: the operator verifies and corrects through the
existing typed writer (PUT /admin/reward-rules/:id, Chunk 6) — this module
never writes card data itself, only a proposal for a human to look at.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .diff import DiffResult

_PERCENT = re.compile(r"^(\d+(?:\.\d+)?)%$")
_RUPEE = re.compile(r"^(?:Rs\.?|₹)\s?([\d,]+(?:\.\d+)?)$", re.IGNORECASE)

HEURISTIC_MODEL_NAME = "heuristic-regex-v1"


@dataclass
class ExtractionProposal:
    proposed_fields: dict
    model_confidence: float
    evidence_excerpt: str
    model_name: str = HEURISTIC_MODEL_NAME


def _extract_numbers(words: list[str], pattern: re.Pattern) -> list[float]:
    values = []
    for word in words:
        match = pattern.match(word.strip(".,;:()"))
        if match:
            values.append(float(match.group(1).replace(",", "")))
    return values


def propose_from_diff(diff: DiffResult) -> ExtractionProposal | None:
    """Returns None when nothing regex-shaped was found — a low-confidence
    guess that isn't even numeric would be worse than no proposal, since
    AD-4.4's whole design assumes the operator is reviewing a plausible
    pre-fill, not decoding noise.
    """
    old_percents = _extract_numbers(diff.removed, _PERCENT)
    new_percents = _extract_numbers(diff.added, _PERCENT)
    old_rupees = _extract_numbers(diff.removed, _RUPEE)
    new_rupees = _extract_numbers(diff.added, _RUPEE)

    fields: dict = {}
    # Only propose a clean 1-for-1 swap — anything more ambiguous (e.g. two
    # percentages changed in the same diff) is exactly the case a human
    # needs to read the actual page for, not something to guess at.
    if len(old_percents) == 1 and len(new_percents) == 1 and old_percents != new_percents:
        fields["rate_percent"] = {"old": old_percents[0], "new": new_percents[0]}
    if len(old_rupees) == 1 and len(new_rupees) == 1 and old_rupees != new_rupees:
        fields["cap_value_inr"] = {"old": old_rupees[0], "new": new_rupees[0]}

    if not fields:
        return None

    # Confidence reflects how little this method actually understands: a
    # single clean swap of one kind is the best case (0.4, still capped
    # below the 0.5 "material" threshold used elsewhere in this codebase —
    # this is a hint, not a verified fact); two kinds changing at once is
    # more surface area for a wrong pairing, so confidence drops.
    confidence = 0.4 if len(fields) == 1 else 0.25

    return ExtractionProposal(
        proposed_fields=fields,
        model_confidence=confidence,
        evidence_excerpt=diff.summary(),
    )
