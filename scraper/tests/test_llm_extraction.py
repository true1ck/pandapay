"""AD-4.3 real-LLM follow-up tests. Everything here is pure-logic — no real
network call to Anthropic is made (there's no key in this environment to
make one with, and this codebase's other unit tests don't hit live services
either; see `scraper/pandapay_scraper/llm_extraction.py`'s module docstring).

Covered:
  - EXTRACTION_MODE dispatch logic for all three modes, with and without a key
  - Fallback-to-heuristic when no key is present (the default, unmodified
    behavior for anyone who hasn't configured AD-4.3)
  - The response parser, fed synthetic hand-written JSON strings standing in
    for what a well-formed (and malformed) LLM response would look like
"""

from __future__ import annotations

import pytest

import pandapay_scraper.llm_extraction as llm_extraction
from pandapay_scraper.diff import compute_diff
from pandapay_scraper.extraction import HEURISTIC_MODEL_NAME
from pandapay_scraper.llm_extraction import LLM_MODEL_NAME_LABEL, _parse_llm_response, dispatch


# ---------------------------------------------------------------------------
# EXTRACTION_MODE dispatch + fallback-to-heuristic (no real API call made)
# ---------------------------------------------------------------------------


def _clean_percent_diff():
    return compute_diff(
        "Cashback rate: 5% on online spends.",
        "Cashback rate: 3% on online spends.",
    )


