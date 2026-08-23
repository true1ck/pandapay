from typing import Dict, Any, List

def get_sbi_profiles() -> Dict[str, Dict[str, Any]]:
    return {
        "sbi-aurum-credit-card": {
            "issuer_name": "SBI Card",
            "card_key": "sbi-aurum-credit-card",
            "card_name": "SBI AURUM Credit Card",
            "network": "VISA", # Usually Visa Infinite or Mastercard
            "tier": "super_premium",
            "annual_fee": 9999,
            "joining_fee": 9999,
            "base_reward_unit": "point",
            "base_reward_rate": 4, # 4 Reward Points per Rs.100
            "category_reward_rules": [],
            "fee_waiver_rule": {
                "threshold_spend_inr": 1200000,
                "period": "annual",
                "waives_fee_inr": 9999
            },
            "milestone_rules": [
                {
                    "label": "Monthly Milestone",
                    "threshold_spend_inr": 100000,
                    "reward_description": "Tata Cliq Voucher",
                    "reward_value_inr": 1500,
                    "period": "monthly"
                },
                {
                    "label": "Annual Milestone",
                    "threshold_spend_inr": 500000,
                    "reward_description": "Luxe gift voucher or Taj voucher",
                    "reward_value_inr": 5000,
                    "period": "annual"
                }
            ],
            "benefits": [
                {
                    "kind": "lounge_access",
                    "label": "International Lounge Access",
                    "description": "Unlimited complimentary International lounge visits",
                    "quota_count": None,
                    "quota_period": "annual"
                },
                {
                    "kind": "lounge_access",
                    "label": "Domestic Lounge Access",
                    "description": "4 complimentary Domestic lounge visits per quarter",
                    "quota_count": 16,
                    "quota_period": "annual"
                },
                {
                    "kind": "movie_tickets",
                    "label": "Free Movie Tickets",
                    "description": "4 free movie tickets every month on BookMyShow",
                    "quota_count": 48,
                    "quota_period": "annual"
                }
            ],
            "forex_markup": 1.99,
            "fuel_surcharge_rule": {
                "surcharge_percent": 1.0,
                "waiver_percent": 1.0,
                "min_txn_inr": 500,
                "max_txn_inr": 4000,
                "monthly_waiver_cap": 1000
            }
        },
        "sbi-card-elite": {
            "issuer_name": "SBI Card",
            "card_key": "sbi-card-elite",
            "card_name": "SBI Card ELITE",
            "network": "VISA",
            "tier": "premium",
            "annual_fee": 4999,
            "joining_fee": 4999,
            "base_reward_unit": "point",
            "base_reward_rate": 2, # 2 Reward Points per Rs.100
            "category_reward_rules": [
                {
                    "merchant_pattern": "dining",
                    "rate": 10
                },
                {
                    "merchant_pattern": "grocery",
                    "rate": 10
                },
                {
                    "merchant_pattern": "departmental_stores",
                    "rate": 10
                }
            ],
            "fee_waiver_rule": {
                "threshold_spend_inr": 1000000,
                "period": "annual",
                "waives_fee_inr": 4999
            },
            "milestone_rules": [
                {
                    "label": "Annual Milestone 1",
                    "threshold_spend_inr": 300000,
                    "reward_description": "10,000 Bonus Reward Points",
                    "reward_value_inr": 2500,
                    "period": "annual"
                },
                {
                    "label": "Annual Milestone 2",
                    "threshold_spend_inr": 400000,
                    "reward_description": "10,000 Bonus Reward Points",
                    "reward_value_inr": 2500,
                    "period": "annual"
                }
            ],
            "benefits": [
                {
                    "kind": "lounge_access",
                    "label": "International Lounge Access",
                    "description": "6 complimentary Airport Lounge visits per year, max 2 visits per quarter",
                    "quota_count": 6,
                    "quota_period": "annual"
                },
                {
                    "kind": "lounge_access",
                    "label": "Domestic Lounge Access",
                    "description": "2 complimentary Domestic Lounge visits every quarter",
                    "quota_count": 8,
                    "quota_period": "annual"
                },
                {
                    "kind": "movie_tickets",
                    "label": "Free Movie Tickets",
                    "description": "Free movie tickets worth Rs.6000 per year (max Rs.250/ticket, 2 tickets per month)",
                    "quota_count": 24,
                    "quota_period": "annual"
                }
            ],
            "forex_markup": 1.99,
            "fuel_surcharge_rule": {
                "surcharge_percent": 1.0,
                "waiver_percent": 1.0,
                "min_txn_inr": 500,
                "max_txn_inr": 4000,
                "monthly_waiver_cap": 250
            }
        },
        "sbi-card-elite-advantage": {
            "issuer_name": "SBI Card",
            "card_key": "sbi-card-elite-advantage",
            "card_name": "SBI Card ELITE Advantage",
            "network": "VISA",
            "tier": "premium",
            "annual_fee": 4999,
            "joining_fee": 4999,
            "base_reward_unit": "point",
            "base_reward_rate": 2,
            "category_reward_rules": [
                {
                    "merchant_pattern": "dining",
                    "rate": 10
                },
                {
                    "merchant_pattern": "grocery",
                    "rate": 10
                }
            ],
            "fee_waiver_rule": {
                "threshold_spend_inr": 1000000,
                "period": "annual",
                "waives_fee_inr": 4999
            },
            "milestone_rules": [
                {
                    "label": "Annual Milestone 1",
                    "threshold_spend_inr": 300000,
                    "reward_description": "10,000 Bonus Reward Points",
                    "reward_value_inr": 2500,
                    "period": "annual"
                }
            ],
            "benefits": [
                {
                    "kind": "lounge_access",
                    "label": "International Lounge Access",
                    "description": "6 complimentary Airport Lounge visits per year",
                    "quota_count": 6,
                    "quota_period": "annual"
                }
            ],
            "forex_markup": 1.99,
            "fuel_surcharge_rule": {
                "surcharge_percent": 1.0,
                "waiver_percent": 1.0,
                "min_txn_inr": 500,
                "max_txn_inr": 4000,
                "monthly_waiver_cap": 250
            }
        },
        "sbi-elite-credit-card": {
            "issuer_name": "SBI Card",
            "card_key": "sbi-elite-credit-card",
            "card_name": "SBI ELITE Credit Card",
            "network": "VISA",
            "tier": "premium",
            "annual_fee": 4999,
            "joining_fee": 4999,
            "base_reward_unit": "point",
            "base_reward_rate": 2,
            "category_reward_rules": [],
            "fee_waiver_rule": {
                "threshold_spend_inr": 1000000,
                "period": "annual",
                "waives_fee_inr": 4999
            },
            "milestone_rules": [],
            "benefits": [],
            "forex_markup": 1.99,
            "fuel_surcharge_rule": {
                "surcharge_percent": 1.0,
                "waiver_percent": 1.0,
                "min_txn_inr": 500,
                "max_txn_inr": 4000,
                "monthly_waiver_cap": 250
            }
        }
    }
