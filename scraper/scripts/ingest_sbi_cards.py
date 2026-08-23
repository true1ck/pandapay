import sys
from pathlib import Path
import os
import json
from datetime import datetime, timezone

# Ensure import paths work
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Force the database URL since we know it
os.environ["SCRAPER_DATABASE_URL"] = "postgresql://postgres:postgres@localhost:55433/pandapay"

from pandapay_scraper.db import insert_card_source_draft
from pandapay_scraper.promotion import promote_draft, _slugify
from pandapay_scraper.issuer_profiles import get_sbi_profile
from pandapay_scraper.queue_models import get_db

TARGETS = [
    "SBI AURUM Credit Card",
    "SBI Card ELITE",
    "SBI Card ELITE Advantage",
    "SBI ELITE Credit Card",
]

def _fetch_all(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params or ())
        return cur.fetchall()

def main():
    conn = get_db()
    
    # Check if we have 'State Bank of India' as an issuer and 'SBI' as a source
    with conn.cursor() as cur:
        cur.execute("SELECT id, name FROM issuers WHERE name ILIKE '%State Bank of India%'")
        issuer = cur.fetchone()
        if not issuer:
            print("Issuer 'State Bank of India' not found. Creating a dummy one.")
            cur.execute("INSERT INTO issuers (slug, name) VALUES ('state-bank-of-india', 'State Bank of India') RETURNING id, name")
            issuer = cur.fetchone()
            
        cur.execute("SELECT id, base_url FROM sources WHERE name ILIKE '%SBI%' OR base_url ILIKE '%sbi%'")
        source = cur.fetchone()
        if not source:
            print("Source for SBI not found. Creating a dummy one.")
            cur.execute("INSERT INTO sources (name, base_url, source_class) VALUES ('SBI Official', 'https://www.sbicard.com', 'issuer_official') RETURNING id, base_url")
            source = cur.fetchone()

    output = []
    
    for card_name in TARGETS:
        print(f"Ingesting: {card_name}")
        profile = get_sbi_profile(card_name)
        card_key = profile.get("card_key") or _slugify(card_name)
        
        draft_id = insert_card_source_draft(
            conn,
            source_id=str(source["id"]),
            source_page_id=None,
            source_url=f"https://www.sbicard.com/en/personal/credit-cards/{card_key}.html",
            source_class="issuer_official",
            source_license=None,
            card_key=card_key,
            card_name=card_name,
            issuer_name=issuer["name"],
            network=profile.get("network", "VISA"),
            tier=profile.get("tier"),
            as_of=datetime.now(timezone.utc).date(),
            source_payload={"note": "Ingested via manual script"},
            normalized_fields=profile,
            field_confidence={"all": 1.0},
            evidence=[],
            confidence=1.0,
            status="ready",
        )
        
        product_id = promote_draft(conn, draft_id)
        print(f"  Promoted as card_product: {product_id}")
        
        # Fetch the inserted data for verification
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM card_products WHERE id = %s", (product_id,))
            product = dict(cur.fetchone())
            
        reward_rules = _fetch_all(conn, "SELECT * FROM reward_rules WHERE card_product_id = %s", (product_id,))
        benefits = _fetch_all(conn, "SELECT * FROM card_benefits WHERE card_product_id = %s", (product_id,))
        milestones = _fetch_all(conn, "SELECT * FROM milestone_rules WHERE card_product_id = %s", (product_id,))
        
        output.append({
            "card_name": product["name"],
            "slug": product["slug"],
            "annual_fee_inr": str(product["annual_fee_inr"]),
            "joining_fee_inr": str(product["joining_fee_inr"]),
            "reward_rules_count": len(reward_rules),
            "benefits_count": len(benefits),
            "milestones_count": len(milestones),
            "base_reward_rate": str(product.get("base_reward_rate") or ""),
            "first_few_rewards": [f"Cat: {r['category_id']} Rate: {r['rate']}" for r in reward_rules[:3]],
            "first_few_benefits": [b['label'] for b in benefits[:3]]
        })
        
    print("\n--- INGESTION COMPLETE ---\n")
    print(json.dumps(output, indent=2))

if __name__ == "__main__":
    main()
