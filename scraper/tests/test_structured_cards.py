import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

from pandapay_scraper.structured_cards import (
    load_cards_from_csv,
    load_cards_from_json,
    load_cards_from_path,
    normalize_card_record,
)
from pandapay_scraper import structured_import


def test_normalize_cardadvisor_style_json_row_maps_key_fields():
    draft = normalize_card_record(
        {
            "cardKey": "hdfc-infinia",
            "name": "HDFC Infinia Metal",
            "issuer": "HDFC Bank",
            "network": "VISA",
            "tier": "SUPER_PREMIUM",
            "annualFeeRs": 12500,
            "joiningFeeRs": 2500,
            "lifetimeFree": False,
            "feeWaiverSpendRs": 800000,
            "forexMarkupPct": 2.0,
            "rewardRateMinPct": 1.0,
            "rewardRateMaxPct": 5.0,
            "lastVerified": "2026-08-16",
            "url": "https://cardadvisor.in/cards/hdfc-infinia",
            "rewards": [
                {
                    "categoryName": "Dining",
                    "rewardType": "points",
                    "ratePct": 5.0,
                    "monthlyCapRs": 10000,
                    "pointValuePaisa": 75,
                    "merchants": ["Swiggy", "Zomato"],
                },
                {
                    "categoryName": "All other spends",
                    "rewardType": "points",
                    "ratePct": 1.0,
                    "monthlyCapRs": None,
                    "pointValuePaisa": 75,
                },
            ],
            "perks": [{"perkType": "LOUNGE_ACCESS", "description": "Airport lounge access"}],
        },
        source_url="https://cardadvisor.in/data",
    )

    assert draft.card_key == "hdfc-infinia"
    assert draft.card_name == "HDFC Infinia Metal"
    assert draft.issuer_name == "HDFC Bank"
    assert draft.network == "VISA"
    assert draft.tier == "SUPER_PREMIUM"
    assert draft.as_of.isoformat() == "2026-08-16"
    assert draft.normalized_fields["annual_fee_inr"] == 12500.0
    assert draft.normalized_fields["reward_rate_max_pct"] == 5.0
    assert draft.normalized_fields["reward_rate_min_pct"] == 1.0
    assert draft.normalized_fields["rewards"][0]["category"] == "Dining"
    assert draft.normalized_fields["rewards"][0]["rate_pct"] == 5.0
    assert draft.normalized_fields["perks"][0]["perk_type"] == "LOUNGE_ACCESS"
    assert draft.confidence is not None and draft.confidence > 0.9


def test_normalize_card_record_derives_key_and_summary_rates_when_missing():
    draft = normalize_card_record(
        {
            "name": "Super Saver Card",
            "issuer": "Bank X",
            "rewards": [
                {"category": "Fuel", "rate": "2%", "pointValuePaisa": 100},
                {"category": "Dining", "rate": "5%", "pointValuePaisa": 100},
            ],
        }
    )

    assert draft.card_key == "bank-x-super-saver-card"
    assert draft.source_url.startswith("structured://")
    assert draft.normalized_fields["reward_rate_min_pct"] == 2.0
    assert draft.normalized_fields["reward_rate_max_pct"] == 5.0


def test_load_cards_from_json_supports_top_level_cards_and_dataset_metadata():
    drafts = load_cards_from_json(
        """
        {
          "asOf": "2026-08-16",
          "url": "https://cardadvisor.in/data",
          "cards": [
            {"cardKey": "card-a", "name": "Card A", "issuer": "Issuer A", "annualFeeRs": 0},
            {"cardKey": "card-b", "name": "Card B", "issuer": "Issuer B", "annualFeeRs": 500}
          ]
        }
        """
    )

    assert [draft.card_key for draft in drafts] == ["card-a", "card-b"]
    assert all(draft.source_url == "https://cardadvisor.in/data" for draft in drafts)
    assert all(draft.as_of.isoformat() == "2026-08-16" for draft in drafts)


