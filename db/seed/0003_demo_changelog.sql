-- Demo data for H10 What's New. No admin console UI writes changelog_entries
-- yet (out of this plan's scope) — seeds one realistic entry so H10 has
-- something real to render instead of an always-empty state.
-- Idempotent: guarded by a marker check so re-running doesn't duplicate rows.

do $$
begin
  if not exists (select 1 from changelog_entries where title = 'Smarter cap-boundary recommendations') then
    insert into changelog_entries (app_version, title, body_markdown, highlights_data_change) values
      ('1.1.0', 'Smarter cap-boundary recommendations',
       'We fixed how the recommendation engine blends rewards when a purchase crosses a card''s reward-value cap mid-transaction — you''ll see more accurate ₹ estimates near your cap limits.',
       true);
  end if;
end $$;
