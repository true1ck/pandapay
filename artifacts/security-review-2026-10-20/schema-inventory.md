# Local database dictionary — 2026-10-20

Metadata only: no emails, phone numbers, transaction records, bank messages, or secret values. This is not a production snapshot. Column `?` means nullable.

## pandapay

89 public tables; 88 with RLS enabled.

### abuse_signals

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `device_hash` (text), `signal` (text), `detail` (jsonb), `severity` (integer), `is_blocked` (boolean), `detected_at` (timestamp with time zone).

Policies:

- `abuse_signals_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### acceptance_reports

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `merchant_id` (uuid), `network` (USER-DEFINED), `rail` (USER-DEFINED), `result` (USER-DEFINED), `device_hash` (text), `submitted_on` (date).

Foreign keys:

- `FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE`

Policies:

- `acceptance_reports_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### acceptance_summary

RLS: enabled; indexes: 1.

Columns: `merchant_id` (uuid), `network` (USER-DEFINED), `rail` (USER-DEFINED), `accepted_count` (integer), `declined_count` (integer), `confidence_score` (numeric), `is_published` (boolean), `last_updated_on` (date).

Foreign keys:

- `FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE`

Policies:

- `acceptance_summary_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### admin_audit_log

RLS: enabled; indexes: 1.

Columns: `id` (bigint), `admin_id?` (uuid), `action` (text), `entity` (text), `entity_id?` (uuid), `before_value?` (jsonb), `after_value?` (jsonb), `reason?` (text), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (admin_id) REFERENCES admin_users(id) ON DELETE SET NULL`

Policies:

- `admin_audit_log_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### admin_users

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `email` (USER-DEFINED), `role` (text), `is_active` (boolean), `created_at` (timestamp with time zone).

Policies:

- `admin_users_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### analytics_events

RLS: enabled; indexes: 3.

Columns: `id` (bigint), `profile_id?` (uuid), `event` (text), `props` (jsonb), `app_version?` (text), `platform?` (text), `occurred_at` (timestamp with time zone), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `analytics_admin_read` (SELECT): USING `pandapay.is_admin()`; CHECK `None`.
- `analytics_owner_insert` (INSERT): USING `None`; CHECK `(profile_id = pandapay.uid())`.

### anonymization_audit_runs

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `run_by` (text), `checks_total` (integer), `checks_failed` (integer), `findings` (jsonb), `passed?` (boolean), `git_sha?` (text), `ran_at` (timestamp with time zone).

Policies:

- `anonymization_audit_runs_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### app_status

RLS: enabled; indexes: 1.

Columns: `id` (boolean), `min_supported_version` (text), `maintenance_mode` (boolean), `maintenance_message?` (text), `updated_at` (timestamp with time zone), `sms_backup_import_enabled` (boolean).

Policies:

- `app_status_public_read` (SELECT): USING `true`; CHECK `None`.

### app_versions

RLS: enabled; indexes: 1.

Columns: `platform` (text), `version` (text), `is_minimum_supported` (boolean), `is_latest` (boolean), `release_notes?` (text), `released_at` (timestamp with time zone).

Policies:

- `app_versions_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `app_versions_public_read` (SELECT): USING `true`; CHECK `None`.

### backup_runs

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `kind` (text), `status` (text), `size_bytes?` (bigint), `location?` (text), `error_text?` (text), `ran_at` (timestamp with time zone).

Policies:

- `backup_runs_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### billing_cycle_rules

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `card_product_id` (uuid), `grace_period_days` (integer), `cycle_notes?` (text).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`

Policies:

- `billing_cycle_rules_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `billing_cycle_rules_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM card_products cp
  WHERE ((cp.id = billing_cycle_rules.card_product_id) AND ((cp.status = 'published'::publish_status) OR pandapay.is_admin()))))`; CHECK `None`.

### budget_periods

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `budget_id` (uuid), `period_start` (date), `period_end` (date), `budget_amount_inr` (numeric), `actual_spend_inr` (numeric), `closed_at?` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (budget_id) REFERENCES budgets(id) ON DELETE CASCADE`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `budget_periods_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### budgets

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `scope` (USER-DEFINED), `scope_ref_id?` (uuid), `period` (USER-DEFINED), `amount_inr` (numeric), `starts_on` (date), `rollover` (boolean), `is_active` (boolean), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `budgets_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### cap_rules

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `card_product_id` (uuid), `reward_rule_id?` (uuid), `category_id?` (uuid), `benefit_kind?` (USER-DEFINED), `label` (text), `measure` (USER-DEFINED), `period` (USER-DEFINED), `cap_value` (numeric), `post_cap_unit?` (USER-DEFINED), `post_cap_rate?` (numeric), `resets_on_day?` (integer), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`
- `FOREIGN KEY (category_id) REFERENCES spend_categories(id)`
- `FOREIGN KEY (reward_rule_id) REFERENCES reward_rules(id) ON DELETE CASCADE`

Policies:

- `cap_rules_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `cap_rules_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM card_products cp
  WHERE ((cp.id = cap_rules.card_product_id) AND ((cp.status = 'published'::publish_status) OR pandapay.is_admin()))))`; CHECK `None`.

### cap_states

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `profile_id` (uuid), `user_card_id` (uuid), `cap_rule_id` (uuid), `period_start` (date), `period_end` (date), `consumed` (numeric), `cap_value_snapshot` (numeric), `state` (USER-DEFINED), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (cap_rule_id) REFERENCES cap_rules(id) ON DELETE CASCADE`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE CASCADE`

