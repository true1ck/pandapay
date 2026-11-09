-- Lets the phone queue a lounge visit or a points correction while offline and
-- send it later without it counting twice.
--
-- The app writes these actions on the phone first and a background queue
-- delivers them. A reply can be lost after the server has stored the row, and
-- the queue then sends the same action again. Before this, each repeat added a
-- second lounge visit (using up the free-visit quota) or a second ledger row.
--
-- The app now sends a stable client_mutation_id per action. The unique index
-- makes a repeat find the row that is already there instead of adding another.
-- Rows written by older app versions have no id and are not affected: the index
-- only covers rows that have one.

ALTER TABLE public.lounge_usage
  ADD COLUMN IF NOT EXISTS client_mutation_id uuid;

ALTER TABLE public.points_ledger
  ADD COLUMN IF NOT EXISTS client_mutation_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS uq_lounge_usage_client_mutation
  ON public.lounge_usage (profile_id, client_mutation_id)
  WHERE client_mutation_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_points_ledger_client_mutation
  ON public.points_ledger (profile_id, client_mutation_id)
  WHERE client_mutation_id IS NOT NULL;
