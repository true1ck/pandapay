"""Structured third-party card ingestion helpers.

This module turns already-structured card catalogues such as CardAdvisor's
open Indian dataset into a canonical draft shape that PandaPay can store in a
staging table or later promote into `card_products`.

The design goal is deliberately conservative:
- accept multiple field aliases because upstream schemas differ
- keep the raw payload for provenance
- preserve explicit values and mark derived values separately
- never guess a value when a card-level field is missing and a reasonable
  fallback does not exist
"""

from __future__ import annotations

import csv
import json
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path
from typing import Any, Mapping, Sequence

_CAMEL_SPLIT = re.compile(r"(?<!^)(?=[A-Z])")
_NUMBER_RE = re.compile(r"[-+]?\d+(?:,\d{3})*(?:\.\d+)?")
_CARD_KEY_RE = re.compile(r"[^a-z0-9]+")

DEFAULT_SOURCE_CLASS = "third_party_structured"
DEFAULT_SOURCE_LICENSE = "CC BY 4.0"

FIELD_ALIASES: dict[str, tuple[str, ...]] = {
    "card_key": ("cardKey", "card_key", "slug", "key"),
    "card_name": ("name", "card_name", "product_name", "title"),
    "issuer_name": ("issuer", "issuer_name", "bank", "issuerBank", "issuer_label"),
    "network": ("network", "card_network"),
    "tier": ("tier", "segment", "card_tier"),
    "annual_fee_inr": ("annualFeeRs", "annual_fee_rs", "annual_fee", "annual_fee_inr", "annual_fee_rs_inr"),
    "joining_fee_inr": ("joiningFeeRs", "joining_fee_rs", "joining_fee", "joining_fee_inr"),
    "lifetime_free": ("lifetimeFree", "lifetime_free"),
    "fee_waiver_spend_inr": ("feeWaiverSpendRs", "fee_waiver_spend_rs", "annual_fee_waiver_spend", "fee_waiver_spend_inr"),
    "forex_markup_pct": ("forexMarkupPct", "forex_markup_pct", "forex_markup", "markup_percent"),
    "apr_monthly_pct": ("aprMonthlyPct", "apr_monthly_pct", "monthly_apr_pct"),
    "min_salary_inr": ("minSalaryRs", "min_salary_rs", "minimum_salary", "min_salary_inr"),
    "min_age_years": ("minAgeYears", "min_age_years"),
    "max_age_years": ("maxAgeYears", "max_age_years"),
    "reward_rate_min_pct": ("rewardRateMinPct", "reward_rate_min_pct", "base_reward_rate", "baseRewardRate"),
    "reward_rate_max_pct": ("rewardRateMaxPct", "reward_rate_max_pct", "best_reward_rate", "bestRewardRate"),
    "last_verified": ("lastVerified", "last_verified", "verified_at"),
    "url": ("url", "source_url", "card_url"),
    "as_of": ("asOf", "as_of", "datasetAsOf"),
}

REWARD_ALIASES = {
    "category": ("category", "categoryName", "category_name", "label"),
    "reward_type": ("rewardType", "reward_type", "unit"),
    "rate_pct": ("ratePct", "rate_pct", "rate", "percentage"),
    "monthly_cap_rs": ("monthlyCapRs", "monthly_cap_rs", "cap", "cap_rs"),
    "point_value_paisa": ("pointValuePaisa", "point_value_paisa", "point_value", "pointValue"),
    "merchants": ("merchants", "merchant", "merchant_scope"),
}

PERK_ALIASES = {
    "perk_type": ("perkType", "perk_type", "kind"),
    "description": ("description", "label", "name"),
}


@dataclass
class StructuredCardDraft:
    source_class: str
    source_license: str | None
    source_url: str
    card_key: str
    card_name: str
    issuer_name: str
    network: str | None
    tier: str | None
    as_of: date | None
    source_payload: dict[str, Any]
    normalized_fields: dict[str, Any]
    field_confidence: dict[str, float] = field(default_factory=dict)
    evidence: list[dict[str, Any]] = field(default_factory=list)
    confidence: float | None = None

    def to_row(self) -> dict[str, Any]:
        return {
            "source_class": self.source_class,
            "source_license": self.source_license,
            "source_url": self.source_url,
            "card_key": self.card_key,
            "card_name": self.card_name,
            "issuer_name": self.issuer_name,
            "network": self.network,
            "tier": self.tier,
            "as_of": self.as_of.isoformat() if isinstance(self.as_of, date) else None,
            "source_payload": self.source_payload,
            "normalized_fields": self.normalized_fields,
            "field_confidence": self.field_confidence,
            "evidence": self.evidence,
            "confidence": self.confidence,
        }


