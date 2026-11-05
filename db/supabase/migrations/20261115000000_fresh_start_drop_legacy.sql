-- Fresh-start release: drop the per-message AI job queue and the autonomous
-- SMS learner's run history. Their only writers were the Gemini worker, the
-- AI job routes and the learning worker, all removed from the API.
--
-- Deliberately NOT dropped, because something that stays still uses them:
--   parser_failures, needs_review_items       written by the email import path
--   inbound_emails, forwarding_addresses,
--   imap_connections                          email import (kept, decision D4)
--   sms_learning_feedback, _feedback_events,
--   sms_learning_examples, _settings,
--   sms_ai_learning_proposals                 read by pandapay.run_anonymization_audit,
--                                             the opt-out purge trigger and the
--                                             SMS rule-bundle admin evidence functions
-- Dropping those needs those functions rewritten first.
--
-- No CASCADE: if anything unexpected still depends on these objects, the
-- migration fails instead of removing it silently.

-- Functions that only read or write the tables below.
drop function if exists pandapay.ai_admin_events(uuid);
drop function if exists pandapay.ai_admin_jobs(text, integer);
drop function if exists pandapay.ai_admin_quota();
drop function if exists pandapay.ai_admin_summary();
drop function if exists pandapay.ai_claim_next_job(text, timestamp with time zone, integer, integer);
drop function if exists pandapay.ai_provider_admin_summary(integer, integer);
drop function if exists pandapay.ai_reserve_provider_capacity(integer, integer, integer);
drop function if exists pandapay.sms_learning_candidates(integer);
drop function if exists pandapay.sms_learning_decide(uuid, text, uuid);

-- ai_events references ai_jobs, so it goes first.
drop table if exists public.ai_events;
drop table if exists public.ai_jobs;
drop table if exists public.ai_quota_days;
drop table if exists public.ai_provider_capacity_checks;
drop table if exists public.ai_provider_reservations;
drop table if exists public.sms_learning_candidate_decisions;
drop table if exists public.sms_learning_worker_runs;
