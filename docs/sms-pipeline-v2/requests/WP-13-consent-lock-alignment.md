# Approved shared-learning consent lock alignment

After WP-16 review, the orchestrator approved additive migration `20261112190000_sms_v2_consent_lock_alignment.sql` and real Postgres ordering regressions. Applied 140000 and 160000 migrations are unchanged.

WP-10 template admission and its withdrawal trigger used `hashtext(key)`. The real POST /consents endpoint, legacy feedback and WP-12 admission/withdrawal use `hashtextextended(key,0)`. The template trigger previously serialized its own purge correctly, but template admission could run while the endpoint had already taken its initial consent lock. Both template functions now take the same existing extended lock. The withdrawal trigger retains the old hashtext consent lock as a compatibility barrier between the common extended lock and the unchanged result-revision lock. It drains admissions already executing the old function body when this migration replaces it.

The template withdrawal trigger now handles inserts and updates to granted/granted_at and reads the latest purpose event in the same deterministic order as admission. A backdated false event does not erase a currently granted contribution; changing the latest grant to false erases submitted/shared text and derived orphan templates, and later admissions fail.

Validation:

- Failing-first real Postgres regressions reproduced the lock mismatch and backdated opt-out overpurge before migration.
- Six real PG tests pass: actual extracted POST /consents handler and real legacy purge function, both admission/revoke orderings observed through pg_locks, fresh grant/withdrawal, correction evidence erasure through the real endpoint, latest-event inserts/updates, existing correction idempotence/ownership correction consent race, and draining an in-flight old-lock admission during function rollout.
- SQL consent alignment test passes, including backdated opt-out preservation, update withdrawal, denied late admission and orphan erasure.

No runtime credentials, new endpoint, contract, dependency or rollout control changed. The template function body is copied into a new CREATE OR REPLACE migration, changing only the consent lock expression; the trigger function/registration carries the approved latest-event/update behavior.