def _canonical_key(value: str) -> str:
    value = str(value or "").strip().lower()
    value = _CARD_KEY_RE.sub("-", value)
    value = value.strip("-")
    return value or "unknown-card"


def _pick(record: Mapping[str, Any], aliases: Sequence[str]) -> Any:
    for key in aliases:
        if key in record and record[key] not in (None, ""):
            return record[key]
    return None


def _camel_to_snake(value: str) -> str:
    return _CAMEL_SPLIT.sub("_", value).lower()


def _as_bool(value: Any) -> bool | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return bool(value)
    text = str(value).strip().lower()
    if text in {"true", "yes", "y", "1"}:
        return True
    if text in {"false", "no", "n", "0"}:
        return False
    return None


def _as_float(value: Any) -> float | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip().lower().replace("₹", "").replace("rs.", "").replace("rs", "")
    match = _NUMBER_RE.search(text)
    if not match:
        return None
    cleaned = match.group(0).replace(",", "")
    try:
        return float(cleaned)
    except ValueError:
        return None


def _as_int(value: Any) -> int | None:
    number = _as_float(value)
    if number is None:
        return None
    return int(number)


def _as_date(value: Any) -> date | None:
    if value is None or value == "":
        return None
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    if isinstance(value, datetime):
        return value.date()
    text = str(value).strip()
    for fmt in ("%Y-%m-%d", "%d-%m-%Y", "%d/%m/%Y", "%Y/%m/%d"):
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    return None


def _normalize_network(value: Any) -> str | None:
    if value is None or value == "":
        return None
    text = str(value).strip().upper().replace(" ", "_")
    return text


def _normalize_tier(value: Any) -> str | None:
    if value is None or value == "":
        return None
    return str(value).strip().upper().replace(" ", "_")


def _normalize_reward_row(row: Mapping[str, Any]) -> dict[str, Any]:
    reward_type = _pick(row, REWARD_ALIASES["reward_type"])
    category = _pick(row, REWARD_ALIASES["category"])
    rate_pct = _as_float(_pick(row, REWARD_ALIASES["rate_pct"]))
    monthly_cap_rs = _as_float(_pick(row, REWARD_ALIASES["monthly_cap_rs"]))
    point_value_paisa = _as_float(_pick(row, REWARD_ALIASES["point_value_paisa"]))
    merchants = _pick(row, REWARD_ALIASES["merchants"])
    if isinstance(merchants, str):
        merchants = [m.strip() for m in merchants.split(",") if m.strip()]
    elif merchants is None:
        merchants = []
    elif not isinstance(merchants, list):
        merchants = [merchants]
    return {
        "category": category,
        "reward_type": reward_type,
        "rate_pct": rate_pct,
        "monthly_cap_rs": monthly_cap_rs,
        "point_value_paisa": point_value_paisa,
        "merchants": merchants,
    }


def _normalize_perk_row(row: Mapping[str, Any]) -> dict[str, Any]:
    perk_type = _pick(row, PERK_ALIASES["perk_type"])
    description = _pick(row, PERK_ALIASES["description"])
    result = {"perk_type": perk_type, "description": description}
    for key, value in row.items():
        if key in {"perkType", "perk_type", "kind", "description", "label", "name"}:
            continue
        result[_camel_to_snake(str(key))] = value
    return result


def _normalize_records(value: Any, normalizer) -> list[dict[str, Any]]:
    if not value:
        return []
    if isinstance(value, list):
        items = value
    elif isinstance(value, dict):
        items = [value]
    else:
        return []
    out = []
    for item in items:
        if isinstance(item, Mapping):
            out.append(normalizer(item))
    return out


def _confidence_for(explicit: bool, derived: bool = False) -> float:
    if explicit:
        return 1.0
    if derived:
        return 0.8
    return 0.0


