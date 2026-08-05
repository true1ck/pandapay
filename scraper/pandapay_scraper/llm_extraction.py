"""AD-4.3 real-LLM follow-up to `extraction.py`'s heuristic-only first pass.

**Honest status, read before trusting this module**: this code is real and
complete, but as of the session that wrote it, this environment has no
`ANTHROPIC_API_KEY` (checked: not in `api/.env`, and `scraper/.env` does not
exist — `scraper/example.env` is a template only). That means the LLM branch
below has never actually executed against a real Anthropic API in this
session. Everything that does NOT require a live key — the fallback-to-
heuristic behavior, the `EXTRACTION_MODE` dispatch logic, and the response
parser (fed a synthetic, hand-written example of a well-formed response) — is
covered by real unit tests (see `tests/test_llm_extraction.py`) and passes.
The one thing nobody can verify without a real key is whether the actual
network call to `claude-sonnet-5` behaves as documented. The moment a real
key lands in `scraper/.env` (gitignored) or the environment, `dispatch()`
picks it up automatically — no code change needed.

Design constraints this module follows (see PROGRESS.md's AD-4.3 chunk and
this codebase's established "never fabricate a capability" convention, e.g.
Chunk 14's heuristic-vs-AI labeling in the console UI):

- Never silently produce empty/wrong results and never let a bad LLM
  response, a network error, or a missing key crash `run.py`'s crawl loop.
  Every failure mode here falls back to the heuristic extractor.
- `model_name` on every `ExtractionProposal` says exactly which path
  produced it (`heuristic-regex-v1` vs `llm-claude-sonnet-5`) — this is what
  reaches the DB (`extraction_proposals.model_name`), the API, and the
  console UI, so operators always know whether a proposal is a real model's
  read of the page or just a regex swap.
- `EXTRACTION_MODE` (env var: `heuristic` | `llm` | `auto`, default `auto`)
  lets an operator force heuristic-only even with a key present, for cost
  control — matching AD-8/AD-9's explicit "no hidden automatic cost/behavior
  changes" stance from earlier chunks.
"""

from __future__ import annotations

import json
import logging
import os

from .diff import DiffResult
from .extraction import ExtractionProposal, propose_from_diff

logger = logging.getLogger(__name__)

LLM_MODEL = "claude-sonnet-5"
LLM_MODEL_NAME_LABEL = f"llm-{LLM_MODEL}"

_VALID_MODES = {"heuristic", "llm", "auto"}

# The exact fields the heuristic extractor targets (see extraction.py) — the
# LLM prompt asks for the same shape so both paths produce a proposal the
# rest of the pipeline (db.insert_extraction_proposal, the console review UI)
# can treat identically.
_SYSTEM_PROMPT = (
    "You extract structured reward-policy field changes from a diff of a "
    "credit card issuer's webpage. You will be given the removed and added "
    "text from a diff. Identify ONLY clean, unambiguous swaps of these two "
    "field kinds:\n"
    "  - rate_percent: a cashback/reward percentage rate, e.g. '5%' -> '3%'\n"
    "  - cap_value_inr: a rupee cap/limit amount, e.g. 'Rs.1,000' -> 'Rs.500'\n"
    "Respond with ONLY a single JSON object, no prose, no markdown fences, "
    "in exactly this shape:\n"
    '{"proposed_fields": {"rate_percent": {"old": <number>, "new": <number>}, '
    '"cap_value_inr": {"old": <number>, "new": <number>}}, '
    '"model_confidence": <float 0-1>}\n'
    "Omit a key from proposed_fields entirely if that kind of value did not "
    "have a clean 1-for-1 change. If nothing regex-shaped or unambiguous "
    "changed, return {\"proposed_fields\": {}, \"model_confidence\": 0.0}. "
    "Never guess when multiple candidates of the same kind changed at once — "
    "omit that field instead."
)


def _extraction_mode() -> str:
    """Reads EXTRACTION_MODE the same way db.py reads SCRAPER_DATABASE_URL —
    plain os.environ.get, no dotenv magic (this codebase doesn't auto-load
    .env files; operators export vars or use a process manager that does).
    Falls back to 'auto' on anything unrecognized rather than raising, since
    a scraper run should never crash over a config typo.
    """
    mode = os.environ.get("EXTRACTION_MODE", "auto").strip().lower()
    if mode not in _VALID_MODES:
        logger.warning(
            "EXTRACTION_MODE=%r is not one of %s — falling back to 'auto'", mode, sorted(_VALID_MODES)
        )
        return "auto"
    return mode


def _api_key() -> str | None:
    key = os.environ.get("ANTHROPIC_API_KEY")
    return key if key else None


