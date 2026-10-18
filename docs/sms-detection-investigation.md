# SMS income detection investigation

The Activity screen sums entries classified as income. The screenshot alone cannot identify the exact missing bank format; no real incoming SMS samples were provided.

## Confirmed gaps and changes

- The shared inbox/foreground/background filter rejected all refund and reversal text. It now forwards these messages for parser classification; declined, failed, pending and security messages stay excluded.
- Local parsing required an account token for income and discarded completed reversals. It now accepts explicit completed receipts with bank, savings, wallet or account evidence, or explicit payment/money received language. Wallet income retains its wallet instrument.
- Server credit parsing accepted future/failed credit language before its normal rejection guard. It now requires a completed receipt and rejects pending, initiated, failed, negated and future credits and promotional alerts.
- Shared local/server fixtures cover salary, bank receipts, payment receipts without an account suffix, refunds, reversals, wallet deposits and unsuccessful/future receipts. Positive fixtures also exercise the mobile intake filter.

## Remaining coverage work

Install the updated Android app and API, then rescan the SMS inbox to recover previously filtered messages. The parser version alone does not automatically replay historical intake. Verify SMS permission, background delivery and OEM battery restrictions on a physical device, including app termination and multipart messages. Compare redacted incoming bank SMS against detected entries to add issuer-specific fixtures. Never infer income from a balance or a credit offer.

Still unsupported: card refunds/reversals (currently excluded rather than adjusting original spending), some abbreviated CR/DR formats, some full account-number formats, and multi-transaction messages. Amount extraction still uses the first currency amount; messages listing a balance first need labelled transaction-amount extraction before support. These need dedicated fixtures and reconciliation rules; universal SMS coverage is not established by this patch.