Policies:

- `cap_states_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### card_benefits

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `card_product_id` (uuid), `kind` (USER-DEFINED), `label` (text), `description?` (text), `quota_count?` (integer), `quota_period?` (USER-DEFINED), `network_program?` (text), `value_estimate_inr?` (numeric), `conditions` (jsonb), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`

Policies:

- `card_benefits_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `card_benefits_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM card_products cp
  WHERE ((cp.id = card_benefits.card_product_id) AND ((cp.status = 'published'::publish_status) OR pandapay.is_admin()))))`; CHECK `None`.

### card_catalogue_changes

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `card_product_id` (uuid), `data_version_after` (bigint), `field_path` (text), `old_value?` (jsonb), `new_value?` (jsonb), `change_summary` (text), `is_user_visible` (boolean), `approved_by?` (uuid), `policy_alert_id?` (uuid), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`
- `FOREIGN KEY (policy_alert_id) REFERENCES policy_change_alerts(id) ON DELETE SET NULL`

Policies:

- `card_catalogue_changes_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `card_catalogue_changes_public_read` (SELECT): USING `true`; CHECK `None`.

### card_overrides

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `profile_id` (uuid), `user_card_id` (uuid), `scope` (text), `vpa?` (USER-DEFINED), `merchant_name?` (text), `category_id?` (uuid), `reason_note?` (text), `is_enabled` (boolean), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (category_id) REFERENCES spend_categories(id)`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE CASCADE`

Policies:

- `card_overrides_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### card_products

RLS: enabled; indexes: 4.

Columns: `id` (uuid), `issuer_id` (uuid), `slug` (text), `name` (text), `network` (USER-DEFINED), `card_type` (USER-DEFINED), `joining_fee_inr` (numeric), `annual_fee_inr` (numeric), `fee_gst_applicable` (boolean), `is_upi_linkable` (boolean), `art_asset?` (text), `art_primary_color?` (text), `base_reward_unit?` (USER-DEFINED), `base_reward_rate?` (numeric), `point_value_inr?` (numeric), `point_value_basis?` (text), `positioning_notes?` (text), `status` (USER-DEFINED), `data_version` (bigint), `verified_at?` (timestamp with time zone), `verified_by?` (uuid), `source_url?` (text), `is_active` (boolean), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone), `apply_url?` (text), `extended_data` (jsonb), `excluded_categories` (ARRAY), `import_source_hash?` (text), `import_source_run_id?` (text), `imported_at?` (timestamp with time zone), `import_transform_version?` (text).

Foreign keys:

- `FOREIGN KEY (issuer_id) REFERENCES issuers(id) ON DELETE RESTRICT`

Policies:

- `card_products_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `card_products_public_read` (SELECT): USING `((status = 'published'::publish_status) OR pandapay.is_admin())`; CHECK `None`.

### card_requests

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `profile_id?` (uuid), `issuer_name` (text), `product_name` (text), `network_guess?` (USER-DEFINED), `image_path?` (text), `request_count` (integer), `state` (USER-DEFINED), `fulfilled_card_id?` (uuid), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (fulfilled_card_id) REFERENCES card_products(id) ON DELETE SET NULL`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE SET NULL`

Policies:

- `card_requests_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `card_requests_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### change_log

RLS: enabled; indexes: 4.

Columns: `id` (bigint), `profile_id` (uuid), `device_id?` (uuid), `entity` (text), `entity_id` (uuid), `op` (USER-DEFINED), `payload` (jsonb), `field_clocks` (jsonb), `client_seq` (bigint), `server_seq` (bigint), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (device_id) REFERENCES user_devices(id) ON DELETE SET NULL`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `change_log_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### changelog_entries

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `app_version` (text), `title` (text), `body_markdown` (text), `highlights_data_change` (boolean), `published_at` (timestamp with time zone).

Policies:

- `changelog_entries_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `changelog_entries_public_read` (SELECT): USING `true`; CHECK `None`.

### contribution_quotas

RLS: enabled; indexes: 1.

Columns: `device_hash` (text), `quota_date` (date), `submission_count` (integer), `rejected_count` (integer).

Policies:

- `contribution_quotas_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### contribution_salts

RLS: enabled; indexes: 1.

Columns: `period_month` (date), `salt` (text), `created_at` (timestamp with time zone).

### data_error_reports

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id?` (uuid), `card_product_id` (uuid), `field_path` (text), `shown_value?` (text), `claimed_value?` (text), `source_url?` (text), `attachment_path?` (text), `state` (USER-DEFINED), `alert_id?` (uuid), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (alert_id) REFERENCES policy_change_alerts(id) ON DELETE SET NULL`
- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE SET NULL`

Policies:

- `error_reports_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `error_reports_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### duplicate_candidates

RLS: enabled; indexes: 4.

Columns: `id` (uuid), `profile_id` (uuid), `txn_a_id` (uuid), `txn_b_id` (uuid), `match_score` (numeric), `match_reason` (text), `state` (USER-DEFINED), `resolution?` (text), `resolved_at?` (timestamp with time zone), `detected_at` (timestamp with time zone), `suppressed_txn_id?` (uuid).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (suppressed_txn_id) REFERENCES transactions(id) ON DELETE SET NULL`
- `FOREIGN KEY (txn_a_id) REFERENCES transactions(id) ON DELETE CASCADE`
- `FOREIGN KEY (txn_b_id) REFERENCES transactions(id) ON DELETE CASCADE`

Policies:

- `duplicate_candidates_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### effective_rate_samples

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `card_product_id` (uuid), `category_id?` (uuid), `period_month` (date), `spend_bucket_inr` (numeric), `observed_reward_inr` (numeric), `observed_rate` (numeric), `device_hash` (text), `submitted_on` (date).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`
- `FOREIGN KEY (category_id) REFERENCES spend_categories(id)`

Policies:

- `effective_rate_samples_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### effective_rate_summary

