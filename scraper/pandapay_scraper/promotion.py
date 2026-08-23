from __future__ import annotations

import re
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any

try:  # pragma: no cover - exercised in the real scraper environment
    from psycopg.types.json import Jsonb
except ImportError:  # pragma: no cover - lets unit tests run without psycopg
    def Jsonb(value):
        return value


try:  # pragma: no cover - the real environment provides this
    from . import db as scraper_db
except Exception:  # pragma: no cover - module remains importable for unit tests
    scraper_db = None

_SLUG_RE = re.compile(r"[^a-z0-9]+")


def _slugify(value: str) -> str:
    text = str(value or "").strip().lower()
    text = _SLUG_RE.sub("-", text)
    return text.strip("-")


def _pick_issuer(cur, draft: dict[str, Any]) -> dict[str, Any]:
    issuer_name = draft["issuer_name"]
    issuer_slug = _slugify(issuer_name)
    cur.execute(
        """
        SELECT *
          FROM issuers
         WHERE slug = %s OR lower(name) = lower(%s)
         ORDER BY CASE WHEN slug = %s THEN 0 ELSE 1 END
         LIMIT 1
        """,
        (issuer_slug, issuer_name, issuer_slug),
    )
    issuer = cur.fetchone()
    if issuer is None:
        raise ValueError(f"Issuer not found for draft {draft['id']}: {issuer_name}")
    return issuer


def _existing_product(cur, *, slug: str, issuer_id: str, card_name: str) -> dict[str, Any] | None:
    cur.execute(
        """
        SELECT *
          FROM card_products
         WHERE slug = %s
            OR (issuer_id = %s AND lower(name) = lower(%s))
         ORDER BY CASE WHEN slug = %s THEN 0 ELSE 1 END
         LIMIT 1
        """,
        (slug, issuer_id, card_name, slug),
    )
    return cur.fetchone()


@contextmanager
def _cursor(conn):
    with conn.cursor() as cur:
        yield cur
    if hasattr(conn, "commit"):
        conn.commit()


