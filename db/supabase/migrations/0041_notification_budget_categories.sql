-- MIGRATION 0041 — allow the two budget notification categories introduced by
-- migration 0040. The API and Flutter gate already treat these as distinct
-- preferences, but migration 0024's original check constraint did not include
-- them, so budget notifications failed at INSERT time.

alter table notifications drop constraint if exists notifications_category_check;

alter table notifications add constraint notifications_category_check check (
  category in (
    'location', 'caps', 'milestones', 'fee_waivers', 'bills', 'expiry',
    'monthly_report', 'needs_review', 'streak', 'card_added',
    'budget_warning', 'budget_exceeded'
  )
);
