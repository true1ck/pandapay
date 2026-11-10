# Upload queue, refused records and the re-sort (10 Nov 2026, build 146)

**Trigger:** after build 145 reached the owner's iPhone, "Refresh rules" ended with "Refreshed, with a problem": the server "refused 36 records for good" and "could not re-sort your spends". The owner asked why a re-sort needs the server at all, and decided the flow.

## What was found

| Finding | Evidence | Effect |
| --- | --- | --- |
| One bad batch stalled the whole upload queue | The phone sent the oldest 500 records of each kind as one batch and, on any non-200 answer, retried the same batch on a backoff, for ever. Records behind it never went. | Spends stayed "waiting to send"; the re-sort holds those, so it never ran. |
| A sender header like `SBI-UPI`, `HDFC_BK`, `Paytm Bank` | Contract `senderBrand` is `^[A-Z0-9]+$`; `normalizeSenderBrand` only cuts the operator prefix and suffix. The server answered 400 `request.facts_batch.sender_brand_invalid` for the whole batch. | Same stall. |
| A timestamp of year 0000 | Prod log: two `sms_v2 facts:batch failed 22008` (PostgreSQL "date/time field value out of range") at 12:20 and 12:20 UTC. The contract accepts `0000-01-01T00:00:00Z`; the database does not. `parseDate` took any four-digit year. | A 500 for the whole batch, same stall. Which message carried it is not known: the phone database is encrypted. |
| "Refused 36 records for good" is a different thing | Only a per-record `rejected` answer sets a record aside. The sheet text said "it already holds a different version", which is true only for conflicts such as `event_leg_role_conflict` (the server keeps an event's legs and refuses a changed role). | Resending those will be refused again. The codes were never recorded, so the 36 could not be explained. Now they are. |
| The re-sort stopped on its first failure | `HistoryCategoryRecheck.run` rethrew; the runtime swallowed it and wrote one fixed sentence. | One spend that could not be looked at cancelled the whole pass, and the sheet gave no reason. |

## What changed

**Phone**
- `uploadSenderBrand` / `uploadBrandOfSender` (domain `engine/sender.dart`): the brand leaves the phone as `A-Z0-9`, 1 to 32 long; nothing usable is `UNKNOWN`; a header that is only a long number is `NUMBER`, never digits. Used where a source is queued, requeued and corrected, and again when a queued record is sent (records queued by older builds).
- `parseDate` refuses a year outside 2000 to 2100.
- `FactsUpload`: a 400, 413, 422 or 500 for a whole batch no longer repeats. The batch is split in halves until the failing record is alone. A record that fails alone is retried once on the usual wait, then set aside (phone copy kept), but only when the server answers an empty batch with 200 or a sibling was accepted in the same pass: an outage never sets records aside. At most 60 requests per drain are spent looking. 401, 403, 429 and 5xx other than 500 are not blamed on a record.
- Why a record was set aside is counted by reason (`upload:refused-reasons`: the server's code, or `http_500`) and shown on the sheet in words.
- Once (`upload:resent-set-aside-v1`), the refresh sends again every message whose facts the server never accepted, with the spend built on them.
- Re-sort: the refresh works out the new categories on a copy of the database and shows "N spends would move to a better category. Nothing has changed yet." with **Apply to N** and **Not now**. Nothing moves until Apply. A spend that cannot be looked at is counted with a fixed reason word and the rest continue. A stopped pass says why in words, never from an error message.
- Ordinary sync no longer re-sorts by itself (`SmsV2Runtime.autoApplyResort`, default false). **This is a behaviour change for every user:** a new category rule set reaches spends only when someone opens Refresh and taps Apply. Set the flag to true to restore the old behaviour.

**Server** (`api/src/sms_v2/upload_hygiene.js`, used by `facts_route.js`)
- `senderBrand` is cleaned before the contract sees it, so an old build's odd header no longer costs it the batch. The contract itself is unchanged (the Dart validator still refuses it; the route fixture for it is covered by its own test).
- A timestamp outside 1970 to 2199 is a clean 400 `common.timestamp_invalid` naming the field paths, not a 500. No contract change, no migration.

## Not changed, and why

- The server's event merge (`event_leg_role_conflict`, `event_status_transition_invalid`) still refuses an event whose legs were read differently by a newer engine. That is a design decision for the server's merge rule (accept a reading from a newer engine version?), not a bug fix. The reasons now written down will show how many records it affects.
- Learning signals and unknown templates still refuse a brand outside `A-Z0-9{1,32}`, because the brand is inside the template hash. The phone already never sends those.

## Checks

See the commit message and the final report for the run results.