RLS: enabled; indexes: 1.

Columns: `card_product_id` (uuid), `category_id` (uuid), `period_month` (date), `sample_count` (integer), `distinct_devices` (integer), `observed_rate_mean?` (numeric), `observed_rate_p50?` (numeric), `published_rate?` (numeric), `divergence_pct?` (numeric), `observed_cap_ceiling?` (numeric), `published_cap_value?` (numeric), `is_divergent` (boolean), `alert_raised_at?` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`
- `FOREIGN KEY (category_id) REFERENCES spend_categories(id)`

Policies:

- `effective_rate_summary_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### extraction_proposals

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `snapshot_id?` (uuid), `card_product_id?` (uuid), `model_name?` (text), `proposed_fields` (jsonb), `model_confidence?` (numeric), `evidence_excerpt?` (text), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`
- `FOREIGN KEY (snapshot_id) REFERENCES page_snapshots(id) ON DELETE CASCADE`

Policies:

- `extraction_proposals_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### feature_flags

RLS: enabled; indexes: 1.

Columns: `key` (text), `is_enabled` (boolean), `rollout_percent` (integer), `min_app_version?` (text), `platforms` (ARRAY), `description?` (text), `updated_by?` (uuid), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (updated_by) REFERENCES admin_users(id) ON DELETE SET NULL`

Policies:

- `feature_flags_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `feature_flags_public_read` (SELECT): USING `true`; CHECK `None`.

### fee_waiver_rules

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `card_product_id` (uuid), `threshold_spend_inr` (numeric), `period` (USER-DEFINED), `waives_fee_inr` (numeric), `excluded_categories?` (ARRAY), `notes?` (text), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`

Policies:

- `fee_waiver_rules_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `fee_waiver_rules_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM card_products cp
  WHERE ((cp.id = fee_waiver_rules.card_product_id) AND ((cp.status = 'published'::publish_status) OR pandapay.is_admin()))))`; CHECK `None`.

### fee_waiver_states

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `profile_id` (uuid), `user_card_id` (uuid), `fee_waiver_rule_id` (uuid), `period_start` (date), `period_end` (date), `qualified_spend` (numeric), `waived_at?` (timestamp with time zone), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (fee_waiver_rule_id) REFERENCES fee_waiver_rules(id) ON DELETE CASCADE`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE CASCADE`

Policies:

- `fee_waiver_states_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### forex_rules

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `card_product_id` (uuid), `markup_percent` (numeric), `gst_on_markup` (boolean), `waiver_notes?` (text), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`

Policies:

- `forex_rules_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `forex_rules_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM card_products cp
  WHERE ((cp.id = forex_rules.card_product_id) AND ((cp.status = 'published'::publish_status) OR pandapay.is_admin()))))`; CHECK `None`.

### forwarding_addresses

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `local_part` (USER-DEFINED), `is_active` (boolean), `verified_at?` (timestamp with time zone), `first_email_at?` (timestamp with time zone), `email_count` (integer), `rotated_from?` (uuid), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (rotated_from) REFERENCES forwarding_addresses(id)`

Policies:

- `forwarding_addresses_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### fuel_surcharge_rules

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `card_product_id` (uuid), `surcharge_percent` (numeric), `waiver_percent` (numeric), `min_txn_inr?` (numeric), `max_txn_inr?` (numeric), `monthly_waiver_cap?` (numeric), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`

Policies:

- `fuel_surcharge_rules_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `fuel_surcharge_rules_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM card_products cp
  WHERE ((cp.id = fuel_surcharge_rules.card_product_id) AND ((cp.status = 'published'::publish_status) OR pandapay.is_admin()))))`; CHECK `None`.

### imap_connections

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `email` (USER-DEFINED), `app_password_encrypted` (bytea), `imap_host` (text), `imap_port` (integer), `sender_filter?` (text), `is_active` (boolean), `verified_at?` (timestamp with time zone), `last_poll_at?` (timestamp with time zone), `last_poll_status?` (text), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `imap_connections_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### inbound_emails

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `forwarding_address_id` (uuid), `profile_id` (uuid), `sender` (text), `subject?` (text), `body_text?` (text), `received_at` (timestamp with time zone), `is_known_bank_sender` (boolean), `parsed_ok?` (boolean), `parser_pattern_id?` (uuid), `produced_txn_id?` (uuid), `policy_keyword_hit` (boolean), `purge_after` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (forwarding_address_id) REFERENCES forwarding_addresses(id) ON DELETE CASCADE`
- `FOREIGN KEY (produced_txn_id) REFERENCES transactions(id) ON DELETE SET NULL`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `inbound_emails_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### issuer_emergency_contacts

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `issuer_id` (uuid), `label` (text), `phone` (text), `is_international` (boolean), `is_collect_call` (boolean), `block_procedure?` (text), `sort_order` (integer), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (issuer_id) REFERENCES issuers(id) ON DELETE CASCADE`

Policies:

- `issuer_emergency_contacts_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `issuer_emergency_contacts_public_read` (SELECT): USING `true`; CHECK `None`.

### issuers

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `slug` (text), `name` (text), `short_name?` (text), `logo_url?` (text), `website_url?` (text), `is_active` (boolean), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone).

