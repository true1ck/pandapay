import pytest

from review_source import check_confirm_tos_read, check_note, check_robots_disallow


def test_note_too_short_is_rejected():
    with pytest.raises(ValueError):
        check_note("too short")


def test_note_long_enough_is_accepted():
    check_note("Read the issuer's public terms of service page in full.")


def test_missing_confirm_flag_is_rejected():
    with pytest.raises(ValueError):
        check_confirm_tos_read(False)


def test_confirm_flag_present_is_accepted():
    check_confirm_tos_read(True)


def test_blanket_robots_disallow_requires_acknowledgement():
    with pytest.raises(ValueError):
        check_robots_disallow(False, acknowledged=False, source_name="AU Small Finance Bank")


def test_blanket_robots_disallow_passes_when_acknowledged():
    check_robots_disallow(False, acknowledged=True, source_name="AU Small Finance Bank")


def test_robots_allowed_never_blocks_regardless_of_acknowledgement():
    check_robots_disallow(True, acknowledged=False, source_name="ICICI Bank")


def test_unknown_robots_status_never_blocks():
    check_robots_disallow(None, acknowledged=False, source_name="HDFC Bank")
