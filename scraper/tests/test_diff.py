from pandapay_scraper.diff import compute_diff


def test_no_change_produces_no_meaningful_diff():
    result = compute_diff("Cashback rate: 5% on online spends", "Cashback rate: 5% on online spends")
    assert result.has_meaningful_change is False


def test_a_real_rate_change_is_detected():
    result = compute_diff(
        "Cashback rate: 5% on online spends, capped at Rs.1,000 per cycle.",
        "Cashback rate: 3% on online spends, capped at Rs.1,000 per cycle.",
    )
    assert result.has_meaningful_change is True
    assert "5%" in result.removed
    assert "3%" in result.added


def test_a_rotating_date_is_suppressed_as_noise():
    result = compute_diff(
        "Offer valid as of 2026-08-01. Cashback rate: 5% on online spends.",
        "Offer valid as of 2026-08-05. Cashback rate: 5% on online spends.",
    )
    assert result.has_meaningful_change is False


def test_a_small_view_counter_is_suppressed_as_noise():
    result = compute_diff(
        "128 people viewed this card today. Annual fee: Rs.499.",
        "241 people viewed this card today. Annual fee: Rs.499.",
    )
    assert result.has_meaningful_change is False


def test_noise_suppression_does_not_hide_a_real_change_next_to_noise():
    result = compute_diff(
        "128 people viewed this. Annual fee: Rs.499.",
        "241 people viewed this. Annual fee: Rs.999.",
    )
    assert result.has_meaningful_change is True
    assert "Rs.499." in result.removed
    assert "Rs.999." in result.added
    assert "128" not in result.removed
    assert "241" not in result.added
