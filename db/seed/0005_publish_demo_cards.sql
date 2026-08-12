-- Publishes the demo catalogue so a locally-run stack can actually recommend
-- a card.
--
-- WHY THIS IS A SEPARATE FILE, not an edit to 0001_demo_cards.sql:
-- those seeds deliberately insert `status = 'draft'`. They were written to
-- populate the admin console's review queue (see 0002_demo_queue_data.sql),
-- and a draft card in a review queue is the correct state for that purpose.
-- Changing them would break what they were for.
--
-- But `v_card_catalogue_export` filters on `status = 'published' and
-- is_active`, so with only those seeds applied `GET /catalogue` returns
-- `{"cards":[]}` — and the app's entire reason to exist, "which of my cards
-- should I use here", has nothing to rank. Bringing the backend up gave you a
-- technically-working API that could not answer the product's core question.
-- This closes that gap without touching either concern.
--
-- DEV/DEMO ONLY. It runs under the same `SEED_DEMO_DATA` flag as the rest of
-- db/seed/ and must never run anywhere real: it marks cards as verified
-- without anyone having verified them, which is exactly the claim
-- `card_published_needs_verification` exists to force someone to make
-- deliberately.

do $$
declare v_count int;
begin
  -- `verified_at` is required by the check constraint
  -- `card_published_needs_verification` — a card cannot be published without
  -- it. Set to a fixed timestamp rather than now() so re-running produces an
  -- identical database, which keeps the seed reproducible.
  update card_products
     set status = 'published',
         verified_at = coalesce(verified_at, timestamptz '2026-01-01 00:00:00+00')
   where status = 'draft'
     and is_active;

  get diagnostics v_count = row_count;
  raise notice 'published % demo card product(s) for local development', v_count;
end $$;
