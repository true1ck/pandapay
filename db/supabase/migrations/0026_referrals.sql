-- >>> MIGRATION 0026 — REFERRALS ============================================
--
-- Design 25 "Invite friends": a per-user invite code, a share link, and a
-- list of who joined with what status.
--
-- The mockup states a specific offer — "Give ₹100, get ₹100" — which is a
-- commercial commitment, not a layout decision. It is therefore stored as
-- configuration (`referral_program`) rather than hardcoded into the app, so
-- the amounts and the whole programme's on/off state are a business call
-- that doesn't need a release. The seed below sets exactly the design's
-- ₹100/₹100 so the screen renders as drawn.
--
-- Nothing here pays anyone. `referrals.reward_state` records what a referral
-- has *qualified* for; actually crediting money is a payout system that
-- doesn't exist, and the UI says "earned" only for rows this table marks
-- qualified, never for a row it merely hopes will be.

create table if not exists referral_program (
  id                   int primary key default 1 check (id = 1),
  is_active            boolean not null default false,
  referrer_reward_inr  numeric(10,2) not null default 0,
  referee_reward_inr   numeric(10,2) not null default 0,
  -- What the invited user has to do before either side qualifies. Stored as
  -- text so the copy on screen and the rule stay in one place.
  qualifying_action    text not null default 'first ranked payment',
  updated_at           timestamptz not null default now()
);

insert into referral_program (id, is_active, referrer_reward_inr, referee_reward_inr)
values (1, true, 100, 100)
on conflict (id) do nothing;

-- Publicly readable: the offer terms are the same for everyone and the app
-- needs them before a user is signed in (the invite landing page).
alter table referral_program enable row level security;
drop policy if exists referral_program_public_read on referral_program;
create policy referral_program_public_read on referral_program for select to public using (true);

create table if not exists referral_codes (
  profile_id  uuid primary key references profiles(id) on delete cascade,
  code        text not null unique,
  created_at  timestamptz not null default now()
);

alter table referral_codes enable row level security;
drop policy if exists referral_codes_owner on referral_codes;
create policy referral_codes_owner on referral_codes
  for all using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());

create table if not exists referrals (
  id             uuid primary key default gen_random_uuid(),
  referrer_id    uuid not null references profiles(id) on delete cascade,
  -- Null until the invited person actually creates an account. A pending
  -- row still shows on the referrer's list as "invited", which is honest —
  -- they did send it.
  referee_id     uuid references profiles(id) on delete set null,
  referee_label  text,
  reward_state   text not null default 'pending'
                   check (reward_state in ('pending', 'signed_up', 'qualified')),
  created_at     timestamptz not null default now(),
  qualified_at   timestamptz,
  -- One referral row per invited account, so re-installing doesn't let the
  -- same person be counted twice.
  unique (referrer_id, referee_id)
);

create index if not exists idx_referrals_referrer on referrals (referrer_id, created_at desc);

alter table referrals enable row level security;

-- The referrer sees their own referrals. The referee deliberately does NOT
-- get read access to the row naming them: it carries who invited them,
-- which is the inviter's information, not theirs.
drop policy if exists referrals_referrer on referrals;
create policy referrals_referrer on referrals
  for all using (referrer_id = pandapay.uid()) with check (referrer_id = pandapay.uid());

grant select on referral_program to app_user;
grant select, insert, update, delete on referral_codes to app_user;
grant select, insert, update, delete on referrals to app_user;