def normalize_card_record(
    record: Mapping[str, Any],
    *,
    source_class: str = DEFAULT_SOURCE_CLASS,
    source_license: str | None = DEFAULT_SOURCE_LICENSE,
    source_url: str | None = None,
    as_of: Any = None,
) -> StructuredCardDraft:
    """Normalize one upstream card row into PandaPay's staging shape."""

    payload = dict(record)

    raw_card_key = _pick(payload, FIELD_ALIASES["card_key"])
    raw_name = _pick(payload, FIELD_ALIASES["card_name"])
    raw_issuer = _pick(payload, FIELD_ALIASES["issuer_name"])
    raw_url = source_url or _pick(payload, FIELD_ALIASES["url"]) or ""
    raw_network = _pick(payload, FIELD_ALIASES["network"])
    raw_tier = _pick(payload, FIELD_ALIASES["tier"])
    raw_as_of = as_of if as_of is not None else _pick(payload, FIELD_ALIASES["as_of"])
    raw_last_verified = _pick(payload, FIELD_ALIASES["last_verified"])

    card_name = str(raw_name or "").strip()
    issuer_name = str(raw_issuer or "").strip()
    source_url_value = str(raw_url or "").strip()

    if not card_name and raw_card_key:
        card_name = str(raw_card_key).replace("-", " ").title()
    if not issuer_name:
        issuer_name = "Unknown Issuer"
    if not source_url_value:
        source_url_value = f"structured://{_canonical_key(raw_card_key or card_name or issuer_name)}"

    card_key = _canonical_key(raw_card_key or f"{issuer_name}-{card_name}")

    annual_fee_inr = _as_float(_pick(payload, FIELD_ALIASES["annual_fee_inr"]))
    joining_fee_inr = _as_float(_pick(payload, FIELD_ALIASES["joining_fee_inr"]))
    lifetime_free = _as_bool(_pick(payload, FIELD_ALIASES["lifetime_free"]))
    fee_waiver_spend_inr = _as_float(_pick(payload, FIELD_ALIASES["fee_waiver_spend_inr"]))
    forex_markup_pct = _as_float(_pick(payload, FIELD_ALIASES["forex_markup_pct"]))
    apr_monthly_pct = _as_float(_pick(payload, FIELD_ALIASES["apr_monthly_pct"]))
    min_salary_inr = _as_float(_pick(payload, FIELD_ALIASES["min_salary_inr"]))
    min_age_years = _as_int(_pick(payload, FIELD_ALIASES["min_age_years"]))
    max_age_years = _as_int(_pick(payload, FIELD_ALIASES["max_age_years"]))
    reward_rate_min_pct = _as_float(_pick(payload, FIELD_ALIASES["reward_rate_min_pct"]))
    reward_rate_max_pct = _as_float(_pick(payload, FIELD_ALIASES["reward_rate_max_pct"]))
    parsed_as_of = _as_date(raw_as_of) or _as_date(raw_last_verified)

    rewards = _normalize_records(payload.get("rewards") or payload.get("reward_rules"), _normalize_reward_row)
    perks = _normalize_records(payload.get("perks") or payload.get("benefits"), _normalize_perk_row)

    if reward_rate_min_pct is None and rewards:
        rates = [r["rate_pct"] for r in rewards if isinstance(r.get("rate_pct"), (int, float))]
        if rates:
            reward_rate_min_pct = min(rates)
    if reward_rate_max_pct is None and rewards:
        rates = [r["rate_pct"] for r in rewards if isinstance(r.get("rate_pct"), (int, float))]
        if rates:
            reward_rate_max_pct = max(rates)

    normalized_fields = {
        "annual_fee_inr": annual_fee_inr,
        "joining_fee_inr": joining_fee_inr,
        "lifetime_free": lifetime_free,
        "fee_waiver_spend_inr": fee_waiver_spend_inr,
        "forex_markup_pct": forex_markup_pct,
        "apr_monthly_pct": apr_monthly_pct,
        "min_salary_inr": min_salary_inr,
        "min_age_years": min_age_years,
        "max_age_years": max_age_years,
        "reward_rate_min_pct": reward_rate_min_pct,
        "reward_rate_max_pct": reward_rate_max_pct,
    }

    field_confidence = {
        "card_key": _confidence_for(True),
        "card_name": _confidence_for(True),
        "issuer_name": _confidence_for(True),
        "network": _confidence_for(raw_network is not None),
        "tier": _confidence_for(raw_tier is not None),
        "annual_fee_inr": _confidence_for(annual_fee_inr is not None),
        "joining_fee_inr": _confidence_for(joining_fee_inr is not None),
        "lifetime_free": _confidence_for(lifetime_free is not None),
        "fee_waiver_spend_inr": _confidence_for(fee_waiver_spend_inr is not None),
        "forex_markup_pct": _confidence_for(forex_markup_pct is not None),
        "apr_monthly_pct": _confidence_for(apr_monthly_pct is not None),
        "min_salary_inr": _confidence_for(min_salary_inr is not None),
        "min_age_years": _confidence_for(min_age_years is not None),
        "max_age_years": _confidence_for(max_age_years is not None),
        "reward_rate_min_pct": _confidence_for(reward_rate_min_pct is not None, derived=not _pick(payload, FIELD_ALIASES["reward_rate_min_pct"])),
        "reward_rate_max_pct": _confidence_for(reward_rate_max_pct is not None, derived=not _pick(payload, FIELD_ALIASES["reward_rate_max_pct"])),
    }

    evidence: list[dict[str, Any]] = []
    for field_name in normalized_fields:
        value = normalized_fields[field_name]
        if value is not None:
            evidence.append({"field": field_name, "value": value, "source": source_url_value})
    if rewards:
        evidence.append({"field": "rewards", "value": rewards, "source": source_url_value})
    if perks:
        evidence.append({"field": "perks", "value": perks, "source": source_url_value})

    confidence_values = [v for v in field_confidence.values() if v > 0]
    confidence = round(sum(confidence_values) / len(confidence_values), 3) if confidence_values else None

    return StructuredCardDraft(
        source_class=source_class,
        source_license=source_license,
        source_url=source_url_value,
        card_key=card_key,
        card_name=card_name,
        issuer_name=issuer_name,
        network=_normalize_network(raw_network),
        tier=_normalize_tier(raw_tier),
        as_of=parsed_as_of,
        source_payload=payload,
        normalized_fields={**normalized_fields, "rewards": rewards, "perks": perks},
        field_confidence=field_confidence,
        evidence=evidence,
        confidence=confidence,
    )