Policies:

- `issuers_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `issuers_public_read` (SELECT): USING `true`; CHECK `None`.

### kill_switches

RLS: enabled; indexes: 1.

Columns: `key` (text), `is_killed` (boolean), `reason?` (text), `killed_by?` (uuid), `killed_at?` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (killed_by) REFERENCES admin_users(id) ON DELETE SET NULL`

Policies:

- `kill_switches_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `kill_switches_public_read` (SELECT): USING `true`; CHECK `None`.

### lounge_usage

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `profile_id` (uuid), `user_card_id` (uuid), `benefit_id` (uuid), `used_on` (date), `airport?` (text), `logged_manually` (boolean), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (benefit_id) REFERENCES card_benefits(id) ON DELETE CASCADE`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE CASCADE`

Policies:

- `lounge_usage_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### mcc_categories

RLS: enabled; indexes: 1.

Columns: `mcc` (character), `description` (text), `category_id?` (uuid), `is_p2p_indicator` (boolean).

Foreign keys:

- `FOREIGN KEY (category_id) REFERENCES spend_categories(id)`

Policies:

- `mcc_categories_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `mcc_categories_public_read` (SELECT): USING `true`; CHECK `None`.

### merchant_category_rules

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `pattern` (text), `category_id` (uuid), `priority` (integer), `is_active` (boolean), `notes?` (text), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (category_id) REFERENCES spend_categories(id) ON DELETE CASCADE`

Policies:

- `merchant_category_rules_public_read` (SELECT): USING `is_active`; CHECK `None`.

### merchant_conflicts

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `merchant_id` (uuid), `field` (text), `competing_values` (jsonb), `auto_resolved` (boolean), `state` (USER-DEFINED), `resolved_value?` (jsonb), `resolved_by?` (uuid), `resolved_at?` (timestamp with time zone), `detected_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE`
- `FOREIGN KEY (resolved_by) REFERENCES admin_users(id) ON DELETE SET NULL`

Policies:

- `merchant_conflicts_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### merchant_contributions

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `kind` (USER-DEFINED), `vpa?` (USER-DEFINED), `merchant_id?` (uuid), `reported_name?` (text), `reported_mcc?` (character), `reported_category_id?` (uuid), `grid_lat?` (numeric), `grid_lng?` (numeric), `device_hash` (text), `app_version?` (text), `submitted_on` (date), `is_counted` (boolean), `rejected_reason?` (text).

Foreign keys:

- `FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE`
- `FOREIGN KEY (reported_category_id) REFERENCES spend_categories(id)`

Policies:

- `merchant_contributions_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### merchant_locations

RLS: enabled; indexes: 4.

Columns: `id` (uuid), `merchant_id` (uuid), `grid_lat` (numeric), `grid_lng` (numeric), `geohash6` (text), `confirmation_count` (integer), `osm_matched` (boolean), `osm_ref?` (text), `first_seen_on` (date), `last_confirmed_on` (date).

Foreign keys:

- `FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE`

Policies:

- `merchant_locations_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `merchant_locations_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM merchants m
  WHERE ((m.id = merchant_locations.merchant_id) AND ((m.is_published = true) OR pandapay.is_admin()))))`; CHECK `None`.

### merchants

RLS: enabled; indexes: 5.

Columns: `id` (uuid), `vpa` (USER-DEFINED), `display_name?` (text), `mcc?` (character), `category_id?` (uuid), `confidence` (USER-DEFINED), `confidence_score` (numeric), `confirmation_count` (integer), `distinct_device_count` (integer), `is_p2p` (boolean), `is_published` (boolean), `operator_locked` (boolean), `first_seen_on` (date), `last_confirmed_on` (date), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (category_id) REFERENCES spend_categories(id)`

Policies:

- `merchants_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `merchants_public_read` (SELECT): USING `((is_published = true) OR pandapay.is_admin())`; CHECK `None`.

### milestone_rules

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `card_product_id` (uuid), `label` (text), `period` (USER-DEFINED), `threshold_spend_inr` (numeric), `reward_description` (text), `reward_value_inr` (numeric), `is_repeatable` (boolean), `max_repeats?` (integer), `anchor` (text), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`

Policies:

- `milestone_rules_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `milestone_rules_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM card_products cp
  WHERE ((cp.id = milestone_rules.card_product_id) AND ((cp.status = 'published'::publish_status) OR pandapay.is_admin()))))`; CHECK `None`.

### milestone_states

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `profile_id` (uuid), `user_card_id` (uuid), `milestone_rule_id` (uuid), `period_start` (date), `period_end` (date), `qualified_spend` (numeric), `achieved_at?` (timestamp with time zone), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (milestone_rule_id) REFERENCES milestone_rules(id) ON DELETE CASCADE`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE CASCADE`

Policies:

- `milestone_states_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### monthly_reports

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `period_month` (date), `total_spend_inr` (numeric), `rewards_earned_inr` (numeric), `baseline_single_card_inr` (numeric), `extra_earned_inr` (numeric), `value_missed_inr` (numeric), `breakdown` (jsonb), `generated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `monthly_reports_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### needs_review_items

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `source` (USER-DEFINED), `raw_text` (text), `sender?` (text), `received_at` (timestamp with time zone), `parse_error?` (text), `parser_pattern_id?` (uuid), `suggested_amount?` (numeric), `suggested_merchant?` (text), `suggested_card_id?` (uuid), `state` (USER-DEFINED), `resolved_txn_id?` (uuid), `resolved_at?` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (resolved_txn_id) REFERENCES transactions(id) ON DELETE SET NULL`
- `FOREIGN KEY (suggested_card_id) REFERENCES user_cards(id) ON DELETE SET NULL`

Policies:

- `needs_review_items_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### notification_muted_merchants

