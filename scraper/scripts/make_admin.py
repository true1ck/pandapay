import sys
import os
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ["SCRAPER_DATABASE_URL"] = "postgresql://postgres:postgres@localhost:55433/pandapay"

from pandapay_scraper.queue_models import get_db

def main():
    conn = get_db()
    with conn.cursor() as cur:
        cur.execute("SELECT id, phone, email FROM auth.users ORDER BY created_at DESC LIMIT 1;")
        user = cur.fetchone()
        if not user:
            print("No users found in auth.users!")
            return
            
        print(f"Found user: {user}")
        user_id = user["id"]
        
        # Insert into admin_users
        cur.execute("""
            INSERT INTO pandapay.admin_users (id, is_active) 
            VALUES (%s, true) 
            ON CONFLICT (id) DO UPDATE SET is_active = true
        """, (user_id,))
        conn.commit()
        print(f"User {user_id} is now an active admin in pandapay.admin_users!")

if __name__ == "__main__":
    main()