def load_cards_from_json(text: str, *, source_class: str = DEFAULT_SOURCE_CLASS, source_license: str | None = DEFAULT_SOURCE_LICENSE, source_url: str | None = None) -> list[StructuredCardDraft]:
    payload = json.loads(text)
    if isinstance(payload, list):
        cards = payload
        dataset_meta: dict[str, Any] = {}
    elif isinstance(payload, dict):
        cards = payload.get("cards") or payload.get("data") or payload.get("items")
        dataset_meta = payload
        if cards is None:
            cards = [payload]
    else:
        raise ValueError("structured dataset must be a JSON object or array")

    as_of = dataset_meta.get("asOf") or dataset_meta.get("as_of") or dataset_meta.get("lastVerified")
    source_url_value = source_url or dataset_meta.get("url") or dataset_meta.get("sourceUrl")

    drafts: list[StructuredCardDraft] = []
    for record in cards:
        if not isinstance(record, Mapping):
            continue
        drafts.append(
            normalize_card_record(
                record,
                source_class=source_class,
                source_license=source_license,
                source_url=source_url_value,
                as_of=as_of,
            )
        )
    return drafts


def load_cards_from_csv(text: str, *, source_class: str = DEFAULT_SOURCE_CLASS, source_license: str | None = DEFAULT_SOURCE_LICENSE, source_url: str | None = None) -> list[StructuredCardDraft]:
    reader = csv.DictReader(text.splitlines())
    drafts: list[StructuredCardDraft] = []
    for row in reader:
        drafts.append(
            normalize_card_record(
                row,
                source_class=source_class,
                source_license=source_license,
                source_url=source_url or row.get("url"),
                as_of=row.get("asOf") or row.get("as_of") or row.get("lastVerified"),
            )
        )
    return drafts


def load_cards_from_path(
    path: str | Path,
    *,
    source_class: str = DEFAULT_SOURCE_CLASS,
    source_license: str | None = DEFAULT_SOURCE_LICENSE,
    source_url: str | None = None,
) -> list[StructuredCardDraft]:
    path = Path(path)
    text = path.read_text(encoding="utf-8")
    suffix = path.suffix.lower()
    if suffix in {".json", ".jsonl"}:
        if suffix == ".jsonl":
            drafts: list[StructuredCardDraft] = []
            for line in text.splitlines():
                line = line.strip()
                if not line:
                    continue
                drafts.extend(
                    load_cards_from_json(
                        line,
                        source_class=source_class,
                        source_license=source_license,
                        source_url=source_url,
                    )
                )
            return drafts
        return load_cards_from_json(text, source_class=source_class, source_license=source_license, source_url=source_url)
    if suffix == ".csv":
        return load_cards_from_csv(text, source_class=source_class, source_license=source_license, source_url=source_url)
    if suffix in {".txt"}:
        try:
            return load_cards_from_json(text, source_class=source_class, source_license=source_license, source_url=source_url)
        except json.JSONDecodeError:
            return load_cards_from_csv(text, source_class=source_class, source_license=source_license, source_url=source_url)
    raise ValueError(f"unsupported structured source format: {path.suffix}")
