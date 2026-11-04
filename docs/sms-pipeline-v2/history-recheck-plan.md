# Controlled history checks

Normal capture processes new sources and retries unknown formats when their processing revision changes. A rule download or sync does not authorize rewriting successful historical readings. The initial legacy migration remains a separate operation.

## Testing flow

1. Open History update in the signed-in Debug app and choose a period.
2. Preview the update against a private memory copy. Show the number of automatic categories that change, preserved user categories, missing-text coverage and the before/after migration report.
3. Apply explicitly. Migration handles newly retained legacy sources through the full pipeline. Category updates use persisted v2 facts and events with the current verified bundle.
4. Commit small chunks with durable progress and yield between chunks. A stopped run resumes from its last committed chunk. Account changes stop the operation.
5. Fingerprint the category rules, merchant aliases, taxonomy, personal category inputs, event set and requested period. Keep a compact progress checkpoint. Repeating a completed request reports zero new category changes. A later intentional request can include newly imported sources or a new personal rule.
6. Queue compact category changes through `POST /sms/v2/categories:batch`. It reuses the facts-batch schema with empty source, instrument and event lists. It requires the normal SMS membership/feature/security gates. The server restricts changes to existing ledger categories and active transaction categories. A changed money reading or a newer user category causes the server reading to be re-emitted for the next pull. An older API returns 404 and keeps the queue for retry.

Manual entries, deletions, corrected money facts and explicitly chosen categories retain their authority. Linked refunds use the purchase category even when the purchase falls outside the requested period. A preview is advisory. Apply reads current user choices before each chunk.

An unsent money record keeps its original upload. The category preview reports it as awaiting sync; after sync, another explicit preview includes it. A money edit queued during a category chunk stops that chunk and leaves its checkpoint available for retry. Custom display categories retain their IDs and names even though the frozen ledger schema cannot represent a custom category ID.

A bounded request does not drain interrupted migration sources from another period. Its retained-text and missing-text counts are bounded too. The saved account migration report remains global; the preview labels its before/after amounts as account monthly totals.

## Release flow

The testing action is Debug-only. Fresh monthly messages continue through ordinary capture once. A production historical update needs a separately reviewed migration identifier, supported app version, bounded period, rollout policy, before/after evidence and rollback procedure. Downloading a rule bundle alone never schedules it.

Existing matched v2 facts are immutable. Reinterpreting them under different extraction/linking rules needs a versioned replacement protocol covering retired facts, merged events, server sync and rollback. Category refresh must not silently invent this protocol. Record that follow-up explicitly and keep it outside this category operation.

The full replacement protocol must use a signed migration ID and frozen bundle, construct a separate generation from retained bodies, reapply user corrections and deletions, and compare paired events and totals before activation. The commit must retire replaced facts and event legs on both phone and server, preserve source identity, and retain the prior generation for rollback. A stale device needs a generation check before uploading old projections. This requires a contract review and conformance tests before implementation. Missing message bodies must remain listed as unverified. Current category refresh and initial legacy migration do not replace already-matched facts.

## Manual phone acceptance

After installing a Debug build containing this change and starting an API with the new category endpoint:

1. Open the separate local-test PandaPay app that is signed into the scratch account. Use **History update → Choose dates → Preview history check**. Opening the screen does not apply changes.
2. Review automatic category changes, preserved choices, missing text, unchecked messages, pending sync and account monthly totals. Missing text cannot be reconstructed from a server transaction.
3. Tap **Apply history check**, then confirm **Apply**. Check Activity and the relevant monthly screens. Pausing or leaving the screen stops at a chunk boundary; return and preview/apply to resume.
4. Let normal sync finish. If the preview reported awaiting-sync readings, preview again. Repeat once more after completion: it should report zero new category changes and retain the same amounts/counts.
5. Verify a previously chosen category, a corrected amount, a deletion and a linked refund. Reopen the app and confirm the changes survive. Record any mismatch from logs without exporting raw messages from the phone.

Physical performance and the owner's history acceptance are separate from desktop test evidence. Do not reinstall, delete account storage or apply the preview automatically as part of this checklist.

## Acceptance evidence

Cover dry-run isolation, automatic-category changes, user choices and deletions, linked refunds across the date boundary, repeated apply, interrupted resume, account fencing, backfill uploads and sources arriving after the first migration. Measure the largest chunk in the retained-history fixture and record device performance separately.