def test_no_key_in_environment_falls_back_to_heuristic(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("EXTRACTION_MODE", raising=False)

    proposal = dispatch(_clean_percent_diff())

    assert proposal is not None
    assert proposal.model_name == HEURISTIC_MODEL_NAME
    assert proposal.proposed_fields == {"rate_percent": {"old": 5.0, "new": 3.0}}


def test_extraction_mode_heuristic_forces_heuristic_even_with_a_key(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-fake-key-for-testing-only")
    monkeypatch.setenv("EXTRACTION_MODE", "heuristic")

    proposal = dispatch(_clean_percent_diff())

    assert proposal is not None
    assert proposal.model_name == HEURISTIC_MODEL_NAME


def test_extraction_mode_llm_without_a_key_falls_back_to_heuristic(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setenv("EXTRACTION_MODE", "llm")

    proposal = dispatch(_clean_percent_diff())

    assert proposal is not None
    assert proposal.model_name == HEURISTIC_MODEL_NAME


def test_extraction_mode_auto_without_a_key_uses_heuristic(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setenv("EXTRACTION_MODE", "auto")

    proposal = dispatch(_clean_percent_diff())

    assert proposal is not None
    assert proposal.model_name == HEURISTIC_MODEL_NAME


def test_extraction_mode_auto_with_a_key_attempts_llm_path(monkeypatch):
    """With a key present and mode=auto, dispatch() must call the LLM path
    (_propose_via_llm), not silently skip straight to heuristic. Mocked —
    no real network call. See the next test for the failure/fallback case.
    """
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-fake-key-for-testing-only")
    monkeypatch.setenv("EXTRACTION_MODE", "auto")

    called_with = {}

    def fake_propose_via_llm(diff, *, api_key):
        called_with["api_key"] = api_key
        from pandapay_scraper.extraction import ExtractionProposal

        return ExtractionProposal(
            proposed_fields={"rate_percent": {"old": 5.0, "new": 3.0}},
            model_confidence=0.9,
            evidence_excerpt="stub",
            model_name=LLM_MODEL_NAME_LABEL,
        )

    monkeypatch.setattr(llm_extraction, "_propose_via_llm", fake_propose_via_llm)

    proposal = dispatch(_clean_percent_diff())

    assert called_with["api_key"] == "sk-ant-fake-key-for-testing-only"
    assert proposal is not None
    assert proposal.model_name == LLM_MODEL_NAME_LABEL


def test_extraction_mode_auto_with_a_key_falls_back_when_llm_call_raises(monkeypatch):
    """If the LLM call raises for any reason (network error, API error,
    malformed response), dispatch() must catch it and fall back to
    heuristic rather than propagating the exception or crashing the crawl.
    Mocked — no real network call.
    """
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-fake-key-for-testing-only")
    monkeypatch.setenv("EXTRACTION_MODE", "auto")

    def raising_propose_via_llm(diff, *, api_key):
        raise RuntimeError("simulated network/API failure")

    monkeypatch.setattr(llm_extraction, "_propose_via_llm", raising_propose_via_llm)

    proposal = dispatch(_clean_percent_diff())

    assert proposal is not None
    assert proposal.model_name == HEURISTIC_MODEL_NAME


def test_unrecognized_extraction_mode_falls_back_to_auto_semantics(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setenv("EXTRACTION_MODE", "not-a-real-mode")

    proposal = dispatch(_clean_percent_diff())

    assert proposal is not None
    assert proposal.model_name == HEURISTIC_MODEL_NAME


def test_dispatch_returns_none_when_heuristic_finds_nothing(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    diff = compute_diff(
        "Terms and conditions apply to this offer.",
        "Terms and conditions may apply to this offer.",
    )

    assert dispatch(diff) is None


# ---------------------------------------------------------------------------
# Response parser — fed synthetic, hand-written LLM-shaped JSON strings.
# This tests our own parsing/validation logic, not a live model response.
# ---------------------------------------------------------------------------


def test_parses_a_well_formed_single_field_response():
    raw = (
        '{"proposed_fields": {"rate_percent": {"old": 5, "new": 3}}, '
        '"model_confidence": 0.82}'
    )

    proposal = _parse_llm_response(raw, evidence_excerpt="- 5%\n+ 3%")

    assert proposal is not None
    assert proposal.model_name == LLM_MODEL_NAME_LABEL
    assert proposal.proposed_fields == {"rate_percent": {"old": 5.0, "new": 3.0}}
    assert proposal.model_confidence == 0.82
    assert proposal.evidence_excerpt == "- 5%\n+ 3%"


def test_parses_a_well_formed_two_field_response():
    raw = (
        '{"proposed_fields": {'
        '"rate_percent": {"old": 5, "new": 3}, '
        '"cap_value_inr": {"old": 1000, "new": 500}'
        '}, "model_confidence": 0.6}'
    )

    proposal = _parse_llm_response(raw, evidence_excerpt="excerpt")

    assert proposal is not None
    assert proposal.proposed_fields == {
        "rate_percent": {"old": 5.0, "new": 3.0},
        "cap_value_inr": {"old": 1000.0, "new": 500.0},
    }


def test_strips_a_markdown_code_fence_the_model_wasnt_supposed_to_add():
    raw = (
        "```json\n"
        '{"proposed_fields": {"rate_percent": {"old": 5, "new": 3}}, '
        '"model_confidence": 0.5}\n'
        "```"
    )

    proposal = _parse_llm_response(raw, evidence_excerpt="excerpt")

    assert proposal is not None
    assert proposal.proposed_fields == {"rate_percent": {"old": 5.0, "new": 3.0}}


def test_empty_proposed_fields_returns_none_not_an_empty_proposal():
    raw = '{"proposed_fields": {}, "model_confidence": 0.0}'

    assert _parse_llm_response(raw, evidence_excerpt="excerpt") is None


def test_non_json_response_raises_value_error_rather_than_corrupting_data():
    with pytest.raises(ValueError, match="not valid JSON"):
        _parse_llm_response("Sure, here's the analysis: the rate changed.", evidence_excerpt="x")


def test_json_array_instead_of_object_raises():
    with pytest.raises(ValueError, match="not an object"):
        _parse_llm_response("[1, 2, 3]", evidence_excerpt="x")


def test_missing_proposed_fields_key_raises():
    with pytest.raises(ValueError, match="proposed_fields"):
        _parse_llm_response('{"model_confidence": 0.5}', evidence_excerpt="x")


def test_unrecognized_field_name_raises_rather_than_silently_accepting_it():
    raw = '{"proposed_fields": {"totally_made_up_field": {"old": 1, "new": 2}}, "model_confidence": 0.5}'
    with pytest.raises(ValueError, match="unrecognized field"):
        _parse_llm_response(raw, evidence_excerpt="x")


def test_field_missing_old_or_new_raises():
    raw = '{"proposed_fields": {"rate_percent": {"old": 5}}, "model_confidence": 0.5}'
    with pytest.raises(ValueError, match="missing old/new"):
        _parse_llm_response(raw, evidence_excerpt="x")


def test_non_numeric_old_new_raises():
    raw = '{"proposed_fields": {"rate_percent": {"old": "five", "new": 3}}, "model_confidence": 0.5}'
    with pytest.raises(ValueError, match="not numeric"):
        _parse_llm_response(raw, evidence_excerpt="x")


def test_boolean_old_new_is_rejected_despite_being_a_python_int_subtype():
    raw = '{"proposed_fields": {"rate_percent": {"old": true, "new": 3}}, "model_confidence": 0.5}'
    with pytest.raises(ValueError, match="not numeric"):
        _parse_llm_response(raw, evidence_excerpt="x")


def test_missing_model_confidence_raises():
    raw = '{"proposed_fields": {"rate_percent": {"old": 5, "new": 3}}}'
    with pytest.raises(ValueError, match="model_confidence"):
        _parse_llm_response(raw, evidence_excerpt="x")


def test_out_of_range_model_confidence_raises():
    raw = '{"proposed_fields": {"rate_percent": {"old": 5, "new": 3}}, "model_confidence": 1.5}'
    with pytest.raises(ValueError, match="out of range"):
        _parse_llm_response(raw, evidence_excerpt="x")