def test_load_cards_from_csv_handles_flat_dataset():
    drafts = load_cards_from_csv(
        "cardKey,name,issuer,annualFeeRs,rewardRateMinPct,rewardRateMaxPct\n"
        "card-c,Card C,Issuer C,999,1.5,4.5\n"
    )

    assert len(drafts) == 1
    draft = drafts[0]
    assert draft.card_key == "card-c"
    assert draft.normalized_fields["annual_fee_inr"] == 999.0
    assert draft.normalized_fields["reward_rate_min_pct"] == 1.5
    assert draft.normalized_fields["reward_rate_max_pct"] == 4.5


def test_load_cards_from_path_supports_jsonl():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = Path(tmpdir) / "cards.jsonl"
        path.write_text(
            '{"cardKey":"card-a","name":"Card A","issuer":"Issuer A"}\n'
            '\n'
            '{"cardKey":"card-b","name":"Card B","issuer":"Issuer B"}\n',
            encoding="utf-8",
        )

        drafts = load_cards_from_path(path)

        assert [draft.card_key for draft in drafts] == ["card-a", "card-b"]


def test_load_cards_from_path_supports_txt_json_and_csv_fallback():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = Path(tmpdir) / "cards.txt"
        path.write_text('{"cards":[{"cardKey":"card-a","name":"Card A","issuer":"Issuer A"}]}', encoding="utf-8")

        # JSON first: the helper should parse the top-level object.
        assert load_cards_from_path(path)[0].card_key == "card-a"

        # Re-write the same file as CSV and the fallback should kick in.
        path.write_text("cardKey,name,issuer\ncard-b,Card B,Issuer B\n", encoding="utf-8")
        drafts = load_cards_from_path(path)
        assert drafts[0].card_key == "card-b"


def test_load_cards_from_json_ignores_non_object_records():
    drafts = load_cards_from_json('[{"cardKey":"card-a","name":"Card A","issuer":"Issuer A"}, 123, "x"]')
    assert [draft.card_key for draft in drafts] == ["card-a"]


def test_remote_loader_uses_csv_for_csv_content_type(monkeypatch):
    monkeypatch.setattr(
        structured_import,
        "_download_dataset",
        lambda url: ("cardKey,name,issuer\ncard-a,Card A,Issuer A\n", "text/csv"),
    )

    drafts = structured_import._load_from_remote(
        "https://example.test/cards.csv",
        source_class="third_party_structured",
        source_license="CC BY 4.0",
        source_url=None,
    )

    assert drafts[0].card_key == "card-a"


def test_remote_loader_defaults_to_json_when_suffix_and_content_type_are_missing(monkeypatch):
    monkeypatch.setattr(
        structured_import,
        "_download_dataset",
        lambda url: ('{"cards":[{"cardKey":"card-a","name":"Card A","issuer":"Issuer A"}]}', "application/octet-stream"),
    )

    drafts = structured_import._load_from_remote(
        "https://example.test/cards",
        source_class="third_party_structured",
        source_license="CC BY 4.0",
        source_url=None,
    )

    assert drafts[0].card_key == "card-a"


def test_main_write_db_uses_source_base_url_lookup(monkeypatch):
    from pandapay_scraper import structured_import as module

    source_row = {"id": "source-1"}
    inserted = []

    class FakeConn:
        def close(self):
            return None

    fake_db = SimpleNamespace(
        connect=lambda: FakeConn(),
        source_by_base_url=lambda conn, base_url: source_row if base_url == "https://cardadvisor.in/data" else None,
        source_by_name=lambda conn, name: None,
        insert_card_source_draft=lambda conn, **kwargs: inserted.append(kwargs) or "draft-1",
    )

    monkeypatch.setattr(module, "load_cards_from_path", lambda path, **kwargs: [normalize_card_record({"cardKey": "card-a", "name": "Card A", "issuer": "Issuer A"})])
    monkeypatch.setitem(sys.modules, "pandapay_scraper.db", fake_db)

    with tempfile.TemporaryDirectory() as tmpdir:
        path = Path(tmpdir) / "cards.json"
        path.write_text('{"cards":[{"cardKey":"card-a","name":"Card A","issuer":"Issuer A"}]}', encoding="utf-8")

        rc = module.main([
            "--input",
            str(path),
            "--write-db",
            "--source-base-url",
            "https://cardadvisor.in/data",
        ])

        assert rc == 0
        assert inserted and inserted[0]["source_id"] == "source-1"
        assert inserted[0]["card_key"] == "card-a"
