import os
import re
from pandapay_scraper.queue_models import get_db, CardTarget, CardCrawlJob, upsert_target, queue_job

def generate_key(issuer: str, card: str) -> str:
    combined = f"{issuer}-{card}".lower()
    combined = re.sub(r'[^a-z0-9]+', '-', combined)
    return combined.strip('-')

def seed_targets(file_path: str):
    db = get_db()
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Simple parsing:
    # ### Issuer Name
    # - Card Name
    # - Card Name
    current_issuer = None
    targets_added = 0
    
    for line in content.split('\n'):
        line = line.strip()
        if line.startswith('### '):
            current_issuer = line.replace('### ', '').strip()
            # Clean up trailing stuff like " (via BOBCARD Ltd.)"
            current_issuer = re.sub(r'\(.*?\)', '', current_issuer).strip()
        elif line.startswith('- ') and current_issuer:
            card_name = line.replace('- ', '').strip()
            # Remove inline notes like "(invite-only, top-tier)"
            card_name = re.sub(r'\(.*?\)', '', card_name).strip()
            
            if not card_name or len(card_name) < 3:
                continue

            card_key = generate_key(current_issuer, card_name)
            target = CardTarget(
                issuer_name=current_issuer,
                card_name=card_name,
                card_key=card_key
            )
            
            target_id = upsert_target(db, target)
            
            # Queue a discover job
            job = CardCrawlJob(
                card_target_id=target_id,
                job_type='discover',
                payload={"source_url_hint": ""}
            )
            queue_job(db, job)
            
            targets_added += 1

    print(f"Successfully seeded {targets_added} card targets into the queue from {file_path}.")

if __name__ == "__main__":
    base_dir = os.path.dirname(os.path.dirname(__file__))
    seed_targets(os.path.join(base_dir, "ALL_CARDS_LIST.md"))
