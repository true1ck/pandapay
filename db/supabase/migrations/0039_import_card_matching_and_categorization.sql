-- >>> MIGRATION 0039 — IMPORT CARD MATCHING + MERCHANT CATEGORIZATION =======
--
-- The two schema gaps that made automatic transaction capture impossible.
-- Together they are the difference between "the app catches your spend" and
-- "the app catches your spend if you tap a card for every single message".
--
-- ---------------------------------------------------------------------------
-- 1. user_cards.last4 — which card an imported message belongs to.
-- ---------------------------------------------------------------------------
--
-- Every import route REQUIRED a caller-supplied userCardId, and said so
-- honestly: the parser extracts amount/merchant/last4/date but not which of
-- the user's cards the message is about. sms_import_screen.dart's own
-- doc-comment spelled out why it couldn't resolve it — "user_cards carries
-- no last4 column in this schema" — and that was correct.
--
-- The consequence was that NO transaction was ever recorded without a human
-- assigning it a card, one message at a time. An SMS backfill of a few
-- thousand messages was a few thousand taps.
--
-- Four digits, never the full PAN — this is a matching key, not card data.
-- The CHECK enforces that: anything longer simply cannot be stored here, so
-- a client bug or a careless admin script can't turn this column into PAN
-- storage. Nullable because it is optional: a user who doesn't enter it
-- keeps exactly the old manual-assignment behaviour.
alter table user_cards add column if not exists last4 char(4);
alter table user_cards drop constraint if exists user_cards_last4_is_four_digits;
alter table user_cards add constraint user_cards_last4_is_four_digits
  check (last4 is null or last4 ~ '^[0-9]{4}$');

comment on column user_cards.last4 is
  'Last four digits of the card number, used ONLY to match an incoming bank '
  'SMS/email to this card. Never the full PAN — the CHECK makes longer '
  'values unstorable. Optional; without it, imports fall back to asking.';

-- Resolution is per-profile and always filtered to active cards, so the
-- index carries profile_id first.
create index if not exists idx_user_cards_last4
  on user_cards (profile_id, last4) where last4 is not null and is_archived = false;

-- The offline sync engine (0034) applies ONLY the columns
-- pandapay.sync_fields_for() names; anything else in a queued push is
-- silently dropped. Edit Card queues last4 like every other field it edits,
-- so without this line a last4 entered while offline would appear to save
-- and then quietly never arrive. Re-declared in full rather than appended
-- to, since the function is a plain CASE over array literals.
create or replace function pandapay.sync_fields_for(p_entity text)
returns text[] language sql immutable as $$
  select case p_entity
    when 'transactions' then array[
      'user_card_id','amount_inr','occurred_at','merchant_name','merchant_vpa',
      'mcc','category_id','rail','status','note'
    ]
    when 'user_cards' then array[
      'nickname','is_default','is_archived','sort_order','credit_limit_inr',
      'statement_day','due_day','anniversary_on','opened_on','autopay_mode','last4'
    ]
    when 'card_overrides' then array[
      'user_card_id','scope','vpa','merchant_name','category_id','reason_note','is_enabled'
    ]
    else null::text[]
  end;
$$;

-- ---------------------------------------------------------------------------
-- 2. merchant_category_rules — what KIND of spend an imported message is.
-- ---------------------------------------------------------------------------
--
-- Nothing mapped a parsed merchant name to a category, so every SMS- and
-- email-imported transaction landed with category_id NULL. Two consequences,
-- both severe and both invisible:
--
--   - Insights showed the user's entire imported history as "Uncategorized".
--   - Reward matching is by category. A NULL category can only ever match a
--     card's base rule, so a 5,000 Swiggy spend imported from SMS was
--     recorded as earning the card's 1% base rate rather than its 5% dining
--     rate. The app under-reported its own value, permanently.
--
-- `merchants` (0007) already maps VPA -> category, but it is keyed by VPA and
-- an SMS carries a NAME. This table is the name-keyed counterpart: catalogue
-- reference data, shipped and centrally fixable, exactly like parser_patterns.
--
-- `pattern` is matched as a SUBSTRING against a normalized merchant name
-- (lowercased, stripped to letters and digits) — the same normalization
-- pandapay.dedupe_hash() and the two reward engines already use, because the
-- string arriving from a bank is 'SWIGGY*ORDER BANGALORE', never 'swiggy'.
create table if not exists merchant_category_rules (
  id            uuid primary key default gen_random_uuid(),
  pattern       text not null,
  category_id   uuid not null references spend_categories(id) on delete cascade,
  -- Lower wins, so a specific pattern can beat a general one: 'amazonpay'
  -- (wallet) must be tried before 'amazon' (online shopping).
  priority      int not null default 100,
  is_active     boolean not null default true,
  notes         text,
  created_at    timestamptz not null default now(),
  unique (pattern, category_id)
);
create index if not exists idx_merchant_category_rules_active
  on merchant_category_rules (priority) where is_active;