def promote_draft(conn, draft_id: str):
    """Promote a structured draft into the live card catalogue.

    Upserts card_products and refreshes all child rule tables atomically.
    Safe to call multiple times — child rows are deleted and re-inserted so
    re-promotion never accumulates duplicates.
    """
    with _cursor(conn) as cur:
        cur.execute("SELECT * FROM card_source_drafts WHERE id = %s", (draft_id,))
        draft = cur.fetchone()
        if draft is None:
            raise ValueError(f"Draft {draft_id} not found")

        fields = draft.get("normalized_fields") or {}

        issuer = _pick_issuer(cur, draft)
        slug = draft["card_key"] or _slugify(draft["card_name"])
        source_url = draft["source_url"]
        now = datetime.now(timezone.utc)
        source_links = {
            "primary": source_url,
            "dataset": (draft.get("source_links") or {}).get("dataset"),
        }
        source_links = {k: v for k, v in source_links.items() if v}
        provenance = {
            "draft_id": str(draft["id"]),
            "source_id": str(draft["source_id"]) if draft.get("source_id") else None,
            "source_page_id": str(draft["source_page_id"]) if draft.get("source_page_id") else None,
            "source_url": source_url,
            "source_class": draft["source_class"],
            "source_license": draft.get("source_license"),
            "card_key": draft["card_key"],
            "card_name": draft["card_name"],
            "issuer_name": draft["issuer_name"],
            "confidence": float(draft["confidence"]) if draft.get("confidence") is not None else None,
        }

        existing = _existing_product(cur, slug=slug, issuer_id=issuer["id"], card_name=draft["card_name"])

        # Shared scalar fields pulled from the normalized profile
        fee_fields = {
            "joining_fee_inr": fields.get("joining_fee_inr") or 0,
            "annual_fee_inr": fields.get("annual_fee_inr") or 0,
            "base_reward_unit": fields.get("base_reward_unit"),
            "base_reward_rate": fields.get("base_reward_rate"),
            "point_value_inr": fields.get("point_value_inr"),
        }

        if existing is not None:
            # UPDATE existing card — preserve identity, refresh every mutable field
            cur.execute(
                """
                UPDATE card_products
                   SET issuer_id         = %s,
                       slug              = %s,
                       name              = %s,
                       network           = %s,
                       card_type         = %s,
                       status            = %s,
                       verified_at       = COALESCE(%s, verified_at),
                       source_url        = %s,
                       source_class      = %s,
                       source_license    = %s,
                       source_links      = %s,
                       provenance        = %s,
                       joining_fee_inr   = %s,
                       annual_fee_inr    = %s,
                       base_reward_unit  = %s,
                       base_reward_rate  = %s,
                       point_value_inr   = %s,
                       updated_at        = now()
                 WHERE id = %s
                RETURNING id
                """,
                (
                    issuer["id"],
                    slug,
                    draft["card_name"],
                    (draft.get("network") or "visa").lower(),
                    "credit",
                    "published",
                    draft.get("as_of") or now,
                    source_url,
                    draft["source_class"],
                    draft.get("source_license"),
                    Jsonb(source_links or {}),
                    Jsonb(provenance),
                    fee_fields["joining_fee_inr"],
                    fee_fields["annual_fee_inr"],
                    fee_fields["base_reward_unit"],
                    fee_fields["base_reward_rate"],
                    fee_fields["point_value_inr"],
                    existing["id"],
                ),
            )
            product_id = cur.fetchone()["id"]
        else:
            # INSERT new card
            cur.execute(
                """
                INSERT INTO card_products (
                  issuer_id, slug, name, network, card_type, status,
                  verified_at, source_url, source_class, source_license,
                  source_links, provenance,
                  joining_fee_inr, annual_fee_inr, base_reward_unit, base_reward_rate, point_value_inr
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
                """,
                (
                    issuer["id"],
                    slug,
                    draft["card_name"],
                    (draft.get("network") or "visa").lower(),
                    "credit",
                    "published",
                    draft.get("as_of") or now,
                    source_url,
                    draft["source_class"],
                    draft.get("source_license"),
                    Jsonb(source_links or {}),
                    Jsonb(provenance),
                    fee_fields["joining_fee_inr"],
                    fee_fields["annual_fee_inr"],
                    fee_fields["base_reward_unit"],
                    fee_fields["base_reward_rate"],
                    fee_fields["point_value_inr"],
                ),
            )
            product_id = cur.fetchone()["id"]

        # === SYNC CHILD TABLES ===
        # Clear existing child rows to prevent stale duplicates on re-promotion.
        # cap_rules and billing_cycle_rules are included even though we don't
        # write them yet — this prevents stale data from prior manual imports.
        for child_table in (
            "reward_rules",
            "cap_rules",
            "fee_waiver_rules",
            "milestone_rules",
            "card_benefits",
            "forex_rules",
            "fuel_surcharge_rules",
        ):
            cur.execute(f"DELETE FROM {child_table} WHERE card_product_id = %s", (product_id,))

        # Category Rewards
        for rule in fields.get("reward_rules", []):
            cat_id = None
            if rule.get("category_slug"):
                cur.execute("SELECT id FROM spend_categories WHERE slug = %s", (rule["category_slug"],))
                cat_row = cur.fetchone()
                if cat_row is None:
                    raise ValueError(
                        f"spend_categories slug {rule['category_slug']!r} not found — "
                        "add the row to the DB or fix the profile slug."
                    )
                cat_id = cat_row["id"]

            cur.execute(
                """
                INSERT INTO reward_rules (card_product_id, category_id, unit, rate, priority, notes)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (product_id, cat_id, rule.get("unit"), rule.get("rate"), rule.get("priority", 100), rule.get("notes")),
            )

        # Fee Waivers
        for w in fields.get("fee_waiver_rules", []):
            cur.execute(
                """
                INSERT INTO fee_waiver_rules (card_product_id, threshold_spend_inr, period, waives_fee_inr, notes)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (product_id, w.get("threshold_spend_inr"), w.get("period", "annual"), w.get("waives_fee_inr"), w.get("notes")),
            )

        # Milestones
        for m in fields.get("milestone_rules", []):
            cur.execute(
                """
                INSERT INTO milestone_rules
                  (card_product_id, label, period, threshold_spend_inr, reward_description, reward_value_inr, is_repeatable)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    product_id,
                    m.get("label"),
                    m.get("period", "annual"),
                    m.get("threshold_spend_inr"),
                    m.get("reward_description"),
                    m.get("reward_value_inr"),
                    m.get("is_repeatable", False),
                ),
            )

        # Benefits
        for b in fields.get("benefits", []):
            cur.execute(
                """
                INSERT INTO card_benefits
                  (card_product_id, kind, label, description, quota_count, quota_period, network_program, value_estimate_inr)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    product_id,
                    b.get("kind"),
                    b.get("label"),
                    b.get("description"),
                    b.get("quota_count"),
                    b.get("quota_period"),
                    b.get("network_program"),
                    b.get("value_estimate_inr"),
                ),
            )

        # Forex
        if fields.get("forex"):
            fx = fields["forex"]
            cur.execute(
                """
                INSERT INTO forex_rules (card_product_id, markup_percent, gst_on_markup, waiver_notes)
                VALUES (%s, %s, %s, %s)
                """,
                (product_id, fx.get("markup_percent"), fx.get("gst_on_markup", True), fx.get("waiver_notes")),
            )

        # Fuel
        if fields.get("fuel"):
            fl = fields["fuel"]
            cur.execute(
                """
                INSERT INTO fuel_surcharge_rules
                  (card_product_id, surcharge_percent, waiver_percent, min_txn_inr, max_txn_inr, monthly_waiver_cap)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (
                    product_id,
                    fl.get("surcharge_percent"),
                    fl.get("waiver_percent"),
                    fl.get("min_txn_inr"),
                    fl.get("max_txn_inr"),
                    fl.get("monthly_waiver_cap"),
                ),
            )

        # Mark draft as promoted
        cur.execute(
            "UPDATE card_source_drafts SET status = 'promoted', updated_at = now() WHERE id = %s",
            (draft_id,),
        )

    return product_id
