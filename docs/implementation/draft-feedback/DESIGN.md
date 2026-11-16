# AI draft feedback loop (device check, rejection report, replacement)

Scope: the PandaPay side only. Provider routing, quotas and spend belong to the standalone AI service project and are out of scope here.

## Flow

1. Worker finishes a draft (`ai_status='ready'`, `ai_draft` set). Unchanged.
2. A consenting, attested submitter syncs. `sms_v2_template_results` returns the draft and, for each ready draft, records a **delivery** row and returns its opaque `draftId`.
3. The phone checks the draft **on the device against the original SMS** before trusting it. Pass: adopt (current behaviour). Fail: drop the private rule, keep the SMS in manual review, queue a report `{draftId, reason}` in the outbox.
4. `POST /sms/v2/draft-rejections` verifies the delivery belongs to the caller, records the rejection **once** per (profile, layout, draft revision), and in the **same transaction** decides on quarantine and replacement.
5. The submitter's own rejection hides that draft revision from them at once (`status: "rejected"`, no rule).

## Wire contract (already written, in contracts/sms/v2/api)

- `sync.response` `aiResults[]` gains optional `draftId` (lowercase uuid). Present only when `status="ready"` with a `rule`.
- `POST /sms/v2/draft-rejections` request `{draftId, reason}`; `reason` is one of `no_match` (rule does not match the original SMS), `invalid_facts` (matches but the engine refuses or the facts are not plausible for the message), `unsafe_rule` (regex dialect / engine refuses the rule). Response `{status: "recorded" | "already_recorded"}`.
- Errors: 400 `request.draft_rejections.*` codes for bad body, 403 `attestation_required` / `sms_shared_learning_consent_required`, 404 `draft_not_delivered` (unknown id **or** id delivered to someone else: same answer), 429 `rate_limited`, 503 `draft_rejections_unavailable`.
- The report carries only the draft id and reason. Never SMS text.

## Server rules

- **Draft revision.** `sms_v2_unknown_templates.ai_draft_revision bigint not null default 0`. A BEFORE UPDATE trigger bumps it whenever `ai_draft` changes to a different non-null value, so no worker code change is needed.
- **Deliveries.** `sms_v2_draft_deliveries(profile_id, template_hash, draft_revision, draft_id uuid default gen_random_uuid(), delivered_at, PK(profile_id, template_hash, draft_revision), UNIQUE(draft_id))`. Inserted idempotently while returning results, so a lost response gives the same `draftId` on the next sync. Only for submitters who are eligible and currently consenting (same filter as today).
- **Rejections.** `sms_v2_draft_rejections(profile_id, template_hash, draft_revision, reason, created_at, PK(profile_id, template_hash, draft_revision))`. Insert is idempotent; a repeat answers `already_recorded` and changes nothing else.
- **Per-submitter hide.** `sms_v2_template_results` returns `rejected` (no rule, no draftId) for a profile that rejected the *current* revision. The row's revision cursor must still move so the phone learns it.
- **Quarantine with a quorum that cannot starve.** Let `n` = distinct rejecters of the current revision and `d` = distinct eligible, consenting submitters of the layout. Quarantine when `n >= min(3, d)`. A layout seen by one person is replaced after that one person's rejection; a popular layout needs three.
- **Quarantine = replacement.** Quarantine clears `ai_draft`, sets `ai_status='queued'` (reuse the existing requeue columns the worker already understands, including `queued_at`, `lease_id=NULL`, `lease_expires_at=NULL`, a fresh `result_revision`), and increments `ai_user_replacements`. If `ai_user_replacements` is already 2, set `ai_status='failed'`, `failure_code='draft_rejected_by_users'` instead (manual review, admin can requeue). Only act when the row is currently `ready` and still on the reported revision, otherwise the report is recorded and nothing else moves (stale report).
- **Concurrency.** One transaction. Take `pg_advisory_xact_lock(hashtext('sms_v2_template_results'))` first (the existing lock for revision allocation), then lock the template row `FOR UPDATE`. Two simultaneous rejections serialise and cannot enqueue two replacements.
- **Consent.** Take the existing per-profile consent lock (`sms-shared-learning-consent:<profile>`) and require current consent, like `sms_v2_submit_templates`.
- **Rate limit.** Reuse `security.checkRate(req, 'draft-rejections', 1)`.
- **Never** let a client report on a draft revision it was not delivered, and never reveal whether a draft id exists for someone else.

## Phone rules

- Check runs when a `ready` result with a rule arrives (in or right after sync pull) and again on startup for stored results that were never verified. It must be deterministic and fast, and run off the UI isolate if it needs more than a few ms (see docs/PERFORMANCE_RULEBOOK.md).
- Original SMS comes from the local capture for the layout's origin (`TemplateOriginStore` local hashes, `v2_review_items` source keys, `intake.capturedById`). If no original SMS is still available, adopt nothing new and do not report (nothing to check against); the rule stays as it is today.
- Pass: store a verified marker next to `ai:<hash>`. Fail: mark the stored result locally rejected so `ProvisionalStore.overlay` skips it, keep the SMS in review, enqueue an outbox record kind `draft_rejection` keyed by `draftId` (so duplicates collapse), drained like `corrections_sync.dart` (retry/backoff, stops when consent is gone, cleared on consent revoke like `template:sent:*`).
- A newer `draftId`/revision for the same layout clears the local rejection and is checked afresh.
- The server's `rejected` status (admin reject, quarantine, own rejection) drops the private rule as today.
- Public repo: tests use synthetic SMS only (tails `XX1234`, round amounts, invented names).

## Not in scope

Provider exclusion on replacement (service project), budgets and caps, global job caps, retry backoff changes, lease reaper.
