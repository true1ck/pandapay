-- >>> MIGRATION 0036 — IMPORT IDEMPOTENCY + SMS BACKUP KILL SWITCH ===========
--
-- smsextractionimple.md §0.1 D5, and Task S-1b's kill switch.
--
-- ============================================================================
-- THE BUG (D5)
-- ============================================================================
-- `detectDuplicates()` (api/src/index.js) finds a duplicate only when the two
-- candidate rows have a DIFFERENT `source`:
--
--     AND source != $4
--
-- That is exactly right for what it was written to catch — the same real-world
-- swipe arriving once as a bank SMS and again in a statement PDF. It is also
-- why importing the SAME SMS backup file twice is completely undetected: both
-- runs insert with source='sms', so every row fails the `source !=` test and
-- the user silently ends up with two of everything. Spend totals, cap
-- progress, milestone progress and fee-waiver progress all double.
--
-- Widening `detectDuplicates` to match same-source rows is the wrong fix: it
-- would start flagging genuine repeat purchases (two ₹120 coffees on the same
-- day at the same merchant is a real thing, not a duplicate) and would put
-- them in front of the user as a review chore.
--
-- The right fix is an identity, not a heuristic. A backup file's messages
-- carry a stable natural key — sender + body + original timestamp — so the
-- SECOND import of the same file is recognisably the same message rather than
-- a suspiciously similar one. `source_key` stores a hash of that, and the
-- unique index makes a repeat insert a no-op at the database level rather
-- than something every call site has to remember to check.
--
-- Hashed rather than stored raw on purpose: the natural key contains the full
-- SMS body, and `transactions` is not a table that should hold message text.
-- The hash is computed server-side (api/src/index.js) so a client cannot
-- forge a collision to suppress someone else's row; it is salted with the
-- profile id so the same bank alert on two accounts never collides.
--
-- ============================================================================
-- THE KILL SWITCH
-- ============================================================================
-- Task S-1b surfaces the SMS backup import in the prod build. The blast radius
-- of a bad import is the user's whole transaction history, and the input is a
-- file this codebase does not control the shape of. `app_status` (0020)
-- already exists and is already read on launch, so it is the cheapest place to
-- put a flag that can disable the entry point without shipping a release.
-- Defaults to true — the feature ships on, and the flag exists to turn it off.

begin;

-- ---------------------------------------------------------------------------
-- 1. transactions.source_key
-- ---------------------------------------------------------------------------

alter table transactions
  add column if not exists source_key text;

comment on column transactions.source_key is
  'Server-computed sha256 of (profile_id, sender, body, occurred_at) for '
  'transactions created from an imported message. Null for manually-entered '
  'transactions and for anything created before migration 0036. Exists so a '
  're-import of the same SMS backup file is a no-op rather than a silent '
  'doubling — see the unique index below.';

-- Partial, so the (very many) manual transactions with a null source_key are
-- not forced into the index and do not collide with each other. Scoped by
-- profile so two users importing the same bank template never interfere.
create unique index if not exists uq_transactions_source_key
  on transactions (profile_id, source_key)
  where source_key is not null;

-- ---------------------------------------------------------------------------
-- 2. app_status.sms_backup_import_enabled
-- ---------------------------------------------------------------------------

alter table app_status
  add column if not exists sms_backup_import_enabled boolean not null default true;

comment on column app_status.sms_backup_import_enabled is
  'Kill switch for the SMS backup-file import entry point (Task S-1b). Set '
  'false to hide the Import Hub tile in shipped builds without a release. '
  'Does not disable the API — an import already in flight completes.';

commit;