RLS: enabled; indexes: 1.

Columns: `profile_id` (uuid), `merchant_id` (uuid), `muted_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `notification_muted_merchants_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### notification_preferences

RLS: enabled; indexes: 1.

Columns: `profile_id` (uuid), `category_location` (boolean), `category_caps` (boolean), `category_milestones` (boolean), `category_fee_waivers` (boolean), `category_bills` (boolean), `category_expiry` (boolean), `category_monthly_report` (boolean), `category_needs_review` (boolean), `quiet_hours_start?` (time without time zone), `quiet_hours_end?` (time without time zone), `daily_cap` (integer), `updated_at` (timestamp with time zone), `category_budget_warning` (boolean), `category_budget_exceeded` (boolean).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `notification_preferences_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### notifications

RLS: enabled; indexes: 4.

Columns: `id` (uuid), `profile_id` (uuid), `category` (text), `severity` (text), `title` (text), `body?` (text), `deep_link?` (text), `dedupe_key?` (text), `read_at?` (timestamp with time zone), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `notifications_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### page_snapshots

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `source_page_id` (uuid), `scrape_run_id?` (uuid), `content_hash` (text), `extracted_text` (text), `http_status?` (integer), `captured_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (scrape_run_id) REFERENCES scrape_runs(id) ON DELETE SET NULL`
- `FOREIGN KEY (source_page_id) REFERENCES source_pages(id) ON DELETE CASCADE`

Policies:

- `page_snapshots_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### parser_failures

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `channel` (USER-DEFINED), `issuer_id?` (uuid), `sender_pattern?` (text), `redacted_shape` (text), `app_version?` (text), `occurrences` (integer), `first_seen_at` (timestamp with time zone), `last_seen_at` (timestamp with time zone), `fixed_in_pattern_id?` (uuid).

Foreign keys:

- `FOREIGN KEY (fixed_in_pattern_id) REFERENCES parser_patterns(id) ON DELETE SET NULL`
- `FOREIGN KEY (issuer_id) REFERENCES issuers(id) ON DELETE SET NULL`

Policies:

- `parser_failures_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### parser_patterns

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `issuer_id?` (uuid), `channel` (USER-DEFINED), `sender_pattern?` (text), `regex` (text), `field_map` (jsonb), `version` (integer), `is_active` (boolean), `sample_text?` (text), `success_count` (bigint), `failure_count` (bigint), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (issuer_id) REFERENCES issuers(id) ON DELETE SET NULL`

Policies:

- `parser_patterns_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `parser_patterns_public_read` (SELECT): USING `true`; CHECK `None`.

### partner_clicks

RLS: enabled; indexes: 4.

Columns: `id` (uuid), `profile_id` (uuid), `card_product_id` (uuid), `partner_program_id?` (uuid), `click_token` (text), `placement?` (text), `clicked_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`
- `FOREIGN KEY (partner_program_id) REFERENCES partner_programs(id) ON DELETE SET NULL`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `partner_clicks_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### partner_conversions

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `click_token` (text), `partner_program_id?` (uuid), `status` (text), `commission_inr?` (numeric), `external_ref?` (text), `raw_payload` (jsonb), `reported_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (partner_program_id) REFERENCES partner_programs(id) ON DELETE SET NULL`

Policies:

- `partner_conversions_admin` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### partner_programs

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `issuer_id` (uuid), `partner_name` (text), `affiliate_id?` (text), `token_param` (text), `payout_model` (text), `payout_inr?` (numeric), `is_active` (boolean), `notes?` (text), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (issuer_id) REFERENCES issuers(id) ON DELETE CASCADE`

Policies:

- `partner_programs_admin` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### points_ledger

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `user_card_id` (uuid), `transaction_id?` (uuid), `delta_points` (numeric), `reason` (text), `state` (USER-DEFINED), `expires_on?` (date), `occurred_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE SET NULL`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE CASCADE`

Policies:

- `points_ledger_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### policy_alert_evidence

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `alert_id` (uuid), `signal` (USER-DEFINED), `snapshot_id?` (uuid), `extraction_id?` (uuid), `rate_summary_key?` (jsonb), `inbound_email_id?` (uuid), `data_error_report_id?` (uuid), `excerpt` (text), `weight` (numeric), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (data_error_report_id) REFERENCES data_error_reports(id) ON DELETE SET NULL`
- `FOREIGN KEY (alert_id) REFERENCES policy_change_alerts(id) ON DELETE CASCADE`
- `FOREIGN KEY (extraction_id) REFERENCES extraction_proposals(id) ON DELETE SET NULL`
- `FOREIGN KEY (inbound_email_id) REFERENCES inbound_emails(id) ON DELETE SET NULL`
- `FOREIGN KEY (snapshot_id) REFERENCES page_snapshots(id) ON DELETE SET NULL`

Policies:

- `policy_alert_evidence_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### policy_change_alerts

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `card_product_id` (uuid), `field_path` (text), `field_label` (text), `current_value?` (jsonb), `proposed_value?` (jsonb), `signal_count` (integer), `distinct_signal_kinds` (integer), `corroboration_score` (numeric), `state` (USER-DEFINED), `decided_by?` (uuid), `decided_at?` (timestamp with time zone), `decision_note?` (text), `published_change_id?` (uuid), `force_sync` (boolean), `first_signal_at` (timestamp with time zone), `last_signal_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`
- `FOREIGN KEY (decided_by) REFERENCES admin_users(id) ON DELETE SET NULL`
- `FOREIGN KEY (published_change_id) REFERENCES card_catalogue_changes(id) ON DELETE SET NULL`

