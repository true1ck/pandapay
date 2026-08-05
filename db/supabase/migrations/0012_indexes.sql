-- >>> MIGRATION 0012 — INDEXES ================================================
-- Driven by the concrete query list in the two implementation plans.

-- Device catalogue sync: "give me everything newer than my version".
create index idx_card_products_version   on card_products (data_version) where status = 'published';
create index idx_card_products_issuer    on card_products (issuer_id, status);
create index idx_reward_rules_card_cat   on reward_rules (card_product_id, category_id);
create index idx_cap_rules_card          on cap_rules (card_product_id);
create index idx_milestone_rules_card    on milestone_rules (card_product_id);
create index idx_fee_waiver_rules_card   on fee_waiver_rules (card_product_id);
create index idx_benefits_card_kind      on card_benefits (card_product_id, kind);

-- D1 transaction list (reverse chronological, filtered).
create index idx_txn_profile_time        on transactions (profile_id, occurred_at desc);
create index idx_txn_profile_card_time   on transactions (profile_id, user_card_id, occurred_at desc);
create index idx_txn_dedupe              on transactions (profile_id, dedupe_hash);
create index idx_txn_needs_reconcile     on transactions (profile_id, reward_state)
                                         where reward_state = 'estimated';
create index idx_txn_suboptimal          on transactions (profile_id, occurred_at desc)
                                         where followed_recommendation = false;

-- Tracker recomputation.
create index idx_cap_states_lookup       on cap_states (profile_id, period_end desc);
create index idx_milestone_states_lookup on milestone_states (profile_id, period_end desc);
create index idx_fee_waiver_deadline     on fee_waiver_states (profile_id, period_end);
create index idx_points_expiry           on points_ledger (profile_id, expires_on) where expires_on is not null;

-- Queues.
create index idx_needs_review_pending    on needs_review_items (profile_id, state) where state = 'pending';
create index idx_dupes_pending           on duplicate_candidates (profile_id, state) where state = 'pending';

-- Sync.
create index idx_change_log_pull         on change_log (profile_id, server_seq);
create index idx_change_log_entity       on change_log (profile_id, entity, entity_id);

-- Ingest.
create index idx_inbound_purge           on inbound_emails (purge_after);
create index idx_inbound_keyword         on inbound_emails (policy_keyword_hit) where policy_keyword_hit;
create index idx_parser_active           on parser_patterns (channel, is_active);

-- Crowdsource / console map queries.
create index idx_merchants_vpa_trgm      on merchants using gin (vpa gin_trgm_ops);
create index idx_merchants_name_trgm     on merchants using gin (display_name gin_trgm_ops);
create index idx_merchants_published     on merchants (is_published, category_id);
create index idx_locations_geohash       on merchant_locations (geohash6);
create index idx_locations_bbox          on merchant_locations (grid_lat, grid_lng);
create index idx_contrib_merchant        on merchant_contributions (merchant_id, submitted_on desc);
create index idx_contrib_device_day      on merchant_contributions (device_hash, submitted_on);
create index idx_acceptance_merchant     on acceptance_reports (merchant_id, network);

-- Console queues.
create index idx_alerts_open_ranked      on policy_change_alerts (state, corroboration_score desc, last_signal_at desc);
create index idx_evidence_alert          on policy_alert_evidence (alert_id, signal);
create index idx_snapshots_page          on page_snapshots (source_page_id, captured_at desc);
create index idx_scrape_runs_source      on scrape_runs (source_id, started_at desc);
create index idx_error_reports_pending   on data_error_reports (state, created_at desc);


