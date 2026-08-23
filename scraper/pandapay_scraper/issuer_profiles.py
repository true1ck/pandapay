"""Issuer-specific structured profiles used to seed richer drafts.

The generic fetch/extract pipeline can recover raw page text, but some cards
need an issuer-aware normalization layer to produce usable catalogue rows.
This module keeps those profiles in one place so the queue runner can attach
them to drafts and promotion can persist the normalized child tables.
"""

from __future__ import annotations

from copy import deepcopy


def _sbi_common() -> dict:
    return {
        "issuer_name": "State Bank of India",
        "source_class": "issuer_official",
        "source_license": None,
        "network": "VISA",
        "point_value_inr": 0.25,
        "fees_currency": "INR",
    }


SBI_CARD_PROFILES: dict[str, dict] = {
    "SBI AURUM Credit Card": {
        **_sbi_common(),
        "card_key": "sbi-aurum-credit-card",
        "tier": "SUPER_PREMIUM",
        "annual_fee_inr": 9999,
        "joining_fee_inr": 9999,
        "base_reward_unit": "points_per_100",
        "base_reward_rate": 4.0,
        "reward_rules": [
            {
                "category_slug": "fuel",
                "unit": "points_per_100",
                "rate": 0.0,
                "priority": 10,
                "notes": "No reward points on fuel spends.",
            }
        ],
        "fee_waiver_rules": [
            {
                "threshold_spend_inr": 1200000,
                "period": "annual",
                "waives_fee_inr": 9999,
                "notes": "Renewal fee waived on annual spends of ₹12 lakh or more in the preceding year.",
            }
        ],
        "milestone_rules": [
            {
                "label": "Welcome reward",
                "threshold_spend_inr": 9999,
                "reward_description": "40,000 AURUM Reward Points on payment of the first annual fee.",
                "reward_value_inr": 10000,
                "is_repeatable": False,
            }
        ],
        "benefits": [
            {
                "kind": "other",
                "label": "Club Marriott membership",
                "description": "Complimentary 1-year Club Marriott membership.",
            },
            {
                "kind": "other",
                "label": "Mint and WSJ subscription",
                "description": "Complimentary 1-year digital subscription to Mint and The Wall Street Journal.",
            },
            {
                "kind": "golf",
                "label": "Golf privileges",
                "description": "16 complimentary golf rounds and 12 golf lessons every year.",
            },
            {
                "kind": "concierge",
                "label": "AURUM secretarial access",
                "description": "Limited interactions can be delegated to a secretary or executive assistant.",
            },
        ],
        "forex": {
            "markup_percent": 1.99,
            "gst_on_markup": True,
            "waiver_notes": "Low forex markup on international transactions.",
        },
        "fuel": {
            "surcharge_percent": 1.0,
            "waiver_percent": 1.0,
            "min_txn_inr": 500,
            "max_txn_inr": 4000,
            "monthly_waiver_cap": 250,
        },
        "source_excerpt": "Official AURUM product and benefits pages. Welcome value, golf privileges, 4 ARP per ₹100 on non-fuel spend, 1.99% forex markup, and 1% fuel surcharge waiver.",
        "source_links": {
            "product": "https://www.sbicard.com/aurum/",
            "benefits": "https://www.sbicard.com/aurum/benefits.html",
            "mitc": "https://www.sbicard.com/en/most-important-terms-and-conditions.page",
        },
    },
    "SBI Card ELITE": {
        **_sbi_common(),
        "card_key": "sbi-card-elite",
        "tier": "PREMIUM",
        "annual_fee_inr": 4999,
        "joining_fee_inr": 4999,
        "base_reward_unit": "points_per_100",
        "base_reward_rate": 2.0,
        "reward_rules": [
            {
                "category_slug": "dining",
                "unit": "points_per_100",
                "rate": 5.0,
                "priority": 10,
                "notes": "5X Reward Points on dining spends.",
            },
            {
                "category_slug": "groceries",
                "unit": "points_per_100",
                "rate": 5.0,
                "priority": 10,
                "notes": "5X Reward Points on grocery spends.",
            },
            {
                "category_slug": "fuel",
                "unit": "points_per_100",
                "rate": 0.0,
                "priority": 10,
                "notes": "Reward accrual excluded on fuel spends; fuel surcharge waiver applies instead.",
            },
        ],
        "fee_waiver_rules": [
            {
                "threshold_spend_inr": 1000000,
                "period": "annual",
                "waives_fee_inr": 4999,
                "notes": "Spend-based reversal of annual fee on spends of ₹10 lakh in the preceding year.",
            }
        ],
        "milestone_rules": [
            {
                "label": "Bonus at ₹3 lakh",
                "threshold_spend_inr": 300000,
                "reward_description": "10,000 bonus reward points.",
                "reward_value_inr": 2500,
                "is_repeatable": False,
            },
            {
                "label": "Bonus at ₹4 lakh",
                "threshold_spend_inr": 400000,
                "reward_description": "10,000 bonus reward points.",
                "reward_value_inr": 2500,
                "is_repeatable": False,
            },
            {
                "label": "Bonus at ₹5 lakh",
                "threshold_spend_inr": 500000,
                "reward_description": "15,000 bonus reward points.",
                "reward_value_inr": 3750,
                "is_repeatable": False,
            },
            {
                "label": "Bonus at ₹8 lakh",
                "threshold_spend_inr": 800000,
                "reward_description": "15,000 bonus reward points.",
                "reward_value_inr": 3750,
                "is_repeatable": False,
            },
        ],
        "benefits": [
            {
                "kind": "movie",
                "label": "Complimentary movie tickets",
                "description": "Free movie tickets worth ₹6,000 every year on the primary card.",
            },
            {
                "kind": "lounge_international",
                "label": "Priority Pass membership",
                "description": "Complimentary membership and 6 lounge visits outside India per calendar year.",
                "quota_count": 6,
                "quota_period": "annual",
                "network_program": "Priority Pass",
                "value_estimate_inr": 99,
            },
            {
                "kind": "lounge_domestic",
                "label": "Domestic lounge visits",
                "description": "2 complimentary domestic airport lounge visits every quarter.",
                "quota_count": 2,
                "quota_period": "quarter",
                "network_program": "Domestic Lounge",
            },
            {
                "kind": "concierge",
                "label": "Concierge service",
                "description": "Dedicated concierge assistance for travel, gifting, and assistance requests.",
            },
            {
                "kind": "other",
                "label": "ITC Silver tier",
                "description": "Complimentary 1-year Club ITC Silver Tier membership.",
            },
        ],
        "forex": {
            "markup_percent": 1.99,
            "gst_on_markup": True,
            "waiver_notes": "Lowest foreign currency markup charge on SBI Card ELITE.",
        },
        "fuel": {
            "surcharge_percent": 1.0,
            "waiver_percent": 1.0,
            "min_txn_inr": 500,
            "max_txn_inr": 4000,
            "monthly_waiver_cap": 250,
        },
        "source_excerpt": "Official ELITE product page and MITC. 5X dining and grocery rewards, 2 points per ₹100 on other spends, free movie tickets, milestone bonuses, 1.99% forex markup, and 1% fuel surcharge waiver.",
        "source_links": {
            "product": "https://www.sbicard.com/en/personal/credit-cards/sbi-card-elite.html",
            "mitc": "https://www.sbicard.com/en/most-important-terms-and-conditions.page",
        },
    },
    "SBI Card ELITE Advantage": {
        **_sbi_common(),
        "card_key": "sbi-card-elite-advantage",
        "tier": "PREMIUM",
        "annual_fee_inr": 4999,
        "joining_fee_inr": 4999,
        "base_reward_unit": "points_per_100",
        "base_reward_rate": 2.0,
        "variant_note": "Secured card variant publicly referenced by SBI Card; no separate public benefits page found in the current source set.",
        "reward_rules": [
            {
                "category_slug": "dining",
                "unit": "points_per_100",
                "rate": 5.0,
                "priority": 10,
                "notes": "5X Reward Points on dining spends.",
            },
            {
                "category_slug": "groceries",
                "unit": "points_per_100",
                "rate": 5.0,
                "priority": 10,
                "notes": "5X Reward Points on grocery spends.",
            },
            {
                "category_slug": "fuel",
                "unit": "points_per_100",
                "rate": 0.0,
                "priority": 10,
                "notes": "Reward accrual excluded on fuel spends; fuel surcharge waiver applies instead.",
            },
        ],
        "fee_waiver_rules": [
            {
                "threshold_spend_inr": 1000000,
                "period": "annual",
                "waives_fee_inr": 4999,
                "notes": "Spend-based reversal of annual fee on spends of ₹10 lakh in the preceding year.",
            }
        ],
        "milestone_rules": [
            {
                "label": "Bonus at ₹3 lakh",
                "threshold_spend_inr": 300000,
                "reward_description": "10,000 bonus reward points.",
                "reward_value_inr": 2500,
                "is_repeatable": False,
            },
            {
                "label": "Bonus at ₹4 lakh",
                "threshold_spend_inr": 400000,
                "reward_description": "10,000 bonus reward points.",
                "reward_value_inr": 2500,
                "is_repeatable": False,
            },
            {
                "label": "Bonus at ₹5 lakh",
                "threshold_spend_inr": 500000,
                "reward_description": "15,000 bonus reward points.",
                "reward_value_inr": 3750,
                "is_repeatable": False,
            },
            {
                "label": "Bonus at ₹8 lakh",
                "threshold_spend_inr": 800000,
                "reward_description": "15,000 bonus reward points.",
                "reward_value_inr": 3750,
                "is_repeatable": False,
            },
        ],
        "benefits": [
            {
                "kind": "movie",
                "label": "Complimentary movie tickets",
                "description": "Free movie tickets worth ₹6,000 every year on the primary card.",
            },
            {
                "kind": "lounge_international",
                "label": "Priority Pass membership",
                "description": "Complimentary membership and 6 lounge visits outside India per calendar year.",
                "quota_count": 6,
                "quota_period": "annual",
                "network_program": "Priority Pass",
                "value_estimate_inr": 99,
            },
            {
                "kind": "lounge_domestic",
                "label": "Domestic lounge visits",
                "description": "2 complimentary domestic airport lounge visits every quarter.",
                "quota_count": 2,
                "quota_period": "quarter",
                "network_program": "Domestic Lounge",
            },
        ],
        "forex": {
            "markup_percent": 1.99,
            "gst_on_markup": True,
            "waiver_notes": "Lowest foreign currency markup charge on SBI Card ELITE Advantage.",
        },
        "fuel": {
            "surcharge_percent": 1.0,
            "waiver_percent": 1.0,
            "min_txn_inr": 500,
            "max_txn_inr": 4000,
            "monthly_waiver_cap": 250,
        },
        "source_excerpt": "Secured ELITE variant aligned to SBI Card ELITE's published benefit set in the current official source set.",
        "source_links": {
            "product": "https://www.sbicard.com/en/personal/credit-cards/lifestyle/sbi-card-elite-advantage.page",
            "elite": "https://www.sbicard.com/en/personal/credit-cards/sbi-card-elite.html",
            "mitc": "https://www.sbicard.com/en/most-important-terms-and-conditions.page",
        },
    },
    "SBI ELITE Credit Card": {
        **_sbi_common(),
        "card_key": "sbi-elite-credit-card",
        "tier": "PREMIUM",
        "annual_fee_inr": 4999,
        "joining_fee_inr": 4999,
        "base_reward_unit": "points_per_100",
        "base_reward_rate": 2.0,
        "reward_rules": [
            {
                "category_slug": "dining",
                "unit": "points_per_100",
                "rate": 5.0,
                "priority": 10,
                "notes": "5X Reward Points on dining spends.",
            },
            {
                "category_slug": "groceries",
                "unit": "points_per_100",
                "rate": 5.0,
                "priority": 10,
                "notes": "5X Reward Points on grocery spends.",
            },
            {
                "category_slug": "fuel",
                "unit": "points_per_100",
                "rate": 0.0,
                "priority": 10,
                "notes": "Reward accrual excluded on fuel spends; fuel surcharge waiver applies instead.",
            },
        ],
        "fee_waiver_rules": [
            {
                "threshold_spend_inr": 1000000,
                "period": "annual",
                "waives_fee_inr": 4999,
                "notes": "Spend-based reversal of annual fee on spends of ₹10 lakh in the preceding year.",
            }
        ],
        "milestone_rules": [
            {
                "label": "Bonus at ₹3 lakh",
                "threshold_spend_inr": 300000,
                "reward_description": "10,000 bonus reward points.",
                "reward_value_inr": 2500,
                "is_repeatable": False,
            },
            {
                "label": "Bonus at ₹4 lakh",
                "threshold_spend_inr": 400000,
                "reward_description": "10,000 bonus reward points.",
                "reward_value_inr": 2500,
                "is_repeatable": False,
            },
            {
                "label": "Bonus at ₹5 lakh",
                "threshold_spend_inr": 500000,
                "reward_description": "15,000 bonus reward points.",
                "reward_value_inr": 3750,
                "is_repeatable": False,
            },
            {
                "label": "Bonus at ₹8 lakh",
                "threshold_spend_inr": 800000,
                "reward_description": "15,000 bonus reward points.",
                "reward_value_inr": 3750,
                "is_repeatable": False,
            },
        ],
        "benefits": [
            {
                "kind": "movie",
                "label": "Complimentary movie tickets",
                "description": "Free movie tickets worth ₹6,000 every year on the primary card.",
            },
            {
                "kind": "lounge_international",
                "label": "Priority Pass membership",
                "description": "Complimentary membership and 6 lounge visits outside India per calendar year.",
                "quota_count": 6,
                "quota_period": "annual",
                "network_program": "Priority Pass",
                "value_estimate_inr": 99,
            },
            {
                "kind": "lounge_domestic",
                "label": "Domestic lounge visits",
                "description": "2 complimentary domestic airport lounge visits every quarter.",
                "quota_count": 2,
                "quota_period": "quarter",
                "network_program": "Domestic Lounge",
            },
        ],
        "forex": {
            "markup_percent": 1.99,
            "gst_on_markup": True,
            "waiver_notes": "Lowest foreign currency markup charge on SBI ELITE Credit Card.",
        },
        "fuel": {
            "surcharge_percent": 1.0,
            "waiver_percent": 1.0,
            "min_txn_inr": 500,
            "max_txn_inr": 4000,
            "monthly_waiver_cap": 250,
        },
        "source_excerpt": "Alias kept for the same ELITE benefits set so the catalog can represent cards named with or without the 'SBI Card' prefix.",
        "source_links": {
            "product": "https://www.sbicard.com/en/personal/credit-cards/sbi-card-elite.html",
            "mitc": "https://www.sbicard.com/en/most-important-terms-and-conditions.page",
        },
    },
}


def get_sbi_profile(card_name: str) -> dict:
    profile = SBI_CARD_PROFILES.get(card_name)
    if profile is None:
        raise KeyError(f"Unknown SBI profile for {card_name!r}")
    return deepcopy(profile)