Policies:

- `policy_change_alerts_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### profiles

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `email?` (USER-DEFINED), `display_name?` (text), `locale` (text), `currency` (text), `number_format` (text), `travel_mode_active` (boolean), `contributions_opt_in` (boolean), `onboarding_completed_at?` (timestamp with time zone), `deletion_requested_at?` (timestamp with time zone), `deletion_due_at?` (timestamp with time zone), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone), `phone_number?` (text).

Policies:

- `profiles_owner` (ALL): USING `(id = pandapay.uid())`; CHECK `(id = pandapay.uid())`.

### recurring_series

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `merchant_key` (text), `display_name?` (text), `category_id?` (uuid), `user_card_id?` (uuid), `typical_amount_inr` (numeric), `cadence_days` (integer), `occurrence_count` (integer), `first_seen_on` (date), `last_seen_on` (date), `next_expected_on?` (date), `is_active` (boolean), `dismissed_at?` (timestamp with time zone), `detected_at` (timestamp with time zone), `updated_at` (timestamp with time zone), `detection_source` (text), `payment_method?` (text).

Foreign keys:

- `FOREIGN KEY (category_id) REFERENCES spend_categories(id) ON DELETE SET NULL`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE SET NULL`

Policies:

- `recurring_series_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### redemption_options

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `card_product_id?` (uuid), `program_name` (text), `method` (text), `value_per_point_inr` (numeric), `min_points?` (integer), `last_checked_at?` (timestamp with time zone), `notes?` (text).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`

Policies:

- `redemption_options_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `redemption_options_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM card_products cp
  WHERE ((cp.id = redemption_options.card_product_id) AND ((cp.status = 'published'::publish_status) OR pandapay.is_admin()))))`; CHECK `None`.

### referral_codes

RLS: enabled; indexes: 2.

Columns: `profile_id` (uuid), `code` (text), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `referral_codes_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### referral_program

RLS: enabled; indexes: 1.

Columns: `id` (integer), `is_active` (boolean), `referrer_reward_inr` (numeric), `referee_reward_inr` (numeric), `qualifying_action` (text), `updated_at` (timestamp with time zone).

Policies:

- `referral_program_public_read` (SELECT): USING `true`; CHECK `None`.

### referrals

RLS: enabled; indexes: 3.

