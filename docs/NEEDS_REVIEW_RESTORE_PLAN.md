# Needs review: bring back Auto-resolved, History and AI progress

Status: built 10 Nov 2026 (Auto, History, AI progress header, Move back to review, failed-AI count). Not built: a Retry button for failed AI reviews, because the server has no way for a phone to ask for a failed draft to be tried again. Old receipts from before 5 Nov are not recoverable.

## What the old screen had (and where it went)

The old Needs review screen (`app/lib/features/activity/needs_review_screen.dart`, deleted in `0364192b`, 5 Nov 2026, "delete legacy SMS parser, uploads and review") had:

| Part | What it showed | Last good version |
| --- | --- | --- |
| Two tabs | "Needs Review (n)" and "Auto-Resolved (n)" | `e3669410` (28 Oct) |
| Auto-Resolved card | Title, amount, category, date, the original SMS text, confidence. Buttons: Edit transaction, Change category, Move to Needs Review (the revert), delete | `ca24a8bb` (27 Oct) |
| Durable receipt | `AutoResolvedHistoryRepository`: one row per settled item, kept after the review row was deleted so the user can see and undo what the engine decided. `isUserModified` marked rows the user changed | `e3669410` |
| AI progress header | "N queued, N in progress, N failed", a progress bar, "AI review finished. Auto-resolved results are in Auto-Resolved", and a "Retry failed AI reviews (n)" button | `b2fd1547`, `1dd6f16f`, `f8becd80` (27 Oct) |
| Bundles, filters | Message bundles, month and category filters, custom date filter | `503484e8`, `6f43a867`, `37af19cf` |

No commit on any branch has a separate tab for items the user resolved by hand. The only "history" the old screen kept was the Auto-Resolved list, with user-modified rows flagged. The History tab for manual resolutions is therefore new work, built on the v2 data below.

## What the current app has

`review_inbox_screen.dart`: tabs "Needs review", "AI suggested" (only when an open item has an AI reading), "Dismissed" (with undo). "Your corrections" screen. `SmsTransactionActions` for editing a transaction. `AiStatusReader` knows which formats are awaiting an AI answer (`template:sent:*`, `ai:*` in `v2_sync_state`). Bulk changes can be undone (`v2_bulk_changes`).

Missing: a list of what the engine settled without asking, a list of what the user settled by hand, and an AI progress header.

## Design

All three read from data the v2 pipeline already writes. No receipt table is copied back from the legacy code.

1. **Auto-resolved tab.** A read of recent facts the engine accepted with no review step (rule or solver, confidence at or above the accept line), newest first. Card = the old card: title, amount, category, date, the source SMS, who decided (rule id or "AI rule"). Actions: Edit (existing `SmsTransactionActions`), Change category, Move to Needs review (re-queue the source as a review item and mark the event unconfirmed).
2. **History tab.** What the user settled by hand: review items with status resolved or dismissed, plus corrections made from Edit. Each row shows what the user chose and when, with Edit again and Undo. Backed by `v2_review_items.status` and the corrections log; a small `v2_review_history` table is added only if those two cannot reconstruct the previous state.
3. **AI progress header.** Counts for messages sent for AI drafting, awaiting an answer, answered, and failed, with a progress bar while any are pending, and a retry button for failed ones. Backed by `AiStatusReader` and the upload queue state.

Tab order: Needs review, AI suggested (when present), Auto-resolved, History, Dismissed.

## Checks

- Widget tests per tab with fakes; golden test for the card (Alchemist).
- A test that a Move to Needs review round trip restores the original state.
- Performance rulebook applies: every list reads a bounded, indexed query, never the whole history on the UI isolate.
- Real-phone check on the Dev app before any release.

## Open questions for the owner

1. Is the History tab meant to include dismissed items, or only items settled with a category or edit?
2. How many days back should Auto-resolved and History reach (proposal: 90 days, 200 rows per tab)?
3. Should "Move to Needs review" also ask Gemini again, or only re-queue it for the person?

## Gemini status bar (added 10 Nov 2026)

Needs review now shows a bar on every tab that says whether Gemini is working.
The phone asks `GET /sms/v2/ai-status` (counts only, from the new
`pandapay.sms_v2_ai_summary()` function; migration `20261120020000`) every 30 s
while the screen is open, and shows one of: not receiving your formats (this
phone is not counted: no App Check, not a listed tester, so layouts are held and
never queued), working (N drafting, N waiting, N done, N failed), could not
draft, on and idle, or status unavailable (server unreachable; falls back to
what the phone knows).

Why it exists: on 10 Nov the owner's phone had sent 12 formats that were all
stored `held`, because the account was not in `sms_v2_testers` and the sideloaded
build has no App Check token. `sms_v2_template_results` also returns nothing to a
phone that is not counted, so nothing could ever come back and nothing said so.