comment on table merchant_category_rules is
  'Name-keyed merchant -> category map for SMS/email imports. The VPA-keyed '
  'equivalent is `merchants`; this exists because a bank SMS carries a '
  'merchant name, not a VPA.';

-- Public read: the app resolves categories client-side too (for the offline
-- import path), same posture as spend_categories and parser_patterns.
alter table merchant_category_rules enable row level security;
drop policy if exists merchant_category_rules_public_read on merchant_category_rules;
create policy merchant_category_rules_public_read on merchant_category_rules
  for select using (is_active);

-- Seed: the merchants that dominate Indian card spend. Deliberately modest
-- and high-confidence rather than exhaustive — a wrong mapping is worse than
-- no mapping (it silently miscategorises spend AND mis-prices the reward),
-- and the admin console can extend this without a migration.
--
-- Patterns are stored already-normalized (lowercase, letters+digits only) so
-- the lookup never has to normalize both sides at query time.
insert into merchant_category_rules (pattern, category_id, priority, notes) values
  -- Wallet loads before the parent brand: 'amazonpay' must beat 'amazon'.
  ('amazonpay',    (select id from spend_categories where slug='wallet'),  10, 'wallet load, not shopping'),
  ('paytmwallet',  (select id from spend_categories where slug='wallet'),  10, null),
  ('mobikwik',     (select id from spend_categories where slug='wallet'),  20, null),

  ('swiggyinstamart', (select id from spend_categories where slug='groceries'), 10, 'grocery arm of Swiggy'),
  ('blinkit',      (select id from spend_categories where slug='groceries'), 20, null),
  ('zepto',        (select id from spend_categories where slug='groceries'), 20, null),
  ('bigbasket',    (select id from spend_categories where slug='groceries'), 20, null),
  ('jiomart',      (select id from spend_categories where slug='groceries'), 20, 'must beat the jio rule'),
  ('dmart',        (select id from spend_categories where slug='groceries'), 20, null),
  ('reliancefresh',(select id from spend_categories where slug='groceries'), 20, null),
  ('moreretail',   (select id from spend_categories where slug='groceries'), 20, null),

  ('swiggy',       (select id from spend_categories where slug='dining'),   30, null),
  ('zomato',       (select id from spend_categories where slug='dining'),   30, null),
  ('dominos',      (select id from spend_categories where slug='dining'),   30, null),
  ('mcdonald',     (select id from spend_categories where slug='dining'),   30, null),
  ('starbucks',    (select id from spend_categories where slug='dining'),   30, null),
  ('kfc',          (select id from spend_categories where slug='dining'),   30, null),
  ('eazydiner',    (select id from spend_categories where slug='dining'),   30, null),

  ('amazon',       (select id from spend_categories where slug='online'),   50, null),
  ('flipkart',     (select id from spend_categories where slug='online'),   50, null),
  ('myntra',       (select id from spend_categories where slug='online'),   50, null),
  -- MUST outrank 'jio' below: 'jio' is a substring of 'ajio', so without a
  -- lower priority number here every AJIO purchase is filed as a phone bill.
  ('ajio',         (select id from spend_categories where slug='online'),   40, 'must beat the jio rule'),
  ('nykaa',        (select id from spend_categories where slug='online'),   50, null),
  ('meesho',       (select id from spend_categories where slug='online'),   50, null),
  ('tatacliq',     (select id from spend_categories where slug='online'),   50, null),

  ('irctc',        (select id from spend_categories where slug='travel'),   30, null),
  ('makemytrip',   (select id from spend_categories where slug='travel'),   30, null),
  ('goibibo',      (select id from spend_categories where slug='travel'),   30, null),
  ('cleartrip',    (select id from spend_categories where slug='travel'),   30, null),
  ('yatra',        (select id from spend_categories where slug='travel'),   30, null),
  ('indigo',       (select id from spend_categories where slug='travel'),   30, null),
  ('airindia',     (select id from spend_categories where slug='travel'),   30, null),
  ('vistara',      (select id from spend_categories where slug='travel'),   30, null),
  ('oyorooms',     (select id from spend_categories where slug='travel'),   30, null),
  -- Ordered pair: 'uber' is a substring of 'ubereats', so the food rule has
  -- to win first or every Uber Eats order is filed as travel.
  ('ubereats',     (select id from spend_categories where slug='dining'),   35, 'must beat the uber rule'),
  ('uber',         (select id from spend_categories where slug='travel'),   40, null),
  ('olacabs',      (select id from spend_categories where slug='travel'),   40, null),
  ('rapido',       (select id from spend_categories where slug='travel'),   40, null),

  ('indianoil',    (select id from spend_categories where slug='fuel'),     30, null),
  ('bharatpetroleum', (select id from spend_categories where slug='fuel'),  30, null),
  ('hindustanpetroleum', (select id from spend_categories where slug='fuel'), 30, null),
  ('hpcl',         (select id from spend_categories where slug='fuel'),     30, null),
  ('bpcl',         (select id from spend_categories where slug='fuel'),     30, null),
  ('shell',        (select id from spend_categories where slug='fuel'),     40, null),

  ('netflix',      (select id from spend_categories where slug='entertainment'), 30, null),
  ('hotstar',      (select id from spend_categories where slug='entertainment'), 30, null),
  ('spotify',      (select id from spend_categories where slug='entertainment'), 30, null),
  ('bookmyshow',   (select id from spend_categories where slug='entertainment'), 30, null),
  ('primevideo',   (select id from spend_categories where slug='entertainment'), 30, null),
  ('sonyliv',      (select id from spend_categories where slug='entertainment'), 30, null),
  ('jiocinema',    (select id from spend_categories where slug='entertainment'), 30, null),

  ('pharmeasy',    (select id from spend_categories where slug='health'),   30, null),
  ('netmeds',      (select id from spend_categories where slug='health'),   30, null),
  ('apollopharmacy', (select id from spend_categories where slug='health'), 30, null),
  ('tata1mg',      (select id from spend_categories where slug='health'),   30, null),
  ('practo',       (select id from spend_categories where slug='health'),   30, null),

  ('airtel',       (select id from spend_categories where slug='bills'),    40, null),
  ('jio',          (select id from spend_categories where slug='bills'),    45, 'after jiocinema, which is entertainment'),
  ('vodafoneidea', (select id from spend_categories where slug='bills'),    40, null),
  ('tatapower',    (select id from spend_categories where slug='bills'),    40, null),
  ('adanielectricity', (select id from spend_categories where slug='bills'),40, null),
  ('bescom',       (select id from spend_categories where slug='bills'),    40, null),

  ('nobroker',     (select id from spend_categories where slug='rent'),     30, null),
  ('redgirraffe',  (select id from spend_categories where slug='rent'),     30, null),
  -- Deliberately NO 'cred' rule. CRED is overwhelmingly a credit-card BILL
  -- PAYMENT app, and a card bill is a transfer, not spend — filing it as
  -- rent would inflate every spending total. Worse, 'cred' is a substring
  -- of 'credit', so the rule would also swallow any merchant string
  -- containing "CREDIT". CRED RentPay is real but a minority of traffic,
  -- and a wrong mapping costs more than a missing one.

  ('licindia',     (select id from spend_categories where slug='insurance'),30, null),
  ('policybazaar', (select id from spend_categories where slug='insurance'),30, null),
  ('hdfclife',     (select id from spend_categories where slug='insurance'),30, null),
  ('starhealth',   (select id from spend_categories where slug='insurance'),30, null),

  ('byjus',        (select id from spend_categories where slug='education'),30, null),
  ('unacademy',    (select id from spend_categories where slug='education'),30, null),
  ('udemy',        (select id from spend_categories where slug='education'),30, null),
  ('coursera',     (select id from spend_categories where slug='education'),30, null)
on conflict (pattern, category_id) do nothing;
