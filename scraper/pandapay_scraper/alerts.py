"""AD-4.1/4.5: turns a genuine content diff into (or reinforces) a
policy_change_alerts row — the ⭐ unified queue. **Scope note, read before
extending this**: without AD-4.3's AI-assisted structured extraction (which
needs a real LLM call — a cost/scope decision, not built in this session),
this module cannot know *which specific field* changed (a cap value? a
rate? just the marketing copy?). It raises one page-level alert per
(card_product_id, page_role) instead of a precise field_path like
'cap_rules.<id>.cap_value'. That's a real, permanent scope limit until
AD-4.3 exists — not a placeholder pretending to be field-level.
"""

from __future__ import annotations

from . import db
from .diff import DiffResult

PAGE_LEVEL_SIGNAL = "scrape_diff"


def record_diff_as_alert_signal(
    conn,
    *,
    card_product_id: str | None,
    page_role: str,
    page_url: str,
    new_snapshot_id: str,
    diff: DiffResult,
) -> str | None:
    """Returns the alert id touched, or None if there's no card to attribute
    this page to (source_pages.card_product_id is nullable — a news_index
    page, for instance, isn't about one specific card) or the diff carried
    no meaningful (non-noise) change.
    """
    if card_product_id is None or not diff.has_meaningful_change:
        return None

    field_path = f"page_content:{page_role}"
    field_label = f"{page_url} ({page_role}) — page content changed"

    existing = db.find_open_alert(conn, card_product_id, field_path)
    if existing is None:
        alert_id = db.create_alert(
            conn, card_product_id=card_product_id, field_path=field_path, field_label=field_label
        )
    else:
        alert_id = str(existing["id"])
        already_has_scrape_signal = db.alert_has_signal_kind(conn, alert_id, PAGE_LEVEL_SIGNAL)
        db.reinforce_alert(conn, alert_id, new_signal_kind=not already_has_scrape_signal)

    db.insert_alert_evidence(
        conn, alert_id=alert_id, snapshot_id=new_snapshot_id, excerpt=diff.summary()
    )
    return alert_id
