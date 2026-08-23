"""Tests for the queue pipeline — profile merging, normalization, and promotion logic.

These tests run without a real DB by using lightweight in-process fakes.
They document the expected behavior of each pipeline step so regressions are
caught before anything reaches the actual DB.
"""
import pytest
from dataclasses import dataclass, field
from typing import Any


# ─── Shared fakes ─────────────────────────────────────────────────────────────

@dataclass
class FakeCursor:
    """Cursor that returns pre-canned fetchone() responses in order.
    
    promote_draft uses a single cursor for all queries via _cursor(), so
    this fake must support sequential execute+fetchone calls through one object.
    """
    _responses: list[Any]
    sqls: list[str] = field(default_factory=list)

    def execute(self, sql, params=None):
        self.sqls.append(sql.strip())

    def fetchone(self):
        return self._responses.pop(0) if self._responses else None

    def fetchall(self):
        return list(self._responses)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass


@dataclass
class FakeConn:
    """Connection that returns a single reusable cursor for all queries."""
    _cursor_obj: FakeCursor
    committed: bool = False

    def cursor(self):
        return self._cursor_obj

    def commit(self):
        self.committed = True


# ─── Phase 1: Profile data ────────────────────────────────────────────────────

def test_sbi_aurum_profile_shape():
    from pandapay_scraper.issuer_profiles import get_sbi_profile
    p = get_sbi_profile("SBI AURUM Credit Card")
    assert p["card_key"] == "sbi-aurum-credit-card"
    assert p["tier"] == "SUPER_PREMIUM"
    assert p["annual_fee_inr"] == 9999
    assert p["joining_fee_inr"] == 9999
    assert p["base_reward_rate"] == 4.0
    assert len(p["benefits"]) > 0
    assert p["forex"]["markup_percent"] == 1.99


def test_sbi_elite_profile_shape():
    from pandapay_scraper.issuer_profiles import get_sbi_profile
    p = get_sbi_profile("SBI Card ELITE")
    assert p["tier"] == "PREMIUM"
    assert p["annual_fee_inr"] == 4999
    # Must have dining + groceries at 5X
    dining = next((r for r in p["reward_rules"] if r["category_slug"] == "dining"), None)
    assert dining is not None
    assert dining["rate"] == 5.0


def test_unknown_profile_raises():
    from pandapay_scraper.issuer_profiles import get_sbi_profile
    with pytest.raises(KeyError, match="Unknown SBI profile"):
        get_sbi_profile("Fake Card XYZ")


def test_profile_returns_deep_copy():
    """Mutations to a returned profile must not affect subsequent calls."""
    from pandapay_scraper.issuer_profiles import get_sbi_profile
    p1 = get_sbi_profile("SBI AURUM Credit Card")
    p1["annual_fee_inr"] = 0
    p2 = get_sbi_profile("SBI AURUM Credit Card")
    assert p2["annual_fee_inr"] == 9999


# ─── Phase 2: Normalization merge ─────────────────────────────────────────────

def test_normalization_merges_profile_over_extracted():
    from pandapay_scraper.issuer_profiles import get_sbi_profile
    extracted = {"extracted_text": "some raw page text", "content_hash": "abc123"}
    profile = get_sbi_profile("SBI Card ELITE Advantage")
    merged = {**extracted, **profile}
    # Profile wins for structured fields
    assert merged["annual_fee_inr"] == 4999
    # Raw extraction is preserved
    assert merged["extracted_text"] == "some raw page text"


def test_normalization_all_four_sbi_cards():
    """All four target card names must yield a valid profile without error."""
    from pandapay_scraper.issuer_profiles import get_sbi_profile
    cards = [
        "SBI AURUM Credit Card",
        "SBI Card ELITE",
        "SBI Card ELITE Advantage",
        "SBI ELITE Credit Card",
    ]
    for name in cards:
        p = get_sbi_profile(name)
        assert p["card_key"], f"Missing card_key for {name}"
        assert p["annual_fee_inr"] > 0, f"Zero annual fee for {name}"


# ─── Phase 3: Promotion logic ─────────────────────────────────────────────────