Columns: `id` (uuid), `referrer_id` (uuid), `referee_id?` (uuid), `referee_label?` (text), `reward_state` (text), `created_at` (timestamp with time zone), `qualified_at?` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (referee_id) REFERENCES profiles(id) ON DELETE SET NULL`
- `FOREIGN KEY (referrer_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `referrals_referrer` (ALL): USING `(referrer_id = pandapay.uid())`; CHECK `(referrer_id = pandapay.uid())`.

### remote_config

RLS: enabled; indexes: 1.

Columns: `key` (text), `value` (jsonb), `description?` (text), `updated_at` (timestamp with time zone).

Policies:

- `remote_config_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `remote_config_public_read` (SELECT): USING `true`; CHECK `None`.

### restore_drills

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `backup_run_id?` (uuid), `restored_ok` (boolean), `row_count_delta?` (jsonb), `duration_seconds?` (integer), `notes?` (text), `ran_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (backup_run_id) REFERENCES backup_runs(id) ON DELETE SET NULL`

Policies:

- `restore_drills_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### reward_rules

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `card_product_id` (uuid), `category_id?` (uuid), `merchant_pattern?` (text), `rail?` (USER-DEFINED), `unit` (USER-DEFINED), `rate` (numeric), `min_txn_inr?` (numeric), `max_txn_inr?` (numeric), `priority` (integer), `conditions` (jsonb), `notes?` (text), `effective_from?` (date), `effective_to?` (date), `created_at` (timestamp with time zone), `excluded_categories` (ARRAY).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE CASCADE`
- `FOREIGN KEY (category_id) REFERENCES spend_categories(id)`

Policies:

- `reward_rules_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `reward_rules_public_read` (SELECT): USING `(EXISTS ( SELECT 1
   FROM card_products cp
  WHERE ((cp.id = reward_rules.card_product_id) AND ((cp.status = 'published'::publish_status) OR pandapay.is_admin()))))`; CHECK `None`.

### schema_migrations

RLS: disabled; indexes: 1.

Columns: `filename` (text), `applied_at` (timestamp with time zone).

### scrape_runs

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `source_id` (uuid), `triggered_by` (text), `status` (USER-DEFINED), `pages_fetched` (integer), `pages_changed` (integer), `started_at?` (timestamp with time zone), `finished_at?` (timestamp with time zone), `duration_ms?` (integer), `error_text?` (text).

Foreign keys:

- `FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE`

Policies:

- `scrape_runs_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### sms_import_batches

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `profile_id` (uuid), `message_count` (integer), `parsed_count` (integer), `failed_count` (integer), `imported_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `sms_import_batches_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### source_pages

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `source_id` (uuid), `url` (text), `page_role` (text), `card_product_id?` (uuid), `selector_hint?` (text), `last_crawled_at?` (timestamp with time zone), `last_changed_at?` (timestamp with time zone), `consecutive_failures` (integer), `is_enabled` (boolean).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE SET NULL`
- `FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE`

Policies:

- `source_pages_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### sources

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `kind` (USER-DEFINED), `issuer_id?` (uuid), `name` (text), `base_url` (text), `robots_allows?` (boolean), `robots_checked_at?` (timestamp with time zone), `tos_reviewed` (boolean), `tos_note?` (text), `crawl_frequency` (interval), `is_enabled` (boolean), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (issuer_id) REFERENCES issuers(id) ON DELETE SET NULL`

Policies:

- `sources_admin_only` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.

### spend_categories

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `slug` (text), `name` (text), `icon?` (text), `is_primary_chip` (boolean), `sort_order` (integer).

Policies:

- `spend_categories_admin_write` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `spend_categories_public_read` (SELECT): USING `true`; CHECK `None`.

### statement_imports

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `profile_id` (uuid), `user_card_id` (uuid), `statement_from` (date), `statement_to` (date), `closing_balance_inr?` (numeric), `points_posted?` (numeric), `txn_count` (integer), `reconciled_count` (integer), `issuer_format_id?` (text), `imported_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE CASCADE`

Policies:

- `statement_imports_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### support_tickets

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `profile_id?` (uuid), `kind` (text), `message` (text), `diagnostics?` (jsonb), `app_version?` (text), `state` (USER-DEFINED), `response?` (text), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE SET NULL`

Policies:

- `tickets_admin_all` (ALL): USING `pandapay.is_admin()`; CHECK `pandapay.is_admin()`.
- `tickets_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### sync_conflicts

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `entity` (text), `entity_id` (uuid), `field` (text), `local_value?` (jsonb), `server_value?` (jsonb), `chosen_value?` (jsonb), `strategy` (USER-DEFINED), `device_id?` (uuid), `user_acknowledged` (boolean), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (device_id) REFERENCES user_devices(id) ON DELETE SET NULL`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `sync_conflicts_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### sync_cursors

RLS: enabled; indexes: 1.

Columns: `device_id` (uuid), `profile_id` (uuid), `last_server_seq` (bigint), `last_pushed_at?` (timestamp with time zone), `last_pulled_at?` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (device_id) REFERENCES user_devices(id) ON DELETE CASCADE`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `sync_cursors_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### transaction_observations

RLS: enabled; indexes: 4.

Columns: `id` (uuid), `profile_id` (uuid), `transaction_id` (uuid), `source` (USER-DEFINED), `source_key?` (text), `external_ref?` (text), `observed_at` (timestamp with time zone), `payload_hash?` (text), `metadata` (jsonb), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE`

Policies:

- `transaction_observations_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### transaction_splits

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `transaction_id` (uuid), `user_card_id?` (uuid), `category_id?` (uuid), `amount_inr` (numeric), `note?` (text).

Foreign keys:

- `FOREIGN KEY (category_id) REFERENCES spend_categories(id)`
- `FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE SET NULL`

Policies:

- `splits_owner` (ALL): USING `(EXISTS ( SELECT 1
   FROM transactions t
  WHERE ((t.id = transaction_splits.transaction_id) AND (t.profile_id = pandapay.uid()))))`; CHECK `(EXISTS ( SELECT 1
   FROM transactions t
  WHERE ((t.id = transaction_splits.transaction_id) AND (t.profile_id = pandapay.uid()))))`.

### transactions

RLS: enabled; indexes: 10.

Columns: `id` (uuid), `profile_id` (uuid), `user_card_id?` (uuid), `amount_inr` (numeric), `occurred_at` (timestamp with time zone), `merchant_name?` (text), `merchant_vpa?` (USER-DEFINED), `mcc?` (character), `category_id?` (uuid), `rail` (USER-DEFINED), `source` (USER-DEFINED), `status` (USER-DEFINED), `reward_state` (USER-DEFINED), `expected_points?` (numeric), `expected_value_inr?` (numeric), `confirmed_points?` (numeric), `confirmed_value_inr?` (numeric), `reconciled_at?` (timestamp with time zone), `statement_import_id?` (uuid), `recommended_card_id?` (uuid), `optimal_value_inr?` (numeric), `followed_recommendation?` (boolean), `dedupe_hash?` (text), `is_split_parent` (boolean), `parent_txn_id?` (uuid), `raw_source_ref?` (uuid), `note?` (text), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone), `source_key?` (text), `instrument` (USER-DEFINED), `entry_kind` (USER-DEFINED), `state_applied?` (boolean), `is_backfill` (boolean), `source_account_last4?` (text).

Foreign keys:

- `FOREIGN KEY (category_id) REFERENCES spend_categories(id)`
- `FOREIGN KEY (parent_txn_id) REFERENCES transactions(id) ON DELETE CASCADE`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`
- `FOREIGN KEY (recommended_card_id) REFERENCES user_cards(id) ON DELETE SET NULL`
- `FOREIGN KEY (user_card_id) REFERENCES user_cards(id) ON DELETE SET NULL`

Policies:

- `transactions_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### user_cards

RLS: enabled; indexes: 2.

Columns: `id` (uuid), `profile_id` (uuid), `card_product_id` (uuid), `nickname?` (text), `credit_limit_inr?` (numeric), `statement_day?` (integer), `due_day?` (integer), `opened_on?` (date), `anniversary_on?` (date), `points_balance` (numeric), `points_balance_state` (USER-DEFINED), `sort_order` (integer), `is_default` (boolean), `is_archived` (boolean), `archived_at?` (timestamp with time zone), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone), `autopay_mode` (text), `last4?` (character), `annual_fee_override_inr?` (numeric).

Foreign keys:

- `FOREIGN KEY (card_product_id) REFERENCES card_products(id) ON DELETE RESTRICT`
- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `user_cards_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### user_consents

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `profile_id` (uuid), `purpose` (text), `policy_version` (text), `granted` (boolean), `granted_at` (timestamp with time zone), `revoked_at?` (timestamp with time zone), `source_screen?` (text), `ip_country?` (text).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `user_consents_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### user_devices

RLS: enabled; indexes: 1.

Columns: `id` (uuid), `profile_id` (uuid), `device_label?` (text), `platform` (text), `app_version?` (text), `os_version?` (text), `push_token?` (text), `last_seen_at?` (timestamp with time zone), `catalogue_version_seen` (bigint), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `user_devices_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

### user_settings

RLS: enabled; indexes: 1.

Columns: `profile_id` (uuid), `settings` (jsonb), `revision` (bigint), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE`

Policies:

- `user_settings_owner` (ALL): USING `(profile_id = pandapay.uid())`; CHECK `(profile_id = pandapay.uid())`.

## pandapay_auth

7 public tables; 0 with RLS enabled.

### auth_audit

RLS: disabled; indexes: 6.

Columns: `id` (uuid), `user_id?` (uuid), `action` (character varying), `status` (character varying), `ip_address?` (character varying), `user_agent?` (text), `device_id?` (character varying), `meta?` (jsonb), `created_at` (timestamp with time zone), `risk_level?` (character varying).

Foreign keys:

- `FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL`

### oauth_accounts

RLS: disabled; indexes: 3.

Columns: `id` (uuid), `user_id` (uuid), `provider` (character varying), `provider_user_id` (character varying), `created_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE`

### otp_codes

RLS: disabled; indexes: 3.

Columns: `id` (uuid), `phone_number` (character varying), `otp_hash` (character varying), `expires_at` (timestamp with time zone), `attempt_count` (integer), `created_at` (timestamp with time zone).

### otp_requests

RLS: disabled; indexes: 4.

Columns: `id` (uuid), `phone_number?` (character varying), `email?` (character varying), `type` (character varying), `country_code?` (character varying), `otp_hash` (character varying), `expires_at` (timestamp with time zone), `consumed_at?` (timestamp with time zone), `deleted` (boolean), `attempt_count` (integer), `created_at` (timestamp with time zone).

### refresh_tokens

RLS: disabled; indexes: 6.

Columns: `id` (uuid), `user_id` (uuid), `token_id` (uuid), `token_hash` (character varying), `device_id` (character varying), `user_agent?` (text), `ip_address?` (character varying), `created_at` (timestamp with time zone), `expires_at` (timestamp with time zone), `last_used_at` (timestamp with time zone), `revoked_at?` (timestamp with time zone), `reuse_detected_at?` (timestamp with time zone), `rotated_from_id?` (uuid).

Foreign keys:

- `FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE`
- `FOREIGN KEY (rotated_from_id) REFERENCES refresh_tokens(id) ON DELETE SET NULL`

### user_devices

RLS: disabled; indexes: 6.

Columns: `id` (uuid), `user_id` (uuid), `device_identifier?` (text), `device_platform` (text), `device_model?` (text), `os_version?` (text), `app_version?` (text), `language_code?` (text), `timezone?` (text), `fcm_token?` (text), `first_seen_at` (timestamp with time zone), `last_seen_at?` (timestamp with time zone), `is_active` (boolean), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone).

Foreign keys:

- `FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE`

### users

RLS: disabled; indexes: 1.

Columns: `id` (uuid), `phone_number?` (character varying), `email?` (character varying), `country_code?` (character varying), `name?` (character varying), `created_at` (timestamp with time zone), `updated_at` (timestamp with time zone), `last_login_at?` (timestamp with time zone), `is_active` (boolean), `deleted` (boolean), `is_phone_verified` (boolean), `is_email_verified` (boolean), `role` (USER-DEFINED), `token_version` (integer), `avatar_url?` (text), `language?` (character varying), `timezone?` (character varying).

## Migration drift

67 SQL migration files in source; 48 ledger entries (includes seeds). Pending filenames:

- `0013_cron_jobs.sql` — intentionally skipped by runner
- `0037_get_profile_by_forwarding_address.sql`
- `0040_budgets_instruments_recurring.sql`
- `0041_card_import_provenance.sql`
- `0041_notification_budget_categories.sql`
- `0042_card_network_unknown.sql`
- `0043_card_product_network_variants.sql`
- `0043_ensure_pgcrypto_extensions.sql`
- `0044_card_upi_linkability_invariant.sql`
- `0044_fix_dedupe_hash_extension_schema.sql`
- `0045_grant_app_user_extensions_usage.sql`
- `0045_remove_unenforceable_reward_triggers.sql`
- `0047_recurring_user_edits.sql`
- `20260908201228_statement_transactions_ingest.sql`
- `20261007120000_allow_cardless_credit_card_sms.sql`
- `20261014120000_dedupe_user_cards.sql`
- `20261014173000_dedupe_catalogue_rules.sql`
- `20261017120000_axis_flipkart_caps.sql`
- `20261018120000_non_card_statement_imports.sql`
- `20261019120000_merchant_mcc_verification.sql`
- `20261019123000_add_emi_category.sql`
- `20261019140000_user_categories_sync.sql`
- `20261019143000_transaction_user_categories.sql`
- `20261019144500_sync_user_category_field.sql`
- `20261020120000_transaction_recorded_notifications.sql`