def dispatch(diff: DiffResult) -> ExtractionProposal | None:
    """The single entry point run.py calls in place of extraction.propose_from_diff
    directly. Decides heuristic vs LLM per EXTRACTION_MODE + key presence,
    logs which path ran (auditable — matches the "heuristic, not AI" print
    line run.py already had), and never lets an LLM failure propagate past
    this function: any exception from the LLM path falls back to heuristic.
    """
    mode = _extraction_mode()
    key = _api_key()

    if mode == "heuristic":
        logger.info("extraction path: heuristic (EXTRACTION_MODE=heuristic)")
        return propose_from_diff(diff)

    if mode == "llm" and key is None:
        # Explicit request for LLM mode with no key is a config error, not a
        # silent downgrade — the operator asked for something that can't
        # happen. Still don't crash the crawl run over it: fall back and say
        # loudly why.
        logger.warning(
            "EXTRACTION_MODE=llm but ANTHROPIC_API_KEY is not set — "
            "falling back to heuristic extraction"
        )
        return propose_from_diff(diff)

    if mode == "auto" and key is None:
        logger.info("extraction path: heuristic (no ANTHROPIC_API_KEY, EXTRACTION_MODE=auto)")
        return propose_from_diff(diff)

    # mode is "llm", or "auto" with a key present — attempt the real call.
    logger.info("extraction path: llm (%s)", LLM_MODEL)
    try:
        proposal = _propose_via_llm(diff, api_key=key)
    except Exception:  # noqa: BLE001 — any LLM/network/parse failure must not crash the crawl loop
        logger.exception("LLM extraction failed — falling back to heuristic extraction")
        return propose_from_diff(diff)

    if proposal is None:
        logger.info("LLM extraction found nothing regex/field-shaped to propose")
    return proposal


def _propose_via_llm(diff: DiffResult, *, api_key: str) -> ExtractionProposal | None:
    """Makes the real Anthropic API call and parses the response. Raises on
    any failure (network, API error, malformed JSON, unexpected shape) —
    dispatch() is the layer that catches and falls back to heuristic, so
    this function is free to fail loudly and stay simple.
    """
    import anthropic  # imported lazily so importing this module never requires the package to be installed at heuristic-only sites

    client = anthropic.Anthropic(api_key=api_key)

    user_content = (
        f"Removed text:\n{' '.join(diff.removed) or '(nothing removed)'}\n\n"
        f"Added text:\n{' '.join(diff.added) or '(nothing added)'}"
    )

    response = client.messages.create(
        model=LLM_MODEL,
        max_tokens=1024,
        system=_SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_content}],
    )

    text = "".join(block.text for block in response.content if getattr(block, "type", None) == "text")
    return _parse_llm_response(text, evidence_excerpt=diff.summary())


def _parse_llm_response(raw_text: str, *, evidence_excerpt: str) -> ExtractionProposal | None:
    """Defensive parsing: a well-formed response yields a proposal; anything
    malformed (non-JSON, wrong shape, wrong types) raises ValueError rather
    than silently producing a proposal that could corrupt page_snapshots/
    policy_change_alerts downstream — the caller (dispatch, or a caller-of-
    _propose_via_llm) is responsible for catching and falling back.
    """
    text = raw_text.strip()
    # Strip a markdown code fence if the model wrapped its JSON in one
    # despite being told not to — defensive, not an expected happy path.
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:]
        text = text.strip()

    try:
        parsed = json.loads(text)
    except (json.JSONDecodeError, ValueError) as exc:
        raise ValueError(f"LLM response was not valid JSON: {exc}") from exc

    if not isinstance(parsed, dict):
        raise ValueError(f"LLM response JSON was not an object: {type(parsed).__name__}")

    proposed_fields = parsed.get("proposed_fields")
    if not isinstance(proposed_fields, dict):
        raise ValueError("LLM response missing/invalid 'proposed_fields' object")

    for key, value in proposed_fields.items():
        if key not in ("rate_percent", "cap_value_inr"):
            raise ValueError(f"LLM response proposed an unrecognized field: {key!r}")
        if not isinstance(value, dict) or "old" not in value or "new" not in value:
            raise ValueError(f"LLM response field {key!r} is missing old/new: {value!r}")
        for side in ("old", "new"):
            if not isinstance(value[side], (int, float)) or isinstance(value[side], bool):
                raise ValueError(f"LLM response field {key!r}.{side} is not numeric: {value[side]!r}")

    confidence = parsed.get("model_confidence")
    if not isinstance(confidence, (int, float)) or isinstance(confidence, bool):
        raise ValueError(f"LLM response 'model_confidence' is not numeric: {confidence!r}")
    if not (0.0 <= float(confidence) <= 1.0):
        raise ValueError(f"LLM response 'model_confidence' out of range [0,1]: {confidence!r}")

    if not proposed_fields:
        return None

    return ExtractionProposal(
        proposed_fields=proposed_fields,
        model_confidence=float(confidence),
        evidence_excerpt=evidence_excerpt,
        model_name=LLM_MODEL_NAME_LABEL,
    )