def _make_draft(card_name="SBI AURUM Credit Card") -> dict:
    from pandapay_scraper.issuer_profiles import get_sbi_profile
    profile = get_sbi_profile(card_name)
    return {
        "id": "draft-001",
        "card_key": profile["card_key"],
        "card_name": card_name,
        "issuer_name": "State Bank of India",
        "network": "VISA",
        "source_url": "https://www.sbicard.com/aurum/",
        "source_id": "source-001",
        "source_page_id": None,
        "source_class": "issuer_official",
        "source_license": None,
        "as_of": None,
        "confidence": 0.95,
        "source_links": {},
        "normalized_fields": profile,
    }


def test_promotion_insert_branch_calls_insert():
    """When no existing product is found, INSERT should be called."""
    from pandapay_scraper import promotion as promo

    draft = _make_draft()
    issuer_row = {"id": "issuer-sbi", "name": "State Bank of India", "slug": "state-bank-of-india"}
    new_product_row = {"id": "product-001"}
    category_fuel = {"id": "cat-fuel-uuid"}

    # All execute+fetchone calls go through ONE cursor instance.
    # Response order matches the sequential fetchone() calls in promote_draft:
    #   draft, issuer, existing=None, inserted_product,
    #   (no fetchone for 7 DELETEs),
    #   fuel_category, (no fetchone for remaining INSERTs/UPDATE)
    cursor = FakeCursor([
        draft,              # SELECT draft
        issuer_row,         # SELECT issuer
        None,               # SELECT existing (not found -> INSERT path)
        new_product_row,    # INSERT card_products RETURNING id
        category_fuel,      # SELECT spend_categories 'fuel'
    ])
    conn = FakeConn(cursor)

    result = promo.promote_draft(conn, "draft-001")
    assert result == "product-001"
    assert conn.committed
    # The INSERT statement must have been issued (not UPDATE)
    insert_sqls = [s for s in cursor.sqls if s.startswith("INSERT INTO card_products")]
    assert len(insert_sqls) == 1, f"Expected 1 INSERT, got: {insert_sqls}"


def test_promotion_update_branch_calls_update():
    """When an existing product is found, UPDATE should be called."""
    from pandapay_scraper import promotion as promo

    draft = _make_draft()
    issuer_row = {"id": "issuer-sbi", "name": "State Bank of India", "slug": "state-bank-of-india"}
    existing_product = {"id": "product-existing"}
    category_fuel = {"id": "cat-fuel-uuid"}

    cursor = FakeCursor([
        draft,
        issuer_row,
        existing_product,   # SELECT existing -> found -> UPDATE path
        existing_product,   # UPDATE RETURNING id
        category_fuel,      # SELECT spend_categories 'fuel'
    ])
    conn = FakeConn(cursor)

    result = promo.promote_draft(conn, "draft-001")
    assert result == "product-existing"
    update_sqls = [s for s in cursor.sqls if s.startswith("UPDATE card_products")]
    assert len(update_sqls) == 1, f"Expected 1 UPDATE card_products, got: {update_sqls}"


def test_promotion_missing_category_slug_raises():
    """If a reward_rule's category_slug is not in spend_categories, ValueError is raised."""
    from pandapay_scraper import promotion as promo

    draft = _make_draft()
    draft["normalized_fields"] = {
        "reward_rules": [{"category_slug": "unknown-exotic-slug", "unit": "points_per_100", "rate": 5.0, "priority": 10}],
        "fee_waiver_rules": [], "milestone_rules": [], "benefits": [],
    }
    issuer_row = {"id": "issuer-sbi", "name": "State Bank of India", "slug": "state-bank-of-india"}
    new_product_row = {"id": "product-001"}

    # fetchone order: draft, issuer, no-existing, new product, then cat lookup -> None
    cursor = FakeCursor([
        draft,
        issuer_row,
        None,               # no existing product
        new_product_row,    # INSERT card_products
        None,               # SELECT spend_categories -> not found
    ])
    conn = FakeConn(cursor)

    with pytest.raises(ValueError, match="not found"):
        promo.promote_draft(conn, "draft-001")


def test_queue_job_model_defaults():
    from pandapay_scraper.queue_models import CardCrawlJob
    job = CardCrawlJob(card_target_id="t1", job_type="discover")
    assert job.state == "queued"
    assert job.priority == 100  # default per CardCrawlJob dataclass


def test_card_target_model_defaults():
    from pandapay_scraper.queue_models import CardTarget
    t = CardTarget(issuer_name="SBI", card_name="Aurum", card_key="sbi-aurum")
    assert t.status == "pending"
    assert t.aliases == []
