from pandapay_scraper.diff import compute_diff
from pandapay_scraper.extraction import propose_from_diff


def test_a_clean_percent_swap_is_proposed():
    diff = compute_diff(
        "Cashback rate: 5% on online spends.",
        "Cashback rate: 3% on online spends.",
    )
    proposal = propose_from_diff(diff)
    assert proposal is not None
    assert proposal.proposed_fields == {"rate_percent": {"old": 5.0, "new": 3.0}}
    assert proposal.model_confidence == 0.4


def test_a_clean_rupee_cap_swap_is_proposed():
    diff = compute_diff(
        "Capped at Rs.1,000 per cycle.",
        "Capped at Rs.500 per cycle.",
    )
    proposal = propose_from_diff(diff)
    assert proposal is not None
    assert proposal.proposed_fields == {"cap_value_inr": {"old": 1000.0, "new": 500.0}}


def test_both_a_rate_and_cap_change_lowers_confidence():
    diff = compute_diff(
        "Cashback rate: 5% on online spends, capped at Rs.1,000 per cycle.",
        "Cashback rate: 3% on online spends, capped at Rs.500 per cycle.",
    )
    proposal = propose_from_diff(diff)
    assert proposal is not None
    assert len(proposal.proposed_fields) == 2
    assert proposal.model_confidence == 0.25


def test_no_extractable_numbers_yields_no_proposal():
    diff = compute_diff(
        "Terms and conditions apply to this offer.",
        "Terms and conditions may apply to this offer.",
    )
    proposal = propose_from_diff(diff)
    assert proposal is None


def test_ambiguous_multiple_percents_of_the_same_kind_are_not_guessed():
    diff = compute_diff(
        "5% on groceries and 2% on dining.",
        "3% on groceries and 4% on dining.",
    )
    proposal = propose_from_diff(diff)
    # Two percent changes at once — deliberately not paired up, since
    # guessing which old value maps to which new one would be a fabrication,
    # not an extraction.
    assert proposal is None
