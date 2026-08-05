-- >>> MIGRATION 0013 — SCHEDULED JOBS =========================================

select cron.schedule('purge-inbound-emails', '0 3 * * *', $$
  delete from inbound_emails where purge_after < now() and policy_keyword_hit = false;
$$);

select cron.schedule('recompute-merchant-confidence', '30 3 * * *', $$
  select pandapay.recompute_merchant_confidence(id)
    from merchants
   where updated_at > now() - interval '2 days';
$$);

select cron.schedule('detect-rate-divergence', '0 4 * * *', $$
  select pandapay.detect_rate_divergence(0.15);
$$);

select cron.schedule('execute-due-deletions', '0 5 * * *', $$
  select pandapay.execute_account_deletion(id)
    from profiles where deletion_due_at is not null and deletion_due_at < now();
$$);

select cron.schedule('anonymization-audit', '0 6 * * *', $$
  select pandapay.run_anonymization_audit('cron');
$$);


